-- Main panel: your AniList anime lists, with progress, status, and score editing.

local render

local STATUSES = { "Watching", "Planning", "Completed", "Repeating", "Paused", "Dropped" }

local STATUS_FROM_API = {
    CURRENT = "Watching", PLANNING = "Planning", COMPLETED = "Completed",
    REPEATING = "Repeating", PAUSED = "Paused", DROPPED = "Dropped",
}
local STATUS_TO_API = {}
for api, name in pairs(STATUS_FROM_API) do STATUS_TO_API[name] = api end

-- Order and icons of the status buttons under the selected anime.
local STATUS_BUTTONS = {
    { "Watching", "player-play" },
    { "Planning", "clock" },
    { "Completed", "checks" },
    { "Dropped", "trash" },
    { "Paused", "player-pause" },
    { "Repeating", "repeat" },
}

local MAX_TITLE_CHARS = 50
local COVER_SIZE = 96
local COVER_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state"))
    .. "/noctalia/anilist/covers/media"

local SEARCH_PANEL = "HotZi/anilistTracker:searchPanel"
local ACTIVITY_PANEL = "HotZi/anilistTracker:activityPanel"

local LIST_QUERY = [[
query ($userId: Int) {
  MediaListCollection(userId: $userId, type: ANIME) {
    lists {
      status
      entries {
        id
        progress
        score
        media {
          id
          title { english romaji }
          episodes
          status
          nextAiringEpisode { episode timeUntilAiring }
          coverImage { medium }
        }
      }
    }
  }
}
]]

local SAVE_ENTRY = [[
mutation ($id: Int, $status: MediaListStatus, $progress: Int, $score: Float) {
  SaveMediaListEntry(id: $id, status: $status, progress: $progress, score: $score) { id }
}
]]

local animeByStatus = {}
for _, name in ipairs(STATUSES) do animeByStatus[name] = {} end

local statusIndex = 0 -- 0-based, matches ui.select
local animeIndex = 0
local needsLogin = false -- no token, or AniList rejected the saved one
local panelOpen = false

local coverPaths = {}
local coverPending = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Builds a child list, skipping nils so optional widgets don't leave holes.
local function compact(...)
    local out = {}
    for i = 1, select("#", ...) do
        local child = select(i, ...)
        if child ~= nil then table.insert(out, child) end
    end
    return out
end

local function truncate(text, maxChars)
    if #text <= maxChars then return text end
    return string.sub(text, 1, maxChars - 3) .. "..."
end

local function savedToken()
    local token = noctalia.state.get("anilist_token")
    if type(token) ~= "string" then return nil end
    token = noctalia.string.trim(token)
    return token ~= "" and token or nil
end

-- POSTs a GraphQL request with the saved token; callback(data, res) gets nil
-- data on any failure.
local function gql(query, variables, callback)
    noctalia.http({
        url = "https://graphql.anilist.co",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "Authorization: Bearer " .. (savedToken() or ""),
        },
        body = noctalia.json.encode({ query = query, variables = variables }),
    }, function(res)
        local parsed = res and res.ok and res.status == 200 and noctalia.json.decode(res.body)
        callback(parsed and parsed.data or nil, res)
    end)
end

local function cover(mediaId, url)
    if url and url ~= "" and coverPaths[mediaId] == nil and not coverPending[mediaId] then
        local path = `{COVER_DIR}/{mediaId}.jpg`
        if noctalia.fileExists(path) then
            coverPaths[mediaId] = path
        else
            noctalia.mkdirAll(COVER_DIR)
            coverPending[mediaId] = true
            noctalia.download(url, path, function(success)
                coverPending[mediaId] = nil
                if success then
                    coverPaths[mediaId] = path
                    render()
                end
            end)
        end
    end

    if coverPaths[mediaId] then
        return ui.image({ width = COVER_SIZE, height = COVER_SIZE, path = coverPaths[mediaId], fit = "cover", radius = 6 })
    end
    return ui.box({ width = COVER_SIZE, height = COVER_SIZE, fill = "surface_variant", radius = 6 })
end

local function currentStatus()
    return STATUSES[statusIndex + 1]
end

local function selectedAnime()
    return animeByStatus[currentStatus()][animeIndex + 1]
end

-- Re-selects the anime last picked in this list, if it's still there.
local function restoreSelection()
    local status = currentStatus()
    local savedId = noctalia.state.get("anilist_selected_id_" .. status)
    animeIndex = 0
    for i, anime in ipairs(animeByStatus[status]) do
        if anime.id == savedId then animeIndex = i - 1 end
    end
end

local function rememberSelection()
    local anime = selectedAnime()
    noctalia.state.set("anilist_selected_id_" .. currentStatus(), anime and anime.id or nil)
end

-- ── AniList sync ─────────────────────────────────────────────────────────────

local function saveEntry(entryId, fields, successMessage)
    if not savedToken() then return end
    fields.id = entryId
    gql(SAVE_ENTRY, fields, function(data)
        if not data then
            noctalia.notifyError("AniList Sync Failed", "Could not sync your change to AniList.")
        elseif successMessage then
            noctalia.notify("AniList", successMessage)
        end
    end)
end

local function storeLists(lists)
    for _, name in ipairs(STATUSES) do animeByStatus[name] = {} end

    for _, list in ipairs(lists) do
        local status = STATUS_FROM_API[list.status]
        if status then
            for _, entry in ipairs(list.entries) do
                local media = entry.media
                table.insert(animeByStatus[status], {
                    id = entry.id,
                    mediaId = media.id,
                    name = truncate(media.title.english or media.title.romaji, MAX_TITLE_CHARS),
                    progress = entry.progress or 0,
                    episodes = media.episodes or 0,
                    airingStatus = media.status or "UNKNOWN",
                    nextAiringEpisode = media.nextAiringEpisode,
                    coverUrl = media.coverImage and media.coverImage.medium,
                    score = entry.score or 0,
                })
            end
        end
    end
end

local function fetchLists()
    gql("query { Viewer { id } }", {}, function(data, res)
        if not data then
            if res and (res.status == 400 or res.status == 401) then
                needsLogin = true -- expired or revoked token
                render()
            else
                noctalia.notifyError("AniList Sync Failed", "Could not reach AniList.")
            end
            return
        end

        gql(LIST_QUERY, { userId = data.Viewer.id }, function(listData)
            if not (listData and listData.MediaListCollection) then
                noctalia.notifyError("AniList Error", "Failed to retrieve your anime lists.")
                return
            end
            storeLists(listData.MediaListCollection.lists)
            restoreSelection()
            render()
        end)
    end)
end

-- ── list actions ─────────────────────────────────────────────────────────────

local function changeProgress(delta)
    local anime = selectedAnime()
    if not anime then return end

    local progress = anime.progress + delta
    if progress < 0 or (anime.episodes > 0 and progress > anime.episodes) then return end

    anime.progress = progress
    saveEntry(anime.id, { progress = progress })
    render()
end

local function moveSelectedTo(newStatus)
    local oldStatus = currentStatus()
    local anime = selectedAnime()
    if newStatus == oldStatus or not anime then return end

    local oldList = animeByStatus[oldStatus]
    table.remove(oldList, animeIndex + 1)
    table.insert(animeByStatus[newStatus], anime)
    saveEntry(anime.id, { status = STATUS_TO_API[newStatus] })

    -- the old list remembers its neighbouring entry; the view follows the anime
    animeIndex = math.min(animeIndex, math.max(#oldList - 1, 0))
    rememberSelection()

    statusIndex = table.find(STATUSES, newStatus) - 1
    noctalia.state.set("anilist_selected_status", statusIndex)
    animeIndex = #animeByStatus[newStatus] - 1
    rememberSelection()

    render()
end

local function setScore(value)
    local anime = selectedAnime()
    local score = tonumber(value)
    if not score then
        noctalia.notify("Invalid score", "Please enter a number.")
        return
    end
    if not anime then return end

    anime.score = score
    saveEntry(anime.id, { score = score }, "Score updated")
    render()
end

-- ── views ────────────────────────────────────────────────────────────────────

local function airingLabel(anime)
    local upcoming = anime.nextAiringEpisode
    if anime.airingStatus ~= "RELEASING" or not upcoming then return nil end

    local seconds = upcoming.timeUntilAiring
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    return ui.label({ text = `Episode: {upcoming.episode} in {days}d {hours}h {minutes}m`, fontSize = 14 })
end

local function scoreLabel(score)
    return ui.label({ text = score == 0 and "Not rated yet" or `Your score: {score}` })
end

local function statusButton(status, glyph)
    return ui.button({
        glyph = glyph,
        variant = currentStatus() == status and "primary" or "outline",
        onClick = function() moveSelectedTo(status) end,
    })
end

local function renderSelected(list)
    local options = {}
    for i, anime in ipairs(list) do
        table.insert(options, `{i}. {anime.name} ({anime.progress} ep)`)
    end
    animeIndex = math.min(animeIndex, #list - 1)
    local anime = list[animeIndex + 1]

    local statusButtons = {}
    for _, button in ipairs(STATUS_BUTTONS) do
        table.insert(statusButtons, statusButton(button[1], button[2]))
    end

    return ui.column({ gap = 12 }, {
        ui.select({ options = options, selectedIndex = animeIndex, onChange = "onAnimeSelect", width = 320 }),

        ui.row({ align = "center", gap = 12 }, {
            cover(anime.mediaId, anime.coverUrl),
            ui.column({ gap = 6 }, compact(
                ui.label({ text = anime.name, fontSize = 16, fontWeight = "bold" }),
                ui.label({ text = "Anime Status: " .. anime.airingStatus, fontSize = 14 }),
                airingLabel(anime),
                scoreLabel(anime.score),
                ui.button({ glyph = "info-circle", text = "Details", variant = "ghost", onClick = "onOpenDetails" })
            )),
        }),

        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = "Change Status:", fontSize = 14 }),
            ui.row({ align = "center", gap = 6 }, {
                ui.label({ text = "⭐" }),
                ui.input({ key = `score-{anime.id}`, placeholder = "Score", onSubmit = setScore }),
            }),
        }),

        ui.row({ align = "center", justify = "space_between" }, {
            ui.row({ align = "center", gap = 6 }, statusButtons),
            ui.row({ align = "center", gap = 10 }, {
                ui.button({ glyph = "minus", onClick = function() changeProgress(-1) end }),
                ui.label({ text = `{anime.progress}/{anime.episodes}`, fontSize = 14 }),
                ui.button({ glyph = "plus", onClick = function() changeProgress(1) end }),
            }),
        }),
    })
end

local function renderLogin()
    local status = noctalia.state.get("anilist_login_status") or ""
    local waiting = status == "waiting"
    local errorText = string.match(status, "^error:(.*)$")

    local message = "Connect your AniList account to see your lists."
    if waiting then
        message = "Approve the app in your browser…"
    elseif errorText then
        message = "Login failed: " .. errorText
    end

    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({ text = "Anilist Tracker", fontSize = 15, fontWeight = "bold", color = "primary" }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),
        ui.column({ flexGrow = 1, gap = 14, align = "center", justify = "center" }, {
            ui.glyph({ name = "device-tv", size = 40, color = "primary" }),
            ui.label({ text = message, fontSize = 14 }),
            ui.button({
                glyph = "login",
                text = waiting and "Waiting for browser…" or "Log in with AniList",
                variant = "primary",
                onClick = "onLoginClicked",
            }),
        }),
    })
end

local function renderLists()
    local list = animeByStatus[currentStatus()]
    local content = #list > 0 and renderSelected(list)
        or ui.label({ text = "No anime in this list yet.", fontSize = 14 })

    return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
        ui.row({ align = "stretch", justify = "space_between" }, {
            ui.select({ options = STATUSES, selectedIndex = statusIndex, onChange = "onStatusSelect", width = 320 }),
            ui.row({ justify = "space_between", gap = 10 }, {
                ui.button({ glyph = "search", onClick = "goToSearch" }),
                ui.button({ glyph = "activity", onClick = "goToActivity" }),
                ui.button({ glyph = "logout", onClick = "onLogoutClicked" }),
                ui.button({ glyph = "close", onClick = "onCloseClicked" }),
            }),
        }),
        ui.row({ padding = { top = 2, bottom = 2 } }, {
            ui.label({ text = `{currentStatus()} ({#list})`, fontSize = 15, fontWeight = "bold", color = "primary" }),
        }),
        ui.scroll({ flexGrow = 1 }, { content }),
    })
end

function render()
    if not panelOpen then return end
    panel.render((needsLogin or not savedToken()) and renderLogin() or renderLists())
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- The widget runs the browser login and stores the token; reload when it lands.
noctalia.state.watch("anilist_token", function()
    if savedToken() then
        needsLogin = false
        if panelOpen then fetchLists() end
    end
    render()
end)

noctalia.state.watch("anilist_login_status", function()
    render()
end)

function onOpen(context)
    panelOpen = true
    statusIndex = tonumber(noctalia.state.get("anilist_selected_status")) or 0
    restoreSelection()
    if savedToken() then fetchLists() end
    render()
end

function onClose()
    panelOpen = false
end

-- ── handlers ─────────────────────────────────────────────────────────────────

function onStatusSelect(index)
    statusIndex = tonumber(index) or 0
    noctalia.state.set("anilist_selected_status", statusIndex)
    restoreSelection()
    render()
end

function onAnimeSelect(index)
    animeIndex = tonumber(index) or 0
    rememberSelection()
    render()
end

function onOpenDetails()
    local anime = selectedAnime()
    if not anime then return end
    noctalia.state.set("anilist_open_media", anime.mediaId)
    noctalia.togglePanel(SEARCH_PANEL)
end

function goToSearch()
    noctalia.togglePanel(SEARCH_PANEL)
end

function goToActivity()
    noctalia.togglePanel(ACTIVITY_PANEL)
end

function onLoginClicked()
    if noctalia.state.get("anilist_login_status") == "waiting" then return end
    -- any new value wakes the widget's watcher
    noctalia.state.set("anilist_login_request", `{os.time()}-{os.clock()}`)
end

function onLogoutClicked()
    noctalia.state.set("anilist_token", "")
    for _, name in ipairs(STATUSES) do animeByStatus[name] = {} end
    needsLogin = true
    render()
end

function onCloseClicked()
    panel.close()
end

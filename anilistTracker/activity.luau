-- Activity panel: list updates from people you follow, with likes.

local render

local MAX_TITLE_CHARS = 40
local COVER_SIZE = 40
local COVER_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state"))
    .. "/noctalia/anilist/covers/media"

local LIST_PANEL = "HotZi/anilistTracker:anilistPanel"

local ACTIVITY_QUERY = [[
query ($page: Int) {
  Page(page: $page, perPage: 20) {
    activities(type: ANIME_LIST, sort: ID_DESC, isFollowing: true) {
      ... on ListActivity {
        id
        status
        progress
        isLiked
        likeCount
        media { id title { english romaji } coverImage { medium } }
        user { name }
      }
    }
  }
}
]]

local TOGGLE_LIKE = [[
mutation ($id: Int) {
  ToggleLike(id: $id, type: ACTIVITY) { id }
}
]]

local activities = {}
local page = 1

local coverPaths = {}
local coverPending = {}

-- ── helpers ──────────────────────────────────────────────────────────────────

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

-- ── AniList sync ─────────────────────────────────────────────────────────────

local function loadPage()
    if not savedToken() then
        noctalia.notify("AniList", "Open the Anilist panel and click Log in with AniList")
        return
    end

    gql(ACTIVITY_QUERY, { page = page }, function(data)
        if not (data and data.Page) then
            noctalia.notifyError("AniList", "Failed to fetch activity.")
            return
        end
        activities = data.Page.activities or {}
        render()
    end)
end

-- Flips the like right away and rolls it back if AniList rejects it.
local function toggleLike(activity)
    if not savedToken() then return end

    local wasLiked, oldCount = activity.isLiked, activity.likeCount or 0
    activity.isLiked = not wasLiked
    activity.likeCount = wasLiked and math.max(oldCount - 1, 0) or oldCount + 1
    render()

    gql(TOGGLE_LIKE, { id = activity.id }, function(data, res)
        if data then return end

        local parsed = res and res.body and noctalia.json.decode(res.body)
        local reason = parsed and parsed.errors and parsed.errors[1] and parsed.errors[1].message
        noctalia.notifyError("AniList Interaction Failed", reason or `Status: {res and res.status or "no response"}`)

        activity.isLiked, activity.likeCount = wasLiked, oldCount
        render()
    end)
end

-- ── views ────────────────────────────────────────────────────────────────────

local function activityRow(activity)
    local media = activity.media
    local title = truncate(media.title.english or media.title.romaji, MAX_TITLE_CHARS)
    local progress = activity.progress and (" " .. activity.progress) or ""

    return ui.row({ padding = 10, border = "outline", borderWidth = 1, radius = 8, justify = "space_between", align = "center" }, {
        ui.row({ align = "center", gap = 10 }, {
            cover(media.id, media.coverImage and media.coverImage.medium),
            ui.label({ text = `{activity.user.name} {activity.status}{progress}:\n{title}` }),
        }),
        ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = tostring(activity.likeCount) }),
            ui.button({
                glyph = activity.isLiked and "heart-filled" or "heart",
                onClick = function() toggleLike(activity) end,
            }),
        }),
    })
end

function render()
    local rows = {}
    for _, activity in ipairs(activities) do
        table.insert(rows, activityRow(activity))
    end

    panel.render(ui.column({ flexGrow = 1, gap = 12 }, {
        ui.row({ justify = "space_between" }, {
            ui.button({ glyph = "arrow-narrow-left", onClick = "goToTracker" }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),
        ui.scroll({ flexGrow = 1, gap = 8 }, rows),
        ui.row({ align = "center", justify = "center", gap = 10 }, {
            ui.button({ glyph = "caret-left", enabled = page > 1, onClick = "previousPage" }),
            ui.label({ text = tostring(page) }),
            ui.button({ glyph = "caret-right", onClick = "nextPage" }),
        }),
    }))
end

-- ── lifecycle and handlers ───────────────────────────────────────────────────

function onOpen(context)
    page = 1
    loadPage()
    render()
end

function nextPage()
    page += 1
    loadPage()
end

function previousPage()
    if page <= 1 then return end
    page -= 1
    loadPage()
end

function goToTracker()
    noctalia.togglePanel(LIST_PANEL)
end

function onCloseClicked()
    panel.close()
end

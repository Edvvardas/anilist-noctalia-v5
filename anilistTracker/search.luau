-- Search AniList and browse an anime's full page: info, characters, relations,
-- recommendations, and your own list entry.

local render

local COVER_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/anilist/covers"
-- media and character ids share no namespace with the list-entry ids the main
-- panel caches covers under, so keep them in their own folders
local MEDIA_DIR = COVER_DIR .. "/media"
local CHAR_DIR = COVER_DIR .. "/characters"

local THUMB_W, THUMB_H = 46, 64
local COVER_W, COVER_H = 120, 170
local TEXT_WIDTH = 420

local LIST_STATUSES = { "Not in list", "Watching", "Planning", "Completed", "Repeating", "Paused", "Dropped" }
local STATUS_TO_API = {
    Watching = "CURRENT", Planning = "PLANNING", Completed = "COMPLETED",
    Repeating = "REPEATING", Paused = "PAUSED", Dropped = "DROPPED",
}
local API_TO_STATUS = {}
for name, api in pairs(STATUS_TO_API) do API_TO_STATUS[api] = name end

local TABS = { "Overview", "Characters", "Relations", "Recommendations" }

local panelOpen = false
local view = "search" -- "search" | "detail"

local query = ""
local results = {}
local trending = {}
local searching = false
local searchSeq = 0

local media = nil
local loadingDetail = false
local detailSeq = 0
local detailTab = "Overview"
local descExpanded = false
local backStack = {}
-- true when the main panel's Details button opened the current page, so Back
-- returns to the list instead of the search page
local openedFromList = false

local LIST_PANEL = "HotZi/anilistTracker:anilistPanel"

local images = {}
local imagePending = {}

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

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function openUrl(url)
    noctalia.runAsync("xdg-open " .. shellQuote(url) .. " >/dev/null 2>&1")
end

local function titleOf(m)
    if not m or not m.title then return "Unknown" end
    return m.title.english or m.title.romaji or m.title.native or "Unknown"
end

local UPPER_WORDS = { TV = true, OVA = true, ONA = true }

-- "TV_SHORT" -> "TV Short", "NOT_YET_RELEASED" -> "Not Yet Released"
local function prettyEnum(value)
    if type(value) ~= "string" or value == "" then return nil end
    local words = {}
    for word in string.gmatch(value, "[^_]+") do
        if UPPER_WORDS[word] then
            table.insert(words, word)
        else
            table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.lower(string.sub(word, 2)))
        end
    end
    return table.concat(words, " ")
end

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local function formatDate(d)
    if not d or not d.year then return nil end
    if d.month and d.day then return `{MONTHS[d.month]} {d.day}, {d.year}` end
    if d.month then return `{MONTHS[d.month]} {d.year}` end
    return tostring(d.year)
end

local function formatCountdown(seconds)
    local days = math.floor(seconds / 86400)
    local hours = math.floor(seconds % 86400 / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    return `{days}d {hours}h {minutes}m`
end

local function cleanDescription(text)
    if type(text) ~= "string" then return "" end
    text = string.gsub(text, "<br%s*/?>", "\n")
    text = string.gsub(text, "<[^>]+>", "")
    text = string.gsub(text, "&quot;", "\"")
    text = string.gsub(text, "&#039;", "'")
    text = string.gsub(text, "&amp;", "&")
    text = string.gsub(text, "&lt;", "<")
    text = string.gsub(text, "&gt;", ">")
    text = string.gsub(text, "\n\n\n+", "\n\n")
    return noctalia.string.trim(text)
end

local function hasToken()
    local token = noctalia.state.get("anilist_token")
    return token ~= nil and token ~= ""
end

local function gql(queryText, variables, callback)
    local headers = { "Content-Type: application/json", "Accept: application/json" }
    local token = noctalia.state.get("anilist_token")
    if token and token ~= "" then
        table.insert(headers, "Authorization: Bearer " .. noctalia.string.trim(token))
    end

    noctalia.http({
        url = "https://graphql.anilist.co",
        method = "POST",
        headers = headers,
        body = noctalia.json.encode({ query = queryText, variables = variables }),
    }, function(res)
        local parsed = res and res.body and noctalia.json.decode(res.body)
        local ok = res and res.ok and res.status == 200 and parsed and parsed.data
        callback(ok and parsed.data or nil, res)
    end)
end

-- Downloads once into the cache and re-renders when it lands.
local function image(dir, id, url, width, height, radius)
    local key = `{dir}/{id}`
    if url and url ~= "" and images[key] == nil and not imagePending[key] then
        local path = `{dir}/{id}.jpg`
        if noctalia.fileExists(path) then
            images[key] = path
        else
            noctalia.mkdirAll(dir)
            imagePending[key] = true
            noctalia.download(url, path, function(success)
                imagePending[key] = nil
                if success then
                    images[key] = path
                    render()
                end
            end)
        end
    end

    if images[key] then
        return ui.image({ path = images[key], width = width, height = height, fit = "cover", radius = radius or 6 })
    end
    return ui.box({ width = width, height = height, fill = "surface_variant", radius = radius or 6 })
end

-- ── queries ──────────────────────────────────────────────────────────────────

local CARD_FIELDS = [[
    id
    title { english romaji }
    format
    episodes
    seasonYear
    averageScore
    status
    coverImage { medium }
    mediaListEntry { status }
]]

local SEARCH_QUERY = [[
query ($search: String) {
  Page(perPage: 25) {
    media(search: $search, type: ANIME, isAdult: false, sort: [SEARCH_MATCH, POPULARITY_DESC]) {]] .. CARD_FIELDS .. [[}
  }
}
]]

local TRENDING_QUERY = [[
query {
  Page(perPage: 25) {
    media(type: ANIME, isAdult: false, sort: [TRENDING_DESC]) {]] .. CARD_FIELDS .. [[}
  }
}
]]

local DETAIL_QUERY = [[
query ($id: Int) {
  Media(id: $id, type: ANIME) {
    id
    siteUrl
    title { english romaji native }
    synonyms
    format
    status
    episodes
    duration
    season
    seasonYear
    source
    startDate { year month day }
    endDate { year month day }
    averageScore
    meanScore
    popularity
    favourites
    isFavourite
    genres
    description(asHtml: false)
    coverImage { large }
    studios(isMain: true) { nodes { name } }
    nextAiringEpisode { episode timeUntilAiring }
    trailer { id site }
    rankings { rank type allTime context season year }
    tags { name rank isMediaSpoiler }
    stats { statusDistribution { status amount } }
    relations {
      edges {
        relationType(version: 2)
        node { id type format status title { english romaji } coverImage { medium } }
      }
    }
    characters(sort: [ROLE, RELEVANCE, ID], perPage: 16) {
      edges {
        role
        node { id name { full } image { medium } }
        voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) { name { full } }
      }
    }
    recommendations(sort: [RATING_DESC, ID], perPage: 12) {
      nodes {
        rating
        mediaRecommendation { id format seasonYear averageScore title { english romaji } coverImage { medium } }
      }
    }
    mediaListEntry { id status progress score }
  }
}
]]

local function runSearch()
    searchSeq += 1
    local seq = searchSeq
    local text = noctalia.string.trim(query)

    if text == "" then
        results = {}
        searching = false
        render()
        return
    end

    searching = true
    render()
    gql(SEARCH_QUERY, { search = text }, function(data)
        if seq ~= searchSeq then return end -- a newer search replaced this one
        searching = false
        if data and data.Page then
            results = data.Page.media or {}
        else
            results = {}
            noctalia.notifyError("AniList", "Search failed.")
        end
        render()
    end)
end

local function loadTrending()
    if #trending > 0 then return end
    gql(TRENDING_QUERY, {}, function(data)
        if data and data.Page then
            trending = data.Page.media or {}
            render()
        end
    end)
end

local function loadDetail(id)
    detailSeq += 1
    local seq = detailSeq
    loadingDetail = true
    media = nil
    descExpanded = false
    detailTab = "Overview"
    render()

    gql(DETAIL_QUERY, { id = id }, function(data)
        if seq ~= detailSeq then return end
        loadingDetail = false
        if data and data.Media then
            media = data.Media
        else
            noctalia.notifyError("AniList", "Could not load this anime.")
        end
        render()
    end)
end

local function openMedia(id)
    if view == "detail" and media then
        table.insert(backStack, media.id)
    end
    view = "detail"
    loadDetail(id)
end

-- ── list entry mutations ─────────────────────────────────────────────────────

local SAVE_ENTRY = [[
mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float) {
  SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score) {
    id status progress score
  }
}
]]

local function saveEntry(fields, successMessage)
    if not media then return end
    if not hasToken() then
        noctalia.notify("AniList", "Log in from the Anilist panel to edit your list.")
        return
    end

    local mediaId = media.id
    fields.mediaId = mediaId
    gql(SAVE_ENTRY, fields, function(data)
        if data and data.SaveMediaListEntry then
            if media and media.id == mediaId then
                media.mediaListEntry = data.SaveMediaListEntry
            end
            if successMessage then noctalia.notify("AniList", successMessage) end
        else
            noctalia.notifyError("AniList Sync Failed", "Could not update your list.")
        end
        render()
    end)
end

local function deleteEntry()
    local entry = media and media.mediaListEntry
    if not entry then return end

    local mediaId = media.id
    gql("mutation ($id: Int) { DeleteMediaListEntry(id: $id) { deleted } }", { id = entry.id }, function(data)
        if data and data.DeleteMediaListEntry and data.DeleteMediaListEntry.deleted then
            if media and media.id == mediaId then media.mediaListEntry = nil end
            noctalia.notify("AniList", "Removed from your list")
        else
            noctalia.notifyError("AniList Sync Failed", "Could not remove it from your list.")
        end
        render()
    end)
end

local function toggleFavourite()
    if not media then return end
    if not hasToken() then
        noctalia.notify("AniList", "Log in from the Anilist panel to add favourites.")
        return
    end

    local mediaId = media.id
    gql("mutation ($id: Int) { ToggleFavourite(animeId: $id) { anime { nodes { id } } } }", { id = mediaId }, function(data)
        if data and data.ToggleFavourite then
            if media and media.id == mediaId then media.isFavourite = not media.isFavourite end
        else
            noctalia.notifyError("AniList Sync Failed", "Could not update favourites.")
        end
        render()
    end)
end

-- ── search view ──────────────────────────────────────────────────────────────

local function resultRow(m)
    local meta = {}
    if m.format then table.insert(meta, prettyEnum(m.format)) end
    if m.seasonYear then table.insert(meta, tostring(m.seasonYear)) end
    if m.episodes then table.insert(meta, `{m.episodes} ep`) end
    if m.averageScore then table.insert(meta, `{m.averageScore}%`) end

    local listStatus = m.mediaListEntry and API_TO_STATUS[m.mediaListEntry.status]

    return ui.row({ gap = 10, align = "center", padding = 4, radius = 8, onClick = function() openMedia(m.id) end }, {
        image(MEDIA_DIR, m.id, m.coverImage and m.coverImage.medium, THUMB_W, THUMB_H, 4),
        ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, compact(
            ui.label({ text = titleOf(m), fontSize = 14, fontWeight = "bold", maxLines = 2, maxWidth = TEXT_WIDTH }),
            ui.label({ text = table.concat(meta, " · "), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
            listStatus and ui.label({ text = "In your list: " .. listStatus, fontSize = 12, color = "primary" }) or nil
        )),
    })
end

local function renderSearch()
    local list, heading
    if noctalia.string.trim(query) == "" then
        list, heading = trending, "Trending now"
    else
        list, heading = results, searching and "Searching…" or `Results ({#results})`
    end

    local rows = {}
    for _, m in ipairs(list) do
        table.insert(rows, resultRow(m))
    end
    if #rows == 0 and not searching then
        table.insert(rows, ui.label({
            text = list == trending and "Loading…" or "No anime found.",
            fontSize = 14,
            color = "on_surface_variant",
        }))
    end

    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.button({ glyph = "arrow-left", tooltip = "Back to your list", onClick = "onBackToList" }),
            ui.input({
                key = "search-input",
                value = query,
                placeholder = "Search anime…",
                flexGrow = 1,
                onChange = "onQueryChange",
                onSubmit = "onQuerySubmit",
            }),
            ui.button({ glyph = "search", variant = "primary", onClick = "onSearchClicked" }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),
        ui.label({ text = heading, fontSize = 15, fontWeight = "bold", color = "primary" }),
        ui.scroll({ flexGrow = 1 }, {
            ui.column({ gap = 4, align = "stretch" }, rows),
        }),
    })
end

-- ── detail view ──────────────────────────────────────────────────────────────

local function infoRow(label, value)
    if value == nil or value == "" then return nil end
    return ui.row({ gap = 8 }, {
        ui.label({ text = label, fontSize = 13, color = "on_surface_variant", width = 110 }),
        ui.label({ text = tostring(value), fontSize = 13, maxWidth = TEXT_WIDTH - 110, wrap = true }),
    })
end

local function sectionTitle(text)
    return ui.label({ text = text, fontSize = 14, fontWeight = "bold", color = "primary" })
end

local function chips(items)
    local rows, current, width = {}, {}, 0
    for _, text in ipairs(items) do
        local w = #text * 7 + 20
        if width + w > TEXT_WIDTH + 100 and #current > 0 then
            table.insert(rows, ui.row({ gap = 6 }, current))
            current, width = {}, 0
        end
        table.insert(current, ui.box({ padding = { left = 8, right = 8, top = 3, bottom = 3 }, radius = 10, fill = "surface_variant" }, {
            ui.label({ text = text, fontSize = 12 }),
        }))
        width += w
    end
    if #current > 0 then table.insert(rows, ui.row({ gap = 6 }, current)) end
    return ui.column({ gap = 6 }, rows)
end

local function renderListControls()
    if not hasToken() then
        return ui.label({ text = "Log in from the Anilist panel to add this to your list.", fontSize = 13, color = "on_surface_variant" })
    end

    local entry = media.mediaListEntry
    local statusName = entry and API_TO_STATUS[entry.status] or "Not in list"
    local selected = 0
    for i, name in ipairs(LIST_STATUSES) do
        if name == statusName then selected = i - 1 end
    end

    local controls = {
        ui.select({ options = LIST_STATUSES, selectedIndex = selected, onChange = "onListStatusChange", width = 150 }),
    }

    if entry then
        local total = media.episodes and tostring(media.episodes) or "?"
        table.insert(controls, ui.row({ gap = 6, align = "center" }, {
            ui.button({ glyph = "minus", onClick = "onProgressDown" }),
            ui.label({ text = `{entry.progress or 0}/{total}`, fontSize = 13 }),
            ui.button({ glyph = "plus", onClick = "onProgressUp" }),
        }))
        table.insert(controls, ui.row({ gap = 4, align = "center" }, {
            ui.glyph({ name = "star", size = 14, color = "primary" }),
            ui.input({
                key = "score-" .. tostring(media.id),
                value = (entry.score and entry.score > 0) and tostring(entry.score) or "",
                placeholder = "Score",
                width = 70,
                onSubmit = "onScoreSubmit",
            }),
        }))
    end

    return ui.row({ gap = 10, align = "center" }, controls)
end

local function renderHeader()
    local m = media
    local meta = {}
    if m.format then table.insert(meta, prettyEnum(m.format)) end
    if m.season and m.seasonYear then
        table.insert(meta, `{prettyEnum(m.season)} {m.seasonYear}`)
    elseif m.seasonYear then
        table.insert(meta, tostring(m.seasonYear))
    end
    if m.status then table.insert(meta, prettyEnum(m.status)) end

    local scoreLine = {}
    if m.averageScore then table.insert(scoreLine, `★ {m.averageScore}%`) end
    if m.popularity then table.insert(scoreLine, `{m.popularity} users`) end
    if m.favourites then table.insert(scoreLine, `♥ {m.favourites}`) end

    local studios = {}
    for _, s in ipairs((m.studios and m.studios.nodes) or {}) do table.insert(studios, s.name) end

    local airing = nil
    if m.nextAiringEpisode then
        airing = ui.label({
            text = `Episode {m.nextAiringEpisode.episode} airs in {formatCountdown(m.nextAiringEpisode.timeUntilAiring)}`,
            fontSize = 13,
            color = "primary",
        })
    end

    local actions = {
        ui.button({
            glyph = m.isFavourite and "heart-filled" or "heart",
            variant = m.isFavourite and "primary" or "outline",
            tooltip = m.isFavourite and "Remove from favourites" or "Add to favourites",
            onClick = "onFavouriteClicked",
        }),
        ui.button({ glyph = "external-link", tooltip = "Open on AniList", onClick = "onOpenSite" }),
    }
    if m.trailer and m.trailer.site == "youtube" and m.trailer.id then
        table.insert(actions, ui.button({ glyph = "player-play", text = "Trailer", onClick = "onOpenTrailer" }))
    end

    return ui.row({ gap = 14, align = "start" }, {
        image(MEDIA_DIR, `{m.id}_large`, m.coverImage and m.coverImage.large, COVER_W, COVER_H, 8),
        ui.column({ gap = 6, flexGrow = 1, minWidth = 0 }, compact(
            ui.label({ text = titleOf(m), fontSize = 18, fontWeight = "bold", maxLines = 2, maxWidth = TEXT_WIDTH, wrap = true }),
            (m.title.native and ui.label({ text = m.title.native, fontSize = 13, color = "on_surface_variant", maxLines = 1 })) or nil,
            ui.label({ text = table.concat(meta, " · "), fontSize = 13 }),
            ui.label({ text = table.concat(scoreLine, "   "), fontSize = 13 }),
            (#studios > 0 and ui.label({ text = table.concat(studios, ", "), fontSize = 13, color = "on_surface_variant", maxLines = 1 })) or nil,
            airing,
            ui.row({ gap = 6, align = "center" }, actions)
        )),
    })
end

local function renderOverview()
    local m = media
    local children = {}

    local description = cleanDescription(m.description)
    if description ~= "" then
        table.insert(children, sectionTitle("Description"))
        table.insert(children, ui.label({
            text = description,
            fontSize = 13,
            wrap = true,
            maxWidth = TEXT_WIDTH + 100,
            maxLines = (not descExpanded) and 5 or nil,
        }))
        table.insert(children, ui.button({
            text = descExpanded and "Show less" or "Show more",
            variant = "ghost",
            onClick = "onToggleDescription",
        }))
    end

    table.insert(children, sectionTitle("Information"))
    local duration = m.duration and `{m.duration} min` or nil
    local info = compact(
        infoRow("Format", prettyEnum(m.format)),
        infoRow("Episodes", m.episodes),
        infoRow("Duration", duration),
        infoRow("Status", prettyEnum(m.status)),
        infoRow("Start date", formatDate(m.startDate)),
        infoRow("End date", formatDate(m.endDate)),
        infoRow("Source", prettyEnum(m.source)),
        infoRow("Mean score", m.meanScore and `{m.meanScore}%` or nil),
        infoRow("Romaji", m.title.romaji),
        infoRow("Synonyms", m.synonyms and #m.synonyms > 0 and table.concat(m.synonyms, ", ") or nil)
    )
    table.insert(children, ui.column({ gap = 4 }, info))

    if m.genres and #m.genres > 0 then
        table.insert(children, sectionTitle("Genres"))
        table.insert(children, chips(m.genres))
    end

    local tags = {}
    for _, tag in ipairs(m.tags or {}) do
        if not tag.isMediaSpoiler and #tags < 12 then
            table.insert(tags, `{tag.name} {tag.rank}%`)
        end
    end
    if #tags > 0 then
        table.insert(children, sectionTitle("Tags"))
        table.insert(children, chips(tags))
    end

    local rankings = {}
    for _, r in ipairs(m.rankings or {}) do
        local scope = r.allTime and "all time" or (r.season and `{prettyEnum(r.season)} {r.year}`) or (r.year and tostring(r.year)) or ""
        local kind = r.type == "RATED" and "Highest rated" or "Most popular"
        table.insert(rankings, ui.label({ text = `#{r.rank} {kind} {scope}`, fontSize = 13 }))
    end
    if #rankings > 0 then
        table.insert(children, sectionTitle("Rankings"))
        table.insert(children, ui.column({ gap = 3 }, rankings))
    end

    local distribution = (m.stats and m.stats.statusDistribution) or {}
    local totalUsers = 0
    for _, d in ipairs(distribution) do totalUsers += d.amount end
    if totalUsers > 0 then
        local bars = {}
        for _, d in ipairs(distribution) do
            table.insert(bars, ui.row({ gap = 8, align = "center" }, {
                ui.label({ text = API_TO_STATUS[d.status] or prettyEnum(d.status), fontSize = 12, width = 80 }),
                ui.progress({ progress = d.amount / totalUsers, width = 260, height = 6, radius = 3 }),
                ui.label({ text = tostring(d.amount), fontSize = 12, color = "on_surface_variant" }),
            }))
        end
        table.insert(children, sectionTitle("Status distribution"))
        table.insert(children, ui.column({ gap = 4 }, bars))
    end

    return children
end

local function renderCharacters()
    local edges = (media.characters and media.characters.edges) or {}
    if #edges == 0 then
        return { ui.label({ text = "No characters listed.", fontSize = 13 }) }
    end

    local rows = {}
    for _, edge in ipairs(edges) do
        local c = edge.node
        local va = edge.voiceActors and edge.voiceActors[1]
        table.insert(rows, ui.row({ gap = 10, align = "center" }, compact(
            image(CHAR_DIR, c.id, c.image and c.image.medium, 40, 54, 4),
            ui.column({ gap = 2, flexGrow = 1, minWidth = 0 }, {
                ui.label({ text = c.name and c.name.full or "Unknown", fontSize = 13, fontWeight = "bold", maxLines = 1 }),
                ui.label({ text = prettyEnum(edge.role) or "", fontSize = 12, color = "on_surface_variant" }),
            }),
            va and ui.label({ text = va.name.full, fontSize = 12, color = "on_surface_variant", maxLines = 1 }) or nil
        )))
    end
    return rows
end

-- Rows for related or recommended media. Anime opens in this panel; anything
-- else (manga, novels) opens on the AniList site.
local function mediaLinkRow(m, caption)
    local isAnime = m.type == nil or m.type == "ANIME"
    local meta = { caption }
    if m.format then table.insert(meta, prettyEnum(m.format)) end
    if m.seasonYear then table.insert(meta, tostring(m.seasonYear)) end
    if m.averageScore then table.insert(meta, `{m.averageScore}%`) end

    local onClick = function()
        if isAnime then
            openMedia(m.id)
        else
            openUrl(`https://anilist.co/{string.lower(m.type)}/{m.id}`)
        end
    end

    return ui.row({ gap = 10, align = "center", padding = 4, radius = 8, onClick = onClick }, compact(
        image(MEDIA_DIR, m.id, m.coverImage and m.coverImage.medium, THUMB_W, THUMB_H, 4),
        ui.column({ gap = 3, flexGrow = 1, minWidth = 0 }, {
            ui.label({ text = titleOf(m), fontSize = 13, fontWeight = "bold", maxLines = 2, maxWidth = TEXT_WIDTH }),
            ui.label({ text = table.concat(meta, " · "), fontSize = 12, color = "on_surface_variant", maxLines = 1 }),
        }),
        (not isAnime) and ui.glyph({ name = "external-link", size = 14, color = "on_surface_variant" }) or nil
    ))
end

local function renderRelations()
    local edges = (media.relations and media.relations.edges) or {}
    if #edges == 0 then
        return { ui.label({ text = "No related media.", fontSize = 13 }) }
    end

    local rows = {}
    for _, edge in ipairs(edges) do
        table.insert(rows, mediaLinkRow(edge.node, prettyEnum(edge.relationType) or "Related"))
    end
    return rows
end

local function renderRecommendations()
    local nodes = (media.recommendations and media.recommendations.nodes) or {}
    local rows = {}
    for _, rec in ipairs(nodes) do
        if rec.mediaRecommendation then
            table.insert(rows, mediaLinkRow(rec.mediaRecommendation, `+{rec.rating or 0}`))
        end
    end
    if #rows == 0 then
        return { ui.label({ text = "No recommendations yet.", fontSize = 13 }) }
    end
    return rows
end

local tabHandlers = {
    Overview = "onTabOverview",
    Characters = "onTabCharacters",
    Relations = "onTabRelations",
    Recommendations = "onTabRecommendations",
}

local function renderDetail()
    local topBar = ui.row({ align = "center", justify = "space_between" }, {
        ui.button({
            glyph = "arrow-left",
            text = (#backStack > 0 or openedFromList) and "Back" or "Search",
            onClick = "onBackClicked",
        }),
        ui.button({ glyph = "close", onClick = "onCloseClicked" }),
    })

    if loadingDetail or not media then
        return ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
            topBar,
            ui.label({ text = loadingDetail and "Loading…" or "Could not load this anime.", fontSize = 14 }),
        })
    end

    local tabButtons = {}
    for _, name in ipairs(TABS) do
        table.insert(tabButtons, ui.button({
            text = name,
            variant = detailTab == name and "primary" or "ghost",
            onClick = tabHandlers[name],
        }))
    end

    local body
    if detailTab == "Characters" then
        body = renderCharacters()
    elseif detailTab == "Relations" then
        body = renderRelations()
    elseif detailTab == "Recommendations" then
        body = renderRecommendations()
    else
        body = renderOverview()
    end

    return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
        topBar,
        ui.scroll({ flexGrow = 1 }, {
            ui.column({ gap = 12, align = "stretch" }, {
                renderHeader(),
                renderListControls(),
                ui.separator({}),
                ui.row({ gap = 4 }, tabButtons),
                ui.column({ gap = 8, align = "stretch" }, body),
            }),
        }),
    })
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

function render()
    if not panelOpen then return end
    panel.render(view == "detail" and renderDetail() or renderSearch())
end

function onOpen(context)
    panelOpen = true

    -- the main panel sets this to jump straight to an anime's page
    local requested = tonumber(noctalia.state.get("anilist_open_media"))
    if requested then
        noctalia.state.set("anilist_open_media", nil)
        backStack = {}
        openedFromList = true
        view = "detail"
        loadDetail(requested)
    end

    loadTrending()
    render()
end

function onClose()
    panelOpen = false
end

-- noctalia msg plugin HotZi/anilistTracker:searchPanel all search "frieren"
-- noctalia msg plugin HotZi/anilistTracker:searchPanel all open 154587
function onIpc(event, payload)
    if event == "search" then
        query = payload or ""
        view = "search"
        runSearch()
    elseif event == "open" and tonumber(payload) then
        backStack = {}
        openedFromList = false
        view = "detail"
        loadDetail(tonumber(payload))
    end
end

-- ── handlers ─────────────────────────────────────────────────────────────────

function onQueryChange(value)
    if type(value) == "string" then query = value end
end

-- Enter in the search field; the host passes the field's text
function onQuerySubmit(value)
    if type(value) == "string" then query = value end
    runSearch()
end

-- The search button passes its own argument, not the field's text, so it must
-- not touch `query`; onQueryChange keeps that in sync while typing.
function onSearchClicked()
    runSearch()
end

function onCloseClicked()
    panel.close()
end

function onBackClicked()
    local previous = table.remove(backStack)
    if previous then
        loadDetail(previous)
    elseif openedFromList then
        onBackToList()
    else
        view = "search"
        media = nil
        render()
    end
end

function onBackToList()
    -- reset so the next open from the search button starts on the search page
    openedFromList = false
    view = "search"
    media = nil
    noctalia.togglePanel(LIST_PANEL)
end

function onTabOverview() detailTab = "Overview"; render() end
function onTabCharacters() detailTab = "Characters"; render() end
function onTabRelations() detailTab = "Relations"; render() end
function onTabRecommendations() detailTab = "Recommendations"; render() end

function onToggleDescription()
    descExpanded = not descExpanded
    render()
end

function onListStatusChange(index)
    local name = LIST_STATUSES[(tonumber(index) or 0) + 1]
    if name == "Not in list" then
        deleteEntry()
    elseif name then
        saveEntry({ status = STATUS_TO_API[name] }, "Moved to " .. name)
    end
end

function onProgressUp()
    local entry = media and media.mediaListEntry
    if not entry then return end
    local progress = (entry.progress or 0) + 1
    if media.episodes and progress > media.episodes then return end
    saveEntry({ progress = progress })
end

function onProgressDown()
    local entry = media and media.mediaListEntry
    if not entry or (entry.progress or 0) <= 0 then return end
    saveEntry({ progress = entry.progress - 1 })
end

function onScoreSubmit(value)
    local score = tonumber(value)
    if not score then
        noctalia.notify("Invalid score", "Please enter a number.")
        return
    end
    saveEntry({ score = score }, "Score saved")
end

function onFavouriteClicked()
    toggleFavourite()
end

function onOpenSite()
    if media and media.siteUrl then openUrl(media.siteUrl) end
end

function onOpenTrailer()
    if media and media.trailer and media.trailer.id then
        openUrl("https://www.youtube.com/watch?v=" .. media.trailer.id)
    end
end

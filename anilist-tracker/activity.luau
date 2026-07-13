local activities = {}
local activityPage = 1



local ACTIVITY_QUERY = [[
    query ($page: Int) {
        Page(page: $page, perPage: 20) {
            activities(
                type: ANIME_LIST
                sort: ID_DESC
                isFollowing: true
            ) {
                ... on ListActivity {
                    id
                    status
                    progress
                    createdAt
                    isLiked
                    likeCount
                    media {
                        title { english romaji }
                        coverImage { medium }
                    }
                    user {
                        name
                    }
                }
            }
        }
    }
]]


local render



local COVER_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/anilist/covers"
local COVER_SIZE = 40

local coverPending = {}
local coverPaths = {}


local function coverCachePath(id)
    return `{COVER_DIR}/{id}.jpg`
end


local function downloadCover(id, url)
    if not url or url == "" then return end
    if coverPaths[id] ~= nil or coverPending[id] then return end

    local dirOk, dirErr = noctalia.mkdirAll(COVER_DIR)
    if not dirOk then
        noctalia.log("AniList: could not create cover cache dir: " .. tostring(dirErr))
        return
    end

    coverPending[id] = true
    local dest = coverCachePath(id)
    local started = noctalia.download(url, dest, function(success)
        coverPending[id] = nil
        if success then
            coverPaths[id] = dest
            render()
        else
            noctalia.log("AniList: cover download failed for id " .. tostring(id) .. " url " .. tostring(url))
        end
    end)
    if not started then
        coverPending[id] = nil
    end
end


function toggleAniListLike(entryId)
    local savedToken = noctalia.state.get("anilist_token")
    if not savedToken or savedToken == "" then return end
    local cleanToken = noctalia.string.trim(savedToken)

    local targetActivity = nil
    for _, activity in ipairs(activities) do
        if activity.id == entryId then
            targetActivity = activity
            break
        end
    end

    local previousLikedState = nil
    local previousLikeCount = nil

    if targetActivity then
        previousLikedState = targetActivity.isLiked
        previousLikeCount = targetActivity.likeCount or 0

        targetActivity.isLiked = not targetActivity.isLiked

        if targetActivity.isLiked then
            targetActivity.likeCount = previousLikeCount + 1
        else
            targetActivity.likeCount = math.max(previousLikeCount - 1, 0)
        end

        render()
    end

    local mutationQuery = noctalia.json.encode({
        query = [[
        mutation ($id: Int, $type: LikeableType) {
          ToggleLike(id: $id, type: $type) {
            id
          }
        }
        ]],
        variables = {
            id = entryId,
            type = "ACTIVITY"
        }
    })

    noctalia.http({
        url = "https://graphql.anilist.co",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "Authorization: Bearer " .. cleanToken
        },
        body = mutationQuery
    }, function(res)
        if not (res and res.ok and res.status == 200) then
            local statusText = res and tostring(res.status) or "no response"
            local bodyText = res and res.body or ""

            local errorMessage = nil
            if res and res.body then
                local ok, parsedError = pcall(noctalia.json.decode, res.body)
                if ok and parsedError and parsedError.errors and parsedError.errors[1] then
                    errorMessage = parsedError.errors[1].message
                end
            end

            noctalia.notifyError(
                "AniList Interaction Failed",
                "Status: " .. statusText .. " - " .. (errorMessage or bodyText or "unknown error")
            )

            if targetActivity then
                targetActivity.isLiked = previousLikedState
                targetActivity.likeCount = previousLikeCount
                render()
            end
            return
        end
    end)
end


function onLikeAt(index)
    local activity = activities[index + 1]
    if not activity then return end
    toggleAniListLike(activity.id)
end


local likeCallbackNames = {
    "onLike0", "onLike1", "onLike2", "onLike3", "onLike4",
    "onLike5", "onLike6", "onLike7", "onLike8", "onLike9",
    "onLike10", "onLike11", "onLike12", "onLike13", "onLike14",
    "onLike15", "onLike16", "onLike17", "onLike18", "onLike19",
}


local function fetchAniListGraphQL(token, query, variables, callback)
    local cleanToken = noctalia.string.trim(token)

    local body = noctalia.json.encode({
        query = query,
        variables = variables or {},
    })

    noctalia.http({
        url = "https://graphql.anilist.co",
        method = "POST",
        headers = {
            "Content-Type: application/json",
            "Authorization: Bearer " .. cleanToken,
        },
        body = body,
    }, function(res)
        if not (res and res.ok and res.status == 200) then
            if callback then callback(nil, res) end
            return
        end

        local parsed = noctalia.json.decode(res.body)
        if callback then callback(parsed, res) end
    end)
end


local function loadActivityPage()
    local savedToken = noctalia.state.get("anilist_token")
    if not savedToken or savedToken == "" then
        noctalia.notify("Middle click the widget icon to set your token :)")
        return
    end

    fetchAniListGraphQL(savedToken, ACTIVITY_QUERY, { page = activityPage }, function(data)
        if not (data and data.data and data.data.Page) then
            noctalia.notifyError("AniList", "Failed to fetch activity.")
            return
        end

        activities = data.data.Page.activities or {}

        for _, activity in ipairs(activities) do
            local cover = activity.media.coverImage and activity.media.coverImage.medium
            downloadCover(activity.media.id or activity.id, cover)
        end

        render()
    end)
end


local function isTitleLong(text, length)
    local textTrimmed = ""
    if string.len(text) > length then
        textTrimmed = string.sub(text,1,length) .. "..."
        return textTrimmed
    end
    return text
end


local function renderActivityFeed()
    local rows = {}

    for index, activity in ipairs(activities) do
        local title = activity.media.title.english or activity.media.title.romaji
        local trimmedTitle = isTitleLong(title, 40)

        local slot = index - 1
        local callbackName = likeCallbackNames[slot + 1]

        local coverId = activity.media.id or activity.id
        local coverPath = coverPaths[coverId]

        local progressText = activity.progress and (" " .. activity.progress) or ""

        local coverWidget
        if coverPath then
            coverWidget = ui.image({
                width = COVER_SIZE,
                height = COVER_SIZE,
                path = coverPath,
                fit = "cover",
                radius = 6,
            })
        else
            coverWidget = ui.box({
                width = COVER_SIZE,
                height = COVER_SIZE,
                fill = "surface_variant",
                radius = 6,
            })
        end

        table.insert(rows, ui.row({
        padding = 10,
        border = "outline",
        borderWidth = 1,
        radius = 8,
        justify = "space_between",
        align = "center",
        }, {

        
        ui.row({ align = "center", gap = 10 }, {
            coverWidget,
            ui.label({
                text = activity.user.name .. " " .. activity.status .. progressText .. ":" .. "\n" .. trimmedTitle,
            }),
        }),

        ui.row({ align = "center", gap = 6 }, {
            ui.label({ text = tostring(activity.likeCount) }),
            ui.button({
                glyph = activity.isLiked and "heart-filled" or "heart",
                onClick = callbackName,
            }),
        })

    }))
    end

    return ui.scroll({ flexGrow = 1, gap = 8, }, rows)
end


function render()
    panel.render(ui.column({ flexGrow = 1, gap = 12, }, {
        ui.row({ justify = "space_between" }, {
            ui.button({glyph = "arrow-narrow-left", onClick = "goToTracker"}),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
        }),

        renderActivityFeed(),

        ui.row({ align = "center", justify = "center", gap = 10 }, {
            ui.button({ glyph = "caret-left", enabled = activityPage > 1, onClick = "previousActivityPage" }),
            ui.label({ text = tostring(activityPage)}),
            ui.button({ glyph = "caret-right", onClick = "nextActivityPage" }),
        }),
    }))
end


function onOpen(context)
    activityPage = 1
    loadActivityPage()
    render()
end


function nextActivityPage()
    activityPage = activityPage + 1
    loadActivityPage()
end

function previousActivityPage()
    if activityPage > 1 then
        activityPage = activityPage - 1
        loadActivityPage()
    end
end


function onCloseClicked()
    panel.close()
end


function goToTracker()
    noctalia.togglePanel("HotZi/anilistTracker:anilistPanel")
end


function onLike0() onLikeAt(0) end
function onLike1() onLikeAt(1) end
function onLike2() onLikeAt(2) end
function onLike3() onLikeAt(3) end
function onLike4() onLikeAt(4) end
function onLike5() onLikeAt(5) end
function onLike6() onLikeAt(6) end
function onLike7() onLikeAt(7) end
function onLike8() onLikeAt(8) end
function onLike9() onLikeAt(9) end
function onLike10() onLikeAt(10) end
function onLike11() onLikeAt(11) end
function onLike12() onLikeAt(12) end
function onLike13() onLikeAt(13) end
function onLike14() onLikeAt(14) end
function onLike15() onLikeAt(15) end
function onLike16() onLikeAt(16) end
function onLike17() onLikeAt(17) end
function onLike18() onLikeAt(18) end
function onLike19() onLikeAt(19) end
local enabled = true
local currentStatus = { "Watching", "Planning", "Completed", "Repeating", "Paused", "Dropped" }
local selectedIndex = 0;



-- titles length
local MAX_CHARS = 50 

local selectedAnimeIndex = 0



-- maps status enums to ui names and vice versa
local statusMap = {
    CURRENT   = "Watching",
    PLANNING  = "Planning",
    COMPLETED = "Completed",
    REPEATING = "Repeating",
    PAUSED    = "Paused",
    DROPPED   = "Dropped"
}

local reverseStatusMap = {
    Watching  = "CURRENT",
    Planning  = "PLANNING",
    Completed = "COMPLETED",
    Repeating = "REPEATING",
    Paused    = "PAUSED",
    Dropped   = "DROPPED",
}

local animeData = {
    Watching = {},
    Planning = {},
    Completed = {},
    Repeating = {},
    Paused = {},
    Dropped = {}
}

local render

-- covers

local COVER_DIR = (noctalia.getenv("XDG_STATE_HOME") or ((noctalia.getenv("HOME") or "") .. "/.local/state")) .. "/noctalia/anilist/covers"
local COVER_SIZE = 96

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

local function restoreSelectionFor(statusName)
    local list = animeData[statusName] or {}
    local savedId = noctalia.state.get("anilist_selected_id_" .. statusName)
    if savedId ~= nil then
        for i, item in ipairs(list) do
            if item.id == savedId then
                selectedAnimeIndex = i - 1
                return
            end
        end
    end
    selectedAnimeIndex = 0
end

-- send progress updates to anilist
local function updateAniListProgress(entryId, newProgress)
    local savedToken = noctalia.state.get("anilist_token")
    if not savedToken or savedToken == "" then return end
    local cleanToken = noctalia.string.trim(savedToken)
    
    local mutationQuery = noctalia.json.encode({
        query = [[
        mutation ($id: Int, $progress: Int) {
          SaveMediaListEntry (id: $id, progress: $progress) {
            id
            progress
          }
        }
        ]],
        variables = { id = entryId, progress = newProgress }
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
            noctalia.notifyError("AniList Sync Failed", "Could not sync progress to your profile.")
        end
    end)
end


-- update anime status
local function updateAniListStatus(entryId, newStatusApiValue)
    local savedToken = noctalia.state.get("anilist_token")
    if not savedToken or savedToken == "" then return end
    local cleanToken = noctalia.string.trim(savedToken)

    local mutationQuery = noctalia.json.encode({
        query = [[
        mutation ($id: Int, $status: MediaListStatus) {
          SaveMediaListEntry (id: $id, status: $status) {
            id
            status
          }
        }
        ]],
        variables = { id = entryId, status = newStatusApiValue }
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
            noctalia.notifyError("AniList Sync Failed", "Could not sync status to your profile.")
        end
    end)
end


-- update anime score
local function updateAniListScore(entryId, newScore)
    local savedToken = noctalia.state.get("anilist_token")
    if not savedToken or savedToken == "" then return end
    local cleanToken = noctalia.string.trim(savedToken)

    local mutationQuery = noctalia.json.encode({
        query = [[
        mutation ($id: Int, $score: Float) {
          SaveMediaListEntry (id: $id, score: $score) {
            id
            status
            score
          }
        }
        ]],
        variables = { id = entryId, score = newScore }
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
            noctalia.notifyError("AniList Sync Failed", "Could not sync score to your profile.")

        elseif (res and res.ok and res.status== 200) then
            noctalia.notify("Updated status succesfully")
        end
    end)
end

-- rate anime

local buffer = ""
local idleTicks = 0
local dirty = false
local pendingEntryId = nil


function rateAnime(entryId, rating)
    for _, statusList in pairs(animeData) do
        for _, item in ipairs(statusList) do
            if item.id == entryId then
                item.score = rating
                updateAniListScore(item.id, item.score)
                render()
                return
            end
        end
    end
end


function animeRatingInput(entryId)
    pendingEntryId = entryId
    return ui.row({ align = "center", gap = 6 }, {
        ui.label({ text = "⭐" }),
        ui.input({onSubmit = "onSubmitString"}),
    })
end



 
function onSubmitString(value)
    buffer = value
    idleTicks = 0
    dirty = true

    local rating = tonumber(value)
    if rating and pendingEntryId then
        rateAnime(pendingEntryId, rating)
        pendingEntryId = nil
    else
        noctalia.notify("Invalid rating", "Please enter a number.")
    end

    render()
end



-- increments ep number locally then calls api
function incrementProgress(entryId)
    for _, statusList in pairs(animeData) do
        for _, item in ipairs(statusList) do
            if item.id == entryId then
                if item.episodes > 0 and item.progress >= item.episodes then return end
                item.progress = item.progress + 1
                updateAniListProgress(item.id, item.progress)
                render()
                return
            end
        end
    end
end


function decrementProgress(entryId)
    for _, statusList in pairs(animeData) do
        for _, item in ipairs(statusList) do
            if item.id == entryId then
                if item.progress <= 0 then return end
                item.progress = item.progress - 1
                updateAniListProgress(item.id, item.progress)
                render()
                return
            end
        end
    end
end



local function fetchAniList(token)
    local cleanToken = noctalia.string.trim(token)
    local viewerQuery = noctalia.json.encode({ query = "query { Viewer { name } }" })
    
    noctalia.http({
        url = "https://graphql.anilist.co",
        method = "POST",
        headers = { 
            "Content-Type: application/json",
            "Authorization: Bearer " .. cleanToken 
        },
        body = viewerQuery
    }, function(res)
        if res and res.ok and res.status == 200 then
            local parsedViewer = noctalia.json.decode(res.body)
            local username = parsedViewer and parsedViewer.data and parsedViewer.data.Viewer and parsedViewer.data.Viewer.name
            
            if username then
                local listQuery = noctalia.json.encode({
                    query = [[
                    query ($name: String) {
                      MediaListCollection(userName: $name, type: ANIME) {
                        lists {
                          status
                          entries {
                            id
                            progress
                            score
                            media { title { english romaji } 
                            episodes
                            status
                            nextAiringEpisode {
                                episode
                                airingAt
                                timeUntilAiring
                            }

                            coverImage { medium } }
                          }
                        }
                      }
                    }
                    ]],
                    variables = { name = username }
                })
                
                noctalia.http({
                    url = "https://graphql.anilist.co",
                    method = "POST",
                    headers = { 
                        "Content-Type: application/json",
                        "Authorization: Bearer " .. cleanToken 
                    },
                    body = listQuery
                }, function(listRes)
                    if listRes and listRes.ok and listRes.status == 200 then
                        local parsedList = noctalia.json.decode(listRes.body)
                        if parsedList and parsedList.data and parsedList.data.MediaListCollection then
                            for k, v in pairs(animeData) do animeData[k] = {} end
                            
                            local lists = parsedList.data.MediaListCollection.lists
                            for _, list in ipairs(lists) do
                                local uiKey = statusMap[list.status]
                                if uiKey then
                                    for _, entry in ipairs(list.entries) do
                                        local name = entry.media.title.english or entry.media.title.romaji
                                        
                                        if #name > MAX_CHARS then
                                            name = string.sub(name, 1, MAX_CHARS - 3) .. "..."
                                        end

                                    local cover = entry.media.coverImage and entry.media.coverImage.medium
                                        table.insert(animeData[uiKey], {
                                            id = entry.id,
                                            name = name,
                                            progress = entry.progress or 0,
                                            episodes = entry.media.episodes or 0,
                                            status = entry.media.status or "UNKNOWN",
                                            nextAiringEpisode = entry.media.nextAiringEpisode,
                                            cover = cover,
                                            score = entry.score or 0
                                        })
                                        downloadCover(entry.id, cover)
                                    end
                                end
                            end
                            restoreSelectionFor(currentStatus[selectedIndex + 1]) -- keep/re-find the saved pick
                            render() 
                        end
                    else
                        noctalia.notifyError("AniList Error", "Failed to retrieve your anime lists.")
                    end
                end)
            else
                noctalia.notifyError("AniList Error", "Could not resolve account profile name.")
            end
        else
            noctalia.notifyError("AniList Sync Failed", "Check your token in widget settings!")
        end
    end)
end

-- total anime count n selected status
local function header(text)
    return ui.row({ padding = { top = 2, bottom = 2 } }, {
        ui.label({ text = text, fontSize = 15, fontWeight = "bold", color = "primary" })
    })
end


-- check if the next episode is airing and display it
local function isEpisodeAiring(text, episodeData)
    if text ~= "RELEASING" or not episodeData then
        return nil
    else
        return ui.label({
             text = "Episode: "
             .. tostring(episodeData.episode) .. " in " 
             .. tostring(math.floor(episodeData.timeUntilAiring/86400))
             .. "d " .. tostring(math.floor(episodeData.timeUntilAiring%86400/3600)) .. "h "
             .. tostring(math.floor(episodeData.timeUntilAiring%86400%3600/60)) .. "m "
              , fontSize = 14 })
        
    end
end

local function isAnimeRated(myRating)
    if (tonumber(myRating) == 0) then
        return ui.label({text = "Not rated yet"})
    else
        return ui.label({text = "Your score: " .. myRating})
    end
            
end


local function findStatusIndex(name)
    for i, s in ipairs(currentStatus) do
        if s == name then return i - 1 end
    end
    return nil
end

local function changeSelectedAnimeStatus(newStatusName)
    local currentStatusName = currentStatus[selectedIndex + 1]
    if newStatusName == currentStatusName then return end 

    local list = animeData[currentStatusName]
    local item = list and list[selectedAnimeIndex + 1]
    if not item then return end

    table.remove(list, selectedAnimeIndex + 1)
    table.insert(animeData[newStatusName], item)

    updateAniListStatus(item.id, reverseStatusMap[newStatusName])

 
    selectedAnimeIndex = math.min(selectedAnimeIndex, math.max(#list - 1, 0))
    local remaining = list[selectedAnimeIndex + 1]
    noctalia.state.set("anilist_selected_id_" .. currentStatusName, remaining and remaining.id or nil)

    local newIndex = findStatusIndex(newStatusName)
    if newIndex then
        selectedIndex = newIndex
        noctalia.state.set("anilist_selected_status", selectedIndex)
    end

    selectedAnimeIndex = math.max(#animeData[newStatusName] - 1, 0)
    noctalia.state.set("anilist_selected_id_" .. newStatusName, item.id)

    render()
end

local statusButtonHandlers = {
    Watching  = "onSetStatusWatching",
    Planning  = "onSetStatusPlanning",
    Completed = "onSetStatusCompleted",
    Repeating = "onSetStatusRepeating",
    Paused    = "onSetStatusPaused",
    Dropped   = "onSetStatusDropped",
}

local function statusButton(glyph, currentSelectorStatusName)
    local isActive = (currentStatus[selectedIndex + 1] == currentSelectorStatusName)
    local variantColour = isActive and "primary" or "outline"
    return ui.button({
        glyph = glyph,
        variant = variantColour,
        onClick = statusButtonHandlers[currentSelectorStatusName],
    })
end


local function renderList(statusKey)
    local list = animeData[statusKey] or {}

    if #list == 0 then
        return ui.column({ gap = 12 }, {
            ui.label({ text = "No anime in this list yet.", fontSize = 14 }),
        })
    end

    local options = {}
    for index, item in ipairs(list) do
        table.insert(options, index .. ". " .. item.name .. " (" .. item.progress .. " ep)")
    end

    if selectedAnimeIndex >= #list then
        selectedAnimeIndex = math.max(#list - 1, 0)
    end

    local selectedItem = list[selectedAnimeIndex + 1]


    downloadCover(selectedItem.id, selectedItem.cover)

    local coverPath = coverPaths[selectedItem.id]
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



    return ui.column({ gap = 12 }, {
        ui.select({
            options = options,
            selectedIndex = selectedAnimeIndex,
            onChange = "onAnimeSelect",
            width = 320,
        }),

        ui.row({ align = "center", gap = 12 }, {
            coverWidget,
            ui.column({ gap = 6 }, {
                ui.label({
                    text = selectedItem.name,
                    fontSize = 16,
                    fontWeight = "bold",
                }),
                ui.label({
                    text = "Anime Status: " .. tostring(selectedItem.status),
                    fontSize = 14,
                }),
                isEpisodeAiring(selectedItem.status, selectedItem.nextAiringEpisode),
                isAnimeRated(selectedItem.score)

            }),
        }),
        

        ui.row({ align = "center", justify = "space_between" }, {

        ui.label({ text = "Change Status:", fontSize = 14}),
        

        animeRatingInput(selectedItem.id),


        }),

        ui.row({ align = "center", justify = "space_between" }, {
            
            ui.row({ align = "center", gap = 6 }, {
                statusButton("player-play", "Watching"),
                statusButton("clock", "Planning"),
                statusButton("checks", "Completed"),
                statusButton("trash", "Dropped"),
                statusButton("player-pause", "Paused"),
                statusButton("repeat", "Repeating"),
                
            }),
           
           

            ui.row({ align = "center", gap = 10 }, {
                ui.button({ glyph = "minus", onClick = "onDecrementSelected" }),
                ui.label({ text = tostring(selectedItem.progress) .. "/" .. tostring(selectedItem.episodes), fontSize = 14 }),
                ui.button({ glyph = "plus", onClick = "onIncrementSelected" }),
            }),
        }),
    })
end

local function renderCurrent()   return renderList("Watching") end
local function renderPlanning()  return renderList("Planning") end
local function renderCompleted() return renderList("Completed") end
local function renderRepeating() return renderList("Repeating") end
local function renderPaused()    return renderList("Paused") end
local function renderDropped()   return renderList("Dropped") end


function render()
  local currentStatusName = currentStatus[selectedIndex + 1]
  local contentScroller
  
  if currentStatusName == "Watching" then
    contentScroller = renderCurrent()
  elseif currentStatusName == "Planning" then
    contentScroller = renderPlanning()
  elseif currentStatusName == "Completed" then
    contentScroller = renderCompleted()
  elseif currentStatusName == "Repeating" then
    contentScroller = renderRepeating()
  elseif currentStatusName == "Paused" then
    contentScroller = renderPaused()
  elseif currentStatusName == "Dropped" then
    contentScroller = renderDropped()
  else
    noctalia.notify("Sum wrong wit status brochacho ")
  end
    
  local entries = animeData[currentStatusName] or {}

  panel.render(ui.column({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.row({ align = "stretch", justify = "space_between" }, {
      ui.select({ options = currentStatus, selectedIndex = selectedIndex, onChange = "onToggle", width = 320}),
       ui.row({justify = "space_between", gap = 10 }, {
            ui.button({ glyph = "activity", onClick = "goToActivity" }),
            ui.button({ glyph = "close", onClick = "onCloseClicked" }),
      }),
    }),

    header(`{currentStatusName} ({#entries})`),

    ui.scroll({ flexGrow = 1, gap = 0 }, { 
        contentScroller 
    }),
  }))
end

function onOpen(context) 
    local savedStatus = noctalia.state.get("anilist_selected_status")
    if savedStatus ~= nil then
        selectedIndex = tonumber(savedStatus) or 0
    end

    local savedToken = noctalia.state.get("anilist_token")
    
    if savedToken and savedToken ~= "" then
        fetchAniList(savedToken)
    else
        noctalia.notify("Middle click the widget icon to set your token :)")
    end
    
    render()
end

function onToggle(index, text)
    selectedIndex = tonumber(index) or 0
    noctalia.state.set("anilist_selected_status", selectedIndex)
    restoreSelectionFor(currentStatus[selectedIndex + 1])
    render()
end


function onAnimeSelect(index, text)
    selectedAnimeIndex = tonumber(index) or 0
    local currentStatusName = currentStatus[selectedIndex + 1]
    local list = animeData[currentStatusName] or {}
    local item = list[selectedAnimeIndex + 1]
    if item then
        noctalia.state.set("anilist_selected_id_" .. currentStatusName, item.id)
    end
    render()
end


function onIncrementSelected()
    local currentStatusName = currentStatus[selectedIndex + 1]
    local list = animeData[currentStatusName] or {}
    local item = list[selectedAnimeIndex + 1]
    if item then
        incrementProgress(item.id)
    end
end

function onDecrementSelected()
    local currentStatusName = currentStatus[selectedIndex + 1]
    local list = animeData[currentStatusName] or {}
    local item = list[selectedAnimeIndex + 1]
    if item then
        decrementProgress(item.id)
    end
end

function onCloseClicked() 
    panel.close() 
end

function goToActivity()
    noctalia.togglePanel("HotZi/anilistTracker:activityPanel")
end


function onSetStatusWatching()  
    changeSelectedAnimeStatus("Watching")
end
function onSetStatusPlanning()
    changeSelectedAnimeStatus("Planning")
end
function onSetStatusCompleted()
    changeSelectedAnimeStatus("Completed")
end
function onSetStatusRepeating()
    changeSelectedAnimeStatus("Repeating")
end
function onSetStatusPaused()
    changeSelectedAnimeStatus("Paused")
end
function onSetStatusDropped()
    changeSelectedAnimeStatus("Dropped")
end
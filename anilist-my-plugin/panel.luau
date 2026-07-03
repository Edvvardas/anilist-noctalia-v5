local enabled = true
local currentStatus = { "Watching", "Planning", "Completed", "Repeating", "Paused", "Dropped" }
local selectedIndex = 0;

-- titles length
local MAX_CHARS = 50 

local selectedAnimeIndex = 0

-- map with the names im using
local statusMap = {
    CURRENT   = "Watching",
    PLANNING  = "Planning",
    COMPLETED = "Completed",
    REPEATING = "Repeating",
    PAUSED    = "Paused",
    DROPPED   = "Dropped"
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

-- increments ep number locally then calls api
function incrementProgress(entryId)
    for _, statusList in pairs(animeData) do
        for _, item in ipairs(statusList) do
            if item.id == entryId then
                item.progress = item.progress + 1
                updateAniListProgress(item.id, item.progress)
                render() 
                return
            end
        end
    end
end

-- same thing here
function decrementProgress(entryId)
    for _, statusList in pairs(animeData) do
        for _, item in ipairs(statusList) do
            if item.id == entryId then
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
                            media { title { english romaji } }
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
                                        
                                        table.insert(animeData[uiKey], {
                                            id = entry.id,
                                            name = name,
                                            progress = entry.progress or 0
                                        })
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

    return ui.column({ gap = 12 }, {
        ui.select({
            options = options,
            selectedIndex = selectedAnimeIndex,
            onChange = "onAnimeSelect",
            width = 320,
        }),
        ui.row({ align = "center", justify = "space_between" }, {
            ui.label({
                text = selectedItem.name,
                fontSize = 14,
            }),
            ui.row({ align = "center", gap = 10 }, {
                ui.button({ glyph = "minus", onClick = "onDecrementSelected" }),
                ui.label({ text = tostring(selectedItem.progress), fontSize = 14 }),
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
      ui.button({ glyph = "close", onClick = "onCloseClicked" }),
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
        noctalia.notify("Right click the widget icon to set your token :)")
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

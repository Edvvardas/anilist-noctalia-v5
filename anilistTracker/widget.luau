-- Public AniList app id; the implicit grant needs no client secret.
local CLIENT_ID = "52753"

local loginRunning = false
local lastLoginRequest = noctalia.state.get("anilist_login_request")
local lastConfigToken = nil

-- A login can't survive a restart, so don't leave the panel stuck on "waiting".
if noctalia.state.get("anilist_login_status") == "waiting" then
    noctalia.state.set("anilist_login_status", "")
end

local function shellQuote(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function finishLogin(status)
    loginRunning = false
    noctalia.state.set("anilist_login_status", status)
end

-- Runs from the widget rather than the panel so the login keeps going after the
-- panel closes when focus moves to the browser.
local function startLogin()
    if loginRunning then return end

    local pluginDir = noctalia.pluginDir()
    if not pluginDir or not noctalia.commandExists("python3") then
        finishLogin("error:python3 is required for browser login")
        return
    end

    loginRunning = true
    noctalia.state.set("anilist_login_status", "waiting")

    local cmd = "python3 -u " .. shellQuote(pluginDir .. "/scripts/login.py") .. " " .. shellQuote(CLIENT_ID)
    local started = noctalia.runStream(cmd, function(line)
        local result = noctalia.json.decode(noctalia.string.trim(line or ""))
        if type(result) ~= "table" then return end

        if result.ok and type(result.access_token) == "string" then
            noctalia.state.set("anilist_token", result.access_token)
            finishLogin("")
            noctalia.notify("AniList", "Logged in successfully")
        else
            finishLogin("error:" .. tostring(result.error or "login failed"))
        end
    end)

    if not started then
        finishLogin("error:could not start the login helper")
    end
end

noctalia.state.watch("anilist_login_request", function(value)
    if value ~= nil and value ~= lastLoginRequest then
        lastLoginRequest = value
        startLogin()
    end
end)

local function render()
    noctalia.setUpdateInterval(1000)
    barWidget.setGlyph("device-tv")
    barWidget.setText("Anilist")
end

-- The manual token setting is a fallback. Apply it when it changes, or on start
-- if there is no saved token, so a stale value can't override a browser login.
local function syncConfigToken(context)
    local token = (context and context.settings and context.settings.anilist_token)
                  or noctalia.getConfig("anilist_token")
    if type(token) ~= "string" then token = "" end
    token = noctalia.string.trim(token)

    local firstTick = lastConfigToken == nil
    local changed = token ~= lastConfigToken
    lastConfigToken = token
    if token == "" or not changed then return end

    local saved = noctalia.state.get("anilist_token")
    if not firstTick or not saved or saved == "" then
        noctalia.state.set("anilist_token", token)
    end
end

function update(context)
    render()
    syncConfigToken(context)
end

function onClick()
    noctalia.togglePanel("HotZi/anilistTracker:anilistPanel")
end

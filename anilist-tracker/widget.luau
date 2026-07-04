local function render()
    noctalia.setUpdateInterval(1000)
    barWidget.setGlyph("device-tv")
    barWidget.setText("Anilist")
end

function update(context)
    render()

    local token = (context and context.settings and context.settings.anilist_token) 
                  or noctalia.getConfig("anilist_token")
    
    if token and token ~= "" then
        noctalia.state.set("anilist_token", token)
    end
end

function onClick()
    noctalia.togglePanel("HotZi/anilistTracker:anilistPanel")
end
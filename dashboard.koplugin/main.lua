local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local LuaSettings = require("luasettings")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local DashboardWidget = require("dashboardwidget")

local DEFAULTS = {
    place = "Chicago",
    lat = 41.8781,
    lon = -87.6298,
    method = "isna",
    madhab = "shafi",
    clock = "12h",
    hijri_offset = 0,
    temperature_unit = "celsius",
    autostart = true,
    full_refresh_minutes = 15,
    weather_minutes = 30,
}

local Dashboard = WidgetContainer:extend{
    name = "dashboard",
    is_doc_only = false,
}

function Dashboard:loadSettings()
    local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard.lua")
    local cfg = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = store:readSetting(k, v) end
    return cfg
end

function Dashboard:init()
    Dispatcher:registerAction("show_dashboard",
        { category = "none", event = "ShowDashboard", title = _("Dashboard"), general = true })
    self.ui.menu:registerToMainMenu(self)
    local first = not PluginShare.dashboard_started
    PluginShare.dashboard_started = true
    if (first or self.ui.document == nil) and self:loadSettings().autostart then
        UIManager:nextTick(function() self:onShowDashboard() end)
    end
end

function Dashboard:addToMainMenu(menu_items)
    menu_items.dashboard = {
        text = _("Dashboard"),
        sorting_hint = "tools",
        callback = function() self:onShowDashboard() end,
    }
end

function Dashboard:onShowDashboard()
    UIManager:show(DashboardWidget:new{ cfg = self:loadSettings() }, "flashui")
    return true
end

return Dashboard

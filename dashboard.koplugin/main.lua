local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local LuaSettings = require("luasettings")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local DashboardWidget = require("dashboardwidget")

local DEFAULTS = {
    place = "Minneapolis",
    lat = 44.9778,
    lon = -93.2650,
    method = "isna",
    madhab = "shafi",
    clock = "12h",
    hijri_offset = 0,
    temperature_unit = "celsius",
    autostart = true,
    full_refresh_minutes = 30,
    weather_minutes = 30,
}

local function blanket(action, module)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok then return end
    local h = lipc.init("com.github.mykindle.dashboard")
    if not h then return end
    pcall(h.set_string_property, h, "com.lab126.blanket", action, module)
    h:close()
end

-- Without the Amazon UI, Amazon's ad lock screen still draws over KOReader and KOReader skips its own sleep screen.
-- Hide the ad lock screen while KOReader runs, and give it back on exit.
if Device:isKindle() and os.getenv("STOP_FRAMEWORK") == "yes" and not Device.dashboard_patched then
    Device.dashboard_patched = true
    blanket("unload", "ad_screensaver")
    Device.isSpecialOffers = false
    local orig_exit = Device.exit
    Device.exit = function(self, ...)
        blanket("load", "ad_screensaver")
        return orig_exit(self, ...)
    end
end

-- KOReader has no plain swipe-up gesture; add one so the sleep screen unlocks like the Amazon one.
if not ScreenSaverLockWidget.dashboard_swipe then
    ScreenSaverLockWidget.dashboard_swipe = true
    local orig_init = ScreenSaverLockWidget.init
    ScreenSaverLockWidget.init = function(self)
        orig_init(self)
        if not Device:isTouchDevice() or G_reader_settings:readSetting("screensaver_delay") ~= "gesture" then return end
        self.ges_events.Tap = nil
        self.ges_events.DashboardSwipeUp = { GestureRange:new{
            ges = "swipe",
            range = Geom:new{ x = 0, y = 0, w = Device.screen:getWidth(), h = Device.screen:getHeight() },
        } }
        self.has_exit_screensaver_gesture = true
        self.handleEvent = function(this, event)
            InputContainer.handleEvent(this, event)
            return true
        end
    end
    ScreenSaverLockWidget.onDashboardSwipeUp = function(self, arg, ges)
        if ges.direction == "north" then return self:onClose() end
        return true
    end
end

-- KOReader has one sort order for all folders, and its "last read date" sort uses file access
-- times, which never change on the Kindle (noatime). Sort the home folder by reading history.
local FileChooser = require("ui/widget/filechooser")
if not FileChooser.dashboard_sort then
    FileChooser.dashboard_sort = true
    local ffiUtil = require("ffi/util")
    local recent = {
        text = _("last opened"),
        can_collate_mixed = false,
        init_sort_func = function()
            local last = {}
            local ok, ReadHistory = pcall(require, "readhistory")
            if ok then
                for _, h in ipairs(ReadHistory.hist or {}) do
                    if h.file then last[h.file] = math.max(last[h.file] or 0, h.time or 0) end
                end
            end
            return function(a, b)
                local ta, tb = last[a.path] or 0, last[b.path] or 0
                if ta ~= tb then return ta > tb end
                return ffiUtil.strcoll(a.text, b.text)
            end
        end,
    }
    local orig_get_collate = FileChooser.getCollate
    FileChooser.getCollate = function(self)
        local home = G_reader_settings:readSetting("home_dir")
        if home and self.path == home then return recent, "dashboard_recent" end
        return orig_get_collate(self)
    end
end

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
    if first then
        local f = io.open("/var/run/mykindle-ko-ready", "w")
        if f then f:close() end
    end
    if (first or self.ui.document == nil) and self:loadSettings().autostart then
        UIManager:nextTick(function() self:onShowDashboard() end)
    end
end

-- KOReader has no per-language page direction; turn Arabic books right-to-left once, so a manual change stays.
function Dashboard:onReaderReady(doc_settings)
    if not doc_settings or doc_settings:isTrue("dashboard_rtl_checked") then return end
    doc_settings:makeTrue("dashboard_rtl_checked")
    local props = self.ui.document.getProps and self.ui.document:getProps()
    local lang = props and props.language
    if type(lang) == "string" and lang:lower():match("^ar") then
        self.ui:handleEvent(Event:new("ToggleReadingOrder", true))
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
    UIManager:show(DashboardWidget:new{ cfg = self:loadSettings() }, "ui")
    return true
end

return Dashboard

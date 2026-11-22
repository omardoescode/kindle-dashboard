local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScreenSaverLockWidget = require("ui/widget/screensaverlockwidget")
local Event = require("ui/event")
local PluginShare = require("pluginshare")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local BluetoothWidget = require("bluetoothwidget")
local Home = require("homemodules")
local StopwatchWidget = require("stopwatchwidget")
local SUI = require("suiadapter")

local function blanket(action, module)
    local ok, lipc = pcall(require, "libopenlipclua")
    if not ok then return end
    local opened, h = pcall(lipc.open_no_name)
    if not opened or not h then return end
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
        -- koreader.sh starts the Amazon UI again after we exit, but it stays on a white screen until
        -- something opens its home. Open it once the UI runs; on a KOReader restart the UI never starts.
        os.execute([[setsid sh -c 'i=0; until status lab126_gui | grep -q start/running; do i=$((i+1)); [ $i -gt 120 ] && exit; sleep 1; done; sleep 30; lipc-set-prop com.lab126.appmgrd start app://com.lab126.booklet.home' >/dev/null 2>&1 &]])
        return orig_exit(self, ...)
    end
end

-- The running stopwatch keeps the Kindle awake; never leave that on after KOReader exits.
if not Device.dashboard_awake_patched then
    Device.dashboard_awake_patched = true
    local orig_exit = Device.exit
    Device.exit = function(self, ...)
        StopwatchWidget.keep_awake(false)
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

-- Two fingers on the two top corners at once shows or hides the KinAMP player on every screen,
-- Simple UI's too. KOReader reports it as one two_finger_tap at the midpoint of the two fingers.
local UIManager = require("ui/uimanager")
if not UIManager.dashboard_corners then
    UIManager.dashboard_corners = true
    local orig_send = UIManager.sendEvent
    UIManager.sendEvent = function(self, event)
        local ges = event.handler == "onGesture" and event.args and event.args[1]
        if ges and ges.ges == "two_finger_tap" and ges.pos and ges.span then
            local w, h = Device.screen:getWidth(), Device.screen:getHeight()
            if ges.span > w * 0.6 and ges.pos.y < h * 0.12 then
                self:broadcastEvent(Event:new("ShowKinAMPPlayer"))
                return true
            end
        end
        return orig_send(self, event)
    end
end

-- KOReader drops the leading zero of 12-hour times ("8:46 PM"); the user wants "08:46 PM" everywhere.
local datetime = require("datetime")
if not datetime.dashboard_padded then
    datetime.dashboard_padded = true
    local orig_hour = datetime.secondsToHour
    datetime.secondsToHour = function(seconds, twelve_hour_clock, pad_with_spaces)
        if twelve_hour_clock and not pad_with_spaces then
            return os.date("%I:%M ", seconds) .. (os.date("%p", seconds) == "AM" and "AM" or "PM")
        end
        return orig_hour(seconds, twelve_hour_clock, pad_with_spaces)
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

-- A Bluetooth section in the settings tab, after Network.
for _, path in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
    local ok, order = pcall(require, path)
    if ok and order.setting then
        local found
        for _, id in ipairs(order.setting) do
            if id == "dashboard_bluetooth" then found = true end
        end
        for i, id in ipairs(found and {} or order.setting) do
            if id == "network" then
                table.insert(order.setting, i + 1, "dashboard_bluetooth")
                break
            end
        end
    end
end

local Dashboard = WidgetContainer:extend{
    name = "dashboard",
    is_doc_only = false,
}

function Dashboard:init()
    self.ui.menu:registerToMainMenu(self)
    -- Each file manager and reader start makes new plugin instances; registering again is harmless.
    SUI.register(Home.modules, Home.actions, Home.bars)
    if not PluginShare.dashboard_started then
        PluginShare.dashboard_started = true
        StopwatchWidget.keep_awake(false)
        -- An older koreader.sh that ends after we start deletes our /var/tmp copy of it, and the next
        -- KOReader restart then shows "startup script has been updated". Put the copy back.
        if Device:isKindle() then
            require("ui/uimanager"):scheduleIn(60, function()
                os.execute("[ -e /var/tmp/koreader.sh ] || cp -pf ./koreader.sh /var/tmp/koreader.sh")
            end)
        end
        local f = io.open("/var/run/mykindle-ko-ready", "w")
        if f then f:close() end
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
    if Device:isKindle() then
        menu_items.dashboard_bluetooth = {
            text = _("Bluetooth"),
            callback = function() BluetoothWidget.show() end,
        }
    end
    menu_items.dashboard_adhkar = {
        text = _("Adhkar"),
        sorting_hint = "tools",
        callback = function() Home.openAdhkar() end,
    }
end

return Dashboard

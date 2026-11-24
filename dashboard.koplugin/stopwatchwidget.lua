local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local DateTimeWidget = require("ui/widget/datetimewidget")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local PluginShare = require("pluginshare")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Store = require("focusstore")
local SUI = require("suiadapter")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_4

local FONTS = "../plugins/dashboard.koplugin/fonts/"
local SANS, SANS_BOLD = FONTS .. "IBMPlexSans-Regular.ttf", FONTS .. "IBMPlexSans-SemiBold.ttf"
local BOLD = FONTS .. "IBMPlexSans-Bold.ttf"

local StopwatchWidget = InputContainer:extend{
    name = "dashboard_stopwatch",
    covers_fullscreen = true,
    clock12 = true,
}

-- Gestures that end a touch. After a touch ends the idle view, the rest of that touch is ignored.
local TOUCH_ENDS = { tap = true, double_tap = true, two_finger_tap = true, swipe = true, two_finger_swipe = true,
    multiswipe = true, hold_release = true, pan_release = true, two_finger_pan_release = true,
    pinch = true, spread = true, rotate = true }

-- The power button still sleeps the device: preventScreenSaver only stops the idle timeout.
-- On Kindle, AutoSuspend's t1 timer re-runs itself at once, forever, once its timeout has passed without
-- a touch, which freezes KOReader; it stops only while PluginShare.keepalive is set (as KeepAlive does).
function StopwatchWidget.keep_awake(on)
    PluginShare.pause_auto_suspend = on
    if not Device:isKindle() then return end
    PluginShare.keepalive = on
    local ok, lipc = pcall(require, "libopenlipclua")
    if not ok then return end
    local opened, h = pcall(lipc.open_no_name)
    if not opened or not h then return end
    pcall(h.set_int_property, h, "com.lab126.powerd", "preventScreenSaver", on and 1 or 0)
    h:close()
end

local function text(s, font, size, fg, max_width)
    return TextWidget:new{ text = s, face = Font:getFace(font, size), fgcolor = fg or BLACK, max_width = max_width }
end

local function hms(secs)
    return string.format("%d:%02d:%02d", math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
end

local function hm(secs)
    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. " min" end
    return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
end

local function goal_text(l, done)
    local left = Store.goal_left(l, done)
    if left == 0 then return "Goal met" end
    if left then return hm(math.ceil(left / 60) * 60) .. " left of " .. string.format("%g", l.goal_hours) .. " h" end
    return ""
end

function StopwatchWidget:fmt_time(t)
    if self.clock12 then return (os.date("%I:%M %p", t):gsub("^0", "")) end
    return os.date("%H:%M", t)
end

function StopwatchWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.data, self.store = Store.load()
    self.tick = function() self:onTick() end
    self.last_touch = os.time()
    if self.data.state.running then StopwatchWidget.keep_awake(true) end
    -- Simple UI wraps self[1] with its bars when it shows this widget, so builds replace only the body.
    self.body = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0 }
    self[1] = self.body
    self:build()
    self:schedule()
end

function StopwatchWidget:schedule()
    UIManager:unschedule(self.tick)
    if self.data.state.running then
        UIManager:scheduleIn(1, self.tick)
    else
        UIManager:scheduleIn(60 - (os.time() % 60) + 0.3, self.tick)
    end
end

function StopwatchWidget:build()
    local W, H = self.dimen.w, SUI.contentHeight()
    local pad = Screen:scaleBySize(18)
    local inner = W - 2 * pad
    local now = os.time()
    local st = self.data.state
    self.minute = math.floor(now / 60)
    self.day = os.date("%Y-%m-%d", now)

    local line = function()
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = Screen:scaleBySize(14) },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    end

    local status = st.running and "RUNNING" or "READY"
    self.time_text = text(hms(Store.elapsed(st, now)), BOLD, 96)
    self.time_box = FrameContainer:new{
        bordersize = Screen:scaleBySize(1), color = GRAY, padding = Screen:scaleBySize(6),
        padding_left = Screen:scaleBySize(24), padding_right = Screen:scaleBySize(24),
        self.time_text,
    }
    local started = st.started and ("Started " .. self:fmt_time(st.started)) or "Tap Start to begin"
    local middle = VerticalGroup:new{
        align = "center",
        text(st.started and (status .. "  ·  " .. (st.label or Store.NO_LABEL)) or status, SANS_BOLD, 22,
            st.started and BLACK or GRAY, inner),
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        self.time_box,
        VerticalSpan:new{ width = Screen:scaleBySize(8) },
        text(started, SANS, 18, GRAY),
    }

    local totals = Store.totals(self.data, now)
    local cw = math.floor(inner / 3)
    local stats = HorizontalGroup:new{}
    for _, c in ipairs({ { "Today", totals.today }, { "This week", totals.week }, { "This month", totals.month } }) do
        table.insert(stats, CenterContainer:new{ dimen = Geom:new{ w = cw, h = Screen:scaleBySize(56) },
            VerticalGroup:new{ align = "center", text(c[1], SANS, 16, GRAY), text(hm(c[2]), SANS_BOLD, 22) } })
    end

    local gap = Screen:scaleBySize(16)
    local bw = math.floor((inner - 3 * gap) / 4)
    local function btn(label, cb, enabled)
        local b = Button:new{ text = label, width = bw, bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(8),
            text_font_face = SANS_BOLD, text_font_bold = false, text_font_size = 20, callback = cb, show_parent = self }
        if enabled == false then b:disable() end
        return b
    end
    local buttons = HorizontalGroup:new{
        btn(st.started and "Stop" or "Start", function() self:onMain() end),
        HorizontalSpan:new{ width = gap },
        btn("Labels", function() self:onLabels() end, not st.running),
        HorizontalSpan:new{ width = gap },
        btn("History", function() self:onHistory() end),
        HorizontalSpan:new{ width = gap },
        btn("Close", function() UIManager:close(self) end),
    }

    -- Removed labels and old unlabeled sessions still show while they have time this week.
    local rows_data, listed = {}, {}
    for _, l in ipairs(self.data.labels) do
        table.insert(rows_data, l)
        listed[l.name] = true
    end
    local extra = {}
    for name in pairs(totals.labels) do
        if not listed[name] then table.insert(extra, name) end
    end
    table.sort(extra)
    for _, name in ipairs(extra) do table.insert(rows_data, { name = name }) end
    local name_w, done_w = math.floor(inner * 0.36), math.floor(inner * 0.22)
    local left_w = inner - name_w - done_w
    local week_head = LeftContainer:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(30) },
        text("This week by label", SANS, 16, GRAY) }

    local fixed = middle:getSize().h + stats:getSize().h + buttons:getSize().h + week_head:getSize().h
        + 2 * Screen:scaleBySize(14)
    local min_gap = Screen:scaleBySize(8)
    local avail = H - fixed - 4 * min_gap
    local row_h = math.min(Screen:scaleBySize(40), math.floor(avail / math.max(1, #rows_data)))
    local fit = #rows_data
    if row_h < Screen:scaleBySize(28) then
        row_h = Screen:scaleBySize(28)
        fit = math.max(1, math.floor(avail / row_h))
    end
    local rows = VerticalGroup:new{ align = "left" }
    for i, l in ipairs(rows_data) do
        if i == fit and #rows_data > fit then
            table.insert(rows, LeftContainer:new{ dimen = Geom:new{ w = inner, h = row_h },
                text(string.format("+ %d more", #rows_data - fit + 1), SANS, 16, GRAY) })
            break
        end
        local done = totals.labels[l.name] or 0
        table.insert(rows, HorizontalGroup:new{
            LeftContainer:new{ dimen = Geom:new{ w = name_w, h = row_h },
                text(l.name, SANS_BOLD, 18, BLACK, name_w - Screen:scaleBySize(8)) },
            RightContainer:new{ dimen = Geom:new{ w = done_w, h = row_h }, text(hm(done), SANS_BOLD, 18) },
            RightContainer:new{ dimen = Geom:new{ w = left_w, h = row_h }, text(goal_text(l, done), SANS, 16, GRAY, left_w) },
        })
    end

    local free = math.max(0, H - fixed - rows:getSize().h)
    local span = math.floor(free / 4)
    self.body[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = span },
            middle,
            VerticalSpan:new{ width = span },
            line(),
            stats,
            line(),
            CenterContainer:new{ dimen = Geom:new{ w = W, h = week_head:getSize().h }, week_head },
            CenterContainer:new{ dimen = Geom:new{ w = W, h = rows:getSize().h }, rows },
            VerticalSpan:new{ width = span },
            buttons,
        },
    }
end

function StopwatchWidget:refresh(full)
    self:build()
    if self.dotted ~= (self.data.state.started ~= nil) then
        self.dotted = self.data.state.started ~= nil
        SUI.rebuildBars()
    end
    UIManager:setDirty(self, full and "full" or "ui")
end

-- Simple UI closes the widget under its bar this way when another tab is tapped.
function StopwatchWidget:onClose()
    UIManager:close(self)
    return true
end

function StopwatchWidget:onMain()
    if self.data.state.started then return self:onStop() end
    if #self.data.labels > 0 then return self:pickLabel() end
    self:start()
end

function StopwatchWidget:start(label)
    Store.start(self.data, os.time(), label)
    Store.save(self.data, self.store)
    StopwatchWidget.keep_awake(true)
    self.last_touch = os.time()
    self:refresh()
    self:schedule()
end

function StopwatchWidget:pickLabel()
    local last = Store.last_label(self.data)
    local names = {}
    for _, l in ipairs(self.data.labels) do
        if l.name == last then table.insert(names, 1, l.name) else table.insert(names, l.name) end
    end
    local dialog
    local buttons = {}
    for _, name in ipairs(names) do
        table.insert(buttons, { { text = name, callback = function()
            UIManager:close(dialog)
            self:start(name)
        end } })
    end
    table.insert(buttons, { { text = "Cancel", callback = function() UIManager:close(dialog) end } })
    dialog = ButtonDialog:new{ title = "Start: choose a label", buttons = buttons }
    UIManager:show(dialog)
end

function StopwatchWidget:saveLabels()
    Store.save(self.data, self.store)
    self:refresh()
end

function StopwatchWidget:onLabels()
    local dialog
    local buttons = {}
    for i, l in ipairs(self.data.labels) do
        local goal = (l.goal_hours or 0) > 0 and string.format("  ·  %g h / week", l.goal_hours) or "  ·  no goal"
        table.insert(buttons, { { text = l.name .. goal, callback = function()
            UIManager:close(dialog)
            self:editLabel(i)
        end } })
    end
    table.insert(buttons, {
        { text = "Add label", callback = function()
            UIManager:close(dialog)
            self:askName("Add label", "", function(name)
                table.insert(self.data.labels, { name = name })
                self:saveLabels()
                self:onLabels()
            end)
        end },
        { text = "Close", callback = function() UIManager:close(dialog) end },
    })
    dialog = ButtonDialog:new{ title = "Labels", buttons = buttons }
    UIManager:show(dialog)
end

function StopwatchWidget:editLabel(i)
    local l = self.data.labels[i]
    local dialog
    dialog = ButtonDialog:new{ title = l.name, buttons = {
        { { text = "Weekly goal", callback = function()
            UIManager:close(dialog)
            self:askGoal(l)
        end } },
        { { text = "Rename", callback = function()
            UIManager:close(dialog)
            self:askName("Rename label", l.name, function(name)
                Store.rename_label(self.data, l.name, name)
                self:saveLabels()
                self:onLabels()
            end)
        end } },
        { { text = "Remove", callback = function()
            UIManager:close(dialog)
            UIManager:show(ConfirmBox:new{
                text = "Remove \"" .. l.name .. "\"?\nPast sessions keep this label and still count.",
                ok_text = "Remove",
                ok_callback = function()
                    table.remove(self.data.labels, i)
                    self:saveLabels()
                    self:onLabels()
                end,
                cancel_callback = function() self:onLabels() end,
            })
        end } },
        { { text = "Back", callback = function()
            UIManager:close(dialog)
            self:onLabels()
        end } },
    } }
    UIManager:show(dialog)
end

function StopwatchWidget:askName(title, value, on_ok)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = value,
        buttons = { {
            { text = "Cancel", id = "close", callback = function()
                UIManager:close(dialog)
                self:onLabels()
            end },
            { text = "Save", is_enter_default = true, callback = function()
                local name = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                if name == value then
                    UIManager:close(dialog)
                    return self:onLabels()
                end
                local taken = name == Store.NO_LABEL
                for _, l in ipairs(self.data.labels) do
                    if l.name == name then taken = true end
                end
                if name == "" or taken then
                    UIManager:show(InfoMessage:new{
                        text = name == "" and "Enter a name." or "This name is already used.", timeout = 3 })
                    return
                end
                UIManager:close(dialog)
                on_ok(name)
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function StopwatchWidget:askGoal(l)
    local dialog
    dialog = InputDialog:new{
        title = "Weekly goal for " .. l.name,
        description = "Hours per week, for example 2.5. Empty or 0: no goal.",
        input = (l.goal_hours or 0) > 0 and string.format("%g", l.goal_hours) or "",
        input_type = "number",
        buttons = { {
            { text = "Cancel", id = "close", callback = function()
                UIManager:close(dialog)
                self:onLabels()
            end },
            { text = "Save", is_enter_default = true, callback = function()
                local s = dialog:getInputText():gsub("%s", ""):gsub(",", ".")
                local hours = tonumber(s)
                if s ~= "" and (not hours or hours < 0 or hours > 168) then
                    UIManager:show(InfoMessage:new{ text = "Enter hours from 0 to 168.", timeout = 3 })
                    return
                end
                UIManager:close(dialog)
                l.goal_hours = (hours and hours > 0) and hours or nil
                self:saveLabels()
                self:onLabels()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function StopwatchWidget:onStop()
    local st = self.data.state
    if not st.started then return end
    self:editSession("stop", { label = st.label, start = st.started, stop = os.time() })
end

function StopwatchWidget:afterChange(on_done)
    Store.save(self.data, self.store)
    if not self.data.state.running then StopwatchWidget.keep_awake(false) end
    self:refresh()
    self:schedule()
    if on_done then on_done() end
end

-- mode: "stop" (the running session), "add" or "edit" (old: the stored session).
-- s is a draft { label, start, stop }; each change shows the dialog again with a new draft.
function StopwatchWidget:editSession(mode, s, old, on_done)
    local dialog
    local function again(ns)
        UIManager:close(dialog)
        self:editSession(mode, ns, old, on_done)
    end
    local function draft() return { label = s.label, start = s.start, stop = s.stop } end
    local t = os.date("*t", s.start)
    local function at(day, hour, min, sec)
        return os.time{ year = t.year, month = t.month, day = day, hour = hour, min = min, sec = sec or 0 }
    end

    local secs = s.stop - s.start
    local info = { ({ stop = "Stop session", add = "Add past session", edit = "Edit session" })[mode],
        "Duration: " .. (secs > 0 and hm(secs) or "-") }
    if mode == "stop" and secs > 0 and secs < 60 then
        table.insert(info, "Shorter than 1 min: Save will not keep it.")
    end
    if old and old.secs < old.stop - old.start and (s.start ~= old.start or s.stop ~= old.stop) then
        table.insert(info, "This session had pauses. Its time is now end - start.")
    end
    local end_text = self:fmt_time(s.stop)
    if os.date("%Y-%m-%d", s.stop) ~= os.date("%Y-%m-%d", s.start) then
        end_text = end_text .. os.date(" (%a %d %b)", s.stop)
    end

    local function save()
        local now = os.time()
        local ok, err
        if mode == "stop" then ok, err = Store.stop(self.data, s, now)
        elseif mode == "add" then ok, err = Store.add(self.data, s, now)
        else ok, err = Store.edit(self.data, old, s, now) end
        if err then
            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
            return
        end
        UIManager:close(dialog)
        if not ok then UIManager:show(InfoMessage:new{ text = "Not saved: shorter than 1 min.", timeout = 3 }) end
        self:afterChange(on_done)
    end
    local function confirm(text, ok_text, action)
        UIManager:show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = function()
            UIManager:close(dialog)
            action()
            self:afterChange(on_done)
        end })
    end
    local last = { { text = "Cancel", callback = function() UIManager:close(dialog) end }, { text = "Save", callback = save } }
    if mode == "stop" then
        table.insert(last, 1, { text = "Discard", callback = function()
            confirm("Discard this session?\nIt will not be saved.", "Discard", function() Store.discard(self.data) end)
        end })
    elseif mode == "edit" then
        table.insert(last, 1, { text = "Delete", callback = function()
            confirm("Delete this session?", "Delete", function() Store.delete(self.data, old) end)
        end })
    end

    local this_year = os.date("*t").year
    dialog = ButtonDialog:new{
        title = table.concat(info, "\n"),
        buttons = {
            { { text = "Label: " .. (s.label or Store.NO_LABEL), callback = function()
                local names, seen = {}, {}
                for _, l in ipairs(self.data.labels) do table.insert(names, l.name); seen[l.name] = true end
                if s.label and not seen[s.label] then table.insert(names, s.label) end
                table.insert(names, Store.NO_LABEL)
                local picker
                local rows = {}
                for _, name in ipairs(names) do
                    table.insert(rows, { { text = name, callback = function()
                        UIManager:close(picker)
                        local ns = draft()
                        ns.label = name ~= Store.NO_LABEL and name or nil
                        again(ns)
                    end } })
                end
                picker = ButtonDialog:new{ title = "Label", buttons = rows }
                UIManager:show(picker)
            end } },
            { { text = "Date: " .. os.date("%a %d %b %Y", s.start), callback = function()
                UIManager:show(DateTimeWidget:new{
                    year = t.year, month = t.month, day = t.day, year_min = this_year - 1, year_max = this_year,
                    title_text = "Date", ok_text = "Set",
                    callback = function(w)
                        local e = os.date("*t", s.stop)
                        local days = math.floor((os.time{ year = e.year, month = e.month, day = e.day, hour = 12 }
                            - at(t.day, 12)) / 86400 + 0.5)
                        local ns = draft()
                        ns.start = os.time{ year = w.year, month = w.month, day = w.day, hour = t.hour, min = t.min, sec = t.sec }
                        ns.stop = os.time{ year = w.year, month = w.month, day = w.day + days, hour = e.hour, min = e.min, sec = e.sec }
                        again(ns)
                    end,
                })
            end } },
            { { text = "Start: " .. self:fmt_time(s.start), callback = function()
                UIManager:show(DateTimeWidget:new{
                    hour = t.hour, min = t.min, title_text = "Start", ok_text = "Set",
                    callback = function(w)
                        local ns = draft()
                        ns.start = at(t.day, w.hour, w.min)
                        again(ns)
                    end,
                })
            end } },
            { { text = "End: " .. end_text, callback = function()
                local e = os.date("*t", s.stop)
                UIManager:show(DateTimeWidget:new{
                    hour = e.hour, min = e.min, title_text = "End", ok_text = "Set",
                    info_text = "An end before the start time is on the next day.",
                    callback = function(w)
                        local ns = draft()
                        local next_day = w.hour * 60 + w.min < t.hour * 60 + t.min
                        ns.stop = at(t.day + (next_day and 1 or 0), w.hour, w.min)
                        again(ns)
                    end,
                })
            end } },
            last,
        },
    }
    UIManager:show(dialog)
end

function StopwatchWidget:onHistory()
    local menu
    local function items()
        local list = { { text = "+ Add past session", callback = function()
            local now = os.time() - os.time() % 60
            self:editSession("add", { label = Store.last_label(self.data), start = now - 3600, stop = now }, nil,
                function() menu:switchItemTable(nil, items()) end)
        end } }
        for i = #self.data.sessions, 1, -1 do
            local s = self.data.sessions[i]
            table.insert(list, {
                text = os.date("%a %d %b  ", s.start) .. self:fmt_time(s.start) .. " - " .. self:fmt_time(s.stop)
                    .. "  " .. (s.label or Store.NO_LABEL),
                mandatory = hm(s.secs),
                callback = function()
                    self:editSession("edit", { label = s.label, start = s.start, stop = s.stop }, s, function()
                        menu:switchItemTable(nil, items(), (menu.page - 1) * menu.perpage + 1)
                    end)
                end,
            })
        end
        if next(self.data.days) then
            table.insert(list, { text = "Older than 12 months: day totals only", dim = true, select_enabled = false })
        end
        return list
    end
    menu = Menu:new{
        title = "History", item_table = items(), covers_fullscreen = true, is_borderless = true, is_popout = false,
        width = Screen:getWidth(), height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

-- The idle view is painted turned 90 degrees clockwise: the top of its text lies along the
-- right edge of the portrait screen.
function StopwatchWidget:enterIdle()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local LW, LH = H, W
    local pad = Screen:scaleBySize(24)
    local now = os.time()
    local st = self.data.state
    local name = st.label or Store.NO_LABEL
    local label = {}
    for _, l in ipairs(self.data.labels) do
        if l.name == name then label = l end
    end
    local size = 150
    while size > 40 and text("00:00:00", BOLD, size):getSize().w > LW - 2 * pad do size = size - 10 end
    local box_w = text("00:00:00", BOLD, size):getSize().w + pad
    self.idle_label = label
    self.idle_time = text(hms(Store.elapsed(st, now)), BOLD, size)
    self.idle_time_box = FrameContainer:new{ bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = box_w, h = self.idle_time:getSize().h }, self.idle_time } }
    local goal = goal_text(label, Store.totals(self.data, now).labels[name] or 0)
    self.idle_goal = text(goal ~= "" and goal or " ", SANS, 30, GRAY)
    self.idle_goal_box = FrameContainer:new{ bordersize = 0, padding = 0,
        CenterContainer:new{ dimen = Geom:new{ w = LW - 2 * pad, h = self.idle_goal:getSize().h }, self.idle_goal } }
    self.idle_view = CenterContainer:new{
        dimen = Geom:new{ w = LW, h = LH },
        VerticalGroup:new{
            align = "center",
            text(name, SANS_BOLD, 40, BLACK, LW - 2 * pad),
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
            self.idle_time_box,
            VerticalSpan:new{ width = Screen:scaleBySize(16) },
            self.idle_goal_box,
        },
    }
    UIManager:setDirty(self, "full")
end

-- A landscape rect of the idle view, as the portrait screen rect it is painted to.
function StopwatchWidget:idleRect(d)
    return Geom:new{ x = self.dimen.w - (d.y + d.h), y = d.x, w = d.h, h = d.w }
end

function StopwatchWidget:freeIdle()
    if not self.idle_view then return end
    self.idle_view:free()
    self.idle_view = nil
    if self.idle_bb then
        self.idle_bb:free()
        self.idle_bb = nil
    end
end

function StopwatchWidget:paintTo(bb, x, y)
    if not self.idle_view then return InputContainer.paintTo(self, bb, x, y) end
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.idle_bb = self.idle_bb or Blitbuffer.new(W, H, bb:getType())
    self.idle_bb:fill(WHITE)
    self.idle_bb:rotateAbsolute(90)
    self.idle_view:paintTo(self.idle_bb, 0, 0)
    self.idle_bb:rotateAbsolute(0)
    bb:blitFrom(self.idle_bb, x, y, 0, 0, W, H)
end

function StopwatchWidget:handleEvent(event)
    if event.handler == "onGesture" then
        self.last_touch = os.time()
        local ges = event.args[1] and event.args[1].ges
        if self.idle_view then
            self:freeIdle()
            self:refresh(true)
            self.swallow_until = not TOUCH_ENDS[ges] and os.time() + 3 or nil
            return true
        end
        if self.swallow_until then
            if os.time() < self.swallow_until then
                if TOUCH_ENDS[ges] then self.swallow_until = nil end
                return true
            end
            self.swallow_until = nil
        end
    end
    return InputContainer.handleEvent(self, event)
end

function StopwatchWidget:onTick()
    local now = os.time()
    local st = self.data.state
    local on_top = UIManager:getTopmostVisibleWidget() == self
    if not on_top then self.last_touch = now end
    local new_minute = math.floor(now / 60) ~= self.minute
    if self.idle_view then
        self.idle_time:setText(hms(Store.elapsed(st, now)))
        UIManager:setDirty(self, function() return "ui", self:idleRect(self.idle_time_box.dimen) end)
        if new_minute then
            self.minute = math.floor(now / 60)
            local goal = goal_text(self.idle_label, Store.totals(self.data, now).labels[st.label or Store.NO_LABEL] or 0)
            self.idle_goal:setText(goal ~= "" and goal or " ")
            UIManager:setDirty(self, function() return "ui", self:idleRect(self.idle_goal_box.dimen) end)
        end
    elseif st.running and on_top and now - self.last_touch >= self.idle_secs then
        self:enterIdle()
    elseif new_minute and (st.running or os.date("%Y-%m-%d", now) ~= self.day) then
        self:refresh()
    elseif st.running and on_top then
        self.time_text:setText(hms(Store.elapsed(st, now)))
        UIManager:setDirty(self, function() return "ui", self.time_box.dimen end)
    end
    self:schedule()
end

-- Data changes only through this widget while it is open, so it is not loaded again here:
-- an open History list holds sessions of self.data.
function StopwatchWidget:onResume()
    if self.data.state.running then StopwatchWidget.keep_awake(true) end
    self.last_touch = os.time()
    -- KOReader already does a full refresh on wake.
    self:refresh()
    self:schedule()
end

function StopwatchWidget:onSuspend()
    UIManager:unschedule(self.tick)
    self:freeIdle()
    StopwatchWidget.keep_awake(false)
end

function StopwatchWidget:onCloseWidget()
    UIManager:unschedule(self.tick)
    self:freeIdle()
    StopwatchWidget.keep_awake(false)
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "ui")
end

return StopwatchWidget

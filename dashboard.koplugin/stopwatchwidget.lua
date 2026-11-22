local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Store = require("focusstore")

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

local function text(s, font, size, fg)
    return TextWidget:new{ text = s, face = Font:getFace(font, size), fgcolor = fg or BLACK }
end

local function hms(secs)
    return string.format("%d:%02d:%02d", math.floor(secs / 3600), math.floor(secs / 60) % 60, secs % 60)
end

local function hm(secs)
    local mins = math.floor(secs / 60)
    if mins < 60 then return mins .. " min" end
    return string.format("%d h %02d min", math.floor(mins / 60), mins % 60)
end

function StopwatchWidget:fmt_time(t)
    if self.clock12 then return (os.date("%I:%M %p", t):gsub("^0", "")) end
    return os.date("%H:%M", t)
end

function StopwatchWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.data, self.store = Store.load()
    self.tick = function() self:onTick() end
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
    local W, H = self.dimen.w, self.dimen.h
    local pad = Screen:scaleBySize(18)
    local inner = W - 2 * pad
    local now = os.time()
    local st = self.data.state
    self.minute = math.floor(now / 60)

    local line = function()
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = Screen:scaleBySize(14) },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    end

    local top = HorizontalGroup:new{
        LeftContainer:new{ dimen = Geom:new{ w = inner / 2, h = Screen:scaleBySize(40) }, text("Focus", SANS_BOLD, 22) },
        RightContainer:new{ dimen = Geom:new{ w = inner / 2, h = Screen:scaleBySize(40) }, text(self:fmt_time(now), SANS, 20) },
    }

    local status = st.running and "RUNNING" or (st.started and "PAUSED" or "READY")
    self.time_text = text(hms(Store.elapsed(st, now)), BOLD, 96)
    self.time_box = FrameContainer:new{
        bordersize = Screen:scaleBySize(1), color = GRAY, padding = Screen:scaleBySize(10),
        padding_left = Screen:scaleBySize(24), padding_right = Screen:scaleBySize(24),
        self.time_text,
    }
    local started = st.started and ("Started " .. self:fmt_time(st.started)) or "Tap Start to begin"
    local middle = VerticalGroup:new{
        align = "center",
        text(status, SANS_BOLD, 20, GRAY),
        VerticalSpan:new{ width = Screen:scaleBySize(10) },
        self.time_box,
        VerticalSpan:new{ width = Screen:scaleBySize(12) },
        text(started, SANS, 18, GRAY),
    }

    local totals = Store.totals(self.data, now)
    local cw = math.floor(inner / 3)
    local stats = HorizontalGroup:new{}
    for _, c in ipairs({ { "Today", totals.today }, { "This week", totals.week }, { "This month", totals.month } }) do
        table.insert(stats, CenterContainer:new{ dimen = Geom:new{ w = cw, h = Screen:scaleBySize(64) },
            VerticalGroup:new{ align = "center", text(c[1], SANS, 16, GRAY), text(hm(c[2]), SANS_BOLD, 22) } })
    end

    local gap = Screen:scaleBySize(16)
    local bw = math.floor((inner - 2 * gap) / 3)
    local function btn(label, cb, enabled)
        local b = Button:new{ text = label, width = bw, bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(8),
            text_font_size = 20, callback = cb, show_parent = self }
        if enabled == false then b:disable() end
        return b
    end
    local main_label = st.running and "Pause" or (st.started and "Resume" or "Start")
    local buttons = HorizontalGroup:new{
        btn(main_label, function() self:onMain() end),
        HorizontalSpan:new{ width = gap },
        btn("Stop", function() self:onStop() end, st.started ~= nil),
        HorizontalSpan:new{ width = gap },
        btn("Dashboard", function() UIManager:close(self) end),
    }

    local fixed = top:getSize().h + middle:getSize().h + stats:getSize().h + buttons:getSize().h
        + 2 * Screen:scaleBySize(14) + 2 * pad
    local free = math.max(0, H - fixed)
    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = pad },
            CenterContainer:new{ dimen = Geom:new{ w = W, h = top:getSize().h }, top },
            line(),
            VerticalSpan:new{ width = math.floor(free * 0.35) },
            middle,
            VerticalSpan:new{ width = math.floor(free * 0.35) },
            line(),
            stats,
            VerticalSpan:new{ width = free - 2 * math.floor(free * 0.35) },
            buttons,
        },
    }
end

function StopwatchWidget:refresh(full)
    self:build()
    UIManager:setDirty(self, full and "full" or "ui")
end

function StopwatchWidget:onMain()
    local now = os.time()
    local st = self.data.state
    if st.running then Store.pause(self.data, now)
    elseif st.started then Store.resume(self.data, now)
    else Store.start(self.data, now) end
    Store.save(self.data, self.store)
    self:refresh()
    self:schedule()
end

function StopwatchWidget:onStop()
    if not self.data.state.started then return end
    local _, saved = Store.stop(self.data, os.time())
    Store.save(self.data, self.store)
    if not saved then
        UIManager:show(require("ui/widget/infomessage"):new{ text = "Not saved: shorter than 1 min.", timeout = 3 })
    end
    self:refresh()
    self:schedule()
end

function StopwatchWidget:onTick()
    local now = os.time()
    if math.floor(now / 60) ~= self.minute then
        -- header clock and totals change once a minute
        self:refresh()
    elseif self.data.state.running then
        self.time_text:setText(hms(Store.elapsed(self.data.state, now)))
        UIManager:setDirty(self, function() return "ui", self.time_box.dimen end)
    end
    self:schedule()
end

function StopwatchWidget:onResume()
    self.data, self.store = Store.load()
    -- KOReader already does a full refresh on wake.
    self:refresh()
    self:schedule()
end

function StopwatchWidget:onSuspend()
    UIManager:unschedule(self.tick)
end

function StopwatchWidget:onCloseWidget()
    UIManager:unschedule(self.tick)
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "ui")
end

return StopwatchWidget

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local Hijri = require("hijri")
local PT = require("prayertimes")
local Weather = require("weather")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_4

local FONTS = "../plugins/dashboard.koplugin/fonts/"
local SANS, SANS_BOLD = FONTS .. "IBMPlexSans-Regular.ttf", FONTS .. "IBMPlexSans-SemiBold.ttf"
local ARABIC = FONTS .. "Zain-Bold.ttf"

local DashboardWidget = InputContainer:extend{
    name = "dashboard_widget",
    covers_fullscreen = true,
    cfg = nil,
}

local function text(s, font, size, opts)
    opts = opts or {}
    return TextWidget:new{
        text = s,
        face = Font:getFace(font, size),
        fgcolor = opts.fg or BLACK,
        bold = opts.bold,
        max_width = opts.max_width,
    }
end

local function box(widget, w, h, align)
    local C = align == "left" and LeftContainer or align == "right" and RightContainer or CenterContainer
    return C:new{ dimen = Geom:new{ w = w, h = h or widget:getSize().h }, widget }
end

function DashboardWidget:h12() return self.cfg.clock ~= "24h" end

function DashboardWidget:fmt_time(epoch)
    if self:h12() then return (os.date("%I:%M %p", epoch):gsub("^0", "")) end
    return os.date("%H:%M", epoch)
end

local function countdown(secs)
    local mins = math.ceil(secs / 60)
    local h, m = math.floor(mins / 60), mins % 60
    if h > 0 then return string.format("in %d h %02d min", h, m) end
    return string.format("in %d min", m)
end

function DashboardWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.minutes = 0
    self.tick = function() self:onTick() end
    self:build()
    UIManager:nextTick(function() self:updateWeather(true) end)
    self:schedule()
end

function DashboardWidget:schedule()
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(60 - (os.time() % 60) + 0.3, self.tick)
end

function DashboardWidget:build()
    local cfg = self.cfg
    local W, H = self.dimen.w, self.dimen.h
    local pad = Screen:scaleBySize(18)
    local inner = W - 2 * pad
    local now = os.time()
    local times, wday = PT.day(now, cfg)
    local next_key, next_at = PT.next(now, cfg)
    self.next_key = next_key
    local lt = os.date("*t", now)
    local hy, hm, hd = Hijri.from_gregorian(lt.year, lt.month, lt.day, cfg.hijri_offset)

    -- Header: dates
    local header = VerticalGroup:new{
        align = "center",
        text(os.date("%A, %B ", now) .. lt.day .. ", " .. lt.year, SANS_BOLD, 18),
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        HorizontalGroup:new{
            align = "center",
            text(string.format("%d %s %d AH", hd, Hijri.months_en[hm], hy), SANS, 16),
            HorizontalSpan:new{ width = Screen:scaleBySize(16) },
            text(Hijri.months_ar[hm], ARABIC, 16),
        },
    }

    -- Clock + next prayer
    local next_en, next_ar = PT.name(next_key, next_at == times[next_key] and wday or os.date("*t", next_at).wday)
    local live = VerticalGroup:new{
        align = "center",
        text(self:fmt_time(now), SANS_BOLD, 62),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        HorizontalGroup:new{
            align = "center",
            text(next_en, SANS_BOLD, 28),
            HorizontalSpan:new{ width = Screen:scaleBySize(20) },
            text(next_ar, ARABIC, 28),
        },
        text(countdown(next_at - now) .. "  ·  " .. self:fmt_time(next_at), SANS, 20),
    }
    self.live = CenterContainer:new{ dimen = Geom:new{ w = W, h = live:getSize().h }, live }

    -- Prayer table
    local row_h = Screen:scaleBySize(36)
    local col = { inner * 0.38, inner * 0.24, inner * 0.38 }
    local rows = VerticalGroup:new{ align = "center" }
    for _, k in ipairs(PT.order) do
        local en, ar = PT.name(k, wday)
        local hl = (k == next_key and next_at == times[k])
        local fg = hl and WHITE or (k == "sunrise" and GRAY or BLACK)
        local row = HorizontalGroup:new{
            box(text(en, hl and SANS_BOLD or SANS, 20, { fg = fg }), col[1] - pad, row_h, "left"),
            box(text(self:fmt_time(times[k]), hl and SANS_BOLD or SANS, 20, { fg = fg }), col[2], row_h),
            box(text(ar, ARABIC, 20, { fg = fg }), col[3] - pad, row_h, "right"),
        }
        table.insert(rows, FrameContainer:new{
            bordersize = 0, margin = 0,
            padding = 0, padding_left = pad, padding_right = pad,
            background = hl and BLACK or WHITE,
            row,
        })
    end

    -- Weather
    local wx = VerticalGroup:new{ align = "center" }
    local d = self.weather
    if d then
        local unit = cfg.temperature_unit == "fahrenheit" and "°F" or "°C"
        local c = d.current
        local day = d.daily or {}
        local hi = day.temperature_2m_max and day.temperature_2m_max[1]
        local lo = day.temperature_2m_min and day.temperature_2m_min[1]
        table.insert(wx, HorizontalGroup:new{
            align = "center",
            text(string.format("%d%s", math.floor(c.temperature_2m + 0.5), unit), SANS_BOLD, 34),
            HorizontalSpan:new{ width = Screen:scaleBySize(20) },
            VerticalGroup:new{
                align = "left",
                text(Weather.describe(c.weather_code), SANS_BOLD, 20),
                text(string.format("Feels %d° · H %d° L %d°", math.floor(c.apparent_temperature + 0.5),
                    math.floor((hi or 0) + 0.5), math.floor((lo or 0) + 0.5)), SANS, 16),
            },
        })
        table.insert(wx, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(wx, text(Weather.rain_line(d, now, self:h12()), SANS_BOLD, 18))
        table.insert(wx, VerticalSpan:new{ width = Screen:scaleBySize(10) })
        local hours = HorizontalGroup:new{ align = "center" }
        local list = Weather.next_hours(d, now, 6, self:h12())
        local cw = math.floor(inner / math.max(1, #list))
        for _, hpt in ipairs(list) do
            table.insert(hours, VerticalGroup:new{
                align = "center",
                box(text(hpt.label, SANS, 16), cw),
                box(text(string.format("%d°", math.floor(hpt.temp + 0.5)), SANS_BOLD, 20), cw),
                box(text(string.format("%d%%", hpt.pop or 0), SANS, 14, { fg = GRAY }), cw),
            })
        end
        table.insert(wx, hours)
        table.insert(wx, text("Updated " .. self:fmt_time(d.fetched_at) .. " · " .. cfg.place, SANS, 13, { fg = GRAY }))
    else
        table.insert(wx, text(self.weather_error and ("Weather: " .. self.weather_error) or "Weather: loading…",
            SANS, 18, { fg = GRAY }))
    end

    -- Buttons
    local bw = math.floor(inner / 3) - Screen:scaleBySize(8)
    local function btn(label, cb)
        return Button:new{ text = label, width = bw, bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(8),
            text_font_size = 18, callback = cb, show_parent = self }
    end
    local buttons = HorizontalGroup:new{
        btn("Books", function() UIManager:close(self) end),
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        btn("Refresh", function() self:updateWeather(true) end),
        HorizontalSpan:new{ width = Screen:scaleBySize(12) },
        btn("Kindle", function()
            UIManager:close(self)
            UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
        end),
    }

    local sep = function()
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = Screen:scaleBySize(14) },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    end

    local body = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = pad },
        header,
        sep(),
        self.live,
        sep(),
        rows,
        sep(),
        wx,
    }
    local used = body:getSize().h
    local bh = buttons:getSize().h
    table.insert(body, VerticalSpan:new{ width = math.max(0, H - used - bh - pad) })
    table.insert(body, buttons)
    body:resetLayout()

    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, body },
    }
end

function DashboardWidget:onTick()
    self.minutes = self.minutes + 1
    local prev_next = self.next_key
    local wx_due = (not self.weather) or (os.time() - (self.weather.fetched_at or 0) >= self.cfg.weather_minutes * 60)
    if wx_due then
        self:updateWeather(false)
    else
        self:build()
        if self.minutes % self.cfg.full_refresh_minutes == 0 then
            UIManager:setDirty(self, "full")
        elseif prev_next ~= self.next_key then
            UIManager:setDirty(self, "ui")
        else
            UIManager:setDirty(self, function() return "ui", self.live.dimen end)
        end
    end
    self:schedule()
end

function DashboardWidget:updateWeather(user)
    if NetworkMgr:isConnected() then
        local ok, data, err = pcall(Weather.fetch, self.cfg.lat, self.cfg.lon, self.cfg.temperature_unit)
        if ok and data then
            self.weather, self.weather_error = data, nil
        else
            self.weather_error = ok and err or tostring(data)
            logger.warn("dashboard weather:", self.weather_error)
        end
    elseif not self.weather then
        self.weather_error = "offline"
    end
    self:build()
    UIManager:setDirty(self, user and "flashui" or "ui")
end

function DashboardWidget:onResume()
    self:build()
    UIManager:setDirty(self, "full")
    self:schedule()
    UIManager:scheduleIn(5, function() self:updateWeather(false) end)
end

function DashboardWidget:onSuspend()
    UIManager:unschedule(self.tick)
end

function DashboardWidget:onCloseWidget()
    UIManager:unschedule(self.tick)
    UIManager:setDirty(nil, "full")
end

return DashboardWidget

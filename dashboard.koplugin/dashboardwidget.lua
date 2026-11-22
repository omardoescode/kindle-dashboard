local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local ProgressWidget = require("ui/widget/progresswidget")
local RenderImage = require("ui/renderimage")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local FocusStore = require("focusstore")
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

-- Cover of the last book, kept for the session: extracting it opens the whole document.
local cover_cache = {}

local function cover_for(path, w, h)
    if cover_cache.path == path then return cover_cache.bb end
    cover_cache.path, cover_cache.bb = path, nil
    local img
    -- The cover browser keeps covers in its database; opening the book is the slow fallback.
    local ok, BIM = pcall(require, "bookinfomanager")
    if ok and BIM then
        local bok, info = pcall(BIM.getBookInfo, BIM, path, true)
        if bok and info and info.cover_bb then img = info.cover_bb end
    end
    if not img then
        local doc = DocumentRegistry:openDocument(path)
        if doc then
            if not doc.loadDocument or doc:loadDocument(false) then
                local gok, g = pcall(doc.getCoverPageImage, doc)
                if gok then img = g end
            end
            doc:close()
        end
    end
    if img then
        local scale = math.min(w / img:getWidth(), h / img:getHeight())
        cover_cache.bb = RenderImage:scaleBlitBuffer(img, math.floor(img:getWidth() * scale),
            math.floor(img:getHeight() * scale), true)
    end
    return cover_cache.bb
end

local function book_info(path)
    local ds = DocSettings:open(path)
    local props = ds:readSetting("doc_props") or {}
    local title = props.title
    if not title or title == "" then title = path:match("([^/]+)%.[^.]+$") or path end
    local author = props.authors and props.authors:match("^[^\n]+")
    if author then
        local last, first = author:match("^([^,]+),%s*([^,]+)$")
        if last then author = first .. " " .. last end
    end
    local info = { title = title, author = author, percent = ds:readSetting("percent_finished") or 0 }
    local md5 = ds:readSetting("partial_md5_checksum")
    if md5 and md5:match("^%x+$") then
        local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
        local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        if ok and lfs.attributes(db, "mode") == "file" then
            local rok, time, pages_read, pages = pcall(function()
                local conn = SQ3.open(db)
                local res = { conn:rowexec(
                    "SELECT total_read_time, total_read_pages, pages FROM book WHERE md5 = '" .. md5 .. "'") }
                conn:close()
                return unpack(res)
            end)
            time, pages_read, pages = tonumber(time), tonumber(pages_read), tonumber(pages)
            if rok and time and pages_read and pages and pages_read > 0 then
                info.secs_left = time / pages_read * pages * (1 - info.percent)
            end
        end
    end
    return info
end

local function time_left(secs)
    local mins = math.floor(secs / 60 + 0.5)
    local h, m = math.floor(mins / 60), mins % 60
    if h > 0 then return string.format("%d h %02d min left", h, m) end
    return string.format("%d min left", m)
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
    if Device:hasFrontlight() then
        local edge = math.floor(self.dimen.w * 0.15)
        self.ges_events = {
            LeftEdgeSwipe = { GestureRange:new{ ges = "swipe",
                range = Geom:new{ x = 0, y = 0, w = edge, h = self.dimen.h } } },
            RightEdgeSwipe = { GestureRange:new{ ges = "swipe",
                range = Geom:new{ x = self.dimen.w - edge, y = 0, w = edge, h = self.dimen.h } } },
        }
    end
    self.weather = Weather.last
    self:loadCaches()
    self:safeBuild()
    if self:weatherDue(os.time()) then
        UIManager:nextTick(function() self:updateWeather(true) end)
    end
    self:schedule()
end

-- Book and focus data change only when a book closes, the device wakes or the stopwatch closes.
function DashboardWidget:loadCaches()
    local last = G_reader_settings:readSetting("lastfile")
    if last and lfs.attributes(last, "mode") == "file" then
        local ok, info = pcall(book_info, last)
        self.book = { path = last, info = ok and info or { title = last:match("([^/]+)$"), percent = 0 } }
    else
        self.book = nil
    end
    local ok, data = pcall(FocusStore.load)
    self.focus_running = ok and data.state.started ~= nil
end

function DashboardWidget:safeBuild()
    local ok, err = pcall(self.build, self)
    if not ok then logger.warn("dashboard build:", err) end
    return ok
end

function DashboardWidget:weatherDue(now)
    if self.weather_error then return now - (self.weather_tried_at or 0) >= 5 * 60 end
    return not self.weather or now - (self.weather.fetched_at or 0) >= self.cfg.weather_minutes * 60
end

function DashboardWidget:weatherStale(now)
    return self.weather ~= nil and now - (self.weather.fetched_at or 0) > 2 * 3600
end

local function swipe_steps(ges)
    local sign = (ges.direction == "north" and 1) or (ges.direction == "south" and -1) or 0
    return sign * math.max(1, math.floor(ges.distance / Screen:scaleBySize(60)))
end

function DashboardWidget:onLeftEdgeSwipe(_, ges)
    local steps = swipe_steps(ges)
    if steps == 0 then return true end
    local powerd = Device:getPowerDevice()
    powerd:setIntensity(powerd:frontlightIntensity() + steps)
    return true
end

function DashboardWidget:onRightEdgeSwipe(_, ges)
    local steps = swipe_steps(ges)
    if steps == 0 or not Device:hasNaturalLight() then return true end
    local powerd = Device:getPowerDevice()
    powerd:setWarmth(powerd:frontlightWarmth() + 5 * steps)
    return true
end

function DashboardWidget:schedule()
    UIManager:unschedule(self.tick)
    UIManager:scheduleIn(60 - (os.time() % 60) + 0.3, self.tick)
end

function DashboardWidget:liveGroup(now)
    local cfg = self.cfg
    local times, wday = PT.day(now, cfg)
    local next_key, next_at = PT.next(now, cfg)
    local next_en, next_ar = PT.name(next_key, next_at == times[next_key] and wday or os.date("*t", next_at).wday)
    return VerticalGroup:new{
        align = "center",
        text(self:fmt_time(now), SANS_BOLD, 54),
        VerticalSpan:new{ width = Screen:scaleBySize(6) },
        HorizontalGroup:new{
            align = "center",
            text(next_en, SANS_BOLD, 28),
            HorizontalSpan:new{ width = Screen:scaleBySize(20) },
            text(next_ar, ARABIC, 28),
        },
        text(countdown(next_at - now) .. "  ·  " .. self:fmt_time(next_at), SANS, 20),
    }
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
    self.day = os.date("%Y%m%d", now)
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
    local live = self:liveGroup(now)
    self.live = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = live:getSize().h }, live },
    }

    -- Prayer table
    local row_h = Screen:scaleBySize(30)
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
                text(string.format("Feels %d°", math.floor(c.apparent_temperature + 0.5))
                    .. ((Weather.num(hi) and Weather.num(lo))
                        and string.format(" · H %d° L %d°", math.floor(hi + 0.5), math.floor(lo + 0.5)) or ""), SANS, 16),
            },
        })
        table.insert(wx, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(wx, text(Weather.rain_line(d, now, self:h12()), SANS_BOLD, 18))
        table.insert(wx, VerticalSpan:new{ width = Screen:scaleBySize(4) })
        local hours = HorizontalGroup:new{ align = "center" }
        local list = Weather.next_hours(d, now, 6, self:h12())
        local cw = math.floor(inner / math.max(1, #list))
        for _, hpt in ipairs(list) do
            table.insert(hours, VerticalGroup:new{
                align = "center",
                box(text(hpt.label, SANS, 16), cw),
                box(HorizontalGroup:new{
                    align = "center",
                    text(string.format("%d°", math.floor(hpt.temp + 0.5)), SANS_BOLD, 20),
                    HorizontalSpan:new{ width = Screen:scaleBySize(6) },
                    text(string.format("%d%%", hpt.pop or 0), SANS, 14, { fg = GRAY }),
                }, cw),
            })
        end
        table.insert(wx, hours)
        self.stale_shown = self:weatherStale(now)
        if self.stale_shown then
            local same_day = os.date("%Y%m%d", d.fetched_at) == os.date("%Y%m%d", now)
            local when = (same_day and "" or os.date("%b %d, ", d.fetched_at)) .. self:fmt_time(d.fetched_at)
            table.insert(wx, text("Updated " .. when .. (self.weather_error and " · " .. self.weather_error or ""),
                SANS, 13, { fg = GRAY }))
        end
    else
        table.insert(wx, text(self.weather_error and ("Weather: " .. self.weather_error) or "Weather: loading…",
            SANS, 18, { fg = GRAY }))
    end

    -- Last book card + buttons
    local gap = Screen:scaleBySize(12)
    local card_h = Screen:scaleBySize(112)
    local cover_w, cover_h = math.floor(card_h * 2 / 3), card_h
    local col_w = math.floor(inner * 0.40)
    local bw = math.floor((col_w - gap) / 2)
    local bh = math.floor((card_h - Screen:scaleBySize(6)) / 2)
    local function btn(label, cb)
        return Button:new{ text = label, width = bw, height = bh, bordersize = Screen:scaleBySize(2), padding = 0,
            margin = 0, radius = Screen:scaleBySize(8), text_font_size = 17, callback = cb, show_parent = self }
    end
    local vgap = Screen:scaleBySize(6)
    local buttons = VerticalGroup:new{
        HorizontalGroup:new{
            btn("Books", function() UIManager:close(self) end),
            HorizontalSpan:new{ width = gap },
            btn(self.focus_running and "Focus •" or "Focus", function()
                self.covered = true
                UIManager:show(require("stopwatchwidget"):new{
                    clock12 = self:h12(),
                    on_close = function()
                        self.covered = false
                        if self.closed then return end
                        self:loadCaches()
                        self:safeBuild()
                        UIManager:setDirty(self, "full")
                    end,
                }, "full")
            end),
        },
        VerticalSpan:new{ width = vgap },
        HorizontalGroup:new{
            btn("Refresh", function() self:updateWeather(true) end),
            HorizontalSpan:new{ width = gap },
            btn("Kindle", function()
                UIManager:close(self)
                UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("Exit")) end)
            end),
        },
    }

    local card_w = inner - col_w - gap
    local card
    if self.book then
        local last, info = self.book.path, self.book.info
        local bb = cover_cache.path == last and cover_cache.bb
        if cover_cache.path ~= last then
            UIManager:nextTick(function()
                if self.closed then return end
                pcall(cover_for, last, cover_w, cover_h)
                if self.covered then return end
                self:safeBuild()
                UIManager:setDirty(self, "ui")
            end)
        end
        local cover = bb and ImageWidget:new{ image = bb, image_disposable = false }
            or CenterContainer:new{ dimen = Geom:new{ w = cover_w, h = cover_h },
                text(cover_cache.path == last and "No cover" or "…", SANS, 12, { fg = GRAY }) }
        local text_w = card_w - cover_w - gap
        local details = VerticalGroup:new{
            align = "left",
            text(info.title, SANS_BOLD, 20, { max_width = text_w }),
        }
        if info.author then table.insert(details, text(info.author, SANS, 16, { fg = GRAY, max_width = text_w })) end
        table.insert(details, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        table.insert(details, ProgressWidget:new{
            width = math.floor(text_w * 0.85), height = Screen:scaleBySize(8), percentage = info.percent,
            margin_h = 0, margin_v = 0, radius = Screen:scaleBySize(4), bordersize = Screen:scaleBySize(1),
            fillcolor = BLACK, bordercolor = BLACK,
        })
        table.insert(details, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        local status = string.format("%d%%", math.floor(info.percent * 100 + 0.5))
        if info.secs_left then status = status .. " · " .. time_left(info.secs_left) end
        table.insert(details, text(status, SANS, 15, { fg = GRAY }))
        card = InputContainer:new{
            dimen = Geom:new{ w = card_w, h = card_h },
            HorizontalGroup:new{
                align = "center",
                FrameContainer:new{ bordersize = Screen:scaleBySize(1), padding = 0, margin = 0, cover },
                HorizontalSpan:new{ width = gap },
                box(details, text_w, card_h, "left"),
            },
        }
        card.ges_events = { TapCard = { GestureRange:new{ ges = "tap", range = function() return card.dimen end } } }
        card.onTapCard = function()
            UIManager:close(self)
            UIManager:nextTick(function() require("apps/reader/readerui"):showReader(last) end)
            return true
        end
    else
        card = CenterContainer:new{ dimen = Geom:new{ w = card_w, h = card_h }, text("No book opened yet", SANS, 18, { fg = GRAY }) }
    end
    local bottom = HorizontalGroup:new{
        align = "center",
        box(card, card_w, card_h, "left"),
        HorizontalSpan:new{ width = gap },
        buttons,
    }

    local sep = function()
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = Screen:scaleBySize(12) },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    end

    local parts = { header, sep(), self.live, sep(), rows, sep(), wx, sep(), bottom }
    local total = 0
    for _, p in ipairs(parts) do total = total + p:getSize().h end
    -- Share the free height equally around the 4 separators.
    local space = math.max(0, math.floor((H - 2 * pad - total) / 8))
    local body = VerticalGroup:new{ align = "center", VerticalSpan:new{ width = pad } }
    for i, p in ipairs(parts) do
        if i % 2 == 0 then table.insert(body, VerticalSpan:new{ width = space }) end
        table.insert(body, p)
        if i % 2 == 0 then table.insert(body, VerticalSpan:new{ width = space }) end
    end

    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = H }, body },
    }
end

function DashboardWidget:onTick()
    self:schedule()
    if self.covered then return end
    self.minutes = self.minutes + 1
    local now = os.time()
    local full = self.minutes % self.cfg.full_refresh_minutes == 0
    local next_key = PT.next(now, self.cfg)
    if full or next_key ~= self.next_key or os.date("%Y%m%d", now) ~= self.day
        or self:weatherStale(now) ~= (self.stale_shown or false) or not (self.live.dimen and self.live.dimen.x) then
        self:safeBuild()
        UIManager:setDirty(self, full and "full" or "ui")
    else
        self:updateLive(now)
    end
    if self:weatherDue(now) then self:updateWeather(false) end
end

-- Repaint only the clock block: rebuilding and painting the whole screen each minute costs CPU for nothing.
function DashboardWidget:updateLive(now)
    local frame = self.live
    local ok, group = pcall(self.liveGroup, self, now)
    if not ok then logger.warn("dashboard live:", group) return end
    frame[1][1] = group
    UIManager:widgetRepaint(frame, frame.dimen.x, frame.dimen.y)
    UIManager:setDirty(nil, function() return "ui", frame.dimen end)
end

function DashboardWidget:updateWeather(user)
    if self.closed or self.fetching then return end
    self.weather_tried_at = os.time()
    if not NetworkMgr:isConnected() then
        self.weather_error = "offline"
        if self.covered then return end
        self:safeBuild()
        UIManager:setDirty(self, "ui")
        return
    end
    self.fetching = true
    Weather.fetch_async(self.cfg.lat, self.cfg.lon, self.cfg.temperature_unit, function(data, err)
        self.fetching = false
        if self.closed then return end
        if data then
            self.weather, self.weather_error = data, nil
        else
            self.weather_error = err or "error"
            logger.warn("dashboard weather:", self.weather_error)
        end
        if self.covered then return end
        self:safeBuild()
        UIManager:setDirty(self, "ui")
    end)
end

function DashboardWidget:onResume()
    self:schedule()
    if self.covered then return end
    self:loadCaches()
    self:safeBuild()
    -- KOReader already does a full refresh on wake.
    UIManager:setDirty(self, "ui")
    UIManager:scheduleIn(5, function()
        if self:weatherDue(os.time()) then self:updateWeather(false) end
    end)
end

function DashboardWidget:onSuspend()
    UIManager:unschedule(self.tick)
end

function DashboardWidget:onCloseWidget()
    self.closed = true
    UIManager:unschedule(self.tick)
    UIManager:setDirty(nil, "ui")
end

return DashboardWidget

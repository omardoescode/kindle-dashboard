-- Our parts of the Simple UI Home screen: prayer times, weather, focus and adhkar.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")

local Adhkar = require("adhkar")
local FocusStore = require("focusstore")
local Hijri = require("hijri")
local PT = require("prayertimes")
local SUI = require("suiadapter")
local Weather = require("weather")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local ARABIC = "../plugins/dashboard.koplugin/fonts/Zain-Bold.ttf"
local SETTINGS = DataStorage:getSettingsDir()

local DEFAULTS = {
    place = "Minneapolis",
    lat = 44.9778,
    lon = -93.2650,
    method = "isna",
    madhab = "shafi",
    clock = "12h",
    hijri_offset = 0,
    temperature_unit = "celsius",
    full_refresh_minutes = 30,
    weather_minutes = 30,
    focus_idle_seconds = 5,
}

local Home = {}

local cfg
function Home.cfg()
    if not cfg then
        local store = LuaSettings:open(SETTINGS .. "/dashboard.lua")
        cfg = {}
        for k, v in pairs(DEFAULTS) do cfg[k] = store:readSetting(k, v) end
    end
    return cfg
end

local function fmt_time(epoch)
    if Home.cfg().clock ~= "24h" then return (os.date("%I:%M %p", epoch):gsub("^0", "")) end
    return os.date("%H:%M", epoch)
end

local function hm(secs)
    local mins = math.floor(secs / 60)
    local h, m = math.floor(mins / 60), mins % 60
    if h > 0 then return string.format("%d h %02d min", h, m) end
    return string.format("%d min", m)
end

local function countdown(secs)
    local mins = math.ceil(secs / 60)
    local h, m = math.floor(mins / 60), mins % 60
    if h > 0 then return string.format("in %d h %02d min", h, m) end
    return string.format("in %d min", m)
end

-- size is in Simple UI units, before the module scale.
local function text(look, s, size, opts)
    opts = opts or {}
    local st = SUI.style()
    local px = math.max(8, math.floor(size * look.scale + 0.5))
    return TextWidget:new{
        text = s,
        face = Font:getFace(opts.arabic and ARABIC or (opts.bold and st.bold or st.regular), px),
        lang = opts.arabic and "ar" or nil,
        fgcolor = opts.fg or look.ink.blk,
        max_width = opts.max_width,
    }
end

local function box(widget, w, align)
    local C = align == "left" and LeftContainer or align == "right" and RightContainer or CenterContainer
    return C:new{ dimen = Geom:new{ w = w, h = widget:getSize().h }, widget }
end

-- The files change only when the stopwatch or the adhkar screen saves; read them again only then.
local function cached(path, load, empty)
    local c = {}
    return function()
        local mtime = lfs.attributes(path, "modification")
        if c.data == nil or c.mtime ~= mtime then
            local ok, data = pcall(load)
            if not ok then logger.warn("dashboard: read", path, data) end
            c.data, c.mtime = ok and data or empty(), mtime
        end
        return c.data
    end
end
local focus_data = cached(SETTINGS .. "/dashboard_focus.lua", FocusStore.load,
    function() return { state = {}, sessions = {}, days = {}, labels = {} } end)
local adhkar_progress = cached(SETTINGS .. "/dashboard_adhkar.lua", Adhkar.load, function() return {} end)

local live = {}
local update

function Home.openStopwatch()
    UIManager:show(require("stopwatchwidget"):new{
        clock12 = Home.cfg().clock ~= "24h",
        idle_secs = Home.cfg().focus_idle_seconds,
        on_close = function() UIManager:nextTick(update) end,
    }, "full")
end

function Home.openAdhkar(set)
    UIManager:show(require("adhkarwidget"):new{
        cfg = Home.cfg(),
        set = set,
        on_close = function() UIManager:nextTick(update) end,
    }, "full")
end

-- Weather: the request runs in a child process (weather.lua); the result stays in Weather.last.
local wx = {}

local function weather_due(now)
    if wx.error then return now - (wx.tried_at or 0) >= 5 * 60 end
    return not Weather.last or now - (Weather.last.fetched_at or 0) >= Home.cfg().weather_minutes * 60
end

local function weather_stale(now)
    return Weather.last ~= nil and now - (Weather.last.fetched_at or 0) > 2 * 3600
end

local function fetch_weather()
    if wx.fetching then return end
    wx.tried_at = os.time()
    if not NetworkMgr:isConnected() then
        wx.error = "offline"
        return update()
    end
    wx.fetching = true
    local c = Home.cfg()
    Weather.fetch_async(c.lat, c.lon, c.temperature_unit, function(data, err)
        wx.fetching = false
        wx.error = not data and (err or "error") or nil
        if wx.error then logger.warn("dashboard weather:", wx.error) end
        update()
    end)
end

local MODULES = {
    {
        id = "dash_prayer",
        name = "Prayer times",
        state = function(now)
            local key, at = PT.next(now, Home.cfg())
            return key .. at .. countdown(at - now) .. os.date("%Y%m%d", now)
        end,
        draw = function(w, look, now)
            local c, st = Home.cfg(), SUI.style()
            local times, wday = PT.day(now, c)
            local next_key, next_at = PT.next(now, c)
            local today = next_at == times[next_key]
            local en, ar = PT.name(next_key, today and wday or os.date("*t", next_at).wday)
            local lt = os.date("*t", now)
            local hy, hmon, hd = Hijri.from_gregorian(lt.year, lt.month, lt.day, c.hijri_offset)
            local gap = Screen:scaleBySize(6)
            local col_w = math.floor(w / #PT.order)
            local cols = HorizontalGroup:new{ align = "top" }
            -- Right to left: Fajr on the right.
            for i = #PT.order, 1, -1 do
                local key = PT.order[i]
                local hl = today and key == next_key
                local fg = hl and WHITE or (key == "sunrise" and look.ink.sub or look.ink.blk)
                local n_en, n_ar = PT.name(key, wday)
                table.insert(cols, FrameContainer:new{
                    bordersize = 0, margin = 0, padding = 0, padding_top = gap, padding_bottom = gap,
                    radius = Screen:scaleBySize(8), background = hl and look.ink.blk or nil,
                    VerticalGroup:new{
                        align = "center",
                        box(text(look, n_en, st.detail, { fg = fg, max_width = col_w }), col_w),
                        box(text(look, n_ar, st.body, { arabic = true, fg = fg }), col_w),
                        box(text(look, fmt_time(times[key]), st.body, { bold = true, fg = fg }), col_w),
                    },
                })
            end
            return VerticalGroup:new{
                align = "center",
                box(HorizontalGroup:new{
                    align = "center",
                    text(look, en, st.title * 1.3, { bold = true }),
                    HorizontalSpan:new{ width = Screen:scaleBySize(16) },
                    text(look, ar, st.title * 1.3, { arabic = true }),
                }, w),
                box(text(look, countdown(next_at - now) .. "  ·  " .. fmt_time(next_at), st.body), w),
                VerticalSpan:new{ width = gap },
                box(HorizontalGroup:new{
                    align = "center",
                    text(look, string.format("%d %s %d AH", hd, Hijri.months_en[hmon], hy), st.detail, { fg = look.ink.sub }),
                    HorizontalSpan:new{ width = Screen:scaleBySize(12) },
                    text(look, Hijri.months_ar[hmon], st.detail, { arabic = true, fg = look.ink.sub }),
                }, w),
                VerticalSpan:new{ width = gap },
                cols,
            }
        end,
    },
    {
        id = "dash_weather",
        name = "Weather",
        label = "Weather",
        tap = function() fetch_weather() end,
        state = function(now)
            local d = Weather.last
            local stale = weather_stale(now)
            return tostring(d and d.fetched_at) .. tostring(wx.error) .. tostring(stale)
                .. (d and Weather.rain_line(d, now, Home.cfg().clock ~= "24h") or "") .. os.date("%Y%m%d%H", now)
        end,
        draw = function(w, look, now)
            local c, st = Home.cfg(), SUI.style()
            local d = Weather.last
            if weather_due(now) then UIManager:nextTick(fetch_weather) end
            if not d then
                return box(text(look, wx.error and ("Weather: " .. wx.error) or "Weather: loading…", st.body,
                    { fg = look.ink.sub }), w)
            end
            local h12 = c.clock ~= "24h"
            local unit = c.temperature_unit == "fahrenheit" and "°F" or "°C"
            local cur, day = d.current, d.daily or {}
            local hi = Weather.num(day.temperature_2m_max and day.temperature_2m_max[1])
            local lo = Weather.num(day.temperature_2m_min and day.temperature_2m_min[1])
            local group = VerticalGroup:new{
                align = "center",
                box(HorizontalGroup:new{
                    align = "center",
                    text(look, string.format("%d%s", math.floor(cur.temperature_2m + 0.5), unit), st.title * 1.5, { bold = true }),
                    HorizontalSpan:new{ width = Screen:scaleBySize(16) },
                    VerticalGroup:new{
                        align = "left",
                        text(look, Weather.describe(cur.weather_code), st.body, { bold = true }),
                        text(look, string.format("Feels %d°", math.floor(cur.apparent_temperature + 0.5))
                            .. ((hi and lo) and string.format(" · H %d° L %d°", math.floor(hi + 0.5), math.floor(lo + 0.5)) or ""),
                            st.detail, { fg = look.ink.sub }),
                    },
                }, w),
                box(text(look, Weather.rain_line(d, now, h12), st.body, { bold = true }), w),
                VerticalSpan:new{ width = Screen:scaleBySize(4) },
            }
            local list = Weather.next_hours(d, now, 6, h12)
            local cw = math.floor(w / 6)
            local hours = HorizontalGroup:new{ align = "center" }
            for _, p in ipairs(list) do
                table.insert(hours, VerticalGroup:new{
                    align = "center",
                    box(text(look, p.label, st.detail, { fg = look.ink.sub }), cw),
                    box(HorizontalGroup:new{
                        align = "center",
                        text(look, string.format("%d°", math.floor(p.temp + 0.5)), st.body, { bold = true }),
                        HorizontalSpan:new{ width = Screen:scaleBySize(4) },
                        text(look, string.format("%d%%", p.pop or 0), st.caption, { fg = look.ink.sub }),
                    }, cw),
                })
            end
            table.insert(group, box(hours, w))
            if weather_stale(now) then
                local same_day = os.date("%Y%m%d", d.fetched_at) == os.date("%Y%m%d", now)
                local when = (same_day and "" or os.date("%b %d, ", d.fetched_at)) .. fmt_time(d.fetched_at)
                table.insert(group, box(text(look, "Updated " .. when .. (wx.error and " · " .. wx.error or ""),
                    st.caption, { fg = look.ink.sub }), w))
            end
            return group
        end,
    },
    {
        id = "dash_focus",
        name = "Focus",
        tap = function() Home.openStopwatch() end,
        lines = function(now)
            local d = focus_data()
            local s = d.state
            local name = s.started and (s.label or FocusStore.NO_LABEL) or FocusStore.last_label(d)
            local t = FocusStore.totals(d, now)
            local sub = "Today " .. hm(t.today)
            for _, l in ipairs(d.labels) do
                local left = l.name == name and FocusStore.goal_left(l, t.labels[name] or 0)
                if left then sub = sub .. "  ·  " .. (left > 0 and hm(left) .. " left this week" or "Week goal done") end
            end
            return (s.started and "● " or "") .. (name or "Focus"),
                s.started and hm(FocusStore.elapsed(s, now)) or "Not running", sub
        end,
        draw = function(w, look, now, mod)
            local st = SUI.style()
            local head, right, sub = mod.lines(now)
            local r = text(look, right, st.body, { bold = true })
            local rw = r:getSize().w
            return VerticalGroup:new{
                align = "left",
                HorizontalGroup:new{
                    align = "center",
                    box(text(look, head, st.title, { bold = true, max_width = w - rw - Screen:scaleBySize(12) }), w - rw, "left"),
                    r,
                },
                box(text(look, sub, st.body, { fg = look.ink.sub, max_width = w }), w, "left"),
            }
        end,
    },
    {
        id = "dash_adhkar",
        name = "Adhkar reminder",
        due = function(now)
            local ok, set = pcall(Adhkar.reminder, now, Home.cfg(), adhkar_progress())
            return ok and set or nil
        end,
        draw = function(w, look, now, mod)
            local set = mod.due(now)
            if not set then return end
            local st = SUI.style()
            return box(FrameContainer:new{
                bordersize = 0, margin = 0, radius = Screen:scaleBySize(10), background = look.ink.blk,
                padding = Screen:scaleBySize(6), padding_left = Screen:scaleBySize(16), padding_right = Screen:scaleBySize(16),
                HorizontalGroup:new{
                    align = "center",
                    text(look, set == "morning" and "Morning adhkar" or "Evening adhkar", st.body, { bold = true, fg = WHITE }),
                    HorizontalSpan:new{ width = Screen:scaleBySize(14) },
                    text(look, Adhkar.titles[set], st.title, { arabic = true, fg = WHITE }),
                },
            }, w)
        end,
    },
}

for _, mod in ipairs(MODULES) do
    mod.category = "extras"
    mod.enabled_key = mod.id .. "_enabled"
    mod.default_on = true
    if mod.lines then mod.state = function(now) return table.concat({ mod.lines(now) }, "|") end end
    if mod.due then
        mod.state = function(now) return mod.due(now) or "" end
        mod.tap = function() Home.openAdhkar(mod.due(os.time())) end
    end
    mod.build = function(w, ctx)
        local look = SUI.context(mod.id, ctx)
        local now = os.time()
        local entry = { look = look, w = w, state = mod.state(now), repaints = 0 }
        live[mod.id] = entry
        Home.screen, Home.refresh = look.screen, look.refresh
        Home.schedule()
        local content = mod.draw(w, look, now, mod)
        if not content then return end
        entry.frame = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, content }
        if not mod.tap then return entry.frame end
        local tappable = InputContainer:new{ dimen = Geom:new(content:getSize()), entry.frame }
        tappable.ges_events = { TapDashModule = { GestureRange:new{ ges = "tap", range = function() return tappable.dimen end } } }
        tappable.onTapDashModule = function()
            mod.tap()
            return true
        end
        return tappable
    end
    mod.getHeight = function(ctx)
        local content = mod.draw(ctx.col_w or Screen:getWidth(), SUI.context(mod.id, ctx), os.time(), mod)
        if not content then return 0 end
        local h = content:getSize().h
        content:free()
        return h
    end
end

-- Each minute, repaint in place only the modules whose text changed, with a "ui" refresh of their own area,
-- like Simple UI's clock. A change in size needs Simple UI to lay out the page again.
update = function()
    local screen = Home.screen
    if not SUI.active(screen) or UIManager:getTopmostVisibleWidget() ~= screen then return end
    local now = os.time()
    if live.dash_weather and weather_due(now) then fetch_weather() end
    local relayout = false
    for _, mod in ipairs(MODULES) do
        local e = live[mod.id]
        if e and e.frame and not util.arrayReferences(screen, e.frame, 64) then
            live[mod.id] = nil
        elseif e then
            local ok, state = pcall(mod.state, now)
            if ok and state ~= e.state then
                local dok, content = pcall(mod.draw, e.w, e.look, now, mod)
                if not dok then
                    logger.warn("dashboard:", mod.id, content)
                elseif not (content and e.frame) or content:getSize().w ~= e.frame[1]:getSize().w
                        or content:getSize().h ~= e.frame[1]:getSize().h then
                    if content then content:free() end
                    relayout = true
                else
                    e.state = state
                    e.frame[1]:free()
                    e.frame[1] = content
                    e.repaints = e.repaints + 1
                    local mode = e.repaints % Home.cfg().full_refresh_minutes == 0 and "flashui" or "ui"
                    local frame = e.frame
                    UIManager:setDirty(screen, function() return mode, frame.dimen end)
                end
            end
        end
    end
    if relayout then SUI.refresh(Home.refresh) end
end

local function tick()
    local RUI = package.loaded["apps/reader/readerui"]
    if Device.screen_saver_mode or (RUI and RUI.instance) or not SUI.active(Home.screen) then return end
    Home.schedule()
    update()
end

-- The next page build (wake, book close, page turn) starts the timer again.
function Home.schedule()
    UIManager:unschedule(tick)
    UIManager:scheduleIn(60 - os.time() % 60 + 1, tick)
end

Home.modules = MODULES
Home.bars = {
    { id = "dash_stopwatch", widget_name = "dashboard_stopwatch", active_action_id = "dash_stopwatch", is_pageable = false },
    { id = "dash_adhkar", widget_name = "dashboard_adhkar", is_pageable = false,
        on_inject = function(widget) SUI.clearActiveTab(widget) end },
}
Home.actions = {
    { id = "dash_stopwatch", label = "Focus", icon = "nerd:F252", execute = function() Home.openStopwatch() end },
    { id = "dash_adhkar_open", label = "Adhkar", icon = "nerd:F186",
        execute = function() Home.openAdhkar(MODULES[4].due(os.time())) end },
    -- KinAMP's own show/hide event. A broadcast reaches its plugin under the Simple UI screens too.
    { id = "dash_music", label = "Music", icon = "nerd:F001",
        execute = function() UIManager:broadcastEvent(require("ui/event"):new("ShowKinAMPPlayer")) end },
}

return Home

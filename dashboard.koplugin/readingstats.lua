-- Lines for Simple UI's Home critter from KOReader's reading statistics: the week's summary
-- (on Friday, the last day of a Saturday-to-Friday week) and when the current book will be finished.
local DataStorage = require("datastorage")
local logger = require("logger")

local Stats = {}

local function hm(secs)
    local m = math.floor(secs / 60)
    if m < 60 then return m .. " min" end
    return math.floor(m / 60) .. " h " .. m % 60 .. " min"
end

local function midnight(t)
    local d = os.date("*t", t)
    d.hour, d.min, d.sec = 0, 0, 0
    return os.time(d)
end

local function week(db, now)
    local wday = os.date("*t", now).wday
    if wday ~= 6 then return end
    local start = midnight(now) - (wday % 7) * 86400
    local last = start - 7 * 86400
    local secs = tonumber(db:rowexec("SELECT coalesce(sum(duration), 0) FROM page_stat_data WHERE start_time >= " .. start)) or 0
    if secs < 60 then return end
    local pages = tonumber(db:rowexec("SELECT count(*) FROM (SELECT DISTINCT id_book, page FROM page_stat_data "
        .. "WHERE start_time >= " .. start .. ")")) or 0
    local before = tonumber(db:rowexec("SELECT coalesce(sum(duration), 0) FROM page_stat_data WHERE start_time >= "
        .. last .. " AND start_time < " .. start)) or 0
    local best = db:rowexec("SELECT min(start_time) FROM page_stat_data WHERE start_time >= " .. start
        .. " GROUP BY date(start_time, 'unixepoch', 'localtime') ORDER BY sum(duration) DESC LIMIT 1")
    local diff = secs - before
    local change = math.abs(diff) < 60 and "same as last week"
        or hm(math.abs(diff)) .. (diff > 0 and " more than last week" or " less than last week")
    return {
        id = "dash_week",
        mood = diff >= 0 and "cheer" or "happy",
        text = "This week: " .. hm(secs) .. ", " .. pages .. " pages",
        sub = (best and "Best day " .. os.date("%A", tonumber(best)) .. " · " or "") .. change,
    }
end

local function forecast(db, now)
    local id, title = db:rowexec("SELECT id, title FROM book ORDER BY last_open DESC LIMIT 1")
    id = tonumber(id)
    if not id then return end
    local page, total = db:rowexec("SELECT page, total_pages FROM page_stat_data WHERE id_book = " .. id
        .. " ORDER BY start_time DESC LIMIT 1")
    page, total = tonumber(page), tonumber(total)
    if not (page and total) or total - page <= 0 then return end
    local since = now - 7 * 86400
    local read = tonumber(db:rowexec("SELECT count(*) FROM (SELECT DISTINCT page FROM page_stat_data WHERE id_book = "
        .. id .. " AND start_time >= " .. since .. ")")) or 0
    if read == 0 then return end
    -- A book started less than 7 days ago is read over fewer days.
    local first = tonumber(db:rowexec("SELECT min(start_time) FROM page_stat_data WHERE id_book = " .. id
        .. " AND start_time >= " .. since))
    local span = math.min(7, math.floor((midnight(now) - midnight(first)) / 86400 + 0.5) + 1)
    local pace = read / span
    local days = math.ceil((total - page) / pace)
    local t = now + days * 86400
    return {
        id = "dash_forecast",
        mood = "curious",
        text = "At this pace, you finish by " .. os.date("%b ", t) .. tonumber(os.date("%d", t)),
        sub = tostring(title) .. " · " .. math.max(1, math.floor(pace + 0.5)) .. " pages a day",
    }
end

-- From Stats.bedtime ("HH:MM") until 5 AM.
local function sleep(_, now)
    local h, m = tostring(Stats.bedtime or ""):match("^(%d+):(%d+)$")
    if not h then return end
    local t = os.date("*t", now)
    local mins, bed = t.hour * 60 + t.min, tonumber(h) * 60 + tonumber(m)
    local late = bed >= 300 and (mins >= bed or mins < 300) or (mins >= bed and mins < 300)
    if not late then return end
    return {
        id = "dash_sleep",
        mood = "sleepy",
        text = "Time to sleep",
        sub = "Your book will still be here tomorrow.",
    }
end

local cache, cache_at = {}, 0

-- Checked at every pick, not cached: it says what to do now.
local low = require("lowbattery")
local function withBattery(lines)
    local cap = low()
    if not cap then return lines end
    local out = { {
        id = "dash_battery", mood = "sleepy", urgent = true,
        text = "Charge me", sub = "Battery at " .. cap .. "%",
    } }
    for _, l in ipairs(lines) do out[#out + 1] = l end
    return out
end

-- The lines that fit now; the database is read at most every 5 minutes.
function Stats.lines()
    local now = os.time()
    if now - cache_at < 300 then return withBattery(cache) end
    cache_at = now
    local ok, res = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local db = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local lines = {}
        for _, fn in ipairs({ week, forecast, sleep }) do
            local ok2, line = pcall(fn, db, now)
            if ok2 and line then table.insert(lines, line)
            elseif not ok2 then logger.warn("dashboard: critter line failed", line) end
        end
        db:close()
        return lines
    end)
    if not ok then logger.warn("dashboard: reading stats failed", res) end
    cache = ok and res or {}
    return withBattery(cache)
end

return Stats

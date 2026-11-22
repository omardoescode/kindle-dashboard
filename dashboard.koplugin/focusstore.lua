-- Focus stopwatch state and history, in settings/dashboard_focus.lua.
-- Sessions stay one by one for a year; older ones become per-day totals.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local KEEP_SECS = 365 * 24 * 3600

local Store = {}

local function open()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_focus.lua")
end

local function day_key(t) return os.date("%Y-%m-%d", t) end

function Store.load()
    local s = open()
    local data = {
        state = s:readSetting("state") or {},
        sessions = s:readSetting("sessions") or {},
        days = s:readSetting("days") or {},
    }
    return data, s
end

function Store.save(data, s)
    s = s or open()
    s:saveSetting("state", data.state)
    s:saveSetting("sessions", data.sessions)
    s:saveSetting("days", data.days)
    s:flush()
end

function Store.elapsed(state, now)
    local secs = state.elapsed or 0
    if state.running then secs = secs + math.max(0, (now or os.time()) - (state.resumed or now or os.time())) end
    return secs
end

function Store.start(data, now)
    data.state = { running = true, started = now, resumed = now, elapsed = 0 }
end

function Store.pause(data, now)
    local st = data.state
    st.elapsed = Store.elapsed(st, now)
    st.running, st.resumed = false, nil
end

function Store.resume(data, now)
    data.state.running, data.state.resumed = true, now
end

function Store.stop(data, now)
    local st = data.state
    local secs = Store.elapsed(st, now)
    local saved = st.started ~= nil and secs >= 60
    if saved then
        table.insert(data.sessions, { start = st.started, stop = now, secs = secs })
    end
    data.state = {}
    Store.compact(data, now)
    return secs, saved
end

function Store.compact(data, now)
    local keep = {}
    for _, s in ipairs(data.sessions) do
        if now - s.start > KEEP_SECS then
            local k = day_key(s.start)
            data.days[k] = (data.days[k] or 0) + s.secs
        else
            table.insert(keep, s)
        end
    end
    data.sessions = keep
end

-- Part of a session's active time inside [from, now]. Pauses are not stored, so a
-- session that crosses the boundary is split in proportion to its wall-clock time.
local function share(start, stop, secs, from)
    if stop <= from then return 0 end
    if start >= from or stop <= start then return secs end
    return secs * (stop - from) / (stop - start)
end

-- Totals for today, this week (from Monday) and this month, with the running session.
function Store.totals(data, now)
    local t = os.date("*t", now)
    local today0 = os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
    -- os.time normalizes day <= 0, and per-day arithmetic stays right across DST changes.
    local week0 = os.time{ year = t.year, month = t.month, day = t.day - (t.wday + 5) % 7, hour = 0 }
    local month0 = os.time{ year = t.year, month = t.month, day = 1, hour = 0 }
    local r = { today = 0, week = 0, month = 0 }
    local function add(start, stop, secs)
        r.today = r.today + share(start, stop, secs, today0)
        r.week = r.week + share(start, stop, secs, week0)
        r.month = r.month + share(start, stop, secs, month0)
    end
    for _, s in ipairs(data.sessions) do add(s.start, s.stop or s.start, s.secs) end
    if data.state.started then add(data.state.started, now, Store.elapsed(data.state, now)) end
    return r
end

return Store

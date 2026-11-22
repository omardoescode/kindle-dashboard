-- Focus stopwatch state and history, in settings/dashboard_focus.lua.
-- Sessions stay one by one for a year; older ones become per-day, per-label totals.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local KEEP_SECS = 365 * 24 * 3600

local Store = {
    NO_LABEL = "No label",
    DEFAULT_LABELS = { "Work", "Uni Study", "Research Work", "Personal Study" },
}

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
        labels = s:readSetting("labels"),
    }
    if not data.labels then
        data.labels = {}
        for _, name in ipairs(Store.DEFAULT_LABELS) do table.insert(data.labels, { name = name }) end
    end
    -- Pause was removed: an old paused session runs on from its start.
    if data.state.started then data.state.running = true end
    -- Day totals before labels existed were plain numbers.
    for k, v in pairs(data.days) do
        if type(v) == "number" then data.days[k] = { [Store.NO_LABEL] = v } end
    end
    return data, s
end

function Store.save(data, s)
    s = s or open()
    s:saveSetting("state", data.state)
    s:saveSetting("sessions", data.sessions)
    s:saveSetting("days", data.days)
    s:saveSetting("labels", data.labels)
    s:flush()
end

function Store.elapsed(state, now)
    return state.started and math.max(0, now - state.started) or 0
end

function Store.start(data, now, label)
    data.state = { running = true, started = now, label = label }
end

function Store.discard(data)
    data.state = {}
end

-- Error text for a session the user entered, or nil.
function Store.check(s, now)
    if s.stop <= s.start then return "End must be after start." end
    if s.stop > now then return "End is in the future." end
    if now - s.start > KEEP_SECS then return "Start is more than 12 months ago." end
end

local function by_start(a, b) return a.start < b.start end

local function insert(data, s)
    table.insert(data.sessions, s)
    table.sort(data.sessions, by_start)
end

-- s: { start, stop, label } from the stop dialog. Returns saved, error.
function Store.stop(data, s, now)
    local err = Store.check(s, now)
    if err then return false, err end
    data.state = {}
    local saved = s.stop - s.start >= 60
    if saved then insert(data, { start = s.start, stop = s.stop, secs = s.stop - s.start, label = s.label }) end
    Store.compact(data, now)
    return saved
end

function Store.add(data, s, now)
    local err = Store.check(s, now)
    if not err and s.stop - s.start < 60 then err = "Shorter than 1 min." end
    if err then return false, err end
    insert(data, { start = s.start, stop = s.stop, secs = s.stop - s.start, label = s.label })
    return true
end

-- Old sessions with pauses keep their active time until their times change.
function Store.edit(data, old, s, now)
    local err = Store.check(s, now)
    if not err and s.stop - s.start < 60 then err = "Shorter than 1 min." end
    if err then return false, err end
    if s.start ~= old.start or s.stop ~= old.stop then old.secs = s.stop - s.start end
    old.start, old.stop, old.label = s.start, s.stop, s.label
    table.sort(data.sessions, by_start)
    return true
end

function Store.delete(data, old)
    for i, s in ipairs(data.sessions) do
        if s == old then return table.remove(data.sessions, i) end
    end
end

function Store.compact(data, now)
    local keep = {}
    for _, s in ipairs(data.sessions) do
        if now - s.start > KEEP_SECS then
            local k, label = day_key(s.start), s.label or Store.NO_LABEL
            data.days[k] = data.days[k] or {}
            data.days[k][label] = (data.days[k][label] or 0) + s.secs
        else
            table.insert(keep, s)
        end
    end
    data.sessions = keep
end

function Store.last_label(data)
    local last = data.sessions[#data.sessions]
    return last and last.label
end

-- Renames the label in its history too, so the week progress stays with it.
function Store.rename_label(data, old, new)
    for _, l in ipairs(data.labels) do
        if l.name == old then l.name = new end
    end
    for _, s in ipairs(data.sessions) do
        if s.label == old then s.label = new end
    end
    if data.state.label == old then data.state.label = new end
    for _, day in pairs(data.days) do
        if day[old] then day[new], day[old] = (day[new] or 0) + day[old], nil end
    end
end

-- Seconds left to the weekly goal, or nil when the label has no goal.
function Store.goal_left(label, week_secs)
    local goal = label.goal_hours
    if not goal or goal <= 0 then return nil end
    return math.max(0, goal * 3600 - week_secs)
end

-- Part of a session's active time inside [from, now]. Pauses are not stored, so a
-- session that crosses the boundary is split in proportion to its wall-clock time.
local function share(start, stop, secs, from)
    if stop <= from then return 0 end
    if start >= from or stop <= start then return secs end
    return secs * (stop - from) / (stop - start)
end

-- Totals for today, this week (from Monday) and this month, and this week per label,
-- with the running session.
function Store.totals(data, now)
    local t = os.date("*t", now)
    local today0 = os.time{ year = t.year, month = t.month, day = t.day, hour = 0 }
    -- os.time normalizes day <= 0, and per-day arithmetic stays right across DST changes.
    local week0 = os.time{ year = t.year, month = t.month, day = t.day - (t.wday + 5) % 7, hour = 0 }
    local month0 = os.time{ year = t.year, month = t.month, day = 1, hour = 0 }
    local r = { today = 0, week = 0, month = 0, labels = {} }
    local function add(start, stop, secs, label)
        local week = share(start, stop, secs, week0)
        r.today = r.today + share(start, stop, secs, today0)
        r.week = r.week + week
        r.month = r.month + share(start, stop, secs, month0)
        if week > 0 then
            label = label or Store.NO_LABEL
            r.labels[label] = (r.labels[label] or 0) + week
        end
    end
    for _, s in ipairs(data.sessions) do add(s.start, s.stop or s.start, s.secs, s.label) end
    if data.state.started then
        add(data.state.started, now, Store.elapsed(data.state, now), data.state.label)
    end
    return r
end

return Store

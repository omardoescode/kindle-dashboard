-- Run from the repo root: luajit test/focusstore_test.lua
package.path = "dashboard.koplugin/?.lua;" .. package.path

local saved = {}
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "settings" end }
end
package.preload["luasettings"] = function()
    local S = {}
    S.__index = S
    function S:open() return setmetatable({}, S) end
    function S:readSetting(k) return saved[k] end
    function S:saveSetting(k, v) saved[k] = v end
    function S:flush() end
    return S
end

local Store = require("focusstore")

local fails = 0
local function eq(name, got, want)
    local ok = got == want
    if not ok and type(got) == "number" and type(want) == "number" then ok = math.abs(got - want) < 1e-6 end
    print((ok and "ok   " or "FAIL ") .. name .. ": got " .. tostring(got) .. (ok and "" or ", want " .. tostring(want)))
    if not ok then fails = fails + 1 end
end

local function at(y, m, d, h, min) return os.time{ year = y, month = m, day = d, hour = h, min = min or 0 } end
local H = 3600

-- Wednesday 2026-11-18 12:00; the week starts Monday 2026-11-16.
local now = at(2026, 11, 18, 12)

local data = Store.load()
eq("default labels", #data.labels, 4)
eq("first default label", data.labels[1].name, "Work")
data.labels[1].goal_hours = 5
data.labels[2].goal_hours = 1

data.sessions = {
    { start = at(2026, 11, 17, 9), stop = at(2026, 11, 17, 11), secs = 2 * H, label = "Work" },
    { start = at(2026, 11, 16, 10), stop = at(2026, 11, 16, 11), secs = H, label = "Uni Study" },
    { start = at(2026, 11, 15, 9), stop = at(2026, 11, 15, 10), secs = H, label = "Work" },
    -- Sunday 23:00 to Monday 01:00: half is in this week.
    { start = at(2026, 11, 15, 23), stop = at(2026, 11, 16, 1), secs = 2 * H, label = "Research Work" },
    -- Tuesday 23:30 to Wednesday 00:30: half is today.
    { start = at(2026, 11, 17, 23, 30), stop = at(2026, 11, 18, 0, 30), secs = H, label = "Personal Study" },
    { start = at(2026, 11, 17, 14), stop = at(2026, 11, 17, 14, 30), secs = H / 2 },
}
Store.start(data, at(2026, 11, 18, 11), "Work")

local t = Store.totals(data, now)
eq("week Work (with running)", t.labels["Work"], 3 * H)
eq("week Uni Study", t.labels["Uni Study"], H)
eq("week Research Work (across Monday)", t.labels["Research Work"], H)
eq("week Personal Study (across midnight)", t.labels["Personal Study"], H)
eq("week No label", t.labels[Store.NO_LABEL], H / 2)
eq("today", t.today, H / 2 + H)
eq("week", t.week, 3 * H + H + H + H + H / 2)

eq("goal left Work", Store.goal_left(data.labels[1], t.labels["Work"]), 2 * H)
eq("goal met Uni Study", Store.goal_left(data.labels[2], t.labels["Uni Study"]), 0)
eq("no goal", Store.goal_left(data.labels[3], H), nil)
eq("goal 0 is no goal", Store.goal_left({ name = "x", goal_hours = 0 }, H), nil)

local ok = Store.stop(data, { start = data.state.started, stop = now, label = data.state.label }, now)
eq("stop saves", ok, true)
eq("stop secs = stop - start", data.sessions[#data.sessions].secs, H)
eq("stop clears state", data.state.started, nil)
eq("stop keeps label", data.sessions[#data.sessions].label, "Work")
eq("last label", Store.last_label(data), "Work")

Store.rename_label(data, "Work", "Job")
eq("rename label", data.labels[1].name, "Job")
eq("rename keeps week time", Store.totals(data, now).labels["Job"], 3 * H)

-- Compaction: sessions older than 12 months go to per-day, per-label totals.
local old = at(2025, 10, 1, 9)
table.insert(data.sessions, 1, { start = old, stop = old + H, secs = H, label = "Job" })
table.insert(data.sessions, 1, { start = old + 2 * H, stop = old + 3 * H, secs = 1800, label = "Job" })
table.insert(data.sessions, 1, { start = old + 4 * H, stop = old + 5 * H, secs = 600 })
local n = #data.sessions
Store.compact(data, now)
eq("compact removes old sessions", #data.sessions, n - 3)
eq("compact day Job", data.days["2025-10-01"]["Job"], H + 1800)
eq("compact day No label", data.days["2025-10-01"][Store.NO_LABEL], 600)

-- Migration: old plain-number day totals go to "No label".
Store.save(data)
saved.days["2024-05-05"] = 1234
saved.days["2025-10-01"] = { Job = 5400 }
local loaded = Store.load()
eq("migrate number day", loaded.days["2024-05-05"][Store.NO_LABEL], 1234)
eq("keep label day", loaded.days["2025-10-01"]["Job"], 5400)
eq("labels saved", loaded.labels[1].name, "Job")
eq("goal saved", loaded.labels[1].goal_hours, 5)

-- Old paused state runs on from its start.
saved.state = { started = at(2026, 11, 18, 10), running = false, elapsed = 100 }
loaded = Store.load()
eq("paused state loads running", loaded.state.running, true)
eq("paused state elapsed from start", Store.elapsed(loaded.state, now), 2 * H)

-- Stop dialog: under 1 min is not saved, edited times give secs = stop - start, bad times stay running.
local d = { sessions = {}, days = {}, labels = {}, state = {} }
Store.start(d, now - 30, "Job")
ok = Store.stop(d, { start = now - 30, stop = now, label = "Job" }, now)
eq("stop under 1 min not saved", ok, false)
eq("stop under 1 min no session", #d.sessions, 0)
eq("stop under 1 min clears state", d.state.started, nil)
Store.start(d, now - H, "Job")
local err
ok, err = Store.stop(d, { start = now - H, stop = now + 60, label = "Job" }, now)
eq("stop rejects future end", err, "End is in the future.")
eq("rejected stop keeps running", d.state.running, true)
ok = Store.stop(d, { start = now - 3 * H, stop = now - H, label = "Uni Study" }, now)
eq("stop with edited times", d.sessions[1].secs, 2 * H)
eq("stop with edited label", d.sessions[1].label, "Uni Study")

Store.start(d, now - H, "Job")
Store.discard(d)
eq("discard clears state", d.state.started, nil)
eq("discard saves nothing", #d.sessions, 1)

-- Checks.
eq("check end before start", Store.check({ start = now - H, stop = now - 2 * H }, now), "End must be after start.")
eq("check end = start", Store.check({ start = now - H, stop = now - H }, now), "End must be after start.")
eq("check future", Store.check({ start = now - H, stop = now + 1 }, now), "End is in the future.")
eq("check older than 12 months", Store.check({ start = at(2025, 11, 17, 9), stop = at(2025, 11, 17, 10) }, now),
    "Start is more than 12 months ago.")
eq("check ok", Store.check({ start = at(2025, 11, 19, 9), stop = at(2025, 11, 19, 10) }, now), nil)

-- Add a past session: kept in start order.
ok = Store.add(d, { start = at(2026, 11, 1, 9), stop = at(2026, 11, 1, 10, 30), label = "Job" }, now)
eq("add ok", ok, true)
eq("add sorted first", d.sessions[1].start, at(2026, 11, 1, 9))
eq("add secs", d.sessions[1].secs, H + 1800)
ok, err = Store.add(d, { start = now - 1800, stop = now - 1770 }, now)
eq("add rejects under 1 min", err, "Shorter than 1 min.")
ok, err = Store.add(d, { start = now - H, stop = now - 2 * H }, now)
eq("add rejects end before start", err, "End must be after start.")
eq("rejected add saves nothing", #d.sessions, 2)

-- Edit: a label change keeps active time; a time change sets secs = stop - start.
local paused = { start = at(2026, 11, 2, 9), stop = at(2026, 11, 2, 11), secs = H, label = "Job" }
table.insert(d.sessions, 2, paused)
ok = Store.edit(d, paused, { start = paused.start, stop = paused.stop, label = "Uni Study" }, now)
eq("edit label", paused.label, "Uni Study")
eq("edit label keeps secs", paused.secs, H)
ok = Store.edit(d, paused, { start = at(2026, 10, 30, 9), stop = at(2026, 10, 30, 12), label = "Uni Study" }, now)
eq("edit times sets secs", paused.secs, 3 * H)
eq("edit resorts", d.sessions[1], paused)
ok, err = Store.edit(d, paused, { start = at(2026, 10, 30, 9), stop = now + H, label = "Job" }, now)
eq("edit rejects future", err, "End is in the future.")
eq("rejected edit keeps label", paused.label, "Uni Study")
eq("rejected edit keeps stop", paused.stop, at(2026, 10, 30, 12))

eq("delete returns it", Store.delete(d, paused), paused)
eq("delete removes", #d.sessions, 2)
eq("delete unknown", Store.delete(d, paused), nil)

print(fails == 0 and "all passed" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

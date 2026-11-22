-- Run from the repo root: TZ=America/Chicago luajit test/adhkar_test.lua
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

local Adhkar = require("adhkar")
local PT = require("prayertimes")

local fails = 0
local function eq(name, got, want)
    local ok = got == want
    print((ok and "ok   " or "FAIL ") .. name .. ": got " .. tostring(got) .. (ok and "" or ", want " .. tostring(want)))
    if not ok then fails = fails + 1 end
end

local function at(y, m, d, h, min) return os.time{ year = y, month = m, day = d, hour = h, min = min or 0 } end
-- Minneapolis, ISNA: on 2026-11-21 Fajr is 5:53 and Asr 2:19 PM.
local cfg = { lat = 44.9778, lon = -93.2650, method = "isna", madhab = "shafi" }
local t21 = PT.day(at(2026, 11, 21, 12), cfg)
eq("fajr 2026-11-21", os.date("%H:%M", t21.fajr), "05:53")
eq("asr 2026-11-21", os.date("%H:%M", t21.asr), "14:19")

eq("morning set size", #Adhkar.lists.morning, 23)
eq("evening set size", #Adhkar.lists.evening, 21)

local function period(name, now, current, morning, evening)
    local p = Adhkar.periods(now, cfg)
    eq(name .. " set", p.current, current)
    eq(name .. " morning key", p.morning, morning)
    eq(name .. " evening key", p.evening, evening)
end
period("00:30", at(2026, 11, 21, 0, 30), "evening", "2026-11-20", "2026-11-20")
period("1 min before Fajr", t21.fajr - 60, "evening", "2026-11-20", "2026-11-20")
period("at Fajr", t21.fajr, "morning", "2026-11-21", "2026-11-20")
period("1 min before Asr", t21.asr - 60, "morning", "2026-11-21", "2026-11-20")
period("at Asr", t21.asr, "evening", "2026-11-21", "2026-11-21")
period("23:59", at(2026, 11, 21, 23, 59), "evening", "2026-11-21", "2026-11-21")
period("next day 03:00", at(2026, 11, 22, 3), "evening", "2026-11-21", "2026-11-21")
-- US clocks move forward on 2026-03-08 at 02:00.
period("DST day 01:30", at(2026, 3, 8, 1, 30), "evening", "2026-03-07", "2026-03-07")
period("DST day 10:00", at(2026, 3, 8, 10), "morning", "2026-03-08", "2026-03-07")

-- Morning of 2026-11-21: count through the whole set.
local morning = at(2026, 11, 21, 7)
local progress = Adhkar.load()
eq("reminder after Fajr, nothing done", Adhkar.reminder(morning, cfg, progress), "morning")
local st = Adhkar.state(progress, "morning", "2026-11-21")
eq("starts at dhikr 1", st.index, 1)
eq("first dhikr count (Ayat al-Kursi)", st.left, 1)
eq("first tap completes dhikr 1", Adhkar.count(st, "morning"), true)
eq("now dhikr 2", st.index, 2)
eq("dhikr 2 left (three Quls)", st.left, 3)
eq("tap 1 of 3 keeps dhikr", Adhkar.count(st, "morning"), false)
eq("left after one tap", st.left, 2)
Adhkar.save(progress)

progress = Adhkar.load()
st = Adhkar.state(progress, "morning", "2026-11-21")
eq("reopen same period: dhikr", st.index, 2)
eq("reopen same period: left", st.left, 2)

local taps = 2
while not st.done do
    Adhkar.count(st, "morning")
    taps = taps + 1
end
eq("taps for the whole morning set", taps, 357)
eq("done shows last index", st.index, 23)
eq("tap when done does nothing", Adhkar.count(st, "morning"), false)
eq("no reminder when morning done", Adhkar.reminder(morning, cfg, progress), nil)
eq("evening reminder at Asr", Adhkar.reminder(t21.asr, cfg, progress), "evening")
Adhkar.save(progress)
eq("saved done flag", Adhkar.load().morning.done, true)

Adhkar.back(st, "morning")
eq("back from done: not done", st.done, nil)
eq("back from done: last dhikr", st.index, 23)
eq("back from done: full count", st.left, 100)
Adhkar.back(st, "morning")
eq("back: previous dhikr", st.index, 22)
Adhkar.skip(st, "morning")
Adhkar.skip(st, "morning")
eq("skip past last: done", st.done, true)
Adhkar.reset(st, "morning")
eq("reset when done: still done", st.done, true)
Adhkar.back(st, "morning")
st.left = 1
Adhkar.reset(st, "morning")
eq("reset: same dhikr", st.index, 23)
eq("reset: full count", st.left, 100)

-- The next morning: yesterday's progress no longer counts.
progress = { morning = { key = "2026-11-21", index = 23, left = 0, done = true } }
local next_morning = at(2026, 11, 22, 7)
eq("done yesterday: no reminder before Asr", Adhkar.reminder(at(2026, 11, 21, 13), cfg, progress), nil)
eq("reminder next morning", Adhkar.reminder(next_morning, cfg, progress), "morning")
st = Adhkar.state(progress, "morning", Adhkar.periods(next_morning, cfg).morning)
eq("new period key", st.key, "2026-11-22")
eq("new period: dhikr 1", st.index, 1)
eq("new period: not done", st.done, nil)

-- A saved index past the end of the list (data changed) starts again.
progress = { evening = { key = "2026-11-21", index = 99, left = 1 } }
st = Adhkar.state(progress, "evening", "2026-11-21")
eq("bad index resets", st.index, 1)

for _, list in pairs(Adhkar.lists) do
    for i, item in ipairs(list) do
        if type(item.text) ~= "string" or type(item.ref) ~= "string" or (item.count or 0) < 1 then
            eq("item " .. i .. " fields", false, true)
        end
    end
end

print(fails == 0 and "all passed" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)

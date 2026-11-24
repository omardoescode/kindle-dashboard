-- Morning and evening adhkar progress, in settings/dashboard_adhkar.lua: one entry per set.
-- Morning runs from Fajr to Asr, evening from Asr to the next Fajr. An entry is valid for the period
-- of its set that started last, so morning progress resets at each Fajr and evening progress at each Asr.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local PT = require("prayertimes")

local Adhkar = {
    titles = { morning = "أذكار الصباح", evening = "أذكار المساء" },
    lists = { morning = {}, evening = {} },
}

for _, item in ipairs(require("adhkardata")) do
    for set, list in pairs(Adhkar.lists) do
        if item.only == nil or item.only == set then table.insert(list, item) end
    end
end

local function open()
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/dashboard_adhkar.lua")
end

-- current: the set for now; morning, evening: the date (YYYY-MM-DD) each set's last period started.
function Adhkar.periods(now, cfg)
    local today, _, midnight = PT.day(now, cfg)
    local fajr, asr = today.fajr, today.asr
    if now < today.asr then
        local yesterday = PT.day(midnight - 12 * 3600, cfg)
        asr = yesterday.asr
        if now < today.fajr then fajr = yesterday.fajr end
    end
    return {
        current = asr > fajr and "evening" or "morning",
        morning = os.date("%Y-%m-%d", fajr),
        evening = os.date("%Y-%m-%d", asr),
    }
end

function Adhkar.load()
    local s = open()
    return { morning = s:readSetting("morning"), evening = s:readSetting("evening") }, s
end

-- Writes one set to a fresh copy of the file, so a widget with stale progress cannot undo another's.
function Adhkar.save(progress, set)
    local s = open()
    s:saveSetting(set, progress[set])
    s:flush()
end

function Adhkar.state(progress, set, key)
    local list = Adhkar.lists[set]
    local st = progress[set]
    if not st or st.key ~= key or not list[st.index] then
        st = { key = key, index = 1, left = list[1].count }
        progress[set] = st
    end
    return st
end

-- The set to remind of now, or nil when it is done.
function Adhkar.reminder(now, cfg, progress)
    local p = Adhkar.periods(now, cfg)
    local st = progress[p.current]
    if not (st and st.key == p[p.current] and st.done) then return p.current end
end

function Adhkar.skip(st, set)
    local list = Adhkar.lists[set]
    if st.done then return end
    if st.index >= #list then
        st.done, st.left = true, 0
    else
        st.index = st.index + 1
        st.left = list[st.index].count
    end
end

-- One tap. Returns true when the dhikr is complete and the next one (or the end) shows.
function Adhkar.count(st, set)
    if st.done then return false end
    st.left = st.left - 1
    if st.left > 0 then return false end
    Adhkar.skip(st, set)
    return true
end

function Adhkar.back(st, set)
    if st.done then
        st.done = nil
    elseif st.index > 1 then
        st.index = st.index - 1
    end
    st.left = Adhkar.lists[set][st.index].count
end

function Adhkar.reset(st, set)
    if st.done then return end
    st.left = Adhkar.lists[set][st.index].count
end

return Adhkar

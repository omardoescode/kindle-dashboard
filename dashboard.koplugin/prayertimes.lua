local M = {}

local RAD = math.pi / 180
local function dsin(d) return math.sin(d * RAD) end
local function dcos(d) return math.cos(d * RAD) end
local function dtan(d) return math.tan(d * RAD) end
local function darcsin(x) return math.asin(x) / RAD end
local function darccos(x) return math.acos(x) / RAD end
local function darctan2(y, x) return math.atan2(y, x) / RAD end
local function darccot(x) return math.atan(1 / x) / RAD end
local function fix(a, b) a = a - b * math.floor(a / b); return a < 0 and a + b or a end

M.methods = {
    isna = { name = "ISNA", fajr = 15, isha = 15 },
    egyptian = { name = "Egyptian", fajr = 19.5, isha = 17.5 },
    mwl = { name = "Muslim World League", fajr = 18, isha = 17 },
    karachi = { name = "Karachi", fajr = 18, isha = 18 },
    umm_al_qura = { name = "Umm al-Qura", fajr = 18.5, isha_minutes = 90 },
}

function M.julian(y, m, d)
    if m <= 2 then y = y - 1; m = m + 12 end
    local a = math.floor(y / 100)
    local b = 2 - a + math.floor(a / 4)
    return math.floor(365.25 * (y + 4716)) + math.floor(30.6001 * (m + 1)) + d + b - 1524.5
end

local function sun(jd)
    local d = jd - 2451545.0
    local g = fix(357.529 + 0.98560028 * d, 360)
    local q = fix(280.459 + 0.98564736 * d, 360)
    local l = fix(q + 1.915 * dsin(g) + 0.020 * dsin(2 * g), 360)
    local e = 23.439 - 0.00000036 * d
    local ra = darctan2(dcos(e) * dsin(l), dcos(l)) / 15
    return darcsin(dsin(e) * dsin(l)), q / 15 - fix(ra, 24)
end

-- Returns minutes after local midnight for fajr, sunrise, dhuhr, asr, maghrib, isha.
function M.compute(y, m, d, lat, lng, tz, method, asr_factor)
    local p = M.methods[method] or M.methods.isna
    local jdate = M.julian(y, m, d) - lng / (15 * 24)
    local function mid_day(t)
        local _, eqt = sun(jdate + t)
        return fix(12 - eqt, 24)
    end
    local function angle_time(angle, t, ccw)
        local decl = sun(jdate + t)
        local noon = mid_day(t)
        local x = (-dsin(angle) - dsin(decl) * dsin(lat)) / (dcos(decl) * dcos(lat))
        local dt = darccos(math.max(-1, math.min(1, x))) / 15
        return noon + (ccw and -dt or dt)
    end
    local function asr_time(factor, t)
        local decl = sun(jdate + t)
        return angle_time(-darccot(factor + dtan(math.abs(lat - decl))), t)
    end
    local t = { fajr = 5, sunrise = 6, dhuhr = 12, asr = 13, sunset = 18, isha = 18 }
    for k, v in pairs(t) do t[k] = v / 24 end
    local r = {
        fajr = angle_time(p.fajr, t.fajr, true),
        sunrise = angle_time(0.833, t.sunrise, true),
        dhuhr = mid_day(t.dhuhr),
        asr = asr_time(asr_factor or 1, t.asr),
        sunset = angle_time(0.833, t.sunset),
    }
    r.isha = p.isha and angle_time(p.isha, t.isha) or nil
    local out = {}
    for k, v in pairs(r) do out[k] = v + tz - lng / 15 end
    out.maghrib = out.sunset
    if p.isha_minutes then out.isha = out.maghrib + p.isha_minutes / 60 end
    local res = {}
    for _, k in ipairs({ "fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha" }) do
        res[k] = math.floor(out[k] * 60 + 0.5)
    end
    return res
end

M.order = { "fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha" }

M.names = {
    fajr = { "Fajr", "الفجر" },
    sunrise = { "Sunrise", "الشروق" },
    dhuhr = { "Dhuhr", "الظهر" },
    asr = { "Asr", "العصر" },
    maghrib = { "Maghrib", "المغرب" },
    isha = { "Isha", "العشاء" },
}

function M.name(key, weekday)
    if key == "dhuhr" and weekday == 6 then return "Jumu'ah", "الجمعة" end
    return M.names[key][1], M.names[key][2]
end

function M.utc_offset_hours(epoch)
    local lt = os.date("*t", epoch)
    local ut = os.date("!*t", epoch)
    ut.isdst = lt.isdst
    return os.difftime(os.time(lt), os.time(ut)) / 3600
end

-- Epoch times of the six prayers on the local date of `epoch`.
function M.day(epoch, cfg)
    local lt = os.date("*t", epoch)
    local noon = os.time({ year = lt.year, month = lt.month, day = lt.day, hour = 12 })
    local tz = M.utc_offset_hours(noon)
    local mins = M.compute(lt.year, lt.month, lt.day, cfg.lat, cfg.lon, tz, cfg.method,
        cfg.madhab == "hanafi" and 2 or 1)
    local midnight = os.time({ year = lt.year, month = lt.month, day = lt.day, hour = 0 })
    local times = {}
    for k, v in pairs(mins) do
        local adj = cfg.adjust and cfg.adjust[k] or 0
        times[k] = os.time({ year = lt.year, month = lt.month, day = lt.day, hour = 0, min = v + adj })
    end
    return times, lt.wday, midnight
end

-- The next prayer (sunrise excluded) after `now`, looking into tomorrow after Isha.
function M.next(now, cfg)
    local today = M.day(now, cfg)
    for _, k in ipairs(M.order) do
        if k ~= "sunrise" and today[k] > now then return k, today[k] end
    end
    local tomorrow = M.day(now + 86400, cfg)
    return "fajr", tomorrow.fajr
end

return M

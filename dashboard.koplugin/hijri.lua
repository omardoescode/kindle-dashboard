local M = {}

M.months_en = { "Muharram", "Safar", "Rabi' al-Awwal", "Rabi' al-Thani", "Jumada al-Ula",
    "Jumada al-Akhirah", "Rajab", "Sha'ban", "Ramadan", "Shawwal", "Dhu al-Qi'dah", "Dhu al-Hijjah" }
M.months_ar = { "محرم", "صفر", "ربيع الأول", "ربيع الآخر", "جمادى الأولى", "جمادى الآخرة",
    "رجب", "شعبان", "رمضان", "شوال", "ذو القعدة", "ذو الحجة" }

local floor = math.floor

local function jdn(y, m, d)
    local a = floor((14 - m) / 12)
    local yy = y + 4800 - a
    local mm = m + 12 * a - 3
    return d + floor((153 * mm + 2) / 5) + 365 * yy + floor(yy / 4) - floor(yy / 100) + floor(yy / 400) - 32045
end

-- Tabular (arithmetic) Islamic calendar.
function M.from_gregorian(y, m, d, offset_days)
    local l = jdn(y, m, d) + (offset_days or 0) - 1948440 + 10632
    local n = floor((l - 1) / 10631)
    l = l - 10631 * n + 354
    local j = floor((10985 - l) / 5316) * floor((50 * l) / 17719) + floor(l / 5670) * floor((43 * l) / 15238)
    l = l - floor((30 - j) / 15) * floor((17719 * j) / 50) - floor(j / 16) * floor((15238 * j) / 43) + 29
    local month = floor((24 * l) / 709)
    local day = l - floor((709 * month) / 24)
    local year = 30 * n + j - 30
    return year, month, day
end

return M

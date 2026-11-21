local http = require("socket.http")
local json = require("json")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")

local M = {}

local CODES = {
    [0] = "Clear", [1] = "Mainly clear", [2] = "Partly cloudy", [3] = "Overcast",
    [45] = "Fog", [48] = "Fog", [51] = "Light drizzle", [53] = "Drizzle", [55] = "Heavy drizzle",
    [56] = "Freezing drizzle", [57] = "Freezing drizzle", [61] = "Light rain", [63] = "Rain",
    [65] = "Heavy rain", [66] = "Freezing rain", [67] = "Freezing rain", [71] = "Light snow",
    [73] = "Snow", [75] = "Heavy snow", [77] = "Snow grains", [80] = "Showers", [81] = "Showers",
    [82] = "Heavy showers", [85] = "Snow showers", [86] = "Snow showers", [95] = "Thunderstorm",
    [96] = "Thunderstorm, hail", [99] = "Thunderstorm, hail",
}

function M.describe(code) return CODES[code] or "—" end

local function fetch_body(lat, lon, unit)
    local url = string.format("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=temperature_2m,apparent_temperature,weather_code,precipitation,wind_speed_10m"
        .. "&hourly=temperature_2m,precipitation_probability,weather_code"
        .. "&minutely_15=precipitation&forecast_minutely_15=16"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        .. "&forecast_days=2&timezone=auto&timeformat=unixtime&temperature_unit=%s",
        lat, lon, unit == "fahrenheit" and "fahrenheit" or "celsius")
    local sink = {}
    socketutil:set_timeout(10, 25)
    local code = socket.skip(1, http.request{
        url = url, method = "GET", sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "koreader-dashboard" },
    })
    socketutil:reset_timeout()
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    return table.concat(sink)
end

local function parse(body)
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or not data.current then return nil, "bad response" end
    data.fetched_at = os.time()
    return data
end

-- The request runs in a child process so a slow network never freezes taps.
function M.fetch_async(lat, lon, unit, cb)
    local pid, fd = ffiutil.runInSubProcess(function(_, child_fd)
        local ok, body, err = pcall(fetch_body, lat, lon, unit)
        if not ok then body, err = nil, body end
        ffiutil.writeToFD(child_fd, body or ("\0" .. tostring(err)), true)
    end, true)
    if not pid then return cb(nil, "no subprocess") end
    local started = os.time()
    local function check()
        if ffiutil.isSubProcessDone(pid) or ffiutil.getNonBlockingReadSize(fd) > 0 then
            local out = ffiutil.readAllFromFD(fd) or ""
            ffiutil.isSubProcessDone(pid, true)
            if out:sub(1, 1) == "\0" then return cb(nil, out:sub(2)) end
            return cb(parse(out))
        end
        if os.time() - started > 45 then
            ffiutil.terminateSubProcess(pid)
            local function collect()
                if ffiutil.isSubProcessDone(pid) then ffiutil.readAllFromFD(fd) else UIManager:scheduleIn(1, collect) end
            end
            UIManager:scheduleIn(1, collect)
            return cb(nil, "timeout")
        end
        UIManager:scheduleIn(0.5, check)
    end
    UIManager:scheduleIn(0.5, check)
end

local function clock(epoch, h12)
    if h12 then return (os.date("%I %p", epoch):gsub("^0", "")) end
    return os.date("%H:00", epoch)
end

-- One line about rain: now, within the next few hours, or later today.
function M.rain_line(data, now, h12)
    local m = data.minutely_15
    if m and m.time then
        local raining_now = (data.current.precipitation or 0) > 0.05
        for i, t in ipairs(m.time) do
            local p = m.precipitation[i] or 0
            if t + 900 > now then
                if raining_now and p < 0.05 then
                    return string.format("Rain easing in ~%d min", math.max(0, math.floor((t - now) / 60)))
                elseif not raining_now and p >= 0.1 then
                    local mins = math.floor((t - now) / 60)
                    if mins <= 0 then return "Rain starting now" end
                    return string.format("Rain in ~%d min", mins)
                end
            end
        end
        if raining_now then return "Rain for the next few hours" end
    end
    local h = data.hourly
    if h and h.time then
        for i, t in ipairs(h.time) do
            if t > now and t < now + 12 * 3600 and (h.precipitation_probability[i] or 0) >= 50 then
                return "Rain likely around " .. clock(t, h12)
            end
        end
    end
    return "No rain expected"
end

-- The next n hourly points after now.
function M.next_hours(data, now, n, h12)
    local out = {}
    local h = data.hourly
    if not (h and h.time) then return out end
    for i, t in ipairs(h.time) do
        if t > now and #out < n then
            table.insert(out, {
                label = clock(t, h12),
                temp = h.temperature_2m[i],
                pop = h.precipitation_probability[i],
                code = h.weather_code[i],
            })
        end
    end
    return out
end

return M

package.path = "/home/omar/projects/kindle-dashboard/dashboard.koplugin/?.lua;" .. package.path
local PT = require("prayertimes")
local H = require("hijri")
local lat, lon, method, y, m, d, tz = tonumber(arg[1]), tonumber(arg[2]), arg[3], tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6]), tonumber(arg[7])
local r = PT.compute(y, m, d, lat, lon, tz, method, 1)
for _, k in ipairs(PT.order) do io.write(k, "=", string.format("%02d:%02d", r[k] // 60, r[k] % 60), " ") end
local hy, hm, hd = H.from_gregorian(y, m, d)
print(string.format("hijri=%d-%02d-%02d", hy, hm, hd))

-- Bluetooth through Amazon's daemon com.lab126.btfd over lipc (Kindle only).
-- Properties, read on a PW6 with lipc-probe:
--   BTstate (int, 0 off, 1 on, 2 connected), BTenable (str "1:1" on), triggerBTscan (int),
--   ListDiscovered, ListPaired, ListConnected (hasharrays of bd_name, bd_address, is_paired, is_connected),
--   Bond, Unbond, Connect, Disconnect (str MAC), PairUserConfirmation (int).
-- btfd refuses BTenable "0:x" ("not safe yet" in /var/log/messages). Off works only through BTflightMode,
-- and turning on after it once hung btmanagerd, so there is no off here; Disconnect always works.
local logger = require("logger")

local BTFD = "com.lab126.btfd"
local BT = {}

local handle
local function lipc()
    if handle then return handle end
    local ok, mod = pcall(require, "libopenlipclua")
    if not ok then return end
    local opened
    ok, opened = pcall(mod.open_no_name)
    if ok then handle = opened end
    return handle
end

local function call(method, prop, value)
    local h = lipc()
    if not h then return end
    local ok, res = pcall(h[method], h, BTFD, prop, value)
    if not ok then
        logger.warn("dashboard: btfd", prop, res)
        return
    end
    return res == nil and true or res
end

local function list(prop)
    local h = lipc()
    if not h then return {} end
    local ok, input = pcall(h.new_hasharray, h)
    if not ok or not input then return {} end
    local got, output = pcall(h.access_hash_property, h, BTFD, prop, input)
    local rows = {}
    if got and output then
        local parsed, t = pcall(output.to_table, output)
        if parsed and t then rows = t end
        if output ~= input then pcall(output.destroy, output) end
    end
    pcall(input.destroy, input)
    local devices = {}
    for _, row in ipairs(rows) do
        if row.bd_address then
            table.insert(devices, {
                name = row.bd_name ~= "" and row.bd_name or row.bd_address,
                mac = row.bd_address,
                paired = tonumber(row.is_paired) == 1,
                connected = tonumber(row.is_connected) == 1,
            })
        end
    end
    return devices
end

function BT.available()
    return call("get_int_property", "BTstate") ~= nil
end

function BT.isOn()
    local state = call("get_int_property", "BTstate")
    return state ~= nil and state ~= 0
end

function BT.turnOn()
    return call("set_string_property", "BTenable", "1:1")
end

function BT.scan()
    return call("set_int_property", "triggerBTscan", 1)
end

-- Paired devices first, then devices found by the last scan that are not paired.
function BT.devices()
    local out, seen = {}, {}
    for _, d in ipairs(list("ListPaired")) do
        seen[d.mac] = true
        table.insert(out, d)
    end
    for _, d in ipairs(list("ListDiscovered")) do
        if not seen[d.mac] then
            seen[d.mac] = true
            table.insert(out, d)
        end
    end
    return out
end

function BT.find(mac)
    for _, d in ipairs(BT.devices()) do
        if d.mac == mac then return d end
    end
end

function BT.connect(mac) return call("set_string_property", "Connect", mac) end
function BT.disconnect(mac) return call("set_string_property", "Disconnect", mac) end
function BT.forget(mac) return call("set_string_property", "Unbond", mac) end

-- The user asked for the pairing in our list, so a confirmation request from btfd is accepted.
function BT.pair(mac)
    local ok = call("set_string_property", "Bond", mac)
    call("set_int_property", "PairUserConfirmation", 1)
    return ok
end

return BT

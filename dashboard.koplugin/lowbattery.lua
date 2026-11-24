-- The battery level when it is below 10% and not charging, else nil.
local Device = require("device")

return function()
    local ok, cap = pcall(function()
        if not Device:hasBattery() then return end
        local power = Device:getPowerDevice()
        if power:isCharging() then return end
        local c = power:getCapacity()
        if c and c < 10 then return c end
    end)
    return ok and cap or nil
end

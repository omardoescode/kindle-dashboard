local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen

local BT = require("bluetooth")

local SCAN_SECONDS = 12
local WAIT_SECONDS = 20

local BluetoothWidget = {}

local function notify(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

-- Shows a message and checks done() every second until it is true or the time is over.
local function wait(text, done, finish)
    local info = InfoMessage:new{ text = text }
    UIManager:show(info)
    UIManager:forceRePaint()
    local left = WAIT_SECONDS
    local function poll()
        left = left - 1
        local ok = done()
        if ok or left <= 0 then
            UIManager:close(info)
            finish(ok)
        else
            UIManager:scheduleIn(1, poll)
        end
    end
    UIManager:scheduleIn(1, poll)
end

function BluetoothWidget:items()
    local on = BT.isOn()
    local items = {
        {
            text = on and "Bluetooth: on" or "Bluetooth: off",
            mandatory = on and "Turn off" or "Turn on",
            callback = function() self:toggle(not on) end,
        },
    }
    if not on then return items end
    table.insert(items, { text = "Scan for devices", callback = function() self:scan() end })
    for _, d in ipairs(BT.devices()) do
        table.insert(items, {
            text = d.name,
            mandatory = d.connected and "Connected" or d.paired and "Paired" or "",
            bold = d.connected,
            callback = function() self:tap(d) end,
            hold_callback = d.paired and function() self:forget(d) end or nil,
        })
    end
    return items
end

function BluetoothWidget:refresh()
    if self.menu then self.menu:switchItemTable(nil, self:items()) end
end

function BluetoothWidget:toggle(on)
    BT.setOn(on)
    wait(on and "Turning Bluetooth on ..." or "Turning Bluetooth off ...",
        function() return BT.isOn() == on end,
        function() self:refresh() end)
end

function BluetoothWidget:scan()
    BT.scan()
    local info = InfoMessage:new{ text = "Scanning for devices ...", timeout = SCAN_SECONDS }
    UIManager:show(info)
    UIManager:scheduleIn(SCAN_SECONDS, function() self:refresh() end)
end

function BluetoothWidget:tap(d)
    if d.connected then
        BT.disconnect(d.mac)
        wait("Disconnecting " .. d.name .. " ...",
            function() local n = BT.find(d.mac) return n and not n.connected end,
            function() self:refresh() end)
    elseif d.paired then
        BT.connect(d.mac)
        wait("Connecting " .. d.name .. " ...",
            function() local n = BT.find(d.mac) return n and n.connected end,
            function(ok)
                if not ok then notify("Could not connect " .. d.name .. ". Is it on and near?") end
                self:refresh()
            end)
    else
        UIManager:show(ConfirmBox:new{
            text = "Pair with " .. d.name .. "?\nPut the device in pairing mode first.",
            ok_text = "Pair",
            ok_callback = function() self:pair(d) end,
        })
    end
end

function BluetoothWidget:pair(d)
    BT.pair(d.mac)
    wait("Pairing " .. d.name .. " ...",
        function() local n = BT.find(d.mac) return n and n.paired end,
        function(ok)
            if not ok then
                notify("Could not pair " .. d.name .. ".")
                return self:refresh()
            end
            BT.connect(d.mac)
            wait("Connecting " .. d.name .. " ...",
                function() local n = BT.find(d.mac) return n and n.connected end,
                function() self:refresh() end)
        end)
end

function BluetoothWidget:forget(d)
    UIManager:show(ConfirmBox:new{
        text = "Forget " .. d.name .. "?\nTo use it again, pair it again.",
        ok_text = "Forget",
        ok_callback = function()
            BT.forget(d.mac)
            UIManager:scheduleIn(2, function() self:refresh() end)
        end,
    })
end

function BluetoothWidget.show()
    if not BT.available() then
        return notify("Bluetooth is not available on this device.")
    end
    local self = setmetatable({}, { __index = BluetoothWidget })
    self.menu = Menu:new{
        title = "Bluetooth",
        item_table = self:items(),
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuHold = function(_, item)
            if item.hold_callback then item.hold_callback() end
            return true
        end,
    }
    UIManager:show(self.menu)
end

return BluetoothWidget

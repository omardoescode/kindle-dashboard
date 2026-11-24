local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Adhkar = require("adhkar")
local SUI = require("suiadapter")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_4

local FONTS = "../plugins/dashboard.koplugin/fonts/"
local SANS, SANS_BOLD = FONTS .. "IBMPlexSans-Regular.ttf", FONTS .. "IBMPlexSans-SemiBold.ttf"
local BOLD = FONTS .. "IBMPlexSans-Bold.ttf"
local ARABIC, ARABIC_REGULAR = FONTS .. "Zain-Bold.ttf", FONTS .. "Zain-Regular.ttf"
-- The smallest sizes are for the longest dhikr (the three Quls), so it fits without scrolling.
local DHIKR_SIZES = { 34, 31, 28, 25, 22, 20, 18 }

local AdhkarWidget = InputContainer:extend{
    name = "dashboard_adhkar",
    covers_fullscreen = true,
    cfg = nil,
    set = nil,
}

local function text(s, font, size, fg)
    return TextWidget:new{ text = s, face = Font:getFace(font, size), fgcolor = fg or BLACK }
end

-- Zain is 1.66 em tall: a smaller line height cuts the marks of stacked diacritics.
local function arabic(s, font, size, width, opts)
    opts = opts or {}
    return TextBoxWidget:new{
        text = s, face = Font:getFace(font, size), fgcolor = opts.fg or BLACK, width = width,
        height = opts.height, for_measurement_only = opts.measure,
        alignment = "center", lang = "ar", para_direction_rtl = true, line_height = 0.66,
    }
end

function AdhkarWidget:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.progress, self.store = Adhkar.load()
    -- Simple UI wraps self[1] with its bars when it shows this widget, so builds replace only the body.
    self.body = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0 }
    self[1] = self.body
    self:open(self.set)
end

function AdhkarWidget:open(set)
    local p = Adhkar.periods(os.time(), self.cfg)
    self.set = set or p.current
    self.st = Adhkar.state(self.progress, self.set, p[self.set])
    self:build()
end

function AdhkarWidget:build()
    if self.body[1] then self.body[1]:free() end
    local W, H = self.dimen.w, SUI.contentHeight()
    local pad = Screen:scaleBySize(18)
    local inner = W - 2 * pad
    local list, st = Adhkar.lists[self.set], self.st
    local item = list[st.index]

    local line_h = Screen:scaleBySize(14)
    local line = function()
        return CenterContainer:new{ dimen = Geom:new{ w = W, h = line_h },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    end

    local top_h = Screen:scaleBySize(52)
    local half = math.floor(inner / 2)
    local seg_w, seg_h = Screen:scaleBySize(130), top_h - Screen:scaleBySize(6)
    local switch = HorizontalGroup:new{}
    -- Arabic order: the first set is on the right.
    for _, set in ipairs({ "evening", "morning" }) do
        local label = set == "morning" and "الصباح" or "المساء"
        if set == self.set then
            table.insert(switch, FrameContainer:new{
                bordersize = Screen:scaleBySize(2), padding = 0, margin = 0, background = BLACK,
                CenterContainer:new{ dimen = Geom:new{ w = seg_w, h = seg_h }, text(label, ARABIC, 24, WHITE) } })
        else
            table.insert(switch, Button:new{ text = label, width = seg_w, height = seg_h, bordersize = Screen:scaleBySize(2),
                radius = 0, text_font_face = ARABIC, text_font_bold = false, text_font_size = 24, show_parent = self,
                callback = function() self:switch(set) end })
        end
    end
    local top = HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = half, h = top_h },
            text(string.format("%d / %d", st.index, #list), SANS_BOLD, 22) },
        RightContainer:new{ dimen = Geom:new{ w = inner - half, h = top_h }, switch },
    }

    local gap = Screen:scaleBySize(16)
    local bw = math.floor((inner - 3 * gap) / 4)
    local function btn(label, cb, enabled)
        local b = Button:new{ text = label, width = bw, bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(8),
            text_font_face = SANS_BOLD, text_font_bold = false, text_font_size = 20, callback = cb, show_parent = self }
        if not enabled then b:disable() end
        return b
    end
    local buttons = HorizontalGroup:new{
        btn("Back", function() self:act(Adhkar.back) end, st.done or st.index > 1),
        HorizontalSpan:new{ width = gap },
        btn("Skip", function() self:act(Adhkar.skip) end, not st.done),
        HorizontalSpan:new{ width = gap },
        btn("Reset", function() self:act(Adhkar.reset) end, not st.done),
        HorizontalSpan:new{ width = gap },
        btn("Close", function() UIManager:close(self) end, true),
    }

    local count_h = Screen:scaleBySize(124)
    local room = H - 2 * pad - top_h - 2 * line_h - buttons:getSize().h - count_h
    local body = VerticalGroup:new{ align = "center" }
    local caption
    self.dhikr, self.scrolls = nil, false
    if st.done then
        table.insert(body, arabic("تمّت " .. Adhkar.titles[self.set], ARABIC, 40, inner))
        self.count_text = text(" ", BOLD, 72)
        caption = "Back: last dhikr"
    else
        local vgap = Screen:scaleBySize(14)
        local fadl = item.fadl and arabic(item.fadl, ARABIC_REGULAR, 20, inner)
        local ref = arabic(item.ref, ARABIC_REGULAR, 15, inner, { fg = GRAY })
        local left = room - 2 * vgap - ref:getSize().h - (fadl and fadl:getSize().h + vgap or 0)
        local size
        for _, s in ipairs(DHIKR_SIZES) do
            local m = arabic(item.text, ARABIC, s, inner, { measure = true })
            local h = m:getTextHeight()
            m:free()
            size, self.scrolls = s, h > left
            if not self.scrolls then break end
        end
        self.dhikr = arabic(item.text, ARABIC, size, inner, { height = self.scrolls and left or nil })
        table.insert(body, self.dhikr)
        table.insert(body, VerticalSpan:new{ width = 2 * vgap })
        if fadl then
            table.insert(body, fadl)
            table.insert(body, VerticalSpan:new{ width = vgap })
        end
        table.insert(body, ref)
        self.count_text = text(tostring(st.left), BOLD, 72)
        caption = item.count > 1 and string.format("of %d  ·  tap to count", item.count) or "tap to count"
        if self.scrolls then caption = caption .. "  ·  swipe up for more" end
    end

    self.count_box = FrameContainer:new{
        width = W, height = count_h, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = W, h = count_h }, VerticalGroup:new{
            align = "center",
            self.count_text,
            text(caption, SANS, 16, GRAY),
        } },
    }
    local area = InputContainer:new{
        dimen = Geom:new{ w = W, h = room + count_h },
        VerticalGroup:new{
            align = "center",
            CenterContainer:new{ dimen = Geom:new{ w = W, h = room }, body },
            self.count_box,
        },
    }
    area.ges_events = {
        TapCount = { GestureRange:new{ ges = "tap", range = function() return area.dimen end } },
        SwipeText = { GestureRange:new{ ges = "swipe", range = function() return area.dimen end } },
    }
    area.onTapCount = function() return self:onCount() end
    area.onSwipeText = function(_, _, ges) return self:onSwipeText(ges) end

    self.body[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0, margin = 0, background = WHITE,
        VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = pad },
            CenterContainer:new{ dimen = Geom:new{ w = W, h = top_h }, top },
            line(),
            area,
            line(),
            buttons,
        },
    }
end

function AdhkarWidget:save()
    Adhkar.save(self.progress, self.store)
end

function AdhkarWidget:refresh()
    self:build()
    UIManager:setDirty(self, "partial")
end

function AdhkarWidget:act(fn)
    fn(self.st, self.set)
    self:save()
    self:refresh()
end

-- Simple UI closes the widget under its bar this way when another tab is tapped.
function AdhkarWidget:onClose()
    UIManager:close(self)
    return true
end

function AdhkarWidget:onCount()
    if self.st.done then return true end
    if Adhkar.count(self.st, self.set) then
        self:save()
        self:refresh()
    else
        self.count_text:setText(tostring(self.st.left))
        UIManager:setDirty(self, function() return "ui", self.count_box.dimen end)
    end
    return true
end

function AdhkarWidget:onSwipeText(ges)
    if not self.scrolls then return true end
    if ges.direction == "north" then
        self.dhikr:scrollDown()
    elseif ges.direction == "south" then
        self.dhikr:scrollUp()
    else
        return true
    end
    UIManager:setDirty(self, function() return "ui", self.dhikr.dimen end)
    return true
end

function AdhkarWidget:switch(set)
    self:save()
    self:open(set)
    UIManager:setDirty(self, "partial")
end

function AdhkarWidget:onSuspend()
    self:save()
end

function AdhkarWidget:onResume()
    local p = Adhkar.periods(os.time(), self.cfg)
    if p[self.set] ~= self.st.key then self:open(p.current) else self:build() end
    UIManager:setDirty(self, "ui")
end

function AdhkarWidget:onCloseWidget()
    self:save()
    if self.on_close then self.on_close() end
    UIManager:setDirty(nil, "ui")
end

return AdhkarWidget

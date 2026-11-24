-- A random highlight or snip from your books, with a button to open the book at it.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_GRAY_4

local function face(bold, size)
    return Font:getFace(bold and "Bookerly-Bold.ttf" or "Bookerly-Regular.ttf", size)
        or Font:getFace(bold and "tfont" or "cfont", size)
end

local Recall = InputContainer:extend{
    name = "dashboard_recall",
    covers_fullscreen = true,
}

-- Every highlight, note and snip of the books in the reading history.
function Recall.collect()
    local ReadHistory = require("readhistory")
    local DocSettings = require("docsettings")
    local DataStorage = require("datastorage")
    -- The open book keeps new highlights in memory until it saves.
    local reader = require("apps/reader/readerui").instance
    if reader then reader:saveSettings() end
    local cards, seen = {}, {}
    for _, h in ipairs(ReadHistory.hist or {}) do
        local file = h.file
        if file and not seen[file] and DocSettings:hasSidecarFile(file) then
            seen[file] = true
            local ok, err = pcall(function()
                local ds = DocSettings:open(file)
                local props = ds:readSetting("doc_props") or {}
                for _, item in ipairs(ds:readSetting("annotations") or {}) do
                    -- Page bookmarks have no drawer; their text is only "in <chapter>".
                    local snip = item.drawer and item.snip
                    if snip and snip:sub(1, 2) == "./" then snip = DataStorage:getDataDir() .. snip:sub(2) end
                    if snip and lfs.attributes(snip, "mode") ~= "file" then snip = nil end
                    local text = item.drawer and type(item.text) == "string" and item.text:match("%S")
                        and item.text ~= "[snip]" and item.text or nil
                    if snip or text then
                        table.insert(cards, {
                            file = file, title = props.title or h.text,
                            author = props.authors and props.authors:gsub("\n", ", "),
                            chapter = item.chapter, text = text, snip = snip,
                            -- snip.lua stores the image name as the note.
                            note = not (item.snip and item.note and item.note:match("^snip: ")) and item.note or nil,
                            page = item.page, pos0 = item.pos0, pageno = item.pageno,
                        })
                    end
                end
            end)
            if not ok then logger.warn("dashboard: recall could not read", file, err) end
        end
    end
    return cards
end

function Recall:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.cards = Recall.collect()
    self[1] = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, background = WHITE }
    self:pick()
end

function Recall:pick()
    local n = #self.cards
    if n > 1 then
        local i
        repeat i = math.random(n) until i ~= self.index
        self.index = i
    else
        self.index = n > 0 and 1 or nil
    end
    self:build()
end

function Recall:open()
    local card = self.cards[self.index]
    if not card then return end
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local go = function(ui) ui.bookmark:gotoBookmark(card.page, card.pos0) end
    if reader and reader.document and reader.document.file == card.file then
        UIManager:close(self, "full")
        return go(reader)
    end
    UIManager:close(self)
    -- Also closes the open reader, or the file manager and Simple UI's home (ShowingReader).
    ReaderUI:showReader(card.file, nil, nil, nil, go)
end

function Recall:build()
    local W, H = self.dimen.w, self.dimen.h
    local pad = Screen:scaleBySize(24)
    local inner = W - 2 * pad
    local card = self.cards[self.index]
    local gap = Screen:scaleBySize(16)
    local bw = math.floor((inner - 2 * gap) / 3)
    local function btn(label, cb, enabled)
        local b = Button:new{ text = label, width = bw, bordersize = Screen:scaleBySize(2), radius = Screen:scaleBySize(8),
            text_font_face = "Bookerly-Bold.ttf", text_font_bold = false, text_font_size = 20, callback = cb,
            show_parent = self }
        if not enabled then b:disable() end
        return b
    end
    local buttons = HorizontalGroup:new{
        btn("Next", function() self:pick() UIManager:setDirty(self, "full") end, #self.cards > 1),
        HorizontalSpan:new{ width = gap },
        btn("Open", function() self:open() end, card ~= nil),
        HorizontalSpan:new{ width = gap },
        btn("Close", function() self:onClose() end, true),
    }
    -- "left" is flipped to right for each RTL (Arabic) paragraph.
    local function box(s, f, fg)
        return TextBoxWidget:new{ text = s, face = f, width = inner, fgcolor = fg or BLACK,
            alignment = "left", auto_para_direction = true }
    end

    local head = VerticalGroup:new{ align = "left" }
    local body
    if card then
        table.insert(head, box(card.title or "", face(true, 24)))
        local where = {}
        if card.author then table.insert(where, card.author) end
        if card.chapter and card.chapter ~= "" then table.insert(where, card.chapter) end
        local pn = card.pageno or (type(card.page) == "number" and card.page)
        if pn then table.insert(where, "p. " .. pn) end
        if #where > 0 then table.insert(head, box(table.concat(where, " · "), face(false, 17), GRAY)) end
    else
        table.insert(head, box("No highlights yet", face(true, 24)))
        table.insert(head, box("Highlights and snips from your books show here.", face(false, 17), GRAY))
    end
    local line = CenterContainer:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(28) },
        LineWidget:new{ dimen = Geom:new{ w = inner, h = Screen:scaleBySize(2) }, background = BLACK } }
    local count = box(#self.cards .. " highlights", face(false, 15), GRAY)
    local room = H - 2 * pad - head:getSize().h - line:getSize().h - buttons:getSize().h - count:getSize().h - 3 * gap
    if card then
        body = VerticalGroup:new{ align = "left" }
        local note = card.note and card.note:match("%S") and box("Note: " .. card.note, face(false, 18), GRAY)
        local left = room - (note and note:getSize().h + gap or 0)
        if card.snip then
            local img = ImageWidget:new{ file = card.snip, width = inner, height = left, scale_factor = 0 }
            local ok, size = pcall(img.getSize, img)
            if ok then table.insert(body, CenterContainer:new{ dimen = Geom:new{ w = inner, h = size.h }, img }) end
        else
            -- Smaller type for long highlights; what still does not fit scrolls (swipe or tap).
            local size = #card.text > 900 and 19 or #card.text > 400 and 22 or 26
            table.insert(body, ScrollTextWidget:new{ text = card.text, face = face(false, size), width = inner,
                height = left, alignment = "left", auto_para_direction = true, dialog = self })
        end
        if note then
            table.insert(body, VerticalSpan:new{ width = gap })
            table.insert(body, note)
        end
    else
        body = VerticalSpan:new{ width = 0 }
    end
    local content = VerticalGroup:new{
        align = "left",
        head,
        line,
        FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, width = inner, height = room,
            body },
        VerticalSpan:new{ width = gap },
        count,
        VerticalSpan:new{ width = gap },
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = buttons:getSize().h }, buttons },
    }
    if self[1][1] then self[1][1]:free() end
    self[1][1] = FrameContainer:new{ bordersize = 0, margin = 0, padding = pad, width = W, height = H,
        background = WHITE, content }
end

function Recall:onClose()
    UIManager:close(self, "full")
    return true
end

return Recall

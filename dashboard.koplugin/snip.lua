-- Snips in PDFs: drag a box over the page, save it as a PNG at 2x the screen size, and keep it as a
-- highlight with a frame around the area. Tap inside a frame to view the image.
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local DataStorage = require("datastorage")
local Device = require("device")
local Document = require("document/document")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageViewer = require("ui/widget/imageviewer")
local InputContainer = require("ui/widget/container/inputcontainer")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ffiUtil = require("ffi/util")
local util = require("util")

local Screen = Device.screen
local DRAWER = "dashboard_snip"
local FRAME = Screen:scaleBySize(3)
local MIN = Screen:scaleBySize(20)

local Snip = {}

local function toast(text)
    UIManager:show(Notification:new{ text = text })
end

-- The areas of a snip annotation on the screen, one per shown page part.
local function screenRects(ui, item)
    local view = ui.view
    local parts = { [item.page] = item }
    if item.ext then parts = item.ext end
    local rects = {}
    for page = item.pos0.page or item.page, item.pos1.page or item.page do
        local part = parts[page]
        if part and (view.page_scroll or page == view.state.page) then
            local rect = Geom:new{
                x = part.pos0.x, y = part.pos0.y,
                w = part.pos1.x - part.pos0.x, h = part.pos1.y - part.pos0.y,
            }
            local r = view:pageToScreenTransform(page, rect)
            if r then table.insert(rects, r) end
        end
    end
    return rects
end

local Overlay = InputContainer:extend{
    ui = nil,
    rect = nil,
}

function Overlay:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local range = function() return self.dimen end
    self.ges_events = {
        SnipPan = { GestureRange:new{ ges = "pan", range = range } },
        SnipRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        SnipHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        SnipHoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
        SnipSwipe = { GestureRange:new{ ges = "swipe", range = range } },
        SnipTap = { GestureRange:new{ ges = "tap", range = range } },
    }
end

function Overlay:paintTo(bb, x, y)
    local r = self.rect
    if r then bb:paintBorder(x + r.x, y + r.y, r.w, r.h, FRAME, Blitbuffer.COLOR_BLACK) end
end

-- The page under the overlay is repainted too, so the old frame goes away.
function Overlay:redraw(old)
    local area = old and self.rect and old:combine(self.rect) or old or self.rect
    if not area then return end
    area = Geom:new{ x = area.x - FRAME, y = area.y - FRAME, w = area.w + 2 * FRAME, h = area.h + 2 * FRAME }
    UIManager:setDirty(self.ui.dialog, function() return "fast", area end)
end

function Overlay:onSnipPan(_, ges)
    local a, b = ges.start_pos, ges.pos
    local old = self.rect
    self.rect = Geom:new{
        x = math.min(a.x, b.x), y = math.min(a.y, b.y),
        w = math.abs(b.x - a.x), h = math.abs(b.y - a.y),
    }
    self:redraw(old)
    return true
end

function Overlay:onSnipRelease()
    if not self.rect or self.rect.w < MIN or self.rect.h < MIN then
        toast("Drag a larger box")
        return true
    end
    self:ask()
    return true
end

Overlay.onSnipHoldPan = Overlay.onSnipPan
Overlay.onSnipHoldRelease = Overlay.onSnipRelease

function Overlay:onSnipSwipe()
    if self.rect then return self:onSnipRelease() end
    toast("Drag slowly to draw the box")
    return true
end

function Overlay:onSnipTap()
    toast("Drag a box over the area")
    return true
end

function Overlay:clear()
    local old = self.rect
    self.rect = nil
    self:redraw(old)
end

function Overlay:finish()
    self:clear()
    UIManager:close(self)
end

function Overlay:ask()
    local dialog
    dialog = ButtonDialog:new{
        tap_close_callback = function() self:finish() end,
        buttons = { {
            { text = "Cancel", callback = function() UIManager:close(dialog) self:finish() end },
            { text = "Again", callback = function() UIManager:close(dialog) self:clear() end },
            { text = "Save", callback = function()
                UIManager:close(dialog)
                local r = self.rect
                self:finish()
                UIManager:nextTick(function() Snip.save(self.ui, r) end)
            end },
        } },
    }
    UIManager:show(dialog)
end

function Snip.start(ui)
    if not ui.paging then
        return toast("Snips work in PDFs only")
    end
    if ui.document.configurable.text_wrap == 1 then
        return toast("Turn off reflow to snip")
    end
    UIManager:show(Overlay:new{ ui = ui })
    toast("Drag a box over the area")
end

-- Renders the area again from the PDF at twice the current zoom.
local function render(ui, pageno, p0, p1)
    local state = ui.view.state
    local zoom = state.zoom * 2
    local rect = Geom:new{
        x = math.floor(p0.x * zoom), y = math.floor(p0.y * zoom),
        w = math.ceil((p1.x - p0.x) * zoom), h = math.ceil((p1.y - p0.y) * zoom),
    }
    rect.scaled_rect = Geom:new(rect)
    -- Document.renderPage, not ui.document:renderPage: KOReader's page optimizing would ignore the rect.
    local ok, tile = pcall(Document.renderPage, ui.document, pageno, rect, zoom, state.rotation,
        state.gamma or 1.0, state.saturation or 1.0)
    if ok and tile and tile.bb then return tile.bb end
    logger.warn("dashboard: snip render failed", tile)
end

-- A corner in the margin around a page or in the gap between pages maps to no page: move it toward the
-- box center, first up or down only, then sideways only, until it lands on a page.
local function toPage(view, r, x, y)
    local cx, cy = r.x + r.w / 2, r.y + r.h / 2
    for _, m in ipairs({ { 0, 1 }, { 1, 0 }, { 1, 1 } }) do
        for i = 0, 50 do
            local f = i / 50
            local p = view:screenToPageTransform({ x = x + (cx - x) * f * m[1], y = y + (cy - y) * f * m[2] })
            if p then return p end
        end
    end
end

function Snip.save(ui, r)
    local view = ui.view
    local p0 = toPage(view, r, r.x, r.y)
    local p1 = toPage(view, r, r.x + r.w, r.y + r.h)
    if not p0 or not p1 then
        return toast("The box must be on the page")
    end
    local parts
    if p0.page == p1.page then
        parts = { { p0 = p0, p1 = p1 } }
    elseif not view.page_scroll then
        return toast("The box must be on one page")
    elseif p1.page > p0.page + 1 then
        return toast("A snip can cover at most 2 pages")
    else
        -- The other two corners give the x of the box on each page.
        local top_right = view:screenToPageTransform({ x = r.x + r.w, y = r.y })
        local bottom_left = view:screenToPageTransform({ x = r.x, y = r.y + r.h })
        -- Part 1 ends and part 2 starts at the page content edge (the margins KOReader crops in its zoom),
        -- or the frames reach into the other page and the PNG gets a white band.
        local bb1, bb2 = ui.document:getPageBBox(p0.page), ui.document:getPageBBox(p1.page)
        parts = {
            { p0 = p0, p1 = { x = top_right.x, y = bb1 and bb1.y1 or math.huge, page = p0.page, zoom = p0.zoom, rotation = p0.rotation } },
            { p0 = { x = bottom_left.x, y = bb2 and bb2.y0 or 0, page = p1.page, zoom = p1.zoom, rotation = p1.rotation }, p1 = p1 },
        }
    end
    for i = #parts, 1, -1 do
        local a, b = parts[i].p0, parts[i].p1
        local dim = ui.document:getNativePageDimensions(a.page)
        a.x, a.y = math.max(0, a.x), math.max(0, a.y)
        b.x, b.y = math.min(dim.w, b.x), math.min(dim.h, b.y)
        if b.x <= a.x or b.y <= a.y then table.remove(parts, i) end
    end
    if #parts == 0 then
        return toast("The box must be on the page")
    end
    p0, p1 = parts[1].p0, parts[#parts].p1
    local pageno = p0.page
    toast("Saving snip ...")
    UIManager:forceRePaint()
    local bb = render(ui, pageno, p0, parts[1].p1)
    if bb and #parts == 2 then
        -- Copy the first part: rendering the second one can drop it from the cache.
        local top = bb:copy()
        local bottom = render(ui, p1.page, parts[2].p0, p1)
        bb = nil
        if bottom then
            bb = Blitbuffer.new(math.max(top:getWidth(), bottom:getWidth()), top:getHeight() + bottom:getHeight(),
                top:getType())
            bb:fill(Blitbuffer.COLOR_WHITE)
            bb:blitFrom(top, 0, 0)
            bb:blitFrom(bottom, 0, top:getHeight())
        end
        top:free()
    end
    if not bb then return toast("Could not save the snip") end

    local book = select(2, util.splitFilePathName(ui.document.file))
    local dir = ffiUtil.realpath(DataStorage:getDataDir()) .. "/snips"
    lfs.mkdir(dir)
    dir = dir .. "/" .. util.getSafeFilename(book, dir)
    lfs.mkdir(dir)
    local name = string.format("p%d-%s.png", pageno, os.date("%Y%m%d-%H%M%S"))
    local path = dir .. "/" .. name
    local ok, err = pcall(bb.writePNG, bb, path)
    if #parts == 2 then bb:free() end
    if not ok then
        logger.warn("dashboard: snip write failed", err)
        return toast("Could not save the snip")
    end

    local pos0 = { x = p0.x, y = p0.y, page = pageno, zoom = p0.zoom, rotation = p0.rotation }
    local pos1 = { x = p1.x, y = p1.y, page = p1.page, zoom = p0.zoom, rotation = p0.rotation }
    local ext = #parts == 2 and {} or nil
    local words = {}
    for _, part in ipairs(parts) do
        local a, b = part.p0, part.p1
        if ext then
            ext[a.page] = { pos0 = { x = a.x, y = a.y, page = a.page }, pos1 = { x = b.x, y = b.y, page = a.page } }
        end
        local got, lines = pcall(ui.document.getPageTextBoxes, ui.document, a.page)
        for _, line in ipairs(got and lines or {}) do
            for _, w in ipairs(line) do
                local cx, cy = (w.x0 + w.x1) / 2, (w.y0 + w.y1) / 2
                if w.word and cx >= a.x and cx <= b.x and cy >= a.y and cy <= b.y then
                    table.insert(words, w.word)
                end
            end
        end
    end
    local text = util.cleanupSelectedText(table.concat(words, " "))
    local item = {
        page = pageno, pos0 = pos0, pos1 = pos1, ext = ext,
        text = text ~= "" and text or "[snip]",
        note = "snip: " .. name,
        drawer = DRAWER,
        chapter = ui.toc:getTocTitleByPage(pageno),
        snip = path,
    }
    local index = ui.annotation:addItem(item)
    view.highlight.page_boxes[pageno] = nil
    view.highlight.page_boxes[p1.page] = nil
    view.footer:maybeUpdateFooter()
    ui:handleEvent(Event:new("AnnotationsModified", { item, nb_highlights_added = 1, index_modified = index }))
    UIManager:setDirty(ui.dialog, "ui")
    toast("Snip saved")
end

-- Called when a PDF opens: draw the frames, keep KOReader from drawing the text boxes of a snip,
-- and open the image on a tap inside a frame.
function Snip.attach(ui)
    if not ui.paging or ui.view.view_modules.dashboard_snips then return end
    local view = ui.view
    if not view.dashboard_snip_patched then
        view.dashboard_snip_patched = true
        local orig = view.drawHighlightRect
        view.drawHighlightRect = function(this, bb, x, y, rect, drawer, ...)
            if drawer == DRAWER then return end
            return orig(this, bb, x, y, rect, drawer, ...)
        end
        -- The text boxes of a snip run in reading order, far outside its frame: a tap there must not open it.
        local orig_saved = view.drawPageSavedHighlight
        view.drawPageSavedHighlight = function(this, ...)
            -- "Apply current style to all highlights" and the style menu give a snip a normal style; undo it.
            for _, item in ipairs(this.ui.annotation.annotations) do
                if item.snip and item.drawer ~= DRAWER then
                    item.drawer, item.color = DRAWER, nil
                end
            end
            local colorful = orig_saved(this, ...)
            local boxes = this.highlight.visible_boxes
            for i = #boxes, 1, -1 do
                if boxes[i].drawer == DRAWER then table.remove(boxes, i) end
            end
            return colorful
        end
        -- The Markdown exporter fails on a drawer that has no formatting option.
        local exporter = G_reader_settings:readSetting("exporter")
        local md = exporter and exporter.markdown
        if md and md.formatting_options and not md.formatting_options[DRAWER] then
            md.formatting_options[DRAWER] = "none"
        end
    end
    -- Early snips kept a path relative to the KOReader folder.
    for _, item in ipairs(ui.annotation.annotations) do
        if item.snip and item.snip:sub(1, 2) == "./" then
            item.snip = ffiUtil.realpath(DataStorage:getDataDir()) .. item.snip:sub(2)
        end
    end
    view:registerViewModule("dashboard_snips", {
        paintTo = function(_, bb, x, y)
            for _, item in ipairs(ui.annotation.annotations) do
                if item.drawer == DRAWER then
                    for _, r in ipairs(screenRects(ui, item)) do
                        bb:paintBorder(x + r.x, y + r.y, r.w, r.h, FRAME, Blitbuffer.COLOR_BLACK)
                    end
                end
            end
        end,
    })
    ui:registerTouchZones({ {
        id = "dashboard_snip_tap",
        ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
        overrides = { "readerhighlight_tap", "tap_forward", "tap_backward", "readermenu_tap", "readermenu_ext_tap",
            "readerconfigmenu_tap", "readerconfigmenu_ext_tap", "readerfooter_tap",
            "tap_top_left_corner", "tap_top_right_corner", "tap_left_bottom_corner", "tap_right_bottom_corner" },
        handler = function(ges)
            for _, item in ipairs(ui.annotation.annotations) do
                if item.drawer == DRAWER and item.snip then
                    local hit
                    for _, r in ipairs(screenRects(ui, item)) do
                        hit = hit or ges.pos:intersectWith(r)
                    end
                    if hit then
                        if lfs.attributes(item.snip, "mode") ~= "file" then
                            toast("The snip image is missing")
                        else
                            UIManager:show(ImageViewer:new{ file = item.snip, fullscreen = true,
                                with_title_bar = true, title_text = item.note })
                        end
                        return true
                    end
                end
            end
        end,
    } })
end

return Snip

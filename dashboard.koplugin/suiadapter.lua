-- The only file that touches Simple UI. Every call is guarded: without Simple UI the plugin loads and shows nothing.
local logger = require("logger")

local SUI = {}

local function load(path)
    local ok, mod = pcall(require, path)
    if ok and type(mod) == "table" then return mod end
    logger.info("dashboard: Simple UI not available:", path)
end

local function call(what, fn, ...)
    if type(fn) ~= "function" then
        logger.warn("dashboard: Simple UI API changed, missing", what)
        return
    end
    local ok, res = pcall(fn, ...)
    if not ok then logger.warn("dashboard: Simple UI", what, "failed:", res) end
    return ok, res
end

-- Simple UI's QA init drops bar tabs whose action is not registered yet, so this must run before its init.
-- Our folder name sorts before simpleui.koplugin, and KOReader starts plugins in path order.
function SUI.register(modules, actions, bars)
    local Registry = load("modules/moduleregistry")
    if Registry then
        for _, mod in ipairs(modules) do call("Registry.register", Registry.register, mod) end
    end
    local QA = load("features/sui_quickactions")
    if QA then
        for _, action in ipairs(actions) do call("QA.register", QA.register, action) end
    end
    local Core = load("infra/sui_core")
    local BarInjection = Core and Core.BarInjection
    if Core and not BarInjection then logger.warn("dashboard: Simple UI API changed, missing BarInjection") end
    if BarInjection then
        for _, bar in ipairs(bars) do
            SUI.bars = call("BarInjection.register", BarInjection.register, bar) or SUI.bars
        end
    end
end

-- A mark on the top right of the icon of a bottom bar tab: mark() returns true for a dot,
-- a string for a small badge with that text, or nothing.
local marks, mark_ids, screen_marks = {}, {}, {}

local function value(fn)
    local ok, v = pcall(fn)
    if ok and (v == true or (type(v) == "string" and v ~= "")) then return v end
end

-- The tab of a custom Simple UI screen gets the mark of a module on that screen.
local function screenHas(cs_id, module_id)
    local Store = package.loaded["infra/sui_store"]
    local layout = Store and Store.get and Store:get("simpleui_layout_cs_" .. cs_id)
    for _, page in ipairs(type(layout) == "table" and layout.pages or {}) do
        for _, m in ipairs(page.modules or {}) do
            if m == module_id then return true end
        end
    end
end

local function markOf(id)
    if marks[id] then return value(marks[id]) end
    local cs_id = type(id) == "string" and id:match("^open_custom_screen:(.+)$")
    if not cs_id then return end
    for module_id, fn in pairs(screen_marks) do
        if screenHas(cs_id, module_id) then
            local v = value(fn)
            if v then return v end
        end
    end
end

local function markWidget(v, size)
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    if v == true then
        local dot = require("ui/widget/widget"):new{ dimen = Geom:new{ w = size, h = size } }
        function dot:paintTo(bb, x, y)
            local r = math.floor(size / 2)
            bb:paintCircle(x + r, y + r, r, Blitbuffer.COLOR_BLACK)
        end
        return dot
    end
    local Screen = require("device").screen
    return require("ui/widget/container/framecontainer"):new{
        bordersize = 0, margin = 0, background = Blitbuffer.COLOR_BLACK, radius = Screen:scaleBySize(7),
        padding = 0, padding_left = Screen:scaleBySize(4), padding_right = Screen:scaleBySize(4),
        require("ui/widget/textwidget"):new{
            text = v, face = require("ui/font"):getFace("cfont", 11), bold = true, fgcolor = Blitbuffer.COLOR_WHITE,
            padding = 0,
        },
    }
end

local install
function SUI.tabMark(action_id, mark)
    if not marks[action_id] then table.insert(mark_ids, action_id) end
    marks[action_id] = mark
    install()
end

function SUI.screenMark(module_id, mark)
    screen_marks[module_id] = mark
    install()
end

install = function()
    local Bottombar = load("screens/sui_bottombar")
    if not Bottombar or Bottombar.dashboard_marks then return end
    if type(Bottombar.buildTabCell) ~= "function" then
        logger.warn("dashboard: Simple UI API changed, missing Bottombar.buildTabCell")
        return
    end
    Bottombar.dashboard_marks = true
    local Screen = require("device").screen
    local orig = Bottombar.buildTabCell
    Bottombar.buildTabCell = function(id, active, tab_w, mode)
        local cell = orig(id, active, tab_w, mode)
        local v = markOf(id)
        if not v or type(cell) ~= "table" then return cell end
        local ok, widget = pcall(markWidget, v, Screen:scaleBySize(9))
        if not ok then
            logger.warn("dashboard: tab mark failed", widget)
            return cell
        end
        local size = widget:getSize()
        local icon = (type(Bottombar.ICON_SZ) == "function" and Bottombar.ICON_SZ()) or size.h * 3
        local bar_h = (type(Bottombar.BAR_H) == "function" and Bottombar.BAR_H()) or icon * 2
        local content = cell[1] and cell[1][1]
        local content_h = content and content.getSize and content:getSize().h or icon
        widget.overlap_offset = {
            math.min(tab_w - size.w, math.floor((tab_w + icon) / 2 - size.h / 2)),
            math.max(0, math.floor((bar_h - content_h) / 2) - math.floor(size.h / 3)),
        }
        cell[#cell + 1] = widget
        return cell
    end
end

-- What the bar shows besides the marks, such as a label that changes; checked by syncBars.
local watched = {}
function SUI.watchBar(fn) table.insert(watched, fn) end

-- Builds again the bottom bars of the shown screens when a mark or a watched value changed.
local last_key
function SUI.syncBars(repaint)
    local Bottombar = package.loaded["screens/sui_bottombar"]
    if not (Bottombar and Bottombar.dashboard_marks) then return end
    local key = {}
    for _, id in ipairs(mark_ids) do table.insert(key, tostring((markOf(id)))) end
    for module_id, fn in pairs(screen_marks) do table.insert(key, module_id .. tostring((value(fn)))) end
    for _, fn in ipairs(watched) do table.insert(key, tostring((select(2, pcall(fn))))) end
    key = table.concat(key, "|")
    if key == last_key then return end
    last_key = key
    local UIManager = require("ui/uimanager")
    for _, win in ipairs(UIManager._window_stack or {}) do
        local w = win.widget
        local state = w and w._navbar_bar and w._navbar_bar._tab_state
        if state and w._navbar_tabs then
            call("Bottombar.replaceBar", Bottombar.replaceBar, w,
                Bottombar.buildBarWidget(state.active, w._navbar_tabs), w._navbar_tabs)
            if repaint and UIManager:getTopmostVisibleWidget() == w then
                call("Bottombar.repaintBar", Bottombar.repaintBar, w)
            end
        end
    end
end

-- Our lines for Simple UI's Home critter: lines() returns { id, text, sub, mood } tables. They come up now
-- and then among Simple UI's own phrases.
function SUI.critterLines(lines)
    local Phrases = load("modules/critter/phrases")
    if not Phrases or Phrases.dashboard_lines then return end
    if type(Phrases.pick) ~= "function" then
        logger.warn("dashboard: Simple UI API changed, missing critter Phrases.pick")
        return
    end
    Phrases.dashboard_lines = true
    local orig = Phrases.pick
    Phrases.pick = function(f, opts, celebrate)
        local phrase = orig(f, opts, celebrate)
        if celebrate and phrase then return phrase end
        local ok, list = pcall(lines)
        if not ok or type(list) ~= "table" or #list == 0 then return phrase end
        if phrase and math.random(4) > 1 then return phrase end
        local line = list[math.random(#list)]
        local source = { id = line.id, cat = "dashboard", mood = line.mood }
        source.when = function()
            local ok2, now = pcall(lines)
            for _, l in ipairs(ok2 and now or {}) do
                if l.id == line.id then line = l return true end
            end
            return false
        end
        source.text = function() return line.text end
        source.sub = function() return line.sub end
        return { text = line.text, sub = line.sub, mood = line.mood, source = source }
    end
end

-- Simple UI keeps the tab of the screen below active; the adhkar screen opened from a menu belongs to no tab.
function SUI.clearActiveTab(widget)
    local Bottombar = load("screens/sui_bottombar")
    call("Bottombar.setActiveTab", Bottombar and Bottombar.setActiveTab, widget, "dash_adhkar_open")
end

-- Height of our full-screen widgets: Simple UI puts its top bar and bottom bar around them.
function SUI.contentHeight()
    local Core = SUI.bars and package.loaded["infra/sui_core"]
    local ok, h = call("getContentHeight", Core and Core.getContentHeight)
    local Screen = require("device").screen
    return ok and type(h) == "number" and h > 0 and h or Screen:getHeight()
end

local style
function SUI.style()
    if style then return style end
    local S = load("features/sui_style") or {}
    local color = S.COLOR or {}
    local Blitbuffer = require("ffi/blitbuffer")
    style = {
        regular = S.FACE_REGULAR or "cfont",
        bold = S.FACE_BOLD or "tfont",
        title = S.FS_TITLE or 22,
        body = S.FS_BODY or 18,
        detail = S.FS_DETAIL or 15,
        caption = S.FS_CAPTION or 12,
        ink = { blk = color.text_primary or Blitbuffer.COLOR_BLACK, sub = color.text_dim or Blitbuffer.gray(0.45) },
    }
    return style
end

-- What a module needs from Simple UI's build context.
function SUI.context(mod_id, ctx)
    if type(ctx) ~= "table" then ctx = {} end
    local Config = package.loaded["infra/sui_config"]
    local ok, scale = call("Config.getModuleScale", Config and Config.getModuleScale, mod_id, ctx.pfx)
    if not ctx._screen_widget or not ctx.refresh_fn then
        logger.warn("dashboard: Simple UI API changed, build context has no screen or refresh_fn")
    end
    local ink = ctx.ink or SUI.style().ink
    return {
        screen = ctx._screen_widget,
        refresh = ctx.refresh_fn,
        ink = { blk = ink.blk or SUI.style().ink.blk, sub = ink.sub or SUI.style().ink.sub },
        scale = ok and type(scale) == "number" and scale or 1,
        width = ctx.col_w,
    }
end

-- Built, not parked under the reader and not suspended.
function SUI.active(screen)
    if not screen then return false end
    if type(screen.isActive) ~= "function" then return true end
    local ok, res = call("ScreenWidget:isActive", screen.isActive, screen)
    return ok and res
end

function SUI.refresh(fn)
    call("refresh_fn", fn)
end

return SUI

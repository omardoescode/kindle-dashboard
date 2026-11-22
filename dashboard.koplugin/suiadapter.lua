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

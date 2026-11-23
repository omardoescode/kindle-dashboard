-- The lock screen: Cinder the critter, in a mood that follows today's reading, with one line about it.
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")

local Screen = Device.screen
local Lock = {}

local function stats()
    local today = os.date("*t")
    today.hour, today.min, today.sec = 0, 0, 0
    local midnight = os.time(today)
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return 0, 0 end
    local db = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
    local secs = tonumber(db:rowexec("SELECT coalesce(sum(duration), 0) FROM page_stat_data WHERE start_time >= "
        .. midnight)) or 0
    local res = db:exec("SELECT DISTINCT date(start_time, 'unixepoch', 'localtime') AS d FROM page_stat_data "
        .. "ORDER BY d DESC LIMIT 400")
    db:close()
    local days = {}
    for _, d in ipairs(res and res[1] or {}) do days[d] = true end
    -- A streak still counts before today's reading starts.
    local streak, t = 0, os.time()
    if not days[os.date("%Y-%m-%d", t)] then t = t - 86400 end
    while days[os.date("%Y-%m-%d", t)] do
        streak = streak + 1
        t = t - 86400
    end
    return secs, streak
end

local function finishedToday()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return end
    local DocSettings = require("docsettings")
    local today = os.date("%Y-%m-%d")
    for i, h in ipairs(ReadHistory.hist or {}) do
        if i > 15 then break end
        if h.file and DocSettings:hasSidecarFile(h.file) then
            local ds = DocSettings:open(h.file)
            local summary = ds:readSetting("summary")
            if summary and summary.status == "complete" and summary.modified == today then
                local props = ds:readSetting("doc_props")
                return props and props.title or h.text
            end
        end
    end
end

function Lock.state()
    local secs, streak = stats()
    local mins = math.floor(secs / 60)
    local goal = G_reader_settings:readSetting("dashboard_daily_goal_minutes") or 30
    local done = finishedToday()
    if done then return "party", "Finished: " .. done end
    if mins == 0 then return "sad", "Cinder waited for you today" end
    if streak >= 7 then return "cheer", streak .. " days in a row!" end
    if mins >= goal then return "love", "Goal met · " .. streak .. "-day streak" end
    local hour = os.date("*t").hour
    if hour >= 21 or hour < 5 then return "sleepy", mins .. " min today · Good night" end
    return "happy", mins .. " min today · " .. (goal - mins) .. " min to your goal"
end

-- The critter pixels as squares of side "scale": its images are a few dozen pixels.
local function paintCritter(bb, mood, cx, top, width)
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_critters/cinder/" .. mood .. ".png"
    local img = RenderImage:renderImageFile(path, false)
    if not img then return 0 end
    local w, h = img:getWidth(), img:getHeight()
    local flat = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    flat:fill(Blitbuffer.COLOR_WHITE)
    flat:alphablitFrom(img, 0, 0, 0, 0, w, h)
    img:free()
    local s = math.floor(width / w)
    local x0 = cx - math.floor(w * s / 2)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local c = flat:getPixel(x, y)
            if c:getColor8().a < 250 then bb:paintRect(x0 + x * s, top + y * s, s, s, c) end
        end
    end
    flat:free()
    return h * s
end

local function paintText(bb, text, face, cx, y)
    local tw = TextWidget:new{ text = text, face = face, max_width = bb:getWidth() - Screen:scaleBySize(40) }
    local size = tw:getSize()
    tw:paintTo(bb, cx - math.floor(size.w / 2), y)
    tw:free()
    return size.h
end

function Lock.render()
    local w, h = Screen:getWidth(), Screen:getHeight()
    local mood, line = Lock.state()
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)
    local cx = math.floor(w / 2)
    -- Sized by the short side, so it fits in landscape too.
    local cw = math.floor(math.min(w, h) * 0.6)
    local top = math.floor((h - cw * 0.73) / 2) - Screen:scaleBySize(30)
    local ch = paintCritter(bb, mood, cx, top, cw)
    local y = top + ch + Screen:scaleBySize(40)
    paintText(bb, line, Font:getFace("cfont", 26), cx, y)
    return bb
end

-- KOReader shows a random image from the lock screen folder; show Cinder instead.
function Lock.install()
    local Screensaver = require("ui/screensaver")
    if Screensaver.dashboard_lock then return end
    Screensaver.dashboard_lock = true
    -- KOReader turns the screen to portrait for images; Cinder is drawn for the current rotation instead.
    local orig_portrait = Screensaver.modeExpectsPortrait
    Screensaver.modeExpectsPortrait = function(self)
        if self.dashboard_drawn then return false end
        return orig_portrait(self)
    end
    local orig_setup = Screensaver.setup
    Screensaver.setup = function(self, event, ...)
        self.dashboard_drawn = nil
        orig_setup(self, event, ...)
        if event or self.screensaver_type ~= "random_image" then return end
        -- The statistics plugin saves the session on Suspend, which comes after this.
        local ReaderUI = require("apps/reader/readerui")
        local stats_plugin = ReaderUI.instance and ReaderUI.instance.statistics
        if stats_plugin and stats_plugin.insertDB then pcall(stats_plugin.insertDB, stats_plugin) end
        local ok, bb = pcall(Lock.render)
        if ok and bb then
            self.image = bb
            self.dashboard_drawn = true
        else
            logger.warn("dashboard: lock screen failed", bb)
        end
    end
end

return Lock

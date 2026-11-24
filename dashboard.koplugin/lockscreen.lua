-- The lock screen: Anqa the critter, in a mood that follows today's reading, with one line about it.
local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local time = require("ui/time")

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

-- Books opened before this year cannot have been finished in it, and the history is newest first.
local function finishedThisYear()
    local ReadHistory = require("readhistory")
    local DocSettings = require("docsettings")
    local year = os.date("*t").year
    local since = os.time{ year = year, month = 1, day = 1, hour = 0 }
    local n = 0
    for _, h in ipairs(ReadHistory.hist or {}) do
        if (h.time or 0) < since then break end
        if h.file and DocSettings:hasSidecarFile(h.file) then
            local summary = DocSettings:open(h.file):readSetting("summary")
            if summary and summary.status == "complete" and tostring(summary.modified):sub(1, 4) == tostring(year) then
                n = n + 1
            end
        end
    end
    return n
end

local function mood(mins, streak)
    local goal = G_reader_settings:readSetting("dashboard_daily_goal_minutes") or 30
    local done = finishedToday()
    if done then return "party", "Finished: " .. done end
    if mins == 0 then return "sad", "Anqa waited for you today" end
    if streak >= 7 then return "cheer", streak .. " days in a row!" end
    if mins >= goal then return "love", "Goal met · " .. streak .. "-day streak" end
    local hour = os.date("*t").hour
    if hour >= 23 or hour < 5 then return "sleepy", mins .. " min today · Good night" end
    return "happy", mins .. " min today · " .. (goal - mins) .. " min to your goal"
end

function Lock.state()
    local secs, streak = stats()
    local m, line = mood(math.floor(secs / 60), streak)
    local ok, books = pcall(finishedThisYear)
    if not ok then logger.warn("dashboard: books this year failed", books) end
    books = ok and books or 0
    local acc = {}
    if books >= 5 then acc[#acc + 1] = "scarf" end
    if books >= 10 then acc[#acc + 1] = "glasses" end
    if streak >= 30 then acc[#acc + 1] = "crown" end
    return m, line, acc
end

-- In the critter's own pixels, from the top left "at" (column, row); a crown sits above the image.
local ACCESSORIES = {
    scarf = { at = { 2, 10 }, rows = {
        "XXXXXXXXXXXXX",
        "XLLDDLLDDLLDX",
        "XLLDDLLDDLLDX",
        "XXXXXXXXXXXXX",
        "XLLX",
        "XDDX",
        "XXXX",
    } },
    glasses = { at = { 5, 4 }, rows = {
        ".XXXXX.",
        "X.....X",
        "X.....XX",
        "X.....X",
        "X.....X",
        ".XXXXX.",
    } },
    crown = { at = { 5, -3 }, rows = {
        "X...X...X",
        "XX.XWX.XX",
        "XWXWWWXWX",
        "XWWWWWWWX",
        "XWDWDWDWX",
        "XXXXXXXXX",
    } },
}
-- The critter's own gray levels.
local TONES = { X = 0, D = 85, G = 136, L = 187, W = 238 }

-- The critter pixels as squares of side "scale": its images are a few dozen pixels.
local function paintCritter(bb, mood, cx, top, width, accessories)
    local path = DataStorage:getSettingsDir() .. "/simpleui/sui_critters/anqa/" .. mood .. ".png"
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
    for _, name in ipairs(accessories or {}) do
        local a = ACCESSORIES[name]
        for dy, row in ipairs(a.rows) do
            for dx = 1, #row do
                local v = TONES[row:sub(dx, dx)]
                if v then
                    bb:paintRect(x0 + (a.at[1] + dx - 1) * s, top + (a.at[2] + dy - 1) * s, s, s, Blitbuffer.Color8(v))
                end
            end
        end
    end
    return h * s
end

local function paintText(bb, text, face, cx, y)
    local tw = TextWidget:new{ text = text, face = face, max_width = bb:getWidth() - Screen:scaleBySize(40) }
    local size = tw:getSize()
    tw:paintTo(bb, cx - math.floor(size.w / 2), y)
    tw:free()
    return size.h
end

-- A pixel speech bubble like Simple UI's, its tail pointing up at the critter. Returns its height.
local function paintBubble(bb, text, face, cx, y, u, pad, dark)
    local tw = TextWidget:new{ text = text, face = face, max_width = bb:getWidth() - Screen:scaleBySize(80),
        fgcolor = dark and Blitbuffer.COLOR_WHITE or nil }
    local size = tw:getSize()
    local tail = 4
    local bw, bh = size.w + 2 * pad + 2 * u, size.h + 2 * pad + 2 * u
    local x, top = cx - math.floor(bw / 2), y + tail * u
    local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
    bb:paintRect(x, top, bw, bh, BLACK)
    bb:paintRect(x + u, top + u, bw - 2 * u, bh - 2 * u, dark and BLACK or WHITE)
    for _, c in ipairs({ { x, top }, { x + bw - u, top }, { x, top + bh - u }, { x + bw - u, top + bh - u } }) do
        bb:paintRect(c[1], c[2], u, u, WHITE)
    end
    bb:paintRect(x + u, top + u, u, u, BLACK)
    bb:paintRect(x + bw - 2 * u, top + u, u, u, BLACK)
    bb:paintRect(x + u, top + bh - 2 * u, u, u, BLACK)
    bb:paintRect(x + bw - 2 * u, top + bh - 2 * u, u, u, BLACK)
    local tx = cx - math.floor(u / 2)
    for k = 0, tail do
        bb:paintRect(tx - k * u, y + k * u, (2 * k + 1) * u, u, BLACK)
        if k > 0 and not dark then bb:paintRect(tx - (k - 1) * u, y + k * u, (2 * k - 1) * u, u, WHITE) end
    end
    tw:paintTo(bb, x + u + pad, top + u + pad)
    tw:free()
    return tail * u + bh, { x = x, y = y, w = bw, h = tail * u + bh }
end

-- powerd puts the Kindle to sleep a few seconds after it asks KOReader to show the lock screen, without
-- waiting. Reading the statistics and the book files then can be too slow, so that work runs while awake,
-- every 2 minutes; at sleep only the drawing is left.
local cached
local REFRESH = 120

local function refresh()
    local ok, mood, line, acc = pcall(Lock.state)
    if ok then
        local okSet, set = pcall(Lock.adhkarSet or function() end)
        cached = { mood = mood, line = line, accessories = acc, adhkar = okSet and type(set) == "string" and set or nil }
    else
        logger.warn("dashboard: lock state failed", mood)
    end
end

function Lock.render()
    local w, h = Screen:getWidth(), Screen:getHeight()
    if not cached then refresh() end
    local mood, line = cached.mood, cached.line
    -- Anqa sleeps from 11 PM to 5 AM, whatever the day was.
    local hour = os.date("*t").hour
    local night = hour >= 23 or hour < 5
    if night then mood = "sleepy" end
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)
    local cx = math.floor(w / 2)
    -- Geist Pixel, like the critter's bubble in Simple UI; Simple UI ships it and adds it to the font list.
    -- Its pixels are 1/13 of its size: other sizes blur them to gray.
    local unit = Screen:scaleBySize(1000) / 1000
    local px = 13 * math.max(2, math.floor(Screen:scaleBySize(26) / 13 + 0.5))
    local face = Font:getFace("GeistPixel-Regular.ttf", (px - 0.5) / unit) or Font:getFace("cfont", 26)
    local cap = require("lowbattery")()
    local azkar = cap and "Charge me · " .. cap .. "%"
        or cached.adhkar and "Don't forget your " .. cached.adhkar .. " azkar"
    local dark = not cap and azkar ~= nil    local gap, u, pad = Screen:scaleBySize(40), Screen:scaleBySize(3), Screen:scaleBySize(10)
    local probe = TextWidget:new{ text = "Xg", face = face }
    local line_h = probe:getSize().h
    probe:free()
    local text_h = line_h + (azkar and Screen:scaleBySize(16) + line_h + 2 * pad + 6 * u or 0)
    -- The whole group is centred above "Swipe up to read"; the critter shrinks when the screen is short.
    local bottom = h - Screen:scaleBySize(90)
    local crown = 0
    for _, name in ipairs(cached.accessories or {}) do
        if name == "crown" then crown = 0.2 end
    end
    local cw = math.floor(math.min(math.min(w, h) * 0.6,
        (bottom - Screen:scaleBySize(40) - gap - text_h) / (0.73 + crown)))
    local group_h = cw * (0.73 + crown) + gap + text_h
    local top = math.floor((bottom - group_h) / 2 + cw * crown)
    local ch = paintCritter(bb, mood, cx, top, cw, cached.accessories)
    local y = top + ch + Screen:scaleBySize(16)
    Lock.bubble = nil
    if azkar then
        local bh, rect = paintBubble(bb, azkar, face, cx, y, u, pad, dark)
        y = y + bh
        if dark then Lock.bubble = rect end
    end
    paintText(bb, line, face, cx, y + (azkar and Screen:scaleBySize(16) or gap - Screen:scaleBySize(16)))
    return bb
end

-- KOReader shows a random image from the lock screen folder; show Anqa instead.
function Lock.install()
    local Screensaver = require("ui/screensaver")
    if Screensaver.dashboard_lock then return end
    Screensaver.dashboard_lock = true
    -- KOReader turns the screen to portrait for images; Anqa is drawn for the current rotation instead.
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
        local start = time.now()
        local ok, bb = pcall(Lock.render)
        if ok and bb then
            self.image = bb
            self.dashboard_drawn = true
            logger.info("dashboard: lock screen drawn in", time.to_ms(time.since(start)), "ms")
        else
            logger.warn("dashboard: lock screen failed", bb)
        end
    end
    local UIManager = require("ui/uimanager")
    local function tick()
        local start = time.now()
        refresh()
        logger.dbg("dashboard: lock state in", time.to_ms(time.since(start)), "ms")
        UIManager:scheduleIn(REFRESH, tick)
    end
    UIManager:scheduleIn(5, tick)
end

return Lock

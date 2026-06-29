
--[[
    composer.lua — Kosmolitifier image composition engine (Blitbuffer edition)

    Loads images into Blitbuffer canvases and manipulates pixels directly.
    All composition happens on a single sw×sh canvas which is then handed
    to KoReader as an ImageWidget.

    Styles:
        1.  scanline_glitch   — strips from two images, some rows shifted/swapped
        2.  pixel_dither      — checkerboard interleave of two images
        3.  data_corrupt      — rows shifted horizontally by random amounts
        4.  inversion_zones   — random inverted rectangles over a base image
        5.  double_exposure   — two images blended by keeping darker/lighter pixel
        6.  column_drift      — columns of img A with random vertical offsets
        7.  noise_burn        — image with random white/black noise burned in
        8.  slice_offset      — image sliced into strips, each nudged horizontally
        9.  threshold_mix     — pixels from A where A is dark, else from B
        10. static_overlay    — dense random noise over a dimmed image
--]]

local ImageWidget   = require("ui/widget/imagewidget")
local OverlapGroup  = require("ui/widget/overlapgroup")
local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Screen        = Device.screen
local logger        = require("logger")

local Composer = {}

local sw = Screen:getWidth()
local sh = Screen:getHeight()

-- ──────────────────────────────────────────────────────────────────────────────
-- Image loading
-- ──────────────────────────────────────────────────────────────────────────────

local function loadImageToBlitbuffer(path)
    -- Try RenderImage first (most KoReader builds)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if ok and RenderImage then
        local bb = RenderImage:renderImageFile(path, false, sw, sh)
        if bb then return bb end
    end

    -- Fallback: Document/Image loader
    local ok2, Image = pcall(require, "image")
    if ok2 and Image then
        local bb = Image:open(path)
        if bb then return bb end
    end

    logger.warn("Kosmolitifier: could not load image: " .. tostring(path))
    return nil
end

--- Return a new blank 8-bit greyscale canvas sized sw×sh.
local function newCanvas()
    return Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
end

--- Wrap a Blitbuffer in an ImageWidget that fills the screen.
local function bbToWidget(bb)
    return ImageWidget:new{
        image        = bb,
        width        = sw,
        height       = sh,
        scale_factor = 0,
        alpha        = false,
    }
end

--- Clamp a value between lo and hi.
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Get a greyscale 0–255 value from a Blitbuffer pixel.
local function getGrey(bb, x, y)
    local c = bb:getPixel(x, y)
    -- getPixel returns a Color object; .a is alpha, use r for grey on BB8
    if c.r then return c.r end
    -- older API returns a number directly
    if type(c) == "number" then return c end
    return 128
end

--- Set a greyscale pixel (0–255).
local function setGrey(bb, x, y, v)
    bb:setPixel(x, y, Blitbuffer.gray(clamp(v, 0, 255), 0xFF))
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Image collection
-- ──────────────────────────────────────────────────────────────────────────────

local function collectImages(plugin_instance)
    local dir = plugin_instance:getPluginDir() .. "/img"
    local paths = {}

    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok then ok, lfs = pcall(require, "lfs") end

    if ok and lfs then
        for entry in lfs.dir(dir) do
            local lower = entry:lower()
            if lower:match("%.png$") or lower:match("%.jpg$") or lower:match("%.jpeg$") then
                table.insert(paths, dir .. "/" .. entry)
            end
        end
    else
        for i = 1, 30 do
            local p = dir .. "/" .. i .. ".png"
            local f = io.open(p, "rb")
            if f then f:close(); table.insert(paths, p) end
        end
    end

    return paths
end

local function pickRandom(list, n)
    local copy = {}
    for _, v in ipairs(list) do table.insert(copy, v) end
    for i = #copy, 2, -1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    local r = {}
    for i = 1, math.min(n, #copy) do r[i] = copy[i] end
    return r
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Composition styles (all return a Blitbuffer canvas)
-- ──────────────────────────────────────────────────────────────────────────────

--- 1. SCANLINE GLITCH
--- Copies horizontal strips alternately from A and B.
--- Some strips are shifted left/right and some are randomly swapped.
local function styleScanlineGlitch(bbA, bbB)
    local canvas = newCanvas()
    local strip_h = math.random(4, 18)
    local y = 0

    while y < sh do
        local h = math.min(strip_h + math.random(-2, 4), sh - y)
        if h < 1 then h = 1 end

        -- Randomly pick source and whether to shift
        local src    = (math.random(2) == 1) and bbA or bbB
        local shift  = 0
        if math.random(100) < 35 then
            shift = math.random(-math.floor(sw * 0.15), math.floor(sw * 0.15))
        end

        for row = y, y + h - 1 do
            if row < sh then
                for x = 0, sw - 1 do
                    local sx = clamp(x - shift, 0, sw - 1)
                    local v  = getGrey(src, sx, row)
                    -- Occasionally corrupt a pixel to pure white/black
                    if math.random(1000) < 3 then
                        v = (math.random(2) == 1) and 0 or 255
                    end
                    setGrey(canvas, x, row, v)
                end
            end
        end

        y = y + h
    end

    return canvas
end

--- 2. PIXEL DITHER MIX
--- Checkerboard: even pixels from A, odd from B, with a bit of noise.
local function stylePixelDither(bbA, bbB)
    local canvas = newCanvas()
    for y = 0, sh - 1 do
        for x = 0, sw - 1 do
            local v
            if (x + y) % 2 == 0 then
                v = getGrey(bbA, x, y)
            else
                v = getGrey(bbB, x, y)
            end
            -- Small noise jitter
            v = clamp(v + math.random(-12, 12), 0, 255)
            setGrey(canvas, x, y, v)
        end
    end
    return canvas
end

--- 3. DATA CORRUPT
--- Each horizontal strip is shifted by a random amount; some strips use the
--- wrong image entirely (simulates read corruption).
local function styleDataCorrupt(bbA, bbB)
    local canvas = newCanvas()
    -- Start with a full blit of A
    canvas:blitFrom(bbA, 0, 0, 0, 0, sw, sh)

    local strip_h = math.random(2, 10)
    local y = 0
    while y < sh do
        local h = math.min(strip_h, sh - y)
        if math.random(100) < 40 then
            local shift  = math.random(-math.floor(sw * 0.3), math.floor(sw * 0.3))
            local use_b  = math.random(100) < 30
            local src    = use_b and bbB or bbA

            for row = y, y + h - 1 do
                if row < sh then
                    for x = 0, sw - 1 do
                        local sx = clamp(x - shift, 0, sw - 1)
                        setGrey(canvas, x, row, getGrey(src, sx, row))
                    end
                end
            end
        end
        y = y + strip_h
    end

    -- Burn in some random bright/dark horizontal lines
    local n_lines = math.random(3, 12)
    for _ = 1, n_lines do
        local ly = math.random(0, sh - 1)
        local lv = (math.random(2) == 1) and 0 or 255
        for x = 0, sw - 1 do
            setGrey(canvas, x, ly, lv)
        end
    end

    return canvas
end

--- 4. INVERSION ZONES
--- Base image with random inverted rectangles punched through it.
local function styleInversionZones(bbA, bbB)
    local canvas = newCanvas()
    canvas:blitFrom(bbA, 0, 0, 0, 0, sw, sh)

    local n_rects = math.random(3, 9)
    for _ = 1, n_rects do
        local rw = math.random(math.floor(sw * 0.1), math.floor(sw * 0.55))
        local rh = math.random(math.floor(sh * 0.05), math.floor(sh * 0.35))
        local rx = math.random(0, sw - rw - 1)
        local ry = math.random(0, sh - rh - 1)

        -- Sometimes fill the zone from B instead of inverting
        if math.random(100) < 40 then
            canvas:blitFrom(bbB, rx, ry, rx, ry, rw, rh)
        else
            canvas:invertRect(rx, ry, rw, rh)
        end
    end

    return canvas
end

--- 5. DOUBLE EXPOSURE
--- Per-pixel: take the darker pixel from A and B (classic multiply-ish blend).
--- Optionally flip to lighter for a bleached look.
local function styleDoubleExposure(bbA, bbB)
    local canvas  = newCanvas()
    local lighter = math.random(2) == 1   -- randomly pick darker or lighter

    for y = 0, sh - 1 do
        for x = 0, sw - 1 do
            local a = getGrey(bbA, x, y)
            local b = getGrey(bbB, x, y)
            local v
            if lighter then
                v = math.max(a, b)
            else
                v = math.min(a, b)
            end
            setGrey(canvas, x, y, v)
        end
    end

    return canvas
end

--- 6. COLUMN DRIFT
--- Each vertical column of A is shifted up or down by a random amount,
--- wrapping around. Gaps filled from B.
local function styleColumnDrift(bbA, bbB)
    local canvas = newCanvas()
    -- Columns come in groups so the drift looks banded not just noise
    local group_w = math.random(4, 20)
    local x = 0
    while x < sw do
        local gw    = math.min(group_w, sw - x)
        local drift = math.random(-math.floor(sh * 0.25), math.floor(sh * 0.25))

        for cx = x, x + gw - 1 do
            if cx < sw then
                for y = 0, sh - 1 do
                    local sy = (y - drift) % sh
                    local v
                    if math.random(100) < 15 then
                        v = getGrey(bbB, cx, y)
                    else
                        v = getGrey(bbA, cx, sy)
                    end
                    setGrey(canvas, cx, y, v)
                end
            end
        end

        x = x + group_w
    end

    return canvas
end

--- 7. NOISE BURN
--- Image A with a layer of random noise burned on top at varying density.
local function styleNoiseBurn(bbA, bbB)
    local canvas   = newCanvas()
    canvas:blitFrom(bbA, 0, 0, 0, 0, sw, sh)

    -- Scatter noise in one or more rectangular zones
    local n_zones = math.random(1, 4)
    for _ = 1, n_zones do
        local zw      = math.random(math.floor(sw * 0.2), sw)
        local zh      = math.random(math.floor(sh * 0.1), sh)
        local zx      = math.random(0, sw - zw)
        local zy      = math.random(0, sh - zh)
        local density = math.random(10, 60)   -- percent of pixels hit

        for y = zy, zy + zh - 1 do
            if y < sh then
                for x = zx, zx + zw - 1 do
                    if x < sw and math.random(100) < density then
                        local nv
                        local r = math.random(3)
                        if r == 1 then
                            nv = 0      -- black pixel
                        elseif r == 2 then
                            nv = 255    -- white pixel
                        else
                            -- bleed a pixel from B
                            nv = getGrey(bbB, x, y)
                        end
                        setGrey(canvas, x, y, nv)
                    end
                end
            end
        end
    end

    return canvas
end

--- 8. SLICE OFFSET
--- Cut the image into vertical slices; shift each slice up/down randomly.
local function styleSliceOffset(bbA, bbB)
    local canvas    = newCanvas()
    canvas:blitFrom(bbA, 0, 0, 0, 0, sw, sh)

    local slice_w   = math.random(8, 40)
    local x = 0
    while x < sw do
        local w    = math.min(slice_w, sw - x)
        local soff = math.random(-math.floor(sh * 0.2), math.floor(sh * 0.2))
        local src  = (math.random(3) == 1) and bbB or bbA

        for cx = x, x + w - 1 do
            if cx < sw then
                for y = 0, sh - 1 do
                    local sy = (y - soff) % sh
                    setGrey(canvas, cx, y, getGrey(src, cx, sy))
                end
            end
        end

        x = x + slice_w
    end

    return canvas
end

--- 9. THRESHOLD MIX
--- Where A is dark (< threshold) use A's pixel, else use B's.
--- Creates a "cutout" effect where one image shows through the dark areas of another.
local function styleThresholdMix(bbA, bbB)
    local canvas    = newCanvas()
    local threshold = math.random(80, 175)
    local invert    = math.random(2) == 1

    for y = 0, sh - 1 do
        for x = 0, sw - 1 do
            local a = getGrey(bbA, x, y)
            local v
            if invert then
                v = (a > threshold) and a or getGrey(bbB, x, y)
            else
                v = (a < threshold) and a or getGrey(bbB, x, y)
            end
            setGrey(canvas, x, y, v)
        end
    end

    return canvas
end

--- 10. STATIC OVERLAY
--- Heavy noise over a dimmed base image — looks like a bad TV signal.
local function styleStaticOverlay(bbA, bbB)
    local canvas  = newCanvas()

    -- Dim A first by averaging toward mid-grey
    for y = 0, sh - 1 do
        for x = 0, sw - 1 do
            local a = getGrey(bbA, x, y)
            -- Mix toward 128 (dim the image)
            local v = math.floor(a * 0.45 + 128 * 0.55)
            setGrey(canvas, x, y, v)
        end
    end

    -- Layer of dense static; some pixels bleed from B
    local density = math.random(25, 55)
    for y = 0, sh - 1 do
        for x = 0, sw - 1 do
            if math.random(100) < density then
                local r = math.random(4)
                if r == 1 then
                    setGrey(canvas, x, y, 0)
                elseif r == 2 then
                    setGrey(canvas, x, y, 255)
                elseif r == 3 then
                    setGrey(canvas, x, y, math.random(0, 255))
                else
                    setGrey(canvas, x, y, getGrey(bbB, x, y))
                end
            end
        end
    end

    return canvas
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Style registry
-- ──────────────────────────────────────────────────────────────────────────────

local STYLES = {
    { name = "scanline_glitch",  fn = styleScanlineGlitch  },
    { name = "pixel_dither",     fn = stylePixelDither     },
    { name = "data_corrupt",     fn = styleDataCorrupt     },
    { name = "inversion_zones",  fn = styleInversionZones  },
    { name = "double_exposure",  fn = styleDoubleExposure  },
    { name = "column_drift",     fn = styleColumnDrift     },
    { name = "noise_burn",       fn = styleNoiseBurn       },
    { name = "slice_offset",     fn = styleSliceOffset     },
    { name = "threshold_mix",    fn = styleThresholdMix    },
    { name = "static_overlay",   fn = styleStaticOverlay   },
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Public entry point
-- ──────────────────────────────────────────────────────────────────────────────

function Composer:create(plugin_instance)
    math.randomseed(os.time())

    local all_images = collectImages(plugin_instance)
    if #all_images == 0 then
        logger.warn("Kosmolitifier: no images found in img/ folder")
        return nil
    end

    local paths = pickRandom(all_images, 2)
    local pathA = paths[1]
    local pathB = paths[2] or paths[1]

    local bbA = loadImageToBlitbuffer(pathA)
    if not bbA then
        logger.warn("Kosmolitifier: failed to load image A: " .. tostring(pathA))
        return nil
    end

    -- Scale A to screen size if needed
    if bbA:getWidth() ~= sw or bbA:getHeight() ~= sh then
        local scaled = bbA:scale(sw, sh)
        if scaled then bbA:free(); bbA = scaled end
    end

    local bbB = loadImageToBlitbuffer(pathB)
    if bbB then
        if bbB:getWidth() ~= sw or bbB:getHeight() ~= sh then
            local scaled = bbB:scale(sw, sh)
            if scaled then bbB:free(); bbB = scaled end
        end
    else
        -- If B failed, just reuse A
        bbB = bbA
    end

    -- Pick and run a random style
    local style  = STYLES[math.random(#STYLES)]
    logger.dbg("Kosmolitifier: style = " .. style.name)

    local ok, canvas = pcall(style.fn, bbA, bbB)

    if not ok or not canvas then
        logger.warn("Kosmolitifier: style failed (" .. style.name .. "): " .. tostring(canvas))
        -- Fallback: just show image A
        canvas = newCanvas()
        canvas:blitFrom(bbA, 0, 0, 0, 0, sw, sh)
    end

    local widget = OverlapGroup:new{
        dimen = Screen:getSize(),
        bbToWidget(canvas),
    }

    -- Note: do NOT free bbA/bbB/canvas here — KoReader will use them
    -- during rendering. They'll be GC'd after the screensaver closes.

    return widget
end

return Composer

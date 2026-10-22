
--[[
    composer.lua — Kosmolitifier image composition engine (Blitbuffer edition)

    Loads images into Blitbuffer canvases and manipulates pixels directly.
    All composition happens on a single sw×sh canvas which is then handed
    to KoReader as an ImageWidget.

    Each image is a "layer": a greyscale buffer (g) plus, for images with
    transparency, an alpha mask (m). Styles move the mask together with the
    pixels, and only at the end is the background (the book page, or black /
    white, per the Sleep screen background setting) filled in under whatever
    is still transparent, so the page itself is never glitched.

    Styles:
        1.  scanline_glitch   — bands from two images, some shifted sideways
        2.  pixel_dither      — checkerboard interleave of two images
        3.  data_corrupt      — a few bursts of horizontally shifted rows
        4.  inversion_zones   — random inverted rectangles over a base image
        5.  double_exposure   — two images blended by keeping darker/lighter pixel
        6.  column_drift      — wide column bands with random vertical offsets
        7.  slice_offset      — some vertical slices nudged up/down
        8.  threshold_mix     — pixels from A where A is dark, else from B
        9.  tile_shuffle      — grid of tiles, some swapped with tiles of A or B
        10. mirror_split      — one side of the image mirrored onto the other
        11. wave_shift        — rows displaced along a sine wave
        12. melt              — pixels dripping down from a wandering line
        13. pixelate_zones    — a few rectangles turned into big blocky pixels
        14. echo_stack        — B shrunk into a framed window, repeated diagonally
        15. scanner_smear     — a row frozen and dragged down, like a moved scan
        16. halftone_blocks   — newspaper-style black squares sized by darkness
        17. bayer_1bit        — pure black/white ordered dither
        18. window_cutouts    — framed holes showing the background through A
        19. stencil           — one image's silhouette filled with the other
        20. shadow_echo       — the silhouette repeated offset behind the image
        21. split_flip        — 2–4 panels from A/B, some flipped or mirrored
--]]

local ImageWidget   = require("ui/widget/imagewidget")
local OverlapGroup  = require("ui/widget/overlapgroup")
local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Screen        = Device.screen
local logger        = require("logger")
local ffi           = require("ffi")

local Composer = {}

local sw = Screen:getWidth()
local sh = Screen:getHeight()

local uint8pt = ffi.typeof("uint8_t*")

-- ──────────────────────────────────────────────────────────────────────────────
-- Buffers and layers
-- ──────────────────────────────────────────────────────────────────────────────

--- Return a new blank 8-bit greyscale canvas sized sw×sh.
local function newCanvas()
    return Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
end

--- Raw pointer to row y of an unrotated 8-bit buffer. Every buffer we build
--- is fresh (never rotated), so direct access is safe and much faster than
--- getPixel/setPixel.
local function row8(bb, y)
    return ffi.cast(uint8pt, bb.data) + bb.stride * y
end

--- A layer is { g = grey BB8, m = alpha mask BB8 or nil (fully opaque) }.
--- `transparent` marks layers whose image really had transparency (others
--- may still get an all-opaque mask so they can be mixed with those).
local function newLayer(with_mask)
    return { g = newCanvas(), m = with_mask and newCanvas() or nil }
end

local function freeLayer(l)
    l.g:free()
    if l.m then l.m:free() end
end

--- Copy a w×h rectangle between layers, grey and alpha together.
local function blitLayer(dst, src, dx, dy, sx, sy, w, h)
    dst.g:blitFrom(src.g, dx, dy, sx, sy, w, h)
    if dst.m then dst.m:blitFrom(src.m, dx, dy, sx, sy, w, h) end
end

--- Copy rows y..y+h-1 of src into dst shifted right by `shift`, wrapping.
local function blitShiftedRows(dst, src, y, h, shift)
    shift = shift % sw
    if shift == 0 then
        blitLayer(dst, src, 0, y, 0, y, sw, h)
    else
        blitLayer(dst, src, shift, y, 0, y, sw - shift, h)
        blitLayer(dst, src, 0, y, sw - shift, y, shift, h)
    end
end

--- Copy columns x..x+w-1 of src into dst shifted down by `shift`, wrapping.
local function blitShiftedCols(dst, src, x, w, shift)
    shift = shift % sh
    if shift == 0 then
        blitLayer(dst, src, x, 0, x, 0, w, sh)
    else
        blitLayer(dst, src, x, shift, x, 0, w, sh - shift)
        blitLayer(dst, src, x, 0, x, sh - shift, w, shift)
    end
end

--- Fill a rectangle of a layer with a grey level (0–255) and an alpha.
local function fillLayer(L, x, y, w, h, v, alpha)
    L.g:paintRect(x, y, w, h, Blitbuffer.Color8(v))
    if L.m then L.m:paintRect(x, y, w, h, Blitbuffer.Color8(alpha)) end
end

--- Nearest-neighbour resize of a full-screen 8-bit buffer to w×h.
local function scaleNearest(bb, w, h)
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    for y = 0, h - 1 do
        local src = row8(bb, math.floor(y * sh / h))
        local dst = row8(out, y)
        for x = 0, w - 1 do
            dst[x] = src[math.floor(x * sw / w)]
        end
    end
    return out
end

--- Clamp a value between lo and hi.
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Does pixel x of this row belong to the layer's shape? For images with
--- real transparency that's "mostly opaque"; otherwise "dark".
local function inShape(L, grow, mrow, x)
    if L.transparent then return mrow[x] >= 128 end
    return grow[x] < 128
end

--- Build a layer by taking each pixel (grey + alpha) from either A or B.
--- pick_a(a, b, x, y) gets both grey values and returns true to take A's.
local function pickPixels(A, B, pick_a)
    local C = newLayer(A.m ~= nil)
    for y = 0, sh - 1 do
        local ga, gb, gc = row8(A.g, y), row8(B.g, y), row8(C.g, y)
        local ma, mb, mc
        if C.m then ma, mb, mc = row8(A.m, y), row8(B.m, y), row8(C.m, y) end
        for x = 0, sw - 1 do
            if pick_a(ga[x], gb[x], x, y) then
                gc[x] = ga[x]
                if mc then mc[x] = ma[x] end
            else
                gc[x] = gb[x]
                if mc then mc[x] = mb[x] end
            end
        end
    end
    return C
end

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

--- Turn a loaded image into a screen-sized layer.
--- Images with transparency get a mask; their grey buffer holds the image
--- as it would look on white (so styles comparing brightness treat
--- transparent areas as light). MuPDF decodes PNGs with premultiplied alpha,
--- so that is simply premultiplied grey + (255 - alpha).
local function toLayer(bb)
    if bb:getWidth() ~= sw or bb:getHeight() ~= sh then
        local scaled = bb:scale(sw, sh)
        if scaled then bb:free(); bb = scaled end
    end

    local t = bb:getType()
    if t == Blitbuffer.TYPE_BB8 and bb:getRotation() == 0 then
        return { g = bb }
    end
    if t ~= Blitbuffer.TYPE_BB8A and t ~= Blitbuffer.TYPE_BBRGB32 then
        local g = newCanvas()
        g:blitFrom(bb, 0, 0, 0, 0, sw, sh)
        bb:free()
        return { g = g }
    end

    local L = newLayer(true)
    L.transparent = true
    for y = 0, sh - 1 do
        local src = bb:getPixelP(0, y)
        local gr, mr = row8(L.g, y), row8(L.m, y)
        for x = 0, sw - 1 do
            local px = src[x]
            local alpha = px.alpha
            local p
            if t == Blitbuffer.TYPE_BB8A then
                p = px.a
            else
                p = math.floor((px.r * 77 + px.g * 151 + px.b * 28) / 256)
            end
            local v = p + 255 - alpha
            gr[x] = v > 255 and 255 or v
            mr[x] = alpha
        end
    end
    bb:free()
    return L
end

--- Fill in the background under the transparent parts of a layer.
--- `under` is either a BB8 (the book page) or a grey level (0 = black).
--- The grey buffer holds the image as seen on white, so swapping white for
--- the real background is: v - (255 - under) * (255 - alpha) / 255.
local function compositeOver(L, under)
    local page = type(under) ~= "number" and under or nil
    for y = 0, sh - 1 do
        local gr, mr = row8(L.g, y), row8(L.m, y)
        local pr = page and row8(page, y)
        for x = 0, sw - 1 do
            local alpha = mr[x]
            if alpha < 255 then
                local u = pr and pr[x] or under
                local v = gr[x] - math.floor((255 - u) * (255 - alpha) / 255)
                gr[x] = v < 0 and 0 or v
            end
        end
    end
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
-- Composition styles (all take two layers and return a new layer)
-- ──────────────────────────────────────────────────────────────────────────────

--- 1. SCANLINE GLITCH
--- Copies thick horizontal bands, mostly from A with some from B.
--- Some bands are shifted left/right.
local function styleScanlineGlitch(A, B)
    local C = newLayer(A.m ~= nil)
    -- Strips thick enough that both images stay recognisable
    local strip_h = math.random(math.floor(sh * 0.03), math.floor(sh * 0.08))
    local y = 0

    while y < sh do
        local h = math.min(strip_h + math.random(-8, 16), sh - y)
        if h < 1 then h = 1 end

        -- Mostly A, with bands of B cutting through
        local src    = (math.random(100) <= 35) and B or A
        local shift  = 0
        if math.random(100) < 25 then
            shift = math.random(-math.floor(sw * 0.08), math.floor(sw * 0.08))
        end

        blitShiftedRows(C, src, y, h, shift)
        y = y + h
    end

    return C
end

--- 2. PIXEL DITHER MIX
--- Checkerboard: even pixels from A, odd from B.
local function stylePixelDither(A, B)
    return pickPixels(A, B, function(_, _, x, y) return (x + y) % 2 == 0 end)
end

--- 3. DATA CORRUPT
--- A few bursts of horizontal strips shifted by random amounts; some bursts
--- use the wrong image entirely (simulates read corruption).
local function styleDataCorrupt(A, B)
    local C = newLayer(A.m ~= nil)
    -- Start with a full blit of A
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    -- Corruption comes in a few bursts rather than across the whole image
    local n_bursts = math.random(2, 5)
    for _ = 1, n_bursts do
        local burst_h = math.random(math.floor(sh * 0.04), math.floor(sh * 0.15))
        local y       = math.random(0, sh - burst_h)
        local y_end   = y + burst_h
        local use_b   = math.random(100) < 30
        local src     = use_b and B or A

        while y < y_end do
            local h = math.min(math.random(6, 30), y_end - y)
            if math.random(100) < 60 then
                local shift = math.random(-math.floor(sw * 0.2), math.floor(sw * 0.2))
                blitShiftedRows(C, src, y, h, shift)
            end
            y = y + h
        end
    end

    return C
end

--- 4. INVERSION ZONES
--- Base image with random inverted rectangles punched through it.
--- Inverted zones are made opaque, so they cover the background too.
local function styleInversionZones(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    local n_rects = math.random(3, 9)
    for _ = 1, n_rects do
        local rw = math.random(math.floor(sw * 0.1), math.floor(sw * 0.55))
        local rh = math.random(math.floor(sh * 0.05), math.floor(sh * 0.35))
        local rx = math.random(0, sw - rw - 1)
        local ry = math.random(0, sh - rh - 1)

        -- Sometimes fill the zone from B instead of inverting
        if math.random(100) < 40 then
            blitLayer(C, B, rx, ry, rx, ry, rw, rh)
        else
            C.g:invertRect(rx, ry, rw, rh)
            if C.m then C.m:paintRect(rx, ry, rw, rh, Blitbuffer.COLOR_WHITE) end
        end
    end

    return C
end

--- 5. DOUBLE EXPOSURE
--- Per-pixel: take the darker pixel from A and B (classic multiply-ish blend).
--- Optionally flip to lighter for a bleached look.
local function styleDoubleExposure(A, B)
    if math.random(2) == 1 then
        return pickPixels(A, B, function(a, b) return a >= b end)
    end
    return pickPixels(A, B, function(a, b) return a <= b end)
end

--- 6. COLUMN DRIFT
--- Bands of columns of A are shifted up or down by a random amount,
--- wrapping around. Some bands are taken from B instead.
local function styleColumnDrift(A, B)
    local C = newLayer(A.m ~= nil)
    -- Wide bands so the drift reads as displaced chunks, not stripes
    local x = 0
    while x < sw do
        local gw    = math.min(math.random(math.floor(sw * 0.05), math.floor(sw * 0.2)), sw - x)
        local drift = 0
        if math.random(100) < 60 then
            drift = math.random(-math.floor(sh * 0.15), math.floor(sh * 0.15))
        end
        local src = (math.random(100) <= 20) and B or A

        blitShiftedCols(C, src, x, gw, drift)
        x = x + gw
    end

    return C
end

--- 7. SLICE OFFSET
--- Cut the image into vertical slices; shift some slices up/down randomly.
local function styleSliceOffset(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    local slice_w   = math.random(math.floor(sw * 0.04), math.floor(sw * 0.12))
    local x = 0
    while x < sw do
        local w = math.min(slice_w, sw - x)

        -- Only some slices move; the rest keep the base image intact
        if math.random(100) < 45 then
            local soff = math.random(-math.floor(sh * 0.12), math.floor(sh * 0.12))
            local src  = (math.random(4) == 1) and B or A
            blitShiftedCols(C, src, x, w, soff)
        end

        x = x + slice_w
    end

    return C
end

--- 8. THRESHOLD MIX
--- Where A is dark (< threshold) use A's pixel, else use B's.
--- Creates a "cutout" effect where one image shows through the dark areas of another.
local function styleThresholdMix(A, B)
    local threshold = math.random(80, 175)
    if math.random(2) == 1 then
        return pickPixels(A, B, function(a) return a > threshold end)
    end
    return pickPixels(A, B, function(a) return a < threshold end)
end

--- 9. TILE SHUFFLE
--- Grid of tiles; about half are swapped for a random tile of A or B.
local function styleTileShuffle(A, B)
    local C = newLayer(A.m ~= nil)
    -- Base of A also covers the leftover edge strips outside the grid
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    local cols, rows = math.random(3, 6), math.random(4, 8)
    local tw, th = math.floor(sw / cols), math.floor(sh / rows)
    for r = 0, rows - 1 do
        for col = 0, cols - 1 do
            if math.random(100) > 55 then
                local src = (math.random(100) <= 40) and B or A
                local sx  = math.random(0, cols - 1) * tw
                local sy  = math.random(0, rows - 1) * th
                blitLayer(C, src, col * tw, r * th, sx, sy, tw, th)
            end
        end
    end

    return C
end

--- 10. MIRROR SPLIT
--- One side of A mirrored onto the other around a random axis.
local function styleMirrorSplit(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    if math.random(2) == 1 then
        local axis = math.random(math.floor(sw * 0.35), math.floor(sw * 0.65))
        for i = 0, math.min(axis, sw - axis) - 1 do
            blitLayer(C, A, axis + i, 0, axis - 1 - i, 0, 1, sh)
        end
    else
        local axis = math.random(math.floor(sh * 0.35), math.floor(sh * 0.65))
        for i = 0, math.min(axis, sh - axis) - 1 do
            blitLayer(C, A, 0, axis + i, 0, axis - 1 - i, sw, 1)
        end
    end

    return C
end

--- 11. WAVE SHIFT
--- Rows displaced sideways along a sine wave — the whole image or one band.
local function styleWaveShift(A, B)
    local C = newLayer(A.m ~= nil)
    local amp    = math.random(math.floor(sw * 0.03), math.floor(sw * 0.12))
    local period = math.random(math.floor(sh * 0.15), math.floor(sh * 0.6))
    local phase  = math.random() * 2 * math.pi

    local y0, y1 = 0, sh
    if math.random(2) == 1 then
        blitLayer(C, A, 0, 0, 0, 0, sw, sh)
        y0 = math.random(0, math.floor(sh * 0.6))
        y1 = math.min(y0 + math.random(math.floor(sh * 0.15), math.floor(sh * 0.4)), sh)
    end

    for y = y0, y1 - 1 do
        local shift = math.floor(amp * math.sin(y * 2 * math.pi / period + phase))
        blitShiftedRows(C, A, y, 1, shift)
    end

    return C
end

--- 12. MELT
--- Pixels drip downward from a wandering line, like melting wax.
local function styleMelt(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    local start  = math.random(math.floor(sh * 0.2), math.floor(sh * 0.7))
    local length = math.random(math.floor(sh * 0.1), math.floor(sh * 0.3))
    for x = 0, sw - 1 do
        start  = clamp(start + math.random(-3, 3), 0, sh - 12)
        length = clamp(length + math.random(-6, 6), 10, sh - start - 1)
        local alpha = A.m and row8(A.m, start)[x] or 255
        fillLayer(C, x, start, 1, length, row8(A.g, start)[x], alpha)
    end

    return C
end

--- 13. PIXELATE ZONES
--- A few rectangles rendered as big blocky pixels.
local function stylePixelateZones(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    for _ = 1, math.random(2, 5) do
        local bs = math.random(12, 40)
        local zw = math.floor(math.random(math.floor(sw * 0.2), math.floor(sw * 0.6)) / bs) * bs
        local zh = math.floor(math.random(math.floor(sh * 0.1), math.floor(sh * 0.35)) / bs) * bs
        local zx = math.random(0, sw - zw)
        local zy = math.random(0, sh - zh)
        local src = (math.random(100) <= 30) and B or A

        for by = zy, zy + zh - 1, bs do
            local cy = by + math.floor(bs / 2)
            local gr = row8(src.g, cy)
            local mr = src.m and row8(src.m, cy)
            for bx = zx, zx + zw - 1, bs do
                local cx = bx + math.floor(bs / 2)
                fillLayer(C, bx, by, bs, bs, gr[cx], mr and mr[cx] or 255)
            end
        end
    end

    return C
end

--- 14. ECHO STACK
--- B shrunk into a framed window, repeated diagonally across A.
local function styleEchoStack(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    local scale = math.random(35, 60) / 100
    local w, h  = math.floor(sw * scale), math.floor(sh * scale)
    local S = { g = scaleNearest(B.g, w, h), m = B.m and scaleNearest(B.m, w, h) }

    local n  = math.random(3, 6)
    local x  = math.random(4, math.floor(sw * 0.15))
    local y  = math.random(4, math.floor(sh * 0.15))
    local dx = math.floor((sw - w - x - 10) / n)
    local dy = math.floor((sh - h - y - 10) / n)
    local border = (math.random(2) == 1) and 0 or 255

    for _ = 1, n do
        fillLayer(C, x - 4, y - 4, w + 8, h + 8, border, 255)
        blitLayer(C, S, x, y, 0, 0, w, h)
        x, y = x + dx, y + dy
    end

    freeLayer(S)
    return C
end

--- 15. SCANNER SMEAR
--- A row is frozen and dragged downward, like a page moved mid-scan.
local function styleScannerSmear(A, B)
    local C = newLayer(A.m ~= nil)
    blitLayer(C, A, 0, 0, 0, 0, sw, sh)

    for _ = 1, math.random(1, 3) do
        local y = math.random(0, math.floor(sh * 0.8))
        local h = math.random(math.floor(sh * 0.05), math.floor(sh * 0.25))
        local x = math.random(0, math.floor(sw * 0.5))
        local w = math.random(math.floor(sw * 0.4), sw - x)
        for r = y + 1, math.min(y + h, sh) - 1 do
            blitLayer(C, A, x, r, x, y, w, 1)
        end
    end

    return C
end

--- 16. HALFTONE BLOCKS
--- Newspaper-print look: one black square per block, sized by darkness.
--- Transparent blocks stay transparent.
local function styleHalftone(A, B)
    local C  = newLayer(A.m ~= nil)
    local bs = math.random(8, 18)

    for by = 0, sh - 1, bs do
        local h  = math.min(bs, sh - by)
        local cy = math.min(by + math.floor(bs / 2), sh - 1)
        local gr = row8(A.g, cy)
        local mr = A.m and row8(A.m, cy)
        for bx = 0, sw - 1, bs do
            local w  = math.min(bs, sw - bx)
            local cx = math.min(bx + math.floor(bs / 2), sw - 1)
            if mr and mr[cx] < 128 then
                fillLayer(C, bx, by, w, h, 255, 0)
            else
                fillLayer(C, bx, by, w, h, 255, 255)
                local side = math.floor(bs * math.sqrt((255 - gr[cx]) / 255) + 0.5)
                local o    = math.floor((bs - side) / 2)
                local fw, fh = math.min(side, w - o), math.min(side, h - o)
                if fw > 0 and fh > 0 then
                    C.g:paintRect(bx + o, by + o, fw, fh, Blitbuffer.COLOR_BLACK)
                end
            end
        end
    end

    return C
end

-- 4×4 Bayer thresholds, (index + 0.5) * 16
local BAYER4 = {}
for y, row in pairs({ [0] = { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }) do
    BAYER4[y] = {}
    for i, v in ipairs(row) do BAYER4[y][i - 1] = (v + 0.5) * 16 end
end

--- 17. BAYER 1-BIT
--- Pure black/white ordered dither (retro Mac / Game Boy look), with
--- occasional bands taken from B.
local function styleBayer1bit(A, B)
    local C = newLayer(A.m ~= nil)

    local bands = {}
    for i = 1, math.random(0, 3) do
        local h = math.random(math.floor(sh * 0.05), math.floor(sh * 0.2))
        local y = math.random(0, sh - h)
        bands[i] = { y, y + h }
    end

    for y = 0, sh - 1 do
        local src = A
        for _, band in ipairs(bands) do
            if y >= band[1] and y < band[2] then src = B end
        end
        local gs, gc = row8(src.g, y), row8(C.g, y)
        local ms, mc
        if C.m then ms, mc = row8(src.m, y), row8(C.m, y) end
        local t = BAYER4[y % 4]
        for x = 0, sw - 1 do
            gc[x] = (gs[x] < t[x % 4]) and 0 or 255
            if mc then mc[x] = (ms[x] >= 128) and 255 or 0 end
        end
    end

    return C
end

--- 18. WINDOW CUTOUTS
--- Framed holes punched through A, showing the background (the book page
--- when the Sleep screen background is "none").
local function styleWindowCutouts(A, B)
    local C = newLayer(true)
    C.g:blitFrom(A.g, 0, 0, 0, 0, sw, sh)
    if A.m then
        C.m:blitFrom(A.m, 0, 0, 0, 0, sw, sh)
    else
        C.m:fill(Blitbuffer.COLOR_WHITE)
    end

    for _ = 1, math.random(2, 4) do
        local w = math.random(math.floor(sw * 0.15), math.floor(sw * 0.45))
        local h = math.random(math.floor(sh * 0.08), math.floor(sh * 0.3))
        local x = math.random(8, sw - w - 8)
        local y = math.random(8, sh - h - 8)
        fillLayer(C, x - 6, y - 6, w + 12, h + 12, 0, 255)   -- frame
        fillLayer(C, x, y, w, h, 255, 0)                    -- hole
    end

    return C
end

--- 19. STENCIL
--- One image's silhouette filled with the other image's texture;
--- everything outside the silhouette is transparent.
local function styleStencil(A, B)
    if not A.transparent and B.transparent then A, B = B, A end
    local C = newLayer(true)

    for y = 0, sh - 1 do
        local ga, gb = row8(A.g, y), row8(B.g, y)
        local ma = A.m and row8(A.m, y)
        local gc, mc = row8(C.g, y), row8(C.m, y)
        for x = 0, sw - 1 do
            if inShape(A, ga, ma, x) then
                gc[x], mc[x] = gb[x], 255
            else
                gc[x], mc[x] = 255, 0
            end
        end
    end

    return C
end

--- 20. SHADOW ECHO
--- The image's silhouette repeated at an offset behind it, either solid
--- black or filled with B.
local function styleShadowEcho(A, B)
    if not A.transparent and B.transparent then A, B = B, A end
    local dx    = math.random(20, 70) * ((math.random(2) == 1) and 1 or -1)
    local dy    = math.random(20, 70) * ((math.random(2) == 1) and 1 or -1)
    local use_b = math.random(2) == 1
    local C = newLayer(true)

    for y = 0, sh - 1 do
        local ga, gb = row8(A.g, y), row8(B.g, y)
        local ma = A.m and row8(A.m, y)
        local gc, mc = row8(C.g, y), row8(C.m, y)
        -- The rows the shadow is cast from
        local sy = y - dy
        local gs, ms
        if sy >= 0 and sy < sh then
            gs, ms = row8(A.g, sy), A.m and row8(A.m, sy)
        end

        for x = 0, sw - 1 do
            local shadow = false
            if gs and not inShape(A, ga, ma, x) then
                local sx = x - dx
                shadow = sx >= 0 and sx < sw and inShape(A, gs, ms, sx)
            end
            if shadow then
                gc[x], mc[x] = use_b and gb[x] or 0, 255
            else
                gc[x], mc[x] = ga[x], ma and ma[x] or 255
            end
        end
    end

    return C
end

--- 21. SPLIT FLIP
--- Screen cut into 2–4 panels, each from A or B, some flipped or mirrored,
--- with thin black dividers.
local function styleSplitFlip(A, B)
    local C = newLayer(A.m ~= nil)
    local vertical = math.random(2) == 1
    local size = vertical and sw or sh

    local edges = { 0, size }
    for _ = 1, math.random(2, 4) - 1 do
        table.insert(edges, math.random(math.floor(size * 0.15), math.floor(size * 0.85)))
    end
    table.sort(edges)

    for k = 1, #edges - 1 do
        local a, b = edges[k], edges[k + 1]
        if b > a then
            local src = (math.random(100) <= 40) and B or A
            local x0, x1, y0, y1
            if vertical then
                x0, x1, y0, y1 = a, b, 0, sh
            else
                x0, x1, y0, y1 = 0, sw, a, b
            end

            local flip = math.random(3)
            if flip == 1 then
                blitLayer(C, src, x0, y0, x0, y0, x1 - x0, y1 - y0)
            elseif flip == 2 then
                -- Upside down within the panel
                for r = y0, y1 - 1 do
                    blitLayer(C, src, x0, r, x0, y1 - 1 - (r - y0), x1 - x0, 1)
                end
            else
                -- Mirrored within the panel
                for c = x0, x1 - 1 do
                    blitLayer(C, src, c, y0, x1 - 1 - (c - x0), y0, 1, y1 - y0)
                end
            end
        end
    end

    for k = 2, #edges - 1 do
        local e = math.max(edges[k] - 2, 0)
        if vertical then
            fillLayer(C, e, 0, 4, sh, 0, 255)
        else
            fillLayer(C, 0, e, sw, 4, 0, 255)
        end
    end

    return C
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
    { name = "slice_offset",     fn = styleSliceOffset     },
    { name = "threshold_mix",    fn = styleThresholdMix    },
    { name = "tile_shuffle",     fn = styleTileShuffle     },
    { name = "mirror_split",     fn = styleMirrorSplit     },
    { name = "wave_shift",       fn = styleWaveShift       },
    { name = "melt",             fn = styleMelt            },
    { name = "pixelate_zones",   fn = stylePixelateZones   },
    { name = "echo_stack",       fn = styleEchoStack       },
    { name = "scanner_smear",    fn = styleScannerSmear    },
    { name = "halftone_blocks",  fn = styleHalftone        },
    { name = "bayer_1bit",       fn = styleBayer1bit       },
    { name = "window_cutouts",   fn = styleWindowCutouts   },
    { name = "stencil",          fn = styleStencil         },
    { name = "shadow_echo",      fn = styleShadowEcho      },
    { name = "split_flip",       fn = styleSplitFlip       },
}

-- ──────────────────────────────────────────────────────────────────────────────
-- Public entry point
-- ──────────────────────────────────────────────────────────────────────────────

--- Fill in what shows through transparent areas, following KOReader's
--- Sleep screen background setting: "none" keeps the book page that is
--- currently on screen, "white" leaves white, anything else is black.
local function fillBackground(C)
    if not C.m then return end
    local background = G_reader_settings:readSetting("screensaver_img_background") or "black"
    if background == "white" then return end

    if background == "none" then
        -- The screen still shows the page at this point (the screensaver
        -- widget hasn't been painted yet)
        local page = newCanvas()
        page:blitFrom(Screen.bb, 0, 0, 0, 0, sw, sh)
        compositeOver(C, page)
        page:free()
    else
        compositeOver(C, 0)
    end
end

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
    local A = toLayer(bbA)

    local bbB = loadImageToBlitbuffer(pathB)
    -- If B failed, just reuse A
    local B = bbB and toLayer(bbB) or A

    -- Styles expect both layers to have a mask or neither
    for _, L in ipairs({ A, B }) do
        if (A.m or B.m) and not L.m then
            L.m = newCanvas()
            L.m:fill(Blitbuffer.COLOR_WHITE)
        end
    end

    -- Pick and run a random style
    local style  = STYLES[math.random(#STYLES)]
    logger.dbg("Kosmolitifier: style = " .. style.name)

    local ok, C = pcall(style.fn, A, B)

    if not ok or not C then
        logger.warn("Kosmolitifier: style failed (" .. style.name .. "): " .. tostring(C))
        -- Fallback: just show image A
        C = A
    end

    fillBackground(C)

    local widget = OverlapGroup:new{
        dimen = Screen:getSize(),
        bbToWidget(C.g),
    }

    -- The source layers and the mask are no longer needed; C.g is kept
    -- for KoReader to render and is GC'd after the screensaver closes.
    if C.m then C.m:free(); C.m = nil end
    if A ~= C then freeLayer(A) end
    if B ~= A and B ~= C then freeLayer(B) end

    return widget
end

return Composer

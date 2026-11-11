--[[
Ink as an xnotes notebook: the pen strokes of a notebook or drawing written as
a ".xnote" file, which the xnotes app for Android (github.com/shardulvs/xnotes-android)
opens with every stroke still a stroke: it can be selected, moved, recoloured,
erased, and copied into another of its notebooks.

The file is a zip holding "manifest.json": the pages, and on each page its
items. A stroke is { kind = "stroke", tool, config, samples = { {x, y, pressure}, ... } }
in the page's own pixels, with the page's size and the pixels per inch beside
it, so the writing keeps the size it was written at.

What goes in is what a pen drew: ink of every pen, and shapes as their
outlines. An eraser stroke is applied first (see ink/export/annots.lua), so the
file holds what the page shows. Text boxes, pictures, paint bucket fills and
smudges have no stroke to write and are counted instead (Annots.leftOut).

xnotes draws a stroke as wide as its pressure says, so a pen's own width along
the stroke (pressure, a fountain or calligraphy nib, the thin ends of a
ballpoint) is worked out here and written as that pressure. A textured pen
(pencil, charcoal) keeps its width and colour but not its grain, and xnotes
rounds off the thin ends of a stroke, as it does for its own pens.

This file is part of the companion plugin, not of Ink Away: it uses Ink Away's
own modules (ink/...) for what a pen draws, and nothing in Ink Away uses it.
Plain Lua, so the headless tests drive it.
]]

local Annots = require("ink/export/annots")
local Pens = require("ink/pens")
local Raster = require("ink/raster")
local Shapes = require("ink/shapes")
local Storage = require("ink/storage")
local Symmetry = require("ink/symmetry")
local Geom = require("ink/geom")
local Zip = require("xnotebridge/zip")

local Xnote = {}

Xnote.EXT = "xnote"

-- The version of xnotes whose files these match (its "writer"): a file that
-- says less has its strokes thinned again when it is opened.
Xnote.WRITER = 67

local floor, sqrt, abs, sin, cos, atan2, exp, log, max, min =
    math.floor, math.sqrt, math.abs, math.sin, math.cos, math.atan2, math.exp, math.log, math.max, math.min

-- The narrowest a stroke is written, as a share of its full width (xnotes'
-- "pressure_min_factor"): low enough for the thin end of a fountain pen.
local MIN_FACTOR = 0.05

-- xnotes bends the pressure through an S-curve before it sets the width
-- (logisticEase with k = 8 in its StrokeEngine). This is that curve backwards:
-- the pressure to write so the width comes out as the share `y` (0-1) of the
-- way from the narrowest to the full width.
local K = 8
local LO, HI = 1 / (1 + exp(K / 2)), 1 / (1 + exp(-K / 2))
local function unease(y)
    if y <= 0 then return 0 elseif y >= 1 then return 1 end
    local s = LO + y * (HI - LO)
    return 0.5 + log(s / (1 - s)) / K
end
Xnote.unease = unease

-- A number as JSON, with at most `places` decimals and no zeros after them.
local function num(v, places)
    if v ~= v or v == math.huge or v == -math.huge then return "0" end
    -- (most points sit on a whole pixel, and a long notebook has a great many)
    if v == floor(v) and v > -1e9 and v < 1e9 then return string.format("%d", v) end
    local s = string.format(places == 3 and "%.3f" or "%.2f", v)
    s = s:gsub("0+$", ""):gsub("%.$", "")
    if s == "-0" then s = "0" end
    return s
end

-- The stroke with points added so that none are further apart than `step`,
-- each new one with the pressure between its neighbours'. A finished stroke is
-- thinned to few points (a straight one to its two ends), and a width that
-- changes along it needs points to carry it.
local function densify(pts, pr, step)
    local n = floor(#pts / 2)
    local out, opr = { pts[1], pts[2] }, pr and { pr[1] } or nil
    for i = 2, n do
        local x0, y0, x1, y1 = pts[2 * i - 3], pts[2 * i - 2], pts[2 * i - 1], pts[2 * i]
        local parts = max(1, math.ceil(sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) / step))
        for k = 1, parts do
            local t = k / parts
            out[#out + 1] = x0 + (x1 - x0) * t
            out[#out + 1] = y0 + (y1 - y0) * t
            if opr then opr[#opr + 1] = (pr[i - 1] or 255) + ((pr[i] or 255) - (pr[i - 1] or 255)) * t end
        end
    end
    return out, opr
end

-- The way the stroke is going at point i of n: toward the next point from the
-- one before.
local function heading(pts, i, n)
    local a, b = max(1, i - 1), min(n, i + 1)
    return pts[2 * b - 1] - pts[2 * a - 1], pts[2 * b] - pts[2 * a]
end

-- Does this pen's width change along a stroke (so the stroke needs its points
-- close together)?
local function shaped(st)
    return st ~= nil and (st.taper ~= nil or st.nib45 == true or st.engine == "nib")
end

-- How wide the pen draws at each point, as a share of op.width: its pressure,
-- its nib against the way it is going, and its thin ends, as ink/pens.lua draws
-- them. Returns nil for a pen that keeps one width.
local function widths(op, st, pts, pr)
    if not st then return nil end
    local n = floor(#pts / 2)
    local pressed = pr ~= nil and st.pressure == true
    local nib = st.engine == "nib"
    -- (a plain solid pen, and a textured or see-through one without pressure, keep one width)
    if (st.solid and not st.engine) or not (pressed or nib or st.engine == "var") then return nil end
    local w = op.width or 1
    local d, total
    if st.taper and n > 1 then
        d = { 0 }
        for i = 2, n do
            d[i] = d[i - 1] + sqrt((pts[2 * i - 1] - pts[2 * i - 3]) ^ 2 + (pts[2 * i] - pts[2 * i - 2]) ^ 2) / w
        end
        total = d[n]
    end
    local angle = nib and Pens.nibAngle(op.nib) or nil
    local thin = st.thin or 0.16
    local out, varies = {}, false
    for i = 1, n do
        local p = pressed and pr[i] or nil
        local f
        if nib then
            -- a flat nib `f` long and `thin` wide, held at `angle`: across the
            -- way it goes it draws its length, along it its thickness
            local dx, dy = heading(pts, i, n)
            f = Pens.factor(st, p)
            if dx ~= 0 or dy ~= 0 then
                local a = atan2(dy, dx) - angle
                f = f * abs(sin(a)) + thin * abs(cos(a))
            end
        else
            local dx, dy = heading(pts, i, n)
            f = Pens.segRadii(st, 1, p, p, dx, dy)
        end
        if d then f = f * Pens.taper(st, d[i], total - d[i], total) end
        if f > 1 then f = 1 elseif f < MIN_FACTOR then f = MIN_FACTOR end
        if f < 0.995 then varies = true end
        out[i] = f
    end
    return varies and out or nil
end

-- A colour as xnotes writes it: [r, g, b, a].
local function rgba(c, a, dark)
    local r, g, b = 0, 0, 0
    if c then r, g, b = c[1] or 0, c[2] or 0, c[3] or 0 end
    -- black ink shows white on a dark paper, as on the screen
    if dark and r == 0 and g == 0 and b == 0 then r, g, b = 255, 255, 255 end
    return string.format("[%d,%d,%d,%d]", r, g, b, a)
end

-- One stroke as an xnotes item: `pts` (a flat x, y list) drawn `width` wide in
-- colour `color`, with the share of the width at each point in `f` (nil: one
-- width). `o`: tool ("pen" or "highlighter"), alpha (0-255), dark.
local function item(pts, width, f, color, o)
    local out = { '{"kind":"stroke","tool":"', o.tool, '","config":{"base_width":', num(width),
        ',"pressure_enabled":', f and "true" or "false",
        ',"pressure_min_factor":', f and num(MIN_FACTOR) or "1",
        ',"direction_strength":0,"rgba":' }
    if o.tool == "highlighter" then
        -- its strength is a setting of its own, and the colour stays solid
        out[#out + 1] = rgba(color, 255, o.dark)
        out[#out + 1] = ',"highlighter_alpha":' .. num(max(0.1, min(1, (o.alpha or 255) / 255)))
    else
        out[#out + 1] = rgba(color, o.alpha or 255, o.dark)
    end
    out[#out + 1] = '},"samples":['
    local n = floor(#pts / 2)
    for i = 1, n do
        local p = f and unease((f[i] - MIN_FACTOR) / (1 - MIN_FACTOR)) or 1
        out[#out + 1] = (i > 1 and ",[" or "[") .. num(pts[2 * i - 1]) .. "," .. num(pts[2 * i]) .. "," .. num(p, 3) .. "]"
    end
    out[#out + 1] = "]}"
    return table.concat(out)
end

-- The strokes one op becomes, added to `items` as xnotes items. `page` is
-- { w, h, dark }. An ink op is a stroke for each part the eraser left of it,
-- a shape a stroke for each line of its outline, and both once more for each
-- mirror image a symmetry mode drew. Returns how many were added.
local function opItems(op, page, items)
    local lines, st
    local o = { tool = "pen", alpha = op.alpha or 255, dark = page.dark }
    if op.kind == "ink" and op.pts and #op.pts >= 2 then
        st = op.style and Raster.STYLES[op.style] or nil
        lines = Geom.runs(op.pts, op.pr, op.breaks)
        if op.style == "highlighter" then o.tool = "highlighter" end
    elseif op.kind == "shape" and op.pts and #op.pts >= 4 then
        lines = {}
        for _i, l in ipairs(Shapes.outlines(op)) do lines[#lines + 1] = { pts = l } end
    else
        return 0
    end
    local width = max(0.5, op.width or 2)
    local added = 0
    for _i, f in ipairs(Symmetry.flips(op.sym)) do
        for _j, l in ipairs(lines) do
            if #l.pts >= 2 then
                local pts, pr = Symmetry.flipPoints(l.pts, f, page.w, page.h), l.pr
                if shaped(st) and #pts > 2 then pts, pr = densify(pts, pr, max(1.5, width * 0.75)) end
                items[#items + 1] = item(pts, width, widths(op, st, pts, pr), op.color, o)
                added = added + 1
            end
        end
    end
    return added
end

-- An ISO 8601 time in UTC, as xnotes writes when a note was made.
local function isoTime(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

-- The manifest of a notebook of `lists` (one list of ops for each page), every
-- page w x h pixels. `opts`: dpi (the pixels per inch the pages were written
-- at, 300 without it), paper ({ r, g, b }, white without it), dark (the paper
-- is dark: black ink is written white), time (when it was made, now without
-- it). Returns the JSON and { pages, strokes, left = Annots.leftOut's count }.
function Xnote.manifest(lists, w, h, opts)
    opts = opts or {}
    local page = { w = w, h = h, dark = opts.dark }
    local pages, strokes = {}, 0
    for i, ops in ipairs(lists) do
        local items = {}
        for _j, op in ipairs(Annots.settle(ops)) do
            strokes = strokes + opItems(op, page, items)
        end
        pages[i] = '{"width":' .. num(w) .. ',"height":' .. num(h) .. ',"pdf_page":null,"items":['
            .. table.concat(items, ",") .. "]}"
    end
    local out = { '{"format":"xnote","version":1,"writer":', tostring(Xnote.WRITER),
        ',"created":"', isoTime(opts.time or os.time()), '"',
        ',"dpi":', tostring(floor((opts.dpi or 300) + 0.5)),
        ',"has_pdf":false,"bookmarks":[],"pages":[', table.concat(pages, ","), "]" }
    local p = opts.paper
    if p then
        out[#out + 1] = string.format(',"style":{"page_color":[%d,%d,%d,255]}', p[1] or 255, p[2] or 255, p[3] or 255)
    end
    out[#out + 1] = "}"
    return table.concat(out), { pages = #lists, strokes = strokes, left = Annots.leftOut(lists) }
end

-- The whole file as a string (see Xnote.manifest for what goes in). Returns
-- it and the same counts.
function Xnote.build(lists, w, h, opts)
    local json, stats = Xnote.manifest(lists, w, h, opts)
    return Zip.build({ { name = "manifest.json", data = json } }, { time = opts and opts.time }), stats
end

-- Write the notebook to `path`. Returns the counts, or nil and what went wrong.
function Xnote.save(path, lists, w, h, opts)
    local data, stats = Xnote.build(lists, w, h, opts)
    local ok, err = Storage.writeAtomic(path, data)
    if not ok then return nil, err end
    return stats
end

return Xnote

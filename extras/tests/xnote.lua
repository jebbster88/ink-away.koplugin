-- A notebook's pen strokes written for the xnotes app (xnotebridge/xnote.lua in the companion plugin): what
-- becomes a stroke and what is counted instead, the eraser applied first, each pen's
-- width written as the pressure xnotes turns back into it, and the zip around it
-- (xnotebridge/zip.lua).
-- Run from Ink Away's folder:  luajit extras/tests/xnote.lua
package.path = "./?.lua;./tests/mock/?.lua;./extras/inkaway-xnotes.koplugin/?.lua;" .. package.path
local Json = require("ink/sync/json")
local Xnote = require("xnotebridge/xnote")
local Zip = require("xnotebridge/zip")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b, tol) return math.abs(a - b) <= (tol or 0.011) end

-- The width xnotes draws a sample at: its StrokeEngine.halfWidth, doubled, with
-- the S-curve it bends the pressure through (logisticEase, k = 8).
local function xnotesWidth(config, p)
    if not config.pressure_enabled then return config.base_width end
    local k = 8
    local lo, hi = 1 / (1 + math.exp(k / 2)), 1 / (1 + math.exp(-k / 2))
    local eased = (1 / (1 + math.exp(-k * (p - 0.5))) - lo) / (hi - lo)
    local m = config.pressure_min_factor
    return config.base_width * (m + (1 - m) * eased)
end

local function manifest(lists, opts)
    local json, stats = Xnote.manifest(lists, 1000, 1400, opts)
    local doc = Json.decode(json)
    return doc, stats, json
end

-- ---- the notebook around the strokes ------------------------------------------------
do
    local doc, stats = manifest({ {}, {} }, { dpi = 227, time = 0, paper = { 250, 240, 220 } })
    ok(doc and doc.format == "xnote" and doc.version == 1 and doc.writer == Xnote.WRITER, "a note xnotes takes as its own")
    ok(doc.dpi == 227 and doc.has_pdf == false and doc.created == "1970-01-01T00:00:00Z", "the reader's pixels per inch and the time, in UTC")
    ok(#doc.pages == 2 and doc.pages[1].width == 1000 and doc.pages[1].height == 1400 and #doc.pages[1].items == 0,
        "a page for each list, blank ones too, in the notebook's size")
    ok(doc.style.page_color[1] == 250 and doc.style.page_color[4] == 255, "the paper's colour")
    ok(stats.pages == 2 and stats.strokes == 0 and stats.left.total == 0, "nothing counted on blank pages")
    ok(manifest({ {} }).style == nil and manifest({ {} }).dpi == 300, "white paper says nothing, and 300 an inch without a size")
end

-- ---- a plain pen: one width, the points as drawn -------------------------------------
do
    local doc, stats = manifest({ {
        { kind = "ink", style = "solid", width = 4, alpha = 255, color = { 200, 10, 20 }, pts = { 100.126, 200, 300, 250.5 }, pr = { 50, 200 } },
        { kind = "ink", style = "solid", width = 6, alpha = 255, pts = { 50, 60 } },
        { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 }, hidden = true },
        { kind = "link", x = 0, y = 0, w = 10, h = 10 },
    } })
    local items = doc.pages[1].items
    ok(#items == 2 and stats.strokes == 2, "ink is strokes; hidden ink and links are not (" .. #items .. ")")
    local s = items[1]
    ok(s.kind == "stroke" and s.tool == "pen" and s.config.base_width == 4, "a pen stroke as wide as it was drawn")
    ok(s.config.pressure_enabled == false and s.config.pressure_min_factor == 1 and s.samples[1][3] == 1,
        "a fineliner keeps one width whatever the pressure")
    ok(s.config.rgba[1] == 200 and s.config.rgba[2] == 10 and s.config.rgba[4] == 255, "in its colour, opaque")
    ok(#s.samples == 2 and s.samples[1][1] == 100.13 and s.samples[2][2] == 250.5, "the points in the page's pixels, to a hundredth")
    ok(#items[2].samples == 1 and items[2].config.rgba[1] == 0, "a dot is one sample, black without a colour")
end

-- ---- pressure: the width the pen drew is the width xnotes draws ---------------------
do
    local Pens = require("ink/pens")
    local Raster = require("ink/raster")
    local op = { kind = "ink", style = "pencil", width = 10, alpha = 255, pts = { 100, 100, 200, 100, 300, 100 }, pr = { 0, 128, 255 } }
    local s = manifest({ { op } }).pages[1].items[1]
    ok(s.config.pressure_enabled == true and s.config.pressure_min_factor < 0.2, "a pressed pen is written with its pressure")
    for i, p in ipairs(op.pr) do
        local drawn = 10 * Pens.factor(Raster.STYLES.pencil, p)
        ok(near(xnotesWidth(s.config, s.samples[i][3]), drawn, 0.06), "pencil at pressure " .. p .. " is " .. drawn .. " wide in xnotes too")
    end
    ok(near(Xnote.unease(0), 0) and near(Xnote.unease(1), 1) and near(Xnote.unease(0.5), 0.5), "the curve backwards keeps its ends and middle")
end

-- ---- pens whose width changes along the stroke ---------------------------------------
do
    -- a ballpoint thins toward both ends: a long straight stroke gets points to carry that
    local s = manifest({ { { kind = "ink", style = "ballpoint", width = 6, alpha = 255, pts = { 100, 500, 700, 500 }, pr = { 255, 255 } } } }).pages[1].items[1]
    ok(#s.samples > 50, "a stroke with thin ends is given points along it (" .. #s.samples .. ")")
    local first, mid, last = xnotesWidth(s.config, s.samples[1][3]), xnotesWidth(s.config, s.samples[math.floor(#s.samples / 2)][3]),
        xnotesWidth(s.config, s.samples[#s.samples][3])
    ok(near(mid, 6, 0.06) and first < 3 and last < 3, "full in the middle, thin at the ends")
    ok(s.samples[1][1] == 100 and s.samples[#s.samples][1] == 700, "and still starts and ends where it did")
    -- a calligraphy nib at its usual slant: broad across it, thin along it
    local function nibWidth(pts)
        local c = manifest({ { { kind = "ink", style = "calligraphy", width = 20, alpha = 255, pts = pts, pr = { 255, 255 } } } }).pages[1].items[1]
        return xnotesWidth(c.config, c.samples[math.floor(#c.samples / 2)][3])
    end
    ok(nibWidth({ 100, 100, 300, 300 }) > 19 and nibWidth({ 100, 300, 300, 100 }) < 5, "a nib is broad across its slant and thin along it")
    -- a made brush nobody has here any more is still a stroke
    local u = manifest({ { { kind = "ink", style = "user:gone", width = 5, alpha = 255, pts = { 1, 1, 50, 50 } } } }).pages[1].items[1]
    ok(u.tool == "pen" and u.config.base_width == 5, "a brush that is not installed is written as a plain pen")
end

-- ---- see-through pens -------------------------------------------------------------------
do
    local items = manifest({ {
        { kind = "ink", style = "highlighter", width = 30, alpha = 128, color = { 255, 235, 59 }, pts = { 10, 10, 400, 10 } },
        { kind = "ink", style = "felttip", width = 12, alpha = 128, color = { 0, 0, 255 }, pts = { 10, 80, 400, 80 } },
    } }).pages[1].items
    ok(items[1].tool == "highlighter" and items[1].config.rgba[4] == 255 and near(items[1].config.highlighter_alpha, 0.5),
        "a highlighter is xnotes' highlighter, as strong")
    ok(items[2].tool == "pen" and items[2].config.rgba[4] == 128, "a marker is a pen you can see through")
end

-- ---- the eraser, shapes, symmetry, and what is left out ------------------------------
do
    local doc, stats = manifest({ {
        { kind = "ink", style = "solid", width = 6, alpha = 255, pts = { 100, 100, 900, 100 } },
        { kind = "erase", width = 40, pts = { 500, 50, 500, 150 } },
        { kind = "shape", shape = "rect", width = 4, alpha = 255, pts = { 100, 300, 300, 400 } },
        { kind = "ink", style = "solid", width = 4, alpha = 255, sym = "vert", pts = { 100, 600, 200, 650 } },
        { kind = "text", x = 10, y = 10, w = 100, h = 40, text = "hello" },
        { kind = "image", x = 10, y = 10, w = 100, h = 40 },
        { kind = "fill", runs = { 1, 1, 5 } },
    } })
    local items = doc.pages[1].items
    ok(#items == 5, "a cut line is two strokes, a rectangle one, a mirrored stroke two (" .. #items .. ")")
    ok(items[1].samples[#items[1].samples][1] < 500 and items[2].samples[1][1] > 500, "the eraser took the middle out of the line")
    ok(#items[3].samples == 5 and items[3].samples[1][1] == items[3].samples[5][1], "a rectangle is its outline, closed")
    ok(items[5].samples[1][1] == 1000 - 1 - 100 and items[5].samples[1][2] == 600, "the mirror image is written where it shows")
    ok(stats.strokes == 5 and stats.left.total == 3 and stats.left.text == 1, "text, pictures and fills are counted, not written")
end

-- ---- black ink on a dark paper shows white -------------------------------------------
do
    local s = manifest({ { { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 } } } },
        { dark = true, paper = { 20, 20, 20 } }).pages[1].items[1]
    ok(s.config.rgba[1] == 255 and s.config.rgba[3] == 255, "black ink is written white on a dark paper")
end

-- ---- the zip ---------------------------------------------------------------------------
-- The files in a zip, read from its list at the end: { [name] = { method, crc, packed, size, data } }.
local function unzip(z)
    local function u16(i) return z:byte(i) + z:byte(i + 1) * 256 end
    local function u32(i) return u16(i) + u16(i + 2) * 65536 end
    local eocd = #z - 21
    if z:sub(eocd, eocd + 3) ~= "PK\5\6" then return nil end
    local n, at = u16(eocd + 10), u32(eocd + 16) + 1
    local out = {}
    for _ = 1, n do
        if z:sub(at, at + 3) ~= "PK\1\2" then return nil end
        local name = z:sub(at + 46, at + 45 + u16(at + 28))
        local loc = u32(at + 42) + 1
        local e = { method = u16(at + 10), crc = u32(at + 16), packed = u32(at + 20), size = u32(at + 24) }
        if z:sub(loc, loc + 3) ~= "PK\3\4" or u32(loc + 14) ~= e.crc or u32(loc + 18) ~= e.packed or u32(loc + 22) ~= e.size then return nil end
        local start = loc + 30 + u16(loc + 26) + u16(loc + 28)
        e.data = z:sub(start, start + e.packed - 1)
        out[name] = e
        at = at + 46 + u16(at + 28) + u16(at + 30) + u16(at + 32)
    end
    return out
end
do
    ok(Zip.crc32("") == 0 and Zip.crc32("123456789") == 0xCBF43926 and Zip.crc32(("a"):rep(1000)) == 0x9A38DA03, "CRC-32, as every zip reader works it out")
    local z = Zip.build({ { name = "manifest.json", data = '{"a":1}' }, { name = "assets/é.txt", data = ("x"):rep(300) } }, { time = 0, store = true })
    local files = unzip(z)
    ok(files and files["manifest.json"] and files["manifest.json"].data == '{"a":1}' and files["manifest.json"].method == 0,
        "a stored file is there as it is, its sizes and checksum before it for a reader that streams")
    ok(files and files["assets/é.txt"] and files["assets/é.txt"].size == 300 and files["assets/é.txt"].crc == Zip.crc32(("x"):rep(300)),
        "and the next one after it")
end
-- with KOReader's zlib there, a file is deflated (here a stand-in on the system's zlib, if it has one)
do
    local ffi = require("ffi")
    local lib
    for _, name in ipairs({ "z", "libz.so.1" }) do
        local found, l = pcall(ffi.load, name)
        if found then lib = l; break end
    end
    if lib then
        ffi.cdef [[
            unsigned long compressBound(unsigned long sourceLen);
            int compress2(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen, int level);
            int inflateInit2_(void *strm, int windowBits, const char *version, int stream_size);
            int inflate(void *strm, int flush);
            int inflateEnd(void *strm);
            typedef struct { const uint8_t *next_in; unsigned int avail_in; unsigned long total_in;
                uint8_t *next_out; unsigned int avail_out; unsigned long total_out; const char *msg; void *state;
                void *zalloc; void *zfree; void *opaque; int data_type; unsigned long adler; unsigned long reserved; } xnote_z_stream;
            const char *zlibVersion(void);
        ]]
        package.loaded["ffi/zlib"] = { zlib_compress = function(data)
            local n = ffi.new("unsigned long[1]", lib.compressBound(#data))
            local buf = ffi.new("uint8_t[?]", n[0])
            assert(lib.compress2(buf, n, data, #data, 1) == 0)
            return ffi.string(buf, n[0])
        end }
        local lists = { {} }
        for i = 1, 60 do
            lists[1][i] = { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 10, i * 20, 400, i * 20, 800, i * 20 + 7 } }
        end
        local json = Xnote.manifest(lists, 1000, 1400, { time = 0 })
        local e = unzip((Xnote.build(lists, 1000, 1400, { time = 0 })))["manifest.json"]
        ok(e and e.method == 8 and e.packed < e.size / 2 and e.size == #json and e.crc == Zip.crc32(json), "the manifest is deflated, with the checksum of what it was")
        -- inflated as a zip reader does (no zlib wrapping), it is the manifest again
        local strm = ffi.new("xnote_z_stream")
        local out = ffi.new("uint8_t[?]", e.size + 16)
        strm.next_in, strm.avail_in, strm.next_out, strm.avail_out = e.data, #e.data, out, e.size + 16
        ok(lib.inflateInit2_(strm, -15, lib.zlibVersion(), ffi.sizeof("xnote_z_stream")) == 0 and lib.inflate(strm, 4) == 1
            and ffi.string(out, strm.total_out) == json, "and inflates back to it")
        lib.inflateEnd(strm)
        package.loaded["ffi/zlib"] = nil
    else
        print("xnote: no zlib on this machine, deflating not checked")
    end
end

-- ---- writing the file -------------------------------------------------------------------
do
    local path = os.tmpname()
    local stats = Xnote.save(path, { { { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 } } } }, 1000, 1400, { time = 0 })
    local f = io.open(path, "rb")
    local data = f and f:read("*a") or ""
    if f then f:close() end
    os.remove(path)
    local files = unzip(data)
    ok(stats and stats.strokes == 1 and files and files["manifest.json"] ~= nil, "the file is written whole, and says what went in")
    ok(Xnote.save("/no/such/folder/x.xnote", { {} }, 10, 10) == nil, "a file that cannot be written is an error, not a crash")
end

print(string.format("xnote: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

--[[
A small zip writer, for the exports that are a zip of their own (an xnotes
notebook, see ink/export/xnote.lua). It writes what a zip needs and no more:
each file's sizes and checksum before its data, so a reader that takes the
archive as a stream reads it too, then the list of files and the end record.

A file is deflated when KOReader's zlib is there (ffi/zlib), and stored as it
is otherwise, which every zip reader takes as well. Plain Lua apart from that,
so the headless tests drive it.
]]

local bit = require("bit")

local Zip = {}

local band, bxor, rshift, bnot = bit.band, bit.bxor, bit.rshift, bit.bnot
local char, byte = string.char, string.byte

-- The CRC-32 table, made on first use.
local crc_table
local function crcTable()
    if crc_table then return crc_table end
    local t = {}
    for i = 0, 255 do
        local c = i
        for _i = 1, 8 do
            if band(c, 1) == 1 then c = bxor(rshift(c, 1), 0xEDB88320) else c = rshift(c, 1) end
        end
        t[i] = c
    end
    crc_table = t
    return t
end

-- The CRC-32 of a string, as a zip keeps it (0 to 2^32 - 1).
function Zip.crc32(s)
    local t = crcTable()
    local c = bnot(0)
    local n = #s
    local i = 1
    -- (a few bytes at a time: string.byte with many results is the quick way to walk a string)
    while i + 7 <= n do
        local b1, b2, b3, b4, b5, b6, b7, b8 = byte(s, i, i + 7)
        c = bxor(rshift(c, 8), t[band(bxor(c, b1), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b2), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b3), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b4), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b5), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b6), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b7), 255)])
        c = bxor(rshift(c, 8), t[band(bxor(c, b8), 255)])
        i = i + 8
    end
    while i <= n do
        c = bxor(rshift(c, 8), t[band(bxor(c, byte(s, i)), 255)])
        i = i + 1
    end
    c = bnot(c)
    if c < 0 then c = c + 4294967296 end
    return c
end

-- A number as 2 or 4 bytes, lowest first.
local function u16(v) return char(v % 256, math.floor(v / 256) % 256) end
local function u32(v)
    return char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- `data` deflated as a zip holds it (no zlib header or checksum around it), or
-- nil when there is no zlib here or it would not make the data smaller.
local function deflate(data)
    local ok, zlib = pcall(require, "ffi/zlib")
    if not ok or type(zlib) ~= "table" or not zlib.zlib_compress then return nil end
    local done, z = pcall(zlib.zlib_compress, data)
    if not done or type(z) ~= "string" or #z < 7 then return nil end
    -- a zlib stream is two bytes, the deflated data, and four bytes of checksum;
    -- a preset dictionary (never used) would add four more at the start
    if band(byte(z, 1), 15) ~= 8 or band(byte(z, 2), 32) ~= 0 then return nil end
    local raw = z:sub(3, -5)
    if #raw >= #data then return nil end
    return raw
end

-- A time as a zip keeps it: the date and the time, two bytes each.
local function dosTime(t)
    local d = os.date("*t", t)
    if d.year < 1980 then return 0, 33 end   -- 1 January 1980, the earliest a zip can say
    return d.hour * 2048 + d.min * 32 + math.floor(d.sec / 2),
        (d.year - 1980) * 512 + d.month * 32 + d.day
end

-- The zip that holds `entries`, a list of { name = , data = } (strings), as a
-- string. `opts.time` is the time each file is given (now by default), and
-- `opts.store` keeps every file as it is, never deflated.
function Zip.build(entries, opts)
    opts = opts or {}
    local time, date = dosTime(opts.time or os.time())
    local out, dir = {}, {}
    local offset = 0
    for _i, e in ipairs(entries) do
        local data = e.data
        local packed = not opts.store and deflate(data) or nil
        local method = packed and 8 or 0
        local body = packed or data
        -- (the names are UTF-8, and flag 11 says so)
        local head = u16(20) .. u16(0x0800) .. u16(method) .. u16(time) .. u16(date)
            .. u32(Zip.crc32(data)) .. u32(#body) .. u32(#data) .. u16(#e.name) .. u16(0)
        out[#out + 1] = "PK\3\4" .. head .. e.name
        out[#out + 1] = body
        dir[#dir + 1] = "PK\1\2" .. u16(20) .. head .. u16(0) .. u16(0) .. u16(0) .. u32(0) .. u32(offset) .. e.name
        offset = offset + 30 + #e.name + #body
    end
    local listing = table.concat(dir)
    out[#out + 1] = listing
    out[#out + 1] = "PK\5\6" .. u16(0) .. u16(0) .. u16(#entries) .. u16(#entries)
        .. u32(#listing) .. u32(offset) .. u16(0)
    return table.concat(out)
end

return Zip

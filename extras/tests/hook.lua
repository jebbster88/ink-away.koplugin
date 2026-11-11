-- The companion plugin against Ink Away as it is, untouched: the export sheet gains
-- "Export for xnotes", which writes the chosen pages' pen strokes, and the Wi-Fi page
-- lists and sends the file (extras/inkaway-xnotes.koplugin/xnotebridge/hook.lua).
-- Run from Ink Away's folder:  luajit extras/tests/hook.lua
package.path = "./?.lua;./tests/mock/?.lua;./extras/inkaway-xnotes.koplugin/?.lua;" .. package.path

local Device = require("device")
local UIManager = require("ui/uimanager")
local TestEnv = require("testenv")
local Screen = Device.screen

_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- How many buttons labelled `text` widget tree `w` holds, and the first of them.
local function buttons(w, text)
    local n, first, seen = 0, nil, {}
    local function has(t, mark)
        if type(t) ~= "table" or mark[t] then return false end
        mark[t] = true
        if t.text == text then return true end
        for k, val in pairs(t) do
            if k ~= "show_parent" and k ~= "parent" and has(val, mark) then return true end
        end
        return false
    end
    local function walk(t)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        if type(t.callback) == "function" and has(t, {}) then
            n = n + 1
            first = first or t
            return
        end
        for k, val in pairs(t) do if k ~= "show_parent" and k ~= "parent" then walk(val) end end
    end
    walk(w)
    return n, first
end
local function textIn(w)
    local out, seen = {}, {}
    local function walk(t)
        if type(t) ~= "table" or seen[t] then return end
        seen[t] = true
        if type(t.text) == "string" then out[#out + 1] = t.text end
        for k, val in pairs(t) do if k ~= "show_parent" and k ~= "parent" then walk(val) end end
    end
    walk(w)
    return table.concat(out, "\n")
end
local function answer(text)
    local field = require("ui/widget/inputtext").last
    field.text = text
    field.enter_callback()
end
local function pos(x, y) return { pos = { x = x, y = y } } end
local function stroke(view, x, y)
    local v = view.view
    view:onIaTouch(nil, pos(x, v.area_y + y))
    view:onIaPan(nil, pos(x + 30, v.area_y + y + 20))
    view:onIaPanRelease(nil, pos(x + 30, v.area_y + y + 20))
    UIManager.fireScheduled()
end
local function read(path)
    local f = io.open(path, "rb")
    local data = f and f:read("*a") or nil
    if f then f:close() end
    return data
end

local Hook = require("xnotebridge/hook")

-- ---- an Ink Away that is not as expected is left alone ---------------------------------
ok(Hook.apply("ink/view/export", {}) == false and Hook.apply("ink/view/share", { sendExport = 1 }) == false,
    "a part without the methods is left as it is")
ok(Hook.apply("ink/view/other", {}) == false, "and so is any other part")

-- ---- the companion starts first, Ink Away is opened later ------------------------------
local LIB = TestEnv.libraryDir() .. "/xnotestest"
os.execute("mkdir -p '" .. LIB .. "/out'")
G_reader_settings.data.inkaway_library_dir = LIB
G_reader_settings.data.inkaway_export_dir = LIB .. "/out"
Screen:setRotationMode(0); Screen:setSize(1072, 1448)
UIManager.reset()

Hook.install()
Hook.install()   -- (KOReader starts a plugin again whenever it moves between the library and a book)
local InkAwayView = require("ink/view")
Hook.install()   -- and once more with Ink Away's view loaded

local view = InkAwayView:new{}
UIManager:show(view)
view:newNotebook("lines", LIB)
stroke(view, 100, 100)
view:nbAddPage()
view:nbAddPage(); stroke(view, 300, 300)

view:openExport()
ok(view._save_dialog ~= nil, "Ink Away's export sheet opens as before")
local n = buttons(view._save_dialog, Hook.LABEL)
ok(n == 1, "with one button for xnotes, however often the companion was started (" .. n .. ")")
ok(buttons(view._save_dialog, "Send to phone or computer (Wi-Fi)\u{2026}") == 1, "and Ink Away's own buttons still there")
ok(rawget(view, "showSheet") == nil, "the view is left with its own way of showing sheets")

-- the sheet's page choice is the export's: the pages with ink
view:exportOptions().scope = "ink"
view:openExport()
local button = select(2, buttons(view._save_dialog, Hook.LABEL))
button.callback()
ok(view._save_dialog == nil and require("ui/widget/inputtext").last.text == view:docName(), "the button asks for a name, starting from the notebook's")
answer("Notes")
local data = read(LIB .. "/out/Notes.xnote") or ""
ok(data:sub(1, 4) == "PK\3\4" and data:find("manifest.json", 1, true), "and writes a zip with its manifest into the export folder")
ok(select(2, data:gsub('"pdf_page"', "")) == 2 and select(2, data:gsub('"kind":"stroke"', "")) == 2, "holding the two pages with ink, a stroke each")
local msg = (UIManager.shown and UIManager.shown.text) or textIn(view._message)
ok(msg:find("2 page", 1, true) and msg:find("Notes.xnote", 1, true), "then says what was saved")
view:closeSheet("_message")

-- ---- the Wi-Fi page ----------------------------------------------------------------------
do
    view.sendExportDirs = function() return { LIB .. "/out" } end   -- (the test's folder is not Ink Away's own)
    local f = io.open(LIB .. "/out/Old.pdf", "wb"); f:write("%PDF"); f:close()
    local names = {}
    for _, e in ipairs(view:sendExportsList("/t/")) do names[e.name] = e.href end
    ok(names["Notes.xnote"] == "/t/export?n=Notes.xnote" and names["Old.pdf"] ~= nil, "the exports listed now include the xnotes notebook, beside the others")
    local sent, code
    local reply = { send = function(c) code = c end, file = function(path) sent = path end }
    view:sendExport("Notes.xnote", reply)
    ok(sent == LIB .. "/out/Notes.xnote", "and it is sent when asked for")
    sent = nil
    view:sendExport("Old.pdf", reply)
    ok(sent == LIB .. "/out/Old.pdf", "a PDF goes out Ink Away's own way")
    sent, code = nil, nil
    view:sendExport("../Notes.xnote", reply)
    view:sendExport("Missing.xnote", reply)
    ok(sent == nil and code == 404, "a name outside the folder, or of no file, is not found")
    view.sendExportDirs = nil
end

-- ---- a drawing is one page -----------------------------------------------------------------
do
    local draw = InkAwayView:new{}
    UIManager:show(draw)
    stroke(draw, 200, 200)
    Hook.write(draw, LIB .. "/out/Drawing.xnote")
    local d = read(LIB .. "/out/Drawing.xnote") or ""
    ok(select(2, d:gsub('"pdf_page"', "")) == 1 and select(2, d:gsub('"kind":"stroke"', "")) == 1, "a drawing is written as one page")
end

Hook.uninstall()
TestEnv.cleanup()
print(string.format("xnotes hook: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)

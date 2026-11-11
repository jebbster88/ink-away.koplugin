--[[
How the companion reaches into Ink Away without changing any of its files.

Ink Away's view is built from parts (ink/view/*.lua), each a table of methods
that ink/view.lua copies into the view when Ink Away is first opened. This
module waits for two of those parts to be loaded and wraps a few of their
methods before they are copied:

  ink/view/export   openExport: the export sheet gets one more button,
                    "Export for xnotes"
  ink/view/share    sendExportsList, sendExport: the Wi-Fi page also lists and
                    sends the .xnote files in the export folder

Everything added runs inside pcall, and every wrapped method falls back to
Ink Away's own, so if a later Ink Away is built differently the button is
simply not there and Ink Away works as it did. The methods of Ink Away this
relies on are listed in the README beside this plugin.

Plain Lua apart from the widgets it asks KOReader for, so the headless tests
drive it.
]]

local Hook = {}

local LABEL = "Export for xnotes\u{2026}"
Hook.LABEL = LABEL

-- The wrappers made here, so a method is never wrapped twice: a part wrapped
-- before Ink Away opened hands its wrapper on to the view, which is looked at
-- again each time KOReader starts the plugin.
local ours = setmetatable({}, { __mode = "k" })

local function warn(...)
    local ok, logger = pcall(require, "logger")
    if ok and logger and logger.warn then logger.warn("Ink Away xnotes export:", ...) end
end

------------------------------------------------------------------------------
-- The export
------------------------------------------------------------------------------

-- The reader's own pixels per inch, so the writing keeps its size in xnotes.
local function screenDPI()
    local ok, Device = pcall(require, "device")
    if not ok or not Device then return 300 end
    local dpi = Device.getDeviceScreenDPI and Device:getDeviceScreenDPI()
    if not dpi and Device.screen and Device.screen.getDPI then dpi = Device.screen:getDPI() end
    return dpi or 300
end

-- Write the pen strokes of the pages the export sheet has chosen (a drawing is
-- one page) to `path`, and say what went in.
function Hook.write(view, path)
    local Xnote = require("xnotebridge/xnote")
    local nb = view.notebook
    local lists = {}
    if nb then
        for _i, i in ipairs(view:exportPageList()) do lists[#lists + 1] = nb.pages[i].ops or {} end
    else
        lists[1] = view:drawnOps()
    end
    local paper = view.paperRGB and view:paperRGB() or nil
    local dark
    if paper then
        local ok, Paint = pcall(require, "ink/paint")
        dark = ok and Paint.darkPaper and Paint.darkPaper(paper) or nil
    end
    local stats, err = Xnote.save(path, lists, nb and nb.w or view.canvas.w, nb and nb.h or view.canvas.h,
        { dpi = screenDPI(), paper = paper, dark = dark })
    if not stats then
        warn("export failed:", err)
        view:tell("Could not export.\n" .. tostring(err))
        return
    end
    local text = string.format("Saved %d page(s) with %d pen stroke(s) for xnotes:\n%s", stats.pages, stats.strokes, path)
    if stats.left.total > 0 then
        text = text .. "\n\n" .. string.format("%d item(s) that are not pen strokes were left out.", stats.left.total)
    end
    view:tell(text)
end

-- Ask for the file name, in the export folder, then write it.
function Hook.prompt(view)
    local Xnote = require("xnotebridge/xnote")
    if view.notebook and #view:exportPageList() == 0 then
        view:showNotice("None of the chosen pages has anything on it.", 3)
        return
    end
    view:askExportPath{
        title = "Export for xnotes",
        name = view:exportName(), default = view:exportName(),
        dir = view:exportDir(), ext = Xnote.EXT,
        on_path = function(path) Hook.write(view, path) end,
    }
end

-- The export sheet's builder with the xnotes button added at its end.
local function withButton(view, build)
    return function(menu)
        local content = build(menu)
        local ok, err = pcall(function()
            local VerticalSpan = require("ui/widget/verticalspan")
            local Screen = require("device").screen
            local width = view:sheetWidth()
            table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(10) })
            table.insert(content, view:actionButton(LABEL, width, function()
                view:closeSheet("_save_dialog")
                local done, perr = pcall(Hook.prompt, view)
                if not done then
                    warn("could not ask for a name:", perr)
                    pcall(view.tell, view, "Could not export for xnotes.\n" .. tostring(perr))
                end
            end))
        end)
        if not ok then warn("could not add the button:", err) end
        return content
    end
end

-- Wrap the export part's openExport: while it runs, the sheet it shows (a
-- notebook's or a drawing's, not a book's) is given the button.
local function wrapExport(part)
    local open = part.openExport
    if type(open) ~= "function" then return false end
    if ours[open] then return true end
    local function wrapped(self, ...)
        local show = self.showSheet
        if type(show) ~= "function" or self.book then return open(self, ...) end
        self.showSheet = function(v, field, build, ...)
            if field == "_save_dialog" and type(build) == "function" then build = withButton(v, build) end
            return show(v, field, build, ...)
        end
        local results = { pcall(open, self, ...) }
        self.showSheet = nil   -- (the view's own again)
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2)
    end
    ours[wrapped] = true
    part.openExport = wrapped
    return true
end

------------------------------------------------------------------------------
-- The Wi-Fi page
------------------------------------------------------------------------------

local function isXnote(name)
    local ext = tostring(name):match("%.(%w+)$")
    return ext ~= nil and ext:lower() == "xnote"
end

-- Is there a plain file (not a link to one elsewhere) at `path`?
local function plainFile(path)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs and lfs.symlinkattributes then return lfs.symlinkattributes(path, "mode") == "file" end
    local f = io.open(path, "rb")
    if f then f:close() end
    return f ~= nil
end

-- Wrap the share part: the list of exports gains the .xnote files, newest
-- first, and one asked for by name is sent.
local function wrapShare(part)
    local list, send = part.sendExportsList, part.sendExport
    if type(list) ~= "function" or type(send) ~= "function" then return false end
    if ours[list] and ours[send] then return true end
    local function listAll(self, base, ...)
        local out = list(self, base, ...)
        pcall(function()
            local Storage = require("ink/storage")
            local Http = require("ink/share/http")
            local files = {}
            for _i, dir in ipairs(self:sendExportDirs()) do
                for _j, e in ipairs(Storage.list(dir)) do
                    if e.mode == "file" and isXnote(e.name) and e.name:sub(1, 1) ~= "." then files[#files + 1] = e end
                end
            end
            table.sort(files, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
            for i = math.min(#files, 20), 1, -1 do
                local e = files[i]
                local size = Storage.size(e.path)
                table.insert(out, 1, { name = e.name, href = base .. "export?n=" .. Http.urlEncode(e.name),
                    size = size and Http.size(size) or nil })
            end
        end)
        return out
    end
    local function sendOne(self, name, reply, ...)
        if type(name) == "string" and isXnote(name) and not name:find("[/\\%z]") and name:sub(1, 1) ~= "." then
            local ok, sent = pcall(function()
                local Storage = require("ink/storage")
                for _i, dir in ipairs(self:sendExportDirs()) do
                    local path = Storage.join(dir, name)
                    if plainFile(path) then
                        reply.file(path, "application/octet-stream", name, function() self:sendCounted() end)
                        return true
                    end
                end
                return false
            end)
            if ok and sent then return end
        end
        return send(self, name, reply, ...)
    end
    ours[listAll], ours[sendOne] = true, true
    part.sendExportsList, part.sendExport = listAll, sendOne
    return true
end

------------------------------------------------------------------------------
-- Waiting for Ink Away's parts
------------------------------------------------------------------------------

local WRAPS = { ["ink/view/export"] = wrapExport, ["ink/view/share"] = wrapShare }

-- Wrap the methods of `t` (a part, or the view itself once the parts are in
-- it) for part `name`. Returns whether they are wrapped now.
function Hook.apply(name, t)
    local wrap = WRAPS[name]
    if not wrap or type(t) ~= "table" then return false end
    local ok, did = pcall(wrap, t)
    if ok and did then return true end
    warn("Ink Away's " .. name .. " is not as expected; nothing added there", (not ok) and did or nil)
    return false
end

-- A module searcher put ahead of Lua's own: for the two parts it loads the
-- module the usual way, wraps it, and hands it on.
local function searcher(name)
    if not WRAPS[name] then return nil end
    return function(modname)
        local tried = {}
        for _i, find in ipairs(package.loaders) do
            if find ~= searcher then
                local loader = find(modname)
                if type(loader) == "function" then
                    local mod = loader(modname)
                    Hook.apply(modname, mod)
                    return mod
                elseif type(loader) == "string" then
                    tried[#tried + 1] = loader
                end
            end
        end
        error("module '" .. modname .. "' not found:" .. table.concat(tried), 0)
    end
end

-- Start waiting (once). If Ink Away has been opened already, its view holds
-- the methods by now and they are wrapped there.
function Hook.install()
    local found = false
    for _i, find in ipairs(package.loaders) do if find == searcher then found = true end end
    if not found then table.insert(package.loaders, 1, searcher) end
    for name in pairs(WRAPS) do
        if package.loaded[name] then Hook.apply(name, package.loaded[name]) end
        if package.loaded["ink/view"] then Hook.apply(name, package.loaded["ink/view"]) end
    end
end

-- Stop waiting (what is wrapped stays wrapped); the tests use it.
function Hook.uninstall()
    for i = #package.loaders, 1, -1 do
        if package.loaders[i] == searcher then table.remove(package.loaders, i) end
    end
end

return Hook

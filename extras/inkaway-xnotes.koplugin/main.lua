--[[
Ink Away: export for xnotes. A companion to the Ink Away plugin, in a folder of
its own so that updating Ink Away never removes it. All it does at start is ask
to be told when Ink Away loads its export code (see xnotebridge/hook.lua).
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local InkAwayXnotes = WidgetContainer:extend{
    name = "inkawayxnotes",
    is_doc_only = false,
}

function InkAwayXnotes:init()
    local ok, err = pcall(function() require("xnotebridge/hook").install() end)
    if not ok then logger.warn("Ink Away xnotes export: could not start:", err) end
end

return InkAwayXnotes

# Ink Away: export for xnotes

A companion plugin for [Ink Away](https://github.com/EmirErtorer/ink-away.koplugin).
It adds **Export for xnotes…** to Ink Away's export sheet: the pen strokes of a
notebook, some of its pages, or a drawing, saved as a `.xnote` file for the
[xnotes](https://github.com/shardulvs/xnotes-android) app on Android. Each stroke
is still a stroke there, so it can be moved, erased, recoloured and copied into
another xnotes notebook, at the size it was written.

It lives in a folder of its own and changes none of Ink Away's files, so Ink
Away can be updated, by its own updater or by hand, without losing it.

## Install

Copy the `inkaway-xnotes.koplugin` folder into KOReader's `plugins` folder, beside
`ink-away.koplugin` (on a Kobo: `.adds/koreader/plugins/`), and restart KOReader.

## Use

1. In Ink Away: File, Export. Choose the pages as for a PDF (this page, all,
   with ink, a range), then tap **Export for xnotes…** at the bottom of the sheet.
2. The file goes to "ink away/exports" unless you pick another folder.
3. Get it to the tablet: Ink Away's "Send to phone or computer (Wi-Fi)" page
   lists it with the other exports, or copy it over USB.
4. Open it in xnotes, select what you want, and copy it into your own notebook.

## What goes in

| | |
|---|---|
| Pens | Every pen, in its colour, with its width along the stroke: pressure, a fountain or calligraphy nib, a ballpoint's thin ends. |
| Highlighter | xnotes' highlighter, as strong. Marker and watercolour are pens you can see through. |
| Eraser | Applied first: what was erased is not in the file. |
| Shapes | Their outlines, as strokes. A filled shape loses its fill. |
| Left out | Text boxes, pictures, paint bucket fills and smudges. The export says how many. |

A textured pen (pencil, charcoal) keeps its width and colour but not its grain,
and xnotes rounds off the thin ends of a stroke as it does for its own pens. A
notebook made from a PDF exports its ink on blank pages; the PDF is not included.

## If Ink Away changes

The plugin wraps a few of Ink Away's methods when Ink Away loads them, and
steps aside if they are not as it expects: the button is then missing, and Ink
Away works as before. `crash.log` says "Ink Away xnotes export: …" when that
happens. What it relies on:

- the view parts `ink/view/export` (`openExport`) and `ink/view/share`
  (`sendExportsList`, `sendExport`), and the view's `showSheet`, `closeSheet`,
  `sheetWidth`, `actionButton`, `askExportPath`, `exportPageList`, `exportName`,
  `exportDir`, `drawnOps`, `paperRGB`, `tell`, `showNotice`, `sendExportDirs`
  and `sendCounted`;
- the modules `ink/export/annots`, `ink/pens`, `ink/raster`, `ink/shapes`,
  `ink/symmetry`, `ink/geom`, `ink/storage`, `ink/paint` and `ink/share/http`.

Written against Ink Away 4.4.3.

## Tests

From Ink Away's folder, with LuaJIT:

    luajit extras/tests/xnote.lua
    luajit extras/tests/hook.lua

The second runs the plugin against Ink Away's real view in its test stand-in
for KOReader, so it fails when a change in Ink Away would break the button.

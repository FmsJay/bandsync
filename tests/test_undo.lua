-- lib/undo.lua's pure half: which undo Ctrl+Z means
package.path = "lib/?.lua;" .. package.path
local undo = require("undo")
assert(undo.native("Edit item") and undo.native("Move items"), "your own edit: REAPER's undo")
assert(not undo.native("BandSync: changes from the band"), "a bandmate's change on top: yours instead")
assert(not undo.native("BandSync: go back"), "or BandSync's own")
assert(not undo.native(nil) and not undo.native(""), "nothing on REAPER's list: yours, if there is one")
-- the shortcut lines
local KB = table.concat({
  'SCR 4 0 RSaaa "Custom: BandSync - Undo.lua" "J:\\x\\BandSync - Undo.lua"',
  'SCR 4 32060 RS7d3c_aaa "Custom: BandSync - Undo.lua" "J:\\x\\BandSync - Undo.lua"',
  'SCR 4 0 RSbbb "Custom: BandSync - Redo.lua" "J:\\x\\BandSync - Redo.lua"',
  "KEY 13 80 101 118\t\t # someone's own",
}, "\n") .. "\n"
local W = { { what = "Undo", section = 0, mod = 9 }, { what = "Undo", section = 32060, mod = 9 }, { what = "Redo", section = 0, mod = 13 }, { what = "Redo", section = 32060, mod = 13 } }
local got = undo.kb_lines(KB, W)
assert(#got == 3, "three lines, as Redo isn't registered for the MIDI editor here: " .. #got)
assert(got[1] == "KEY 9 90 _RSaaa 0" and got[2] == "KEY 9 90 _RS7d3c_aaa 32060" and got[3] == "KEY 13 90 _RSbbb 0", table.concat(got, "; "))
assert(#undo.kb_lines(KB .. "KEY 9 90 40029 0\n", { W[1] }) == 0, "Ctrl+Z already mapped in that section: left alone")
assert(#undo.kb_lines(KB .. "KEY 9 90 40029 0\n", { W[2] }) == 1, "another section's doesn't count")
assert(#undo.kb_lines(KB .. "KEY 9 90 40029 32060\t\t # note\n", { W[2] }) == 0, "nor is a section mistaken at a comment")
print("ok")

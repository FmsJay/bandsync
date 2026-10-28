-- sync.chunk_block / chunk_set_block are pure: run with lupa or any Lua 5.4 from the repo root
package.loaded.band = {}
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")

local chunk = table.concat({
  "<TRACK", "  NAME Keys", "  <FXCHAIN", "    SHOW 0", "    <VST \"VSTi: ReaSynth (Cockos)\" reasynth.dll 0", "      ZXZhdg==", "    >",
  "    <JS chmaha-inst/DrNine.jsfx \"\"", "      0 0", "    >", "  >", "  <FXCHAIN_REC", "    SHOW 0", "  >",
  "  <ITEM", "    POSITION 0", "  >", ">" }, "\n")
local block = sync.chunk_block(chunk, "FXCHAIN")
assert(block and block:match("^  <FXCHAIN\n") and block:match("DrNine") and block:match("\n  >$"), tostring(block))
assert(not block:find("FXCHAIN_REC", 1, true), "the record chain is its own block")
assert(sync.chunk_block(chunk, "FXCHAIN_REC"):match("^  <FXCHAIN_REC"), "record chain found by its exact tag")

local without = sync.chunk_set_block(chunk, "FXCHAIN", nil)
assert(not sync.chunk_block(without, "FXCHAIN") and without:find("<FXCHAIN_REC", 1, true) and without:find("<ITEM", 1, true), "removed only that block")
local back = sync.chunk_set_block(without, "FXCHAIN", block)
assert(sync.chunk_block(back, "FXCHAIN") == block and back:match("\n>$"), "inserted before the track's end")
local replaced = sync.chunk_set_block(chunk, "FXCHAIN", "  <FXCHAIN\n    SHOW 0\n  >")
assert(sync.chunk_block(replaced, "FXCHAIN") == "  <FXCHAIN\n    SHOW 0\n  >" and replaced:find("<ITEM", 1, true), "replaced in place")
print("ok")

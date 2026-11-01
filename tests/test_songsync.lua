-- songsync.block / merge are pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local songsync = require("songsync")
local block = songsync.block({ ["Mirror Test"] = true, Lantern = true })
local text = table.concat(block, "\n")
-- the band-wide folders, then the opened songs (sorted), then every song's listing, then the rest of every song
local function at(s) for i, l in ipairs(block) do if l == s then return i end end end
assert(at("!/_*") and at("!/plugins") and at("!/drummaps"), "band-wide folders always come")
assert(at("!/Lantern") < at("!/Mirror Test"), "opened songs, in name order")
assert(at("!/Mirror Test") < at("!/*/session.json") and at("!/*/rooms/*/summary") < at("/*/*"), "every ! line before the one ignore line")
assert(block[#block - 1] == "/*/*", "the rest of every other song is the last rule")
-- merging keeps the person's own lines, and replacing the block never stacks it
local own = "// my own\n(?d).DS_Store\n"
local once = songsync.merge(own, { Lantern = true })
assert(once:find("(?d).DS_Store", 1, true) and once:find("!/Lantern", 1, true), "own lines kept, block added")
local twice = songsync.merge(once, { Lantern = true, ["Mirror Test"] = true })
local _, n = twice:gsub("// BandSync end", "")
assert(n == 1 and twice:find("!/Mirror Test", 1, true) and twice:find("(?d).DS_Store", 1, true), "replaced in place, once")
assert(songsync.merge(twice, nil) == own, "keep every song: the block comes out, own lines as they were")
assert(songsync.merge("", nil) == "", "nothing to write")
assert(songsync.merge(songsync.merge("", {}), {}) == songsync.merge("", {}), "the same choice writes the same file")
assert(not text:find("!/Saltmarsh", 1, true), "a song not opened here isn't let in")
-- a byte-order mark in front (an editor, or PowerShell 5.1) must not make the block look like someone's own lines
local bom = "\239\187\191" .. songsync.merge("", {})
local again = songsync.merge(bom, { Lantern = true })
local _, blocks = again:gsub("// BandSync end", "")
assert(blocks == 1 and again:find("!/Lantern", 1, true), "one block, replaced, despite a byte-order mark")
print("ok")

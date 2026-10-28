-- sessionfile.map_files is pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local sf = require("sessionfile")
local text = table.concat({ "<REAPER_PROJECT", "  <SOURCE FLAC", '    FILE "C:\\proj\\bandsync\\takes_Laptop-1.flac" 1', "  >",
  "  <SOURCE WAVE", "    FILE media/mine.wav", "  >", ">" }, "\n")
local seen = {}
local out = sf.map_files(text, function(p) seen[#seen + 1] = p; if p:find("takes_") then return "../rooms/main/takes/Laptop-1.flac" end end)
assert(seen[1] == "C:\\proj\\bandsync\\takes_Laptop-1.flac" and seen[2] == "media/mine.wav", "quoted and bare paths are both read")
assert(out:find('    FILE "../rooms/main/takes/Laptop-1.flac" 1', 1, true), "a mapped path keeps what followed it")
assert(out:find("    FILE media/mine.wav", 1, true), "an unmapped line is left exactly as it was")
assert(select(2, out:gsub("\n", "")) == select(2, text:gsub("\n", "")) + 1, "same lines")
print("ok")

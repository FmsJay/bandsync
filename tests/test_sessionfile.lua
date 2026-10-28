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
package.loaded.sync = package.loaded.sync or {}
local split = require("mixlayer").split_live
local proj = table.concat({ "<REAPER_PROJECT", "  <EXTSTATE", "    <BANDSYNC", "      SONG Saltmarsh", "    >", "    <OTHER", "      X 1", "    >", "  >",
  "  <MASTERFXLIST", "    SHOW 0", "    BYPASS 0 0 0", "    <VST \"VST3: SonoBus (Sonosaurus)\" SonoBus.vst3 0", "      c2VjcmV0", "    >", "    WAK 0 0", "  >",
  "  <TRACK", "    NAME \"Live in\"", "    <FXCHAIN", "      SHOW 0", "      BYPASS 0 0 0", "      <VST \"VST: ReaNINJAM (Cockos)\" reaninjam.dll 0", "        bmluamE=", "      >",
  "      BYPASS 0 0 0", "      <JS loser/limiter \"\"", "        0", "      >", "    >", "  >", ">" }, "\n")
local plain = sf.plain(proj, split)
assert(not plain:find("SonoBus") and not plain:find("ReaNINJAM") and not plain:find("c2VjcmV0"), "no live plug-ins anywhere, nor their state")
assert(plain:find("loser/limiter", 1, true) and plain:find("NAME \"Live in\"", 1, true), "the rest of the chains and tracks stay")
assert(not plain:find("BANDSYNC") and not plain:find("SONG Saltmarsh") and plain:find("<OTHER", 1, true), "BandSync's state goes, other extensions' stay")
assert(select(2, ("\n" .. plain):gsub("\n%s*<", "")) == select(2, plain:gsub("\n%s*>", "")), "blocks still balance")
assert(sf.plain(proj:gsub("\n", "\r\n"), split) == plain, "a Windows (CRLF) project comes out the same, whole")
print("ok")

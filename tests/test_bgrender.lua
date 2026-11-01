-- bgrender.offline_others is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
reaper.GetOS = reaper.GetOS or function() return "Win64" end
package.loaded.band = package.loaded.band or {}
local bg = require("bgrender")
local rpp = table.concat({
  '<REAPER_PROJECT 0.1 "7.84/win64" 1 0',
  '  <MASTERFXLIST',
  '    BYPASS 0 0 0',
  '    <VST "VST: ReaLimit (Cockos)" reaxcomp.dll 0 "" 1>',
  '    >',
  '  >',
  '  <TRACK {AAAA-1}',
  '    NAME Keys',
  '    <FXCHAIN',
  '      BYPASS 0 0 0',
  '      <VST "VSTi: Kontakt" kontakt.dll 0 "" 1>',
  '      >',
  '    >',
  '    <ITEM',
  '      <TAKEFX',
  '        BYPASS 1 0 0',
  '      >',
  '    >',
  '  >',
  '  <TRACK {bbbb-2}',
  '    NAME Gtr',
  '    <FXCHAIN',
  '      BYPASS 0 0 0',
  '      BYPASS 1 0 0',
  '    >',
  '  >',
  '>',
  '' }, "\n")
local out = bg.offline_others(rpp, { ["{BBBB-2}"] = true })
local lines = {}
for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
assert(lines[3] == "    BYPASS 0 1 0", "the master's plug-ins go offline: " .. lines[3])
assert(lines[10] == "      BYPASS 0 1 0" and lines[16] == "        BYPASS 1 1 0", "another track's, its items' too, bypass kept")
assert(lines[23] == "      BYPASS 0 0 0" and lines[24] == "      BYPASS 1 0 0", "the kept track's stay as they were (GUIDs in any case)")
assert(#out == #rpp, "nothing else changes")
print("ok")

-- bgrender.prepare is pure (lupa or Lua 5.4, from the repo root)
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
local out = bg.prepare(rpp, { ["{BBBB-2}"] = true })
local lines = {}
for l in out:gmatch("[^\n]+") do lines[#lines + 1] = l end
assert(lines[3] == "    BYPASS 0 1 0", "the master's plug-ins go offline: " .. lines[3])
assert(lines[10] == "      BYPASS 0 1 0" and lines[16] == "        BYPASS 1 1 0", "another track's, its items' too, bypass kept")
assert(lines[23] == "      BYPASS 0 0 0" and lines[24] == "      BYPASS 1 0 0", "the kept track's stay as they were (GUIDs in any case)")
assert(#out == #rpp, "nothing else changes")
-- a routed print's stem renders as the master mix: others muted, folders flat, kept ones to the master at 0 dB
local stem = table.concat({
  '<REAPER_PROJECT 0.1 "7.84/win64" 1 0',
  '  RENDER_STEMS 2',
  '  MASTERMUTESOLO 1',
  '  MASTER_VOLUME 0.5 -0.2 -1 -1 1',
  '  <TRACK {A}',
  '    MUTESOLO 0 0 0',
  '    ISBUS 1 1',
  '    MAINSEND 0 0',
  '  >',
  '  <TRACK {B}',
  '    MUTESOLO 0 0 0',
  '    ISBUS 2 -1',
  '    MAINSEND 0 0',
  '  >',
  '>', '' }, "\n")
local m = {}
for l in bg.prepare(stem, { ["{B}"] = true }):gmatch("[^\n]+") do m[#m + 1] = l end
assert(m[2] == "  RENDER_STEMS 0" and m[3] == "  MASTERMUTESOLO 0" and m[4] == "  MASTER_VOLUME 1 0 -1 -1 1", "master mix, master at 0 dB, unmuted")
assert(m[6] == "    MUTESOLO 1 0 0" and m[7] == "    ISBUS 0 0" and m[8] == "    MAINSEND 0 0", "another track: muted, no folder")
assert(m[11] == "    MUTESOLO 0 0 0" and m[12] == "    ISBUS 0 0" and m[13] == "    MAINSEND 1 0", "the kept one: playing, to the master")
local plain = table.concat({ '<REAPER_PROJECT', '  RENDER_STEMS 32', '  <TRACK {A}', '    MUTESOLO 0 0 0', '  >', '>', '' }, "\n")
assert(bg.prepare(plain, {}) == plain, "an item render (RENDER_STEMS 32) keeps its tracks as they are")
local ext = table.concat({ '<REAPER_PROJECT', '  <EXTSTATE', '    <BANDSYNC', '      SONG Lantern', '    >', '    <BANDSYNC.MIRROR', '      X 1', '    >',
  '    <OTHER', '      Y 2', '    >', '  >', '>', '' }, "\n")
assert(bg.prepare(ext, {}) == table.concat({ '<REAPER_PROJECT', '  <EXTSTATE', '    <OTHER', '      Y 2', '    >', '  >', '>', '' }, "\n"),
  "StudioSync's project state left out of the copy, anyone else's kept")
-- the render profile's reaper.ini: no MIDI devices, surfaces, splash or recent projects; the device closed while inactive
local ini = bg.profile_ini(table.concat({ "[REAPER]", "splash=1", "midiins=19954", "midiouts_clock=344388", "midiins_x_h=0",
  "csurf_cnt=1", "csurf_0=HTTP 0 8080 '' 'index.html' 0 ''", "recent01=C:/a.rpp", "lastproject=C:/a.rpp", "audiocloseinactive=0",
  "asio_driver=1", "[other]", "x=1" }, "\r\n"))
assert(ini == table.concat({ "[REAPER]", "audiocloseinactive=1", "renderclosewhendone=4", "splash=0", "midiins=0", "midiouts_clock=0", "midiins_x_h=0",
  "csurf_cnt=0", "asio_driver=1", "[other]", "x=1", "" }, "\n"), ini)
assert(bg.profile_ini("[reaper]\nfoo=1\n") == "[reaper]\naudiocloseinactive=1\nrenderclosewhendone=4\nfoo=1\n") -- (the Mac's section is lower case)
-- printing mustn't leave an undo point on top of the edit: SelectAllMediaItems does, when the part is selected (a step
-- across passes shows it, which one in-REAPER suite can't: undo points only settle between script passes)
do
  local f = assert(io.open("lib/sync.lua", "rb")); local text = f:read("a"); f:close()
  local body = text:match("function sync%.print_item.-\nend\n")
  assert(body and not body:find("SelectAllMediaItems(", 1, true), "print_item keeps clear of SelectAllMediaItems")
end
-- the Mac's job script (bash -n checks its syntax from the release steps)
local helped = bg.mac_script({ tmp = "/t/r", profile = "/t/r/profile", res = "/res", exe = "/Applications/REAPER.app/Contents/MacOS/REAPER",
  ini = "job3.ini", job = "/t/r/print-1/job.rpp", helpers = "/res/Scripts/StudioSync/lib/mac" })
assert(helped:find("LSBackgroundOnly", 1, true) and helped:find("H='/res/Scripts/StudioSync/lib/mac'", 1, true), "makes the private copy")
assert(helped:find('"$P/job3.ini"', 1, true) and helped:find("J='/t/r/print-1/job.rpp'", 1, true) and not helped:find("@%u+@"), "every value filled in")
assert(helped:find('echo "$?" > "$D/done.txt"', 1, true) and helped:find('echo "$p" > "$D/pid.txt"', 1, true), "says when it's done, and its process")
local plain = bg.mac_script({ tmp = "/t", profile = "/p", res = "/r", exe = "/x", ini = "job1.ini", job = "/j/job.rpp" })
assert(plain:find("H=''", 1, true), "no helpers: REAPER itself")
assert(bg.mac_script({ tmp = "/t", profile = "/p", res = "/it's", exe = "/x", ini = "job1.ini", job = "/j" }):find([[R='/it'\''s']], 1, true), "a quote in a path")
assert(bg.helpers() == nil, "Windows has no helpers")
assert(bg.profile_ini("[REAPER]\nrenderclosewhendone=0\n"):find("renderclosewhendone=4\n", 1, true) and not bg.profile_ini("[REAPER]\nrenderclosewhendone=0\n"):find("=0", 1, true), "the hidden render window closes on its own")
print("ok")

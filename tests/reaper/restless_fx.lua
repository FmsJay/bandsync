-- Run inside REAPER (ReaScript). A plug-in that writes different saved data on every read (0.42.1; a JSFX stands in for
-- Kilohearts Disperser): found restless, its chain goes out once, its parts get prints, both machines end on the same
-- fingerprint, it sends nothing more, and moving its knob or another plug-in's still counts.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 1.5 -- (as in real use: a chain that keeps changing renders nothing)
local band, sync, mirror, prints = require("band"), require("sync"), require("mirror"), require("prints")
local root = D .. "/rroot_" .. os.time()
local song, room = "RestlessLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function sent(who, obj)
  local n = 0
  for _, f in ipairs(band.files(events, ".json")) do
    if f:sub(1, #who + 1) == who .. "-" then
      local e = band.read_json(events .. "/" .. f)
      if not obj or (e and e.obj == obj) then n = n + 1 end
    end
  end
  return n
end
local yes = function() return true end
local fxdir = reaper.GetResourcePath() .. "/Effects/BandSyncTest"
reaper.RecursiveCreateDirectory(fxdir, 0)
local fxfile = fxdir .. "/restless.jsfx"
band.write_atomic(fxfile, "desc:BandSync test restless\nslider1:0<0,1,0.01>knob\n@init\nc = 1;\n@serialize\nc += 1;\nfile_var(0, c);\n@sample\nspl0 = spl0; spl1 = spl1;\n")
local front = reaper.EnumProjects(-1)
local was_bg = reaper.GetExtState(band.SECTION, "bg render")
local was_list = reaper.GetExtState("BandSync", "restless plugins")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.DeleteExtState("BandSync", "restless plugins", true)
mirror.restless, mirror.restless_loaded = {}, nil
mirror.RESTLESS_FLIPS, mirror.RESTLESS_SECS = 3, 1 -- (quicker than the real thing)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
sync.driver_name = "Laptop"
local function watch(p, cfg)
  reaper.SelectProjectInstance(p)
  return (mirror.watch(p, cfg, song, room, { can = yes, mode = "claims", here = { Laptop = true, James = true } }))
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function pkey(it)
  local _, p = prints.takes(it)
  return p and select(2, reaper.GetSetMediaItemTakeInfo_String(p, "P_EXT:" .. prints.KEY, "", false)) or ""
end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Keys", true)
  reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
  check(reaper.TrackFX_AddByName(tr, "BandSyncTest/restless.jsfx", false, -1) >= 0, "the restless stand-in loads")
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  local tk = reaper.GetActiveTake(it)
  for n = 0, 3 do reaper.MIDI_InsertNote(tk, false, false, n * 480, n * 480 + 400, 0, 50 + n, 100, true) end
  reaper.MIDI_Sort(tk)
  watch(pa, A)
  local _, c1 = reaper.GetTrackStateChunk(tr, "", false)
  local _, c2 = reaper.GetTrackStateChunk(tr, "", false)
  check(c1 ~= c2, "its saved data differs on every read")
  check(sent("Laptop", "fx") == 0, "at first its chain waits, as it never holds still")

  local t = reaper.time_precise()
  while reaper.time_precise() - t < 25 and sent("Laptop", "fx") == 0 do watch(pa, A); hold(0.4) end
  check(sent("Laptop", "fx") == 1, string.format("found restless, its chain goes out (%.1f s)", reaper.time_precise() - t))
  check(next(mirror.restless) ~= nil, "it's on the list: " .. tostring(next(mirror.restless)))
  check(reaper.GetExtState("BandSync", "restless plugins") ~= "", "and kept for next time")
  t = reaper.time_precise()
  while reaper.time_precise() - t < 10 and pkey(it) == "" do watch(pa, A); hold(0.2) end
  check(pkey(it) ~= "", "its part has its print")
  for _ = 1, 4 do watch(pa, A); hold(0.2) end
  local key = pkey(it)
  local n1 = sent("Laptop")
  for _ = 1, 10 do watch(pa, A); hold(0.2) end
  check(sent("Laptop") == n1 and pkey(it) == key, "and nothing more goes out or renders while it just sits there")

  -- the bandmate gets it, and hears the name from the event: same fingerprint, nothing sent back
  mirror.restless, mirror.restless_loaded = {}, true -- (as a machine that has never seen it)
  recv(pb, B)
  check(next(mirror.restless) ~= nil, "the bandmate learns the name from the event")
  local n2 = sent("James")
  for _ = 1, 8 do watch(pb, B); hold(0.2); recv(pb, B) end
  check(sent("James") == n2, "and sends nothing back")
  check(mirror.root(pa) == mirror.root(pb), "both on the same fingerprint")
  local _, c3 = reaper.GetTrackStateChunk(reaper.GetTrack(pb, 0), "", false)
  check(c3:find("BandSyncTest/restless.jsfx", 1, true) ~= nil, "the bandmate has the plug-in")

  -- its knob moving still counts
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_SetParam(tr, 1, 0, 0.5)
  local n3 = sent("Laptop", "fx")
  t = reaper.time_precise()
  while reaper.time_precise() - t < 8 and sent("Laptop", "fx") == n3 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == n3 + 1, "moving its knob goes out")
  t = reaper.time_precise()
  while reaper.time_precise() - t < 10 and pkey(it) == key do watch(pa, A); hold(0.3) end
  check(pkey(it) ~= key, "and its part prints again, as it sounds different")
  local key2 = pkey(it)
  for _ = 1, 8 do watch(pa, A); hold(0.2) end
  check(pkey(it) == key2, "once")
  recv(pb, B)
  check(math.abs(reaper.TrackFX_GetParam(reaper.GetTrack(pb, 0), 1, 0) - 0.5) < 0.01, "and lands on the bandmate")
  for _ = 1, 8 do watch(pb, B); hold(0.2) end
  check(sent("James") == n2, "without coming back")
  for _ = 1, 8 do watch(pa, A); hold(0.2) end
  local n4 = sent("Laptop", "fx")
  for _ = 1, 8 do watch(pa, A); hold(0.2) end
  check(sent("Laptop", "fx") == n4, "once, not over and over")

  -- another plug-in's saved data on the same chain still counts
  reaper.SelectProjectInstance(pa)
  reaper.TrackFX_SetParam(tr, 0, 0, 0.3)
  t = reaper.time_precise()
  while reaper.time_precise() - t < 8 and sent("Laptop", "fx") == n4 do watch(pa, A); hold(0.3) end
  check(sent("Laptop", "fx") == n4 + 1, "another plug-in on the chain still goes out")
  recv(pb, B)
  check(mirror.root(pa) == mirror.root(pb), "and the fingerprints still agree")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
reaper.SetExtState("BandSync", "restless plugins", was_list, true)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
os.remove(fxfile); os.remove(fxdir)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")

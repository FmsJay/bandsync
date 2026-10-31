-- Run inside REAPER (ReaScript). Freezing a track (its items rendered to audio, its plug-ins kept aside in the track's
-- own <FREEZE> block) and unfreezing it, between two scratch tabs "James" (A) and "Bee" (B). Scratch only.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "prints" }) do package.loaded[m] = nil end
local sync, mirror = require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/froot_" .. stamp
local song, room = "FreezeLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function pass(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }); settle() end; return n end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function fxn(tr) local t = {} for i = 0, reaper.TrackFX_GetCount(tr) - 1 do t[#t + 1] = select(2, reaper.TrackFX_GetFXName(tr, i, "")) end return table.concat(t, ",") end
local function kinds(tr)
  local t = {}
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local tk = reaper.GetActiveTake(reaper.GetTrackMediaItem(tr, i))
    t[#t + 1] = tk and (reaper.TakeIsMIDI(tk) and "midi" or "audio") or "empty"
  end
  return table.concat(t, ",")
end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  out[#out + 1] = "actions: 41223 = " .. reaper.kbd_getTextFromCmd(41223, 0) .. " | 41644 = " .. reaper.kbd_getTextFromCmd(41644, 0)
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Synth", true)
  reaper.TrackFX_AddByName(tr, "ReaSynth", false, -1)
  local it = reaper.CreateNewMIDIItemInProj(tr, 0, 2, false)
  reaper.MIDI_InsertNote(reaper.GetActiveTake(it), false, false, 0, 960, 0, 60, 100, true); reaper.MIDI_Sort(reaper.GetActiveTake(it))
  pass(pa, A); recv(pb, B)
  local btr = mirror.find(pb, "track", mirror.track_oid(tr))
  check(btr and kinds(btr) == "midi" and fxn(btr):find("ReaSynth"), "B: MIDI item and ReaSynth before the freeze")
  -- A freezes the track
  reaper.SelectProjectInstance(pa)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(41223, 0)
  out[#out + 1] = "A frozen: items " .. kinds(tr) .. ", plug-ins [" .. fxn(tr) .. "]"
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  out[#out + 1] = "B after the freeze: items " .. kinds(btr) .. ", plug-ins [" .. fxn(btr) .. "]"
  check(kinds(btr) == kinds(tr) and fxn(btr) == fxn(tr), "B matches A's frozen track")
  -- A unfreezes it
  reaper.SelectProjectInstance(pa)
  reaper.SetOnlyTrackSelected(tr)
  reaper.Main_OnCommand(41644, 0)
  out[#out + 1] = "A unfrozen: items " .. kinds(tr) .. ", plug-ins [" .. fxn(tr) .. "]"
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  out[#out + 1] = "B after unfreeze: items " .. kinds(btr) .. ", plug-ins [" .. fxn(btr) .. "]"
  check(kinds(btr) == "midi" and fxn(btr):find("ReaSynth") ~= nil, "B has the MIDI item and ReaSynth back")
  check(pass(pb, B) == 0, "B sends nothing back")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/freeze_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

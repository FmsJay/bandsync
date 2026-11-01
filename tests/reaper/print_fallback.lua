-- Run inside REAPER (ReaScript). Who prints (0.39, prints.printer): the bandmate who changed a MIDI part lacks its
-- synth, so a bandmate in the song who has it prints it instead, and its print goes out even on a track it may not
-- change (claimed). Also: an item's takes become fixed lanes, the comp kept, and reach the bandmate.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json" }) do package.loaded[m] = nil end
local band, sync, mirror, prints, plugins = require("band"), require("sync"), require("mirror"), require("prints"), require("plugins")
local root = D .. "/froot_" .. os.time()
local song, room = "PrintLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
reaper.RecursiveCreateDirectory(root .. "/plugins", 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function sent(who) local n = 0; for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end; return n end
local yes = function() return true end
local not_james = function(u) return u ~= "James" end -- (Keys is the laptop's claim: James may not change it)
local front = reaper.EnumProjects(-1)
reaper.SetExtState(band.SECTION, "bg render", "off", false) -- (in front: audio_prints covers the background)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local real_plays = prints.track_plays
local function lacks(on) prints.track_plays = on and function() return false end or real_plays end -- (the laptop's synth doesn't load there)
local function watch(p, cfg, can, here)
  lacks(cfg.user == "Laptop")
  reaper.SelectProjectInstance(p)
  local n = mirror.watch(p, cfg, song, room, { can = can, mode = "claims", here = here })
  lacks(false)
  return n
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function synth_print(it) return select(2, prints.takes(it)) end
local ok, err = pcall(function()
  -- the laptop makes Keys with a synth it doesn't have (offline there), and a part on it
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local ka = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(ka, "P_NAME", "Keys", true)
  reaper.TrackFX_AddByName(ka, "ReaSynth", false, -1)
  local key = prints.track_keys(ka)[1]
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  band.write_json(root .. "/plugins/James.json", { user = "James", time = now, names = { key } })
  band.write_json(root .. "/plugins/Laptop.json", { user = "Laptop", time = now, names = {} })
  local it = reaper.CreateNewMIDIItemInProj(ka, 0, 2, false)
  local tk = reaper.GetActiveTake(it)
  for i = 0, 3 do reaper.MIDI_InsertNote(tk, false, false, i * 480, i * 480 + 400, 0, 60 + i, 100, true) end
  reaper.MIDI_Sort(tk)
  watch(pa, A, yes, { James = true })
  local w = reaper.time_precise(); while reaper.time_precise() - w < 3.3 do end -- (a plug-in chain goes once it has held still 3 s)
  watch(pa, A, yes, { James = true })
  recv(pb, B)
  local kb = reaper.GetTrack(pb, 0)
  local ib = kb and reaper.GetTrackMediaItem(kb, 0)
  check(ib ~= nil and not synth_print(ib), "James has the part, with no print yet")
  -- the laptop can't print it, so it doesn't try
  watch(pa, A, yes, { James = true }); watch(pa, A, yes, { James = true })
  check(not synth_print(it), "the laptop (synth missing) doesn't print it")
  -- James, in the song with the synth, prints it, though Keys is the laptop's claim
  local n = sent("James")
  watch(pb, B, not_james, { Laptop = true }); watch(pb, B, not_james, { Laptop = true })
  check(synth_print(ib) ~= nil, "James prints it, with the synth he has")
  check(sent("James") > n, "and it goes to the band (a print isn't put back on a claimed track)")
  recv(pa, A)
  check(synth_print(it) ~= nil and reaper.CountTakes(it) == 2, "the laptop gets the print: dry and wet")
  lacks(true); prints.choose(it); lacks(false)
  check(reaper.GetActiveTake(it) == synth_print(it), "and plays it (its synth doesn't load there)")
  -- James gone: nobody here can, so the laptop leaves it (the old print stays)
  reaper.SelectProjectInstance(pa)
  reaper.MIDI_InsertNote(tk, false, false, 1920, 2300, 0, 72, 100, false)
  local before = select(2, reaper.GetSetMediaItemTakeInfo_String(synth_print(it), "P_EXT:" .. prints.KEY, "", false))
  watch(pa, A, yes, {}); watch(pa, A, yes, {})
  check(select(2, reaper.GetSetMediaItemTakeInfo_String(synth_print(it), "P_EXT:" .. prints.KEY, "", false)) == before, "with nobody here who can, the old print stays")
  -- takes become lanes: two takes on the laptop's Vox, the second playing; then on James's too
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 1, 0)
  local va = reaper.GetTrack(pa, 1)
  reaper.GetSetMediaTrackInfo_String(va, "P_NAME", "Vox", true)
  local vi = reaper.CreateNewMIDIItemInProj(va, 0, 1, false)
  reaper.AddTakeToMediaItem(vi)
  reaper.SetActiveTake(reaper.GetTake(vi, 1))
  watch(pa, A, yes, {}); watch(pa, A, yes, {}); watch(pa, A, yes, {})
  check(reaper.GetMediaTrackInfo_Value(va, "I_NUMFIXEDLANES") >= 2 and reaper.CountTrackMediaItems(va) >= 2, string.format("the laptop's takes became lanes (%d lanes, %d items)",
    reaper.GetMediaTrackInfo_Value(va, "I_NUMFIXEDLANES"), reaper.CountTrackMediaItems(va)))
  local one = true
  for j = 0, reaper.CountTrackMediaItems(va) - 1 do one = one and reaper.CountTakes(reaper.GetTrackMediaItem(va, j)) == 1 end
  check(one, "each lane item has one take")
  recv(pb, B)
  local vb = reaper.GetTrack(pb, 1)
  check(vb and reaper.CountTrackMediaItems(vb) == reaper.CountTrackMediaItems(va) and reaper.GetMediaTrackInfo_Value(vb, "I_NUMFIXEDLANES") == reaper.GetMediaTrackInfo_Value(va, "I_NUMFIXEDLANES"),
    "James gets the same lanes")
  local nb = sent("James")
  watch(pb, B, yes, { Laptop = true })
  check(sent("James") == nb, "and doesn't explode or send anything of his own")
end)
lacks(false)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
reaper.DeleteExtState(band.SECTION, "bg render", false)
for k, p in ipairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/print_fallback_" .. k .. ".rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")

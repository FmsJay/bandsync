-- Run inside REAPER (ReaScript). A MIDI item whose instrument is on another track (a MIDI send to "Kit", ReaSynth)
-- gets a print rendered through that track: a wet take with sound, made from this item alone (another MIDI track
-- feeding Kit is kept out), and every mute, the selection and the playing take put back. Scratch tab, saved into the
-- scratch folder and closed.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "json" }) do package.loaded[m] = nil end
local band, prints = require("band"), require("prints")
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local p = reaper.EnumProjects(-1)
local media = D .. "/routed_media_" .. os.time()
reaper.RecursiveCreateDirectory(media, 0)
-- the loudest sample of a take, from its own audio
local function peak(tk)
  local acc = reaper.CreateTakeAudioAccessor(tk)
  local sr, n, buf, best = 44100, 44100 * 2, reaper.new_array(44100 * 2 * 2), 0
  reaper.GetAudioAccessorSamples(acc, sr, 2, 0, n, buf)
  for i = 1, n * 2 do local v = math.abs(buf[i]); if v > best then best = v end end
  reaper.DestroyAudioAccessor(acc)
  return best
end
local ok, err = pcall(function()
  for i = 0, 2 do reaper.InsertTrackInProject(p, i, 0) end
  local notes, other, kit = reaper.GetTrack(p, 0), reaper.GetTrack(p, 1), reaper.GetTrack(p, 2)
  reaper.GetSetMediaTrackInfo_String(notes, "P_NAME", "Notes", true)
  reaper.GetSetMediaTrackInfo_String(other, "P_NAME", "Other", true)
  reaper.GetSetMediaTrackInfo_String(kit, "P_NAME", "Kit", true)
  check(reaper.TrackFX_AddByName(kit, "ReaSynth", false, -1) >= 0, "Kit has ReaSynth")
  reaper.CreateTrackSend(notes, kit); reaper.CreateTrackSend(other, kit)
  local it = reaper.CreateNewMIDIItemInProj(notes, 0, 1, false)
  local tk = reaper.GetActiveTake(it)
  reaper.MIDI_InsertNote(tk, false, false, 0, 960, 0, 60, 110, true); reaper.MIDI_Sort(tk)
  local it2 = reaper.CreateNewMIDIItemInProj(other, 0, 1, false)
  local tk2 = reaper.GetActiveTake(it2)
  reaper.MIDI_InsertNote(tk2, false, false, 0, 960, 0, 72, 110, true); reaper.MIDI_Sort(tk2)
  reaper.SetMediaItemInfo_Value(it2, "B_MUTE", 0)
  reaper.SetMediaTrackInfo_Value(kit, "D_VOL", 0.5) -- (a fader that isn't printed)
  reaper.SetTrackSelected(other, true)
  check(prints.route(notes) == kit, "Notes plays Kit's instrument (a MIDI send)")
  check(prints.route(kit) == nil, "Kit has its own instrument")
  check(prints.track_plays(notes), "every plug-in it plays through loads here")
  reaper.SelectProjectInstance(p)
  local did = prints.refresh(p, it, media, "fx", "kit")
  check(did == true, "a print was made")
  local midi, wet = prints.takes(it)
  check(midi ~= nil and wet ~= nil and reaper.CountTakes(it) == 2, "the item has its dry and wet takes")
  check(select(2, reaper.GetSetMediaItemTakeInfo_String(wet, "P_NAME", "", false)):match("^wet") ~= nil, "named wet")
  local pk = peak(wet)
  check(pk > 0.01, string.format("the print has sound (peak %.3f)", pk))
  check(reaper.GetMediaItemInfo_Value(it2, "B_MUTE") == 0 and reaper.GetMediaTrackInfo_Value(kit, "D_VOL") == 0.5, "Other's item and Kit's fader are as they were")
  check(reaper.IsTrackSelected(other) and not reaper.IsTrackSelected(kit), "the track selection is as it was")
  local recv_muted = false
  for r = 0, reaper.GetTrackNumSends(kit, -1) - 1 do if reaper.GetTrackSendInfo_Value(kit, -1, r, "B_MUTE") ~= 0 then recv_muted = true end end
  check(not recv_muted, "Kit's receives are unmuted again")
  check(reaper.GetActiveTake(it) == midi, "the dry take plays here (Auto: the instrument loads)")
  -- the send carries MIDI only now (with Wet, the print went down an audio send into Kit too and played twice)
  local s_notes = -1
  for s = 0, reaper.GetTrackNumSends(notes, 0) - 1 do if reaper.GetTrackSendInfo_Value(notes, 0, s, "P_DESTTRACK") == kit then s_notes = s end end
  check(s_notes >= 0 and reaper.GetTrackSendInfo_Value(notes, 0, s_notes, "I_SRCCHAN") == -1, "Notes' send to Kit carries MIDI only now")
  check(reaper.GetTrackSendInfo_Value(other, 0, 0, "I_SRCCHAN") ~= -1, "Other's send is left as it was (not printed yet)")
  local wfile = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(wet))
  check(wfile:find("%-" .. (reaper.GetExtState("BandSync", "user"):gsub("[^%w%-_]", "_")) .. "%.flac$") ~= nil, "the print's file carries who rendered it (" .. (wfile:match("[^/\\]+$") or "") .. ")")
  -- the same notes again: nothing to do
  check(prints.refresh(p, it, media, "fx", "kit") == false, "an unchanged item isn't printed again")
  -- the instrument changed: printed again
  check(prints.refresh(p, it, media, "fx", "kit2") == true, "a change to the instrument's chain prints it again")
  -- on a computer without Kit's instrument (offline): not playable, so Auto plays the print (and Health says why)
  reaper.TrackFX_SetOffline(kit, 0, true)
  check(not prints.track_plays(notes), "with Kit's instrument missing, Notes doesn't play here")
  prints.choose(it)
  check(reaper.GetActiveTake(it) == select(2, prints.takes(it)), "so the wet take plays")
  reaper.TrackFX_SetOffline(kit, 0, false)
  prints.choose(it)
  -- this item alone: one with no notes, while Other plays at the same time, prints silent
  local quiet = reaper.CreateNewMIDIItemInProj(notes, 0, 1, false)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 3) -- (out of the way)
  check(prints.refresh(p, quiet, media, "fx", "kit") == true, "the empty item gets a print too")
  local _, qwet = prints.takes(quiet)
  local qp = qwet and peak(qwet) or -1
  check(qp >= 0 and qp < 0.001, string.format("and it's silent: Other, playing at the same time, stays out (peak %.4f)", qp))
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
if reaper.ValidatePtr2(0, p, "ReaProject*") then
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, D .. "/routed_print.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")

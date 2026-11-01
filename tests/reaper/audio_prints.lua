-- Run inside REAPER (ReaScript). Audio wet takes rendered in the background (0.37): an audio item on a track with a
-- plug-in a bandmate lacks gets a wet print, rendered by a second REAPER while this one carries on; the print has
-- the track's plug-ins but not the item's own volume; while it plays, the track's FX are held off here only. Also:
-- SWS auto-colouring off while a band song is in front, back on elsewhere. Scratch folder and tab, closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "bgrender", "json" }) do package.loaded[m] = nil end
local band, prints, mirror, plugins = require("band"), require("prints"), require("mirror"), require("plugins")
local root = D .. "/aroot_" .. os.time()
local cfg = { user = "James", root = root }
local media = root .. "/AudioLab/rooms/main/media"
reaper.RecursiveCreateDirectory(media, 0)
reaper.RecursiveCreateDirectory(root .. "/plugins", 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function peak(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  local g = src and reaper.CalculateNormalization(src, 2, 0, 0, 0) or 0
  if src then reaper.PCM_Source_Destroy(src) end
  return g > 0 and -20 * math.log(g, 10) or -999
end
local function sine_wav(path, secs, sr) -- 220 Hz at -12 dBFS, 16-bit mono
  local n = math.floor(secs * sr)
  local t = { "RIFF", string.pack("<I4", 36 + n * 2), "WAVE", "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16), "data", string.pack("<I4", n * 2) }
  for i = 0, n - 1 do t[#t + 1] = string.pack("<i2", math.floor(0.25 * 32767 * math.sin(2 * math.pi * 220 * i / sr))) end
  local f = io.open(path, "wb"); f:write(table.concat(t)); f:close()
end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local sws_id = reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE")
local sws_was = sws_id > 0 and reaper.GetToggleCommandState(sws_id) or -1
local ok, err = pcall(function()
  sine_wav(media .. "/gtr-take.wav", 2, 44100)
  reaper.InsertTrackInProject(pa, 0, 0); reaper.InsertTrackInProject(pa, 1, 0)
  local tr, plain = reaper.GetTrack(pa, 0), reaper.GetTrack(pa, 1)
  local fx = reaper.TrackFX_AddByName(tr, "JS: Volume Adjustment", false, -1)
  if fx < 0 then fx = reaper.TrackFX_AddByName(tr, "utility/volume", false, -1) end
  reaper.TrackFX_SetParam(tr, fx, 0, 6) -- (+6 dB: the print must have it)
  reaper.TrackFX_AddByName(plain, "ReaEQ", false, -1)
  local function key(t, i) local _, n = reaper.TrackFX_GetNamedConfigParm(t, i, "fx_name"); return plugins.key(n) end
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  band.write_json(root .. "/plugins/James.json", { user = "James", time = now, names = { key(tr, fx), key(plain, 0) } })
  band.write_json(root .. "/plugins/Mac.json", { user = "Mac", time = now, names = { key(plain, 0) } }) -- (the Mac lacks the volume plug-in)
  local function audio_item(t, oid)
    local it = reaper.AddMediaItemToTrack(t)
    local tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(media .. "/gtr-take.wav"))
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", 1); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
    reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", oid, true)
    return it
  end
  local it, other = audio_item(tr, "I-JAMES-20261101000000-1"), audio_item(plain, "I-JAMES-20261101000000-2")
  reaper.SetMediaItemInfo_Value(it, "D_VOL", 0.5) -- (-6 dB on the item: the print leaves it to the item)
  reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 0.25)
  reaper.UpdateArrange()
  check(prints.audio_take(it) ~= nil and prints.lacking(tr, cfg) and not prints.lacking(plain, cfg), "the guitar track needs a print (the Mac lacks its plug-in), the other doesn't")
  -- the print renders in the background: the first call only starts it
  local t0 = reaper.time_precise()
  local did = prints.refresh(pa, it, media, "fxhash", nil, cfg)
  local first = reaper.time_precise() - t0
  check(not did and first < 1.0, string.format("starting it took %.2f s (no waiting for the render)", first))
  check(require("bgrender").busy(), "a second REAPER is rendering it")
  while not did and reaper.time_precise() - t0 < 90 do
    local w = reaper.time_precise(); while reaper.time_precise() - w < 0.5 do end
    did = prints.refresh(pa, it, media, "fxhash", nil, cfg)
  end
  say(string.format("     background print in %.1f s", reaper.time_precise() - t0))
  local bg_done, bg_failed = require("bgrender").counts()
  check(bg_done == 1 and bg_failed == 0, string.format("it really rendered in the background (%d done, %d failed: a failed one renders in front)", bg_done, bg_failed))
  local dry, wet = prints.audio_take(it), select(2, prints.takes(it))
  check(did and wet ~= nil and reaper.CountTakes(it) == 2, "the item has its dry and wet takes")
  local wpath = wet and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(wet), "") or ""
  check(wpath:find(media, 1, true) == 1 and wpath:match("%.flac$") ~= nil, "the print is in the room's media folder (" .. wpath:match("[^/\\]*$") .. ")")
  -- the same print rendered in front, the old way: the background one must match it
  local fg = require("sync").print_item(pa, it, dry, media, "fg-reference", nil, false, true)
  local src_pk, wet_pk, fg_pk = peak(media .. "/gtr-take.wav"), peak(wpath), fg and peak(fg) or -999
  check(math.abs(wet_pk - fg_pk) < 0.1, string.format("the background print matches one rendered in front (%.2f / %.2f dBFS peak)", wet_pk, fg_pk))
  check(wet_pk - src_pk > 4, string.format("it has the track's +6 dB, not the item's -6 (%.1f -> %.1f dBFS)", src_pk, wet_pk))
  check(select(2, reaper.GetSetMediaItemTakeInfo_String(wet, "P_NAME", "", false)):match("^wet") ~= nil, "it's labelled wet")
  check(reaper.GetActiveTake(it) == dry and reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") == 1, "here the plug-in loads: the dry take plays through it")
  check(not prints.refresh(pa, it, media, "fxhash", nil, cfg), "up to date: nothing more to render")
  -- the other track: everyone has its plug-in, so no print, and nothing renders
  check(not prints.refresh(pa, other, media, "fxhash2", nil, cfg) and not require("bgrender").busy() and reaper.CountTakes(other) == 1, "no print where everyone has the plug-ins")
  -- playing the wet take: the track's FX held off here, and the band still sees them on
  reaper.SetExtState(band.SECTION, "midi_plays", "sound", false)
  prints.choose(it)
  check(reaper.GetActiveTake(it) == wet and reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") == 0, "Wet: the print plays, the track's FX held off (no +6 dB twice)")
  check(mirror.track_state(pa, tr).fxen == "1", "and the band's FX button still reads on (" .. tostring(mirror.track_state(pa, tr).fxen) .. ")")
  reaper.DeleteExtState(band.SECTION, "midi_plays", false)
  prints.choose(it)
  check(reaper.GetActiveTake(it) == dry and reaper.GetMediaTrackInfo_Value(tr, "I_FXEN") == 1 and band.track_ext(tr, prints.FXEN) == "", "back to Auto: dry again, FX back on")
  -- a routed MIDI print (notes on one track, the instrument on another) in the background, as in front
  reaper.InsertTrackInProject(pa, 2, 0); reaper.InsertTrackInProject(pa, 3, 0)
  local notes, kit = reaper.GetTrack(pa, 2), reaper.GetTrack(pa, 3)
  reaper.TrackFX_AddByName(kit, "ReaSynth", false, -1)
  local send = reaper.CreateTrackSend(notes, kit)
  reaper.SetTrackSendInfo_Value(notes, 0, send, "I_SRCCHAN", -1) -- (MIDI only)
  local mi = reaper.CreateNewMIDIItemInProj(notes, 0.5, 2.5, false)
  local mtk = reaper.GetActiveTake(mi)
  for i = 0, 3 do reaper.MIDI_InsertNote(mtk, false, false, i * 480, i * 480 + 400, 0, 60 + i, 100, true) end
  reaper.MIDI_Sort(mtk)
  reaper.GetSetMediaItemInfo_String(mi, "P_EXT:band_oid", "I-JAMES-20261101000000-3", true)
  local rfg = require("sync").print_routed(pa, mi, mtk, kit, media, "fg-routed")
  local t1, rdid = reaper.time_precise(), false
  while not rdid and reaper.time_precise() - t1 < 90 do
    rdid = prints.refresh(pa, mi, media, "fx", "route", cfg)
    if not rdid then local w = reaper.time_precise(); while reaper.time_precise() - w < 0.5 do end end
  end
  local rwet = select(2, prints.takes(mi))
  local rpath = rwet and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(rwet), "") or ""
  local d2, f2 = require("bgrender").counts()
  check(rdid and d2 == 2 and f2 == 0, string.format("a routed MIDI print renders in the background too (%.1f s; %d done, %d failed)", reaper.time_precise() - t1, d2, f2))
  local rp, fp = rpath ~= "" and peak(rpath) or -999, rfg and peak(rfg) or -999
  check(rp > -60 and math.abs(rp - fp) < 0.1, string.format("and sounds as the in-front one does (%.2f / %.2f dBFS peak)", rp, fp))
  -- SWS auto-colouring: off while a band song is in front, back on elsewhere
  if sws_id > 0 then
    if reaper.GetToggleCommandState(sws_id) ~= 1 then reaper.Main_OnCommand(sws_id, 0) end
    reaper.DeleteExtState(band.SECTION, "sws colour off", true)
    band.bind(pa, { role = "guest", song = "AudioLab", room = "main", root = root })
    band.sws_colours()
    check(reaper.GetToggleCommandState(sws_id) == 0, "SWS auto-colouring goes off with a band song in front")
    reaper.Main_OnCommand(40859, 0) -- (a plain tab in front)
    band.sws_colours()
    check(reaper.GetToggleCommandState(sws_id) == 1 and reaper.GetExtState(band.SECTION, "sws colour off") == "", "and back on with another project in front")
    reaper.Main_OnCommand(40860, 0)
    reaper.SelectProjectInstance(pa)
    reaper.Main_OnCommand(sws_id, 0) -- (switched off by hand, not by BandSync)
    reaper.Main_OnCommand(40859, 0); band.sws_colours(); reaper.Main_OnCommand(40860, 0)
    check(reaper.GetToggleCommandState(sws_id) == 0, "someone who switched it off themselves keeps it off")
    reaper.SetProjExtState(pa, band.SECTION, "song", "") -- (not a band song any more)
  else
    say("     (no SWS here: auto-colouring not tried)")
  end
end)
if not ok then say("ERROR " .. tostring(err)); fails = fails + 1 end
if sws_id > 0 and sws_was >= 0 and reaper.GetToggleCommandState(sws_id) ~= sws_was then reaper.Main_OnCommand(sws_id, 0) end
reaper.DeleteExtState(band.SECTION, "sws colour off", true)
if reaper.ValidatePtr2(0, pa, "ReaProject*") then
  reaper.SelectProjectInstance(pa)
  reaper.Main_SaveProjectEx(pa, D .. "/audio_prints.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")

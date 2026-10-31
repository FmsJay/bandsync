-- Run inside REAPER (ReaScript). The master track, automation items, ruler lanes, local solo, arriving-audio
-- placeholders and plug-in files, between two scratch tabs "James" (A) and "Bee" (B). Scratch folder and tabs only.
local D = reaper.GetResourcePath() .. "/BandSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json", "fxfiles" }) do package.loaded[m] = nil end
local band, sync, mirror = require("band"), require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/xroot_" .. stamp
local song, room = "MoreLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
local rdir = sync.room_dir(A, song, room)
reaper.RecursiveCreateDirectory(rdir .. "/events", 0)
local media = rdir .. "/media"
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function pass(p, cfg) reaper.SelectProjectInstance(p); local n = mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }); settle()
  return n + mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Synth", true)
  sync.watch_timeline(pa, A, song, room, yes); sync.watch_timeline(pb, B, song, room, yes) -- (first look: just noted)
  pass(pa, A); recv(pb, B)
  local btr = mirror.find(pb, "track", mirror.track_oid(tr))
  check(btr ~= nil, "B has the track")

  -- 1. solo is each person's own
  reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 1)
  check(pass(pa, A) == 0, "soloing a track sends nothing")
  reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", 0)

  -- 2. the master: a plug-in and its volume automation travel; its fader doesn't; a live link (ReaNINJAM stand-in) stays
  local mA, mB = reaper.GetMasterTrack(pa), reaper.GetMasterTrack(pb)
  reaper.TrackFX_AddByName(mA, "ReaLimit", false, -1)
  reaper.SetMediaTrackInfo_Value(mA, "D_VOL", 0.5)
  local _, mch = reaper.GetTrackStateChunk(mA, "", false)
  reaper.SetTrackStateChunk(mA, (mch:gsub("\n>%s*$", "\n<VOLENV2\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 4 0.5 0\n>\n>\n")), false)
  reaper.SelectProjectInstance(pb)
  reaper.TrackFX_AddByName(mB, "ReaEQ", false, -1) -- (stands in for B's live link: renamed below so live_fx sees it)
  reaper.TrackFX_SetNamedConfigParm(mB, 0, "renamed_name", "ReaNINJAM (stand-in)")
  check(mirror.live_fx(mB)[reaper.TrackFX_GetFXGUID(mB, 0)] == true, "B's live link is recognised by name")
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  local names = {}
  for i = 0, reaper.TrackFX_GetCount(mB) - 1 do names[#names + 1] = select(2, reaper.TrackFX_GetFXName(mB, i, "")) end
  check(#names == 2 and table.concat(names, ","):find("ReaLimit", 1, true) and table.concat(names, ","):find("stand%-in"), "B's master: the band's limiter, and its own live link kept (" .. table.concat(names, ", ") .. ")")
  check(math.abs(reaper.GetMediaTrackInfo_Value(mB, "D_VOL") - 1) < 1e-6, "B's master fader stays B's")
  local menv = reaper.GetTrackEnvelopeByChunkName(mB, "<VOLENV2")
  check(menv and reaper.CountEnvelopePoints(menv) == 2, "B's master has the band's volume automation")
  do -- what A sent for the master's chain, against what B holds (without its live link)
    local _, _, fev = mirror.known(pa, "F-MASTER")
    local sent = (band.read_json(rdir .. "/events/" .. tostring(fev) .. ".json") or {}).state or ""
    local _, bch = reaper.GetTrackStateChunk(mB, "", false)
    local here = mirror.fxchain(bch, mirror.live_fx(mB)) or ""
    local raw, on = {}, false
    for l in bch:gmatch("[^\n]+") do
      local s = l:match("^%s*(.-)%s*$")
      if s == "<FXCHAIN" then on = true end
      if on and (s:match("^BYPASS") or s:match("^FXID") or s:match("^<") or s == ">") then raw[#raw + 1] = s:sub(1, 50) end
    end
    out[#out + 1] = "  B master raw: " .. table.concat(raw, " | ")
    local live = {}
    for g in pairs(mirror.live_fx(mB)) do live[#live + 1] = g end
    out[#out + 1] = "  live: " .. table.concat(live, ",")
    if here ~= sent then
      local la, lb = {}, {}
      for l in sent:gmatch("[^\n]+") do la[#la + 1] = l end
      for l in here:gmatch("[^\n]+") do lb[#lb + 1] = l end
      for i = 1, math.max(#la, #lb) do if la[i] ~= lb[i] then out[#out + 1] = string.format("  master line %d sent: %s | here: %s", i, tostring(la[i]):sub(1, 80), tostring(lb[i]):sub(1, 80)) end end
    end
    check(here == sent, "B's master chain is what A sent")
  end
  check(pass(pb, B) == 0, "B sends nothing back (its live link isn't part of the master's chain)")

  -- 3. an automation item on the track's volume envelope
  reaper.SelectProjectInstance(pa)
  local _, tch = reaper.GetTrackStateChunk(tr, "", false)
  reaper.SetTrackStateChunk(tr, (tch:gsub("\n>%s*$", "\n<VOLENV2\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\n>\n>\n")), false)
  local env = reaper.GetTrackEnvelopeByChunkName(tr, "<VOLENV2")
  local pool = 0
  local ai = reaper.InsertAutomationItem(env, 1000 + (stamp % 1000), 2, 2)
  reaper.InsertEnvelopePointEx(env, ai, 2, 0.2, 0, 0, false, true)
  reaper.InsertEnvelopePointEx(env, ai, 3, 0.8, 0, 0, false, true)
  reaper.Envelope_SortPointsEx(env, ai)
  reaper.GetSetAutomationItemInfo(env, ai, "D_AMPLITUDE", 0.5, true)
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  local benv = reaper.GetTrackEnvelopeByChunkName(btr, "<VOLENV2")
  local n = benv and reaper.CountAutomationItems(benv) or 0
  check(n == 1, "B's envelope has the automation item (" .. n .. ")")
  if n == 1 then
    check(math.abs(reaper.GetSetAutomationItemInfo(benv, 0, "D_POSITION", 0, false) - 2) < 1e-6 and
      math.abs(reaper.GetSetAutomationItemInfo(benv, 0, "D_AMPLITUDE", 0, false) - 0.5) < 1e-6, "at 2 s, amplitude 50%")
    check(reaper.CountEnvelopePointsEx(benv, 0) == 2, "with its 2 points (" .. reaper.CountEnvelopePointsEx(benv, 0) .. ")")
  end
  check(pass(pb, B) == 0, "B sends nothing back after the automation item")
  pool = pool

  -- 4. ruler lanes and a marker in one (the driver's)
  reaper.SelectProjectInstance(pa)
  reaper.GetSetProjectInfo(pa, "RULER_LANE_COUNT", 3, true)
  reaper.GetSetProjectInfo_String(pa, "RULER_LANE_NAME:2", "Lyrics", true)
  reaper.AddProjectMarker2(pa, false, 4, 0, "chorus line", -1, 0)
  local mk = reaper.GetRegionOrMarker(pa, 0, "")
  reaper.SetRegionOrMarkerInfo_Value(pa, mk, "I_LANENUMBER", 2)
  sync.watch_timeline(pa, A, song, room, yes)
  recv(pb, B)
  check(select(2, reaper.GetSetProjectInfo_String(pb, "RULER_LANE_NAME:2", "", false)) == "Lyrics", "B has the Lyrics ruler lane")
  local bm = reaper.GetRegionOrMarker(pb, 0, "")
  check(bm and reaper.GetRegionOrMarkerInfo_Value(pb, bm, "I_LANENUMBER") == 2, "B's marker sits in it")

  -- 5. a recording whose audio hasn't arrived: a grey stand-in, then the real item
  local wav = D .. "/arrive_" .. stamp .. ".wav"
  reaper.SelectProjectInstance(pa)
  local it = reaper.AddMediaItemToTrack(tr)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 8)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 1)
  do -- a second of 48 kHz 16-bit mono silence with one click
    local n = 48000
    local data = { string.rep("\0", 2 * n) }
    local f = assert(io.open(wav, "wb"))
    f:write("RIFF", string.pack("<I4", 36 + 2 * n), "WAVEfmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, 48000, 96000, 2, 16),
      "data", string.pack("<I4", 2 * n), "\255\127", data[1]:sub(3))
    f:close()
  end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, src)
  pass(pa, A)
  -- the event as it would be while its audio is still syncing: it names a file that isn't in the room yet (renaming
  -- the real copy won't do: tab A is playing it, so Windows won't let it go)
  local ioid = mirror.item_oid(it)
  local _, _, kev = mirror.known(pa, ioid)
  local epath = rdir .. "/events/" .. tostring(kev) .. ".json"
  local ev = band.read_json(epath)
  local late = "late-" .. stamp .. ".wav"
  ev.state, ev.hash = ev.state:gsub('FILE "{media:main}/[^"]+"', 'FILE "{media:main}/' .. late .. '"'), nil
  band.write_json(epath, ev)
  recv(pb, B)
  local stand = mirror.find(pb, "item", ioid)
  check(stand ~= nil and select(2, reaper.GetSetMediaItemInfo_String(stand, "P_EXT:band_arriving", "", false)) == "1", "B shows a stand-in while the audio is on its way")
  check(stand and math.abs(reaper.GetMediaItemInfo_Value(stand, "D_POSITION") - 8) < 1e-6, "at its place")
  check(pass(pb, B) == 0, "the stand-in isn't sent")
  band.copy_atomic(wav, media .. "/" .. late) -- (it lands)
  recv(pb, B)
  local real = mirror.find(pb, "item", ioid)
  check(real and select(2, reaper.GetSetMediaItemInfo_String(real, "P_EXT:band_arriving", "", false)) == "" and reaper.GetActiveTake(real) ~= nil,
    "the real item replaced it when the audio landed")
  wav = wav
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/more_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

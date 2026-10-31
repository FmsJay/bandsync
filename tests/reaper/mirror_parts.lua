-- Run inside REAPER (ReaScript). Automation envelopes and receives between two scratch tabs: "James" (A) and "Bee" (B).
-- Scratch folder and scratch tabs only; both tabs are saved to the scratch folder and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests" -- scratch: never the shared folder
reaper.RecursiveCreateDirectory(D, 0)
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "recall", "json" }) do package.loaded[m] = nil end
local sync, mirror = require("sync"), require("mirror")
local stamp = os.time()
local root = D .. "/proot_" .. stamp
local song, room = "PartsLab", "main"
local A, B = { user = "James", root = root }, { user = "Bee", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local yes = function() return true end
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function settle() for _, f in pairs(mirror.fx_seen) do f.since = -math.huge end end
local function pass(p, cfg) local n = mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }); settle()
  return n + mirror.watch(p, cfg, song, room, { can = yes, mode = "claims" }) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); local n = 0; -- (in front, as when someone switches to it)
   for _ = 1, 3 do n = n + sync.receive(p, cfg, song, room, yes) end; return n end
local function track(p, name)
  for i = 0, reaper.CountTracks(p) - 1 do
    local t = reaper.GetTrack(p, i)
    if select(2, reaper.GetTrackName(t)) == name then return t end
  end
end
local function vol_env(t) return reaper.GetTrackEnvelopeByChunkName(t, "<VOLENV2") end
local function src_name(t, i) return select(2, reaper.GetTrackName(reaper.GetTrackSendInfo_Value(t, -1, i, "P_SRCTRACK"))) end
local front = reaper.EnumProjects(-1)
local pa, pb
local ok, err = pcall(function()
  reaper.Main_OnCommand(40859, 0); pa = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0); pb = reaper.EnumProjects(-1)
  for i, n in ipairs({ "Drums", "Bass", "Keys" }) do
    reaper.InsertTrackInProject(pa, i - 1, 0)
    reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, i - 1), "P_NAME", n, true)
  end
  local bass, keys = track(pa, "Bass"), track(pa, "Keys")
  sync.watch_timeline(pa, A, song, room, yes); sync.watch_timeline(pb, B, song, room, yes) -- (first look: just noted)
  -- a volume envelope on Bass, and Keys hearing Bass at half level
  local _, ch = reaper.GetTrackStateChunk(bass, "", false)
  ch = ch:gsub("\n>%s*$", "\n<VOLENV2\nACT 1 -1\nVIS 1 1 1\nLANEHEIGHT 0 0\nARM 0\nDEFSHAPE 0 -1 -1\nPT 0 1 0\nPT 2 0.5 0\n>\n>\n")
  reaper.SetTrackStateChunk(bass, ch, false)
  local s = reaper.CreateTrackSend(bass, keys)
  reaper.SetTrackSendInfo_Value(bass, 0, s, "D_VOL", 0.5)
  check(vol_env(bass) and reaper.CountEnvelopePoints(vol_env(bass)) == 2, "A: Bass has its 2-point volume envelope")
  out[#out + 1] = "A sent " .. pass(pa, A)
  out[#out + 1] = "B applied " .. recv(pb, B)
  local bb, bk = track(pb, "Bass"), track(pb, "Keys")
  check(bb and vol_env(bb) and reaper.CountEnvelopePoints(vol_env(bb)) == 2, "B: Bass got the volume envelope")
  check(bk and reaper.GetTrackNumSends(bk, -1) == 1 and src_name(bk, 0) == "Bass", "B: Keys receives from Bass")
  check(bk and math.abs(reaper.GetTrackSendInfo_Value(bk, -1, 0, "D_VOL") - 0.5) < 1e-6, "B: at half level")
  -- B draws a point; it reaches A
  reaper.InsertEnvelopePoint(vol_env(bb), 3, 0.25, 0, 0, false, true); reaper.Envelope_SortPoints(vol_env(bb))
  out[#out + 1] = "B sent " .. pass(pb, B)
  recv(pa, A)
  check(reaper.CountEnvelopePoints(vol_env(bass)) == 3, "A: B's new point arrived (" .. reaper.CountEnvelopePoints(vol_env(bass)) .. ")")
  -- B has a track of its own at the top (positions differ now) and its own receive into Keys from it
  reaper.InsertTrackInProject(pb, 0, 0)
  local mine = reaper.GetTrack(pb, 0)
  reaper.GetSetMediaTrackInfo_String(mine, "P_NAME", "Bee only", true)
  reaper.GetSetMediaTrackInfo_String(mine, "P_EXT:band_local", "yours", true)
  reaper.CreateTrackSend(mine, bk)
  -- A changes the receive's level: B applies it to the right source, and keeps its own receive
  reaper.SetTrackSendInfo_Value(keys, -1, 0, "D_VOL", 0.25)
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  local names, lvl = {}, nil
  for i = 0, reaper.GetTrackNumSends(bk, -1) - 1 do
    names[#names + 1] = src_name(bk, i)
    if src_name(bk, i) == "Bass" then lvl = reaper.GetTrackSendInfo_Value(bk, -1, i, "D_VOL") end
  end
  check(#names == 2, "B: Keys has the band's receive and its own (" .. table.concat(names, ",") .. ")")
  check(lvl and math.abs(lvl - 0.25) < 1e-6, "B: the band's receive is from Bass, at the new level (" .. tostring(lvl) .. ")")
  check(pass(pb, B) == 0, "B: nothing to send back (no echo)")
  -- more of a track (channels, width, FX button, timebase), its groups, lock and note names, and the project's settings
  reaper.SelectProjectInstance(pa) -- (A's own chunk edit below: in front, as anyone editing is)
  reaper.SetMediaTrackInfo_Value(keys, "I_NCHAN", 4)
  reaper.SetMediaTrackInfo_Value(keys, "D_WIDTH", 0.5)
  reaper.SetMediaTrackInfo_Value(keys, "I_FXEN", 0)
  reaper.SetMediaTrackInfo_Value(keys, "C_BEATATTACHMODE", 1)
  reaper.GetSetTrackGroupMembership(keys, "VOLUME_LEAD", 1, 1)
  reaper.SetTrackMIDINoteNameEx(pa, keys, 36, -1, "Kick")
  local _, kc = reaper.GetTrackStateChunk(keys, "", false)
  reaper.SetTrackStateChunk(keys, (kc:gsub("\nNAME ", "\nLOCK 1\nNAME ", 1)), false)
  reaper.GetSetProjectInfo_String(pa, "PROJECT_TITLE", "Parts song", true)
  reaper.GetSetProjectNotes(pa, true, "verse twice")
  reaper.SNM_SetIntConfigVarEx(pa, "itemtimelock", 0)
  sync.watch_timeline(pa, A, song, room, yes)
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  check(reaper.GetMediaTrackInfo_Value(bk, "I_NCHAN") == 4 and reaper.GetMediaTrackInfo_Value(bk, "D_WIDTH") == 0.5, "B: Keys has 4 channels, width 50%")
  check(reaper.GetMediaTrackInfo_Value(bk, "I_FXEN") == 0 and reaper.GetMediaTrackInfo_Value(bk, "C_BEATATTACHMODE") == 1, "B: Keys's FX button off, timebase beats")
  check(reaper.GetSetTrackGroupMembership(bk, "VOLUME_LEAD", 0, 0) & 1 == 1, "B: Keys leads volume group 1")
  check(reaper.GetTrackMIDINoteNameEx(pb, bk, 36, -1) == "Kick", "B: Keys's note 36 is called Kick (" .. tostring(reaper.GetTrackMIDINoteNameEx(pb, bk, 36, -1)) .. ")")
  local _, bkc = reaper.GetTrackStateChunk(bk, "", false)
  check(bkc:find("\nLOCK 1", 1, true) ~= nil, "B: Keys is locked")
  check(select(2, reaper.GetSetProjectInfo_String(pb, "PROJECT_TITLE", "", false)) == "Parts song" and reaper.GetSetProjectNotes(pb, false, "") == "verse twice",
    "B: the project's title and notes")
  check(reaper.SNM_GetIntConfigVarEx(pb, "itemtimelock", -1) == 0, "B: the project's timebase")
  check(pass(pb, B) == 0, "B: nothing of that to send back")
  -- A removes the receive and the envelope
  -- (B's envelope change was written into A's Bass chunk: its send must still be linked; a track chunk written in a
  -- tab behind used to leave "Bass sends 0, Keys receives 1")
  check(reaper.GetTrackNumSends(bass, 0) == 1 and reaper.GetTrackNumSends(keys, -1) == 1, "A: the send is still linked after B's change landed")
  check(reaper.RemoveTrackSend(keys, -1, 0), "A: Keys's receive from Bass removed")
  local _, c2 = reaper.GetTrackStateChunk(bass, "", false)
  reaper.SetTrackStateChunk(bass, (c2:gsub("<VOLENV2.-\n>\n", "", 1)), false)
  out[#out + 1] = "A sent " .. pass(pa, A)
  recv(pb, B)
  check(reaper.GetTrackNumSends(bk, -1) == 1 and src_name(bk, 0) == "Bee only", "B: the band's receive went, B's own stayed")
  check(not vol_env(bb) or reaper.CountEnvelopePoints(vol_env(bb)) == 0, "B: the envelope went")
  local oa = select(2, mirror.scan(pa, "x", sync.room_dir(A, song, room) .. "/media"))
  local ob = select(2, mirror.scan(pb, "x", sync.room_dir(A, song, room) .. "/media"))
  local diff = {}
  for oid, o in pairs(oa) do if not ob[oid] or ob[oid].hash ~= o.hash then diff[#diff + 1] = oid end end
  check(#diff == 0, "both tabs hold the same project (" .. table.concat(diff, ",") .. ")")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
for _, p in pairs({ pa, pb }) do
  if reaper.ValidatePtr2(0, p, "ReaProject*") then
    reaper.SelectProjectInstance(p)
    reaper.Main_SaveProjectEx(p, D .. "/parts_" .. stamp .. "_end.rpp", 8)
    reaper.Main_OnCommand(40860, 0)
  end
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

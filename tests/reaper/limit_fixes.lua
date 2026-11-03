-- Run inside REAPER (ReaScript). What limit testing broke (0.42.3): deleting a bandmate's track brings it back with its
-- items; a track only moved in the list isn't reported as put back; Hold renders no prints; a stuck job doesn't render in
-- front. Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json", "bgrender" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, sync, mirror, prints, bg = require("band"), require("sync"), require("mirror"), require("prints"), require("bgrender")
local root = D .. "/lroot_" .. os.time()
local song, room = "LimitLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/events", 0)
local events = sync.room_dir(A, song, room) .. "/events"
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function sent(who) local n = 0; for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end; return n end
local yes = function() return true end
local only_laptop = function(u) return u == "Laptop" end
local front = reaper.EnumProjects(-1)
local was_bg, was_put = reaper.GetExtState(band.SECTION, "bg render"), reaper.GetExtState(band.SECTION, "put back")
reaper.SetExtState(band.SECTION, "bg render", "off", false)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
sync.driver_name = "Laptop"
local function watch(p, cfg, can, hold) reaper.SelectProjectInstance(p); return (mirror.watch(p, cfg, song, room, { can = can or yes, mode = "claims", here = { Laptop = true }, hold = hold })) end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function put_back_n() return (band.json_decode(reaper.GetExtState(band.SECTION, "put back")) or {}).n or 0 end
local ok, err = pcall(function()
  reaper.SelectProjectInstance(pa)
  local function add(i, name)
    reaper.InsertTrackInProject(pa, i, 0)
    local tr = reaper.GetTrack(pa, i)
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
    return tr
  end
  local t1, t2, t3 = add(0, "One"), add(1, "Two"), add(2, "Three")
  reaper.TrackFX_AddByName(t2, "ReaSynth", false, -1)
  local it = reaper.CreateNewMIDIItemInProj(t2, 0, 2, false)
  local tk = reaper.GetActiveTake(it)
  for n = 0, 3 do reaper.MIDI_InsertNote(tk, false, false, n * 480, n * 480 + 400, 0, 50 + n, 100, true) end
  reaper.MIDI_Sort(tk)
  watch(pa, A); hold(3.2); watch(pa, A); watch(pa, A)
  recv(pb, B)
  check(reaper.CountTracks(pb) == 3 and reaper.CountTrackMediaItems(reaper.GetTrack(pb, 1)) == 1, "the bandmate has the tracks and the item")

  -- deleting a bandmate's track: it comes back with its item, and nothing goes out
  local n0 = sent("James")
  reaper.SelectProjectInstance(pb)
  reaper.DeleteTrack(reaper.GetTrack(pb, 1))
  check(reaper.CountTracks(pb) == 2, "deleted here")
  local pb0 = put_back_n()
  local t = reaper.time_precise()
  while reaper.time_precise() - t < 6 do watch(pb, B, only_laptop); hold(0.3) end -- (its plug-ins settle first, as any chain does)
  local back
  for i = 0, reaper.CountTracks(pb) - 1 do
    if select(2, reaper.GetTrackName(reaper.GetTrack(pb, i))) == "Two" then back = reaper.GetTrack(pb, i) end
  end
  check(back ~= nil, "their track came back")
  check(back and reaper.CountTrackMediaItems(back) == 1, "with its item, not without")
  check(back and reaper.TrackFX_GetCount(back) == 1, "and its plug-ins")
  local what = {}
  for _, f in ipairs(band.files(events, ".json")) do
    if f:sub(1, 6) == "James-" then
      local e = band.read_json(events .. "/" .. f)
      what[#what + 1] = tostring(e and e.obj) .. " " .. tostring(e and e.name) .. (e and e.gone and " gone" or "")
    end
  end
  local tracks_sent = table.concat(what, ", "):find("track") or table.concat(what, ", "):find("gone")
  check(not tracks_sent, "and nothing of theirs was deleted or changed by it: " .. table.concat(what, ", "))
  recv(pa, A) -- (the bandmate printed it again, its chain not back yet: that lands here)
  local rb, ra = mirror.root(pb), mirror.root(pa)
  local function differs()
    local function all(pj)
      local t, i = {}, 0
      while true do
        local ok, oid, v = reaper.EnumProjExtState(pj, mirror.SEC, i)
        if not ok then return t end
        i = i + 1; t[oid:upper()] = v
      end
    end
    local x, y, o = all(pb), all(pa), {}
    for k, v in pairs(x) do if y[k] ~= v then o[#o + 1] = k .. " B=" .. v .. " A=" .. tostring(y[k]) end end
    for k, v in pairs(y) do if x[k] == nil then o[#o + 1] = k .. " B=nil A=" .. v end end
    return table.concat(o, "; ")
  end
  check(rb == ra, "both on the same fingerprint" .. (rb == ra and "" or ": " .. differs()))
  -- the track under it only moved in the list and back: said once for the track, not for the ones it moved
  check(put_back_n() - pb0 <= 5, "put-back notices stayed about what was deleted (track, item, its parts): " .. (put_back_n() - pb0))

  -- tracks moved by a put-back don't go out, and nothing goes round for good
  do
    reaper.SelectProjectInstance(pb)
    reaper.InsertTrackInProject(pb, 1, 0)
    local mine = reaper.GetTrack(pb, 1)
    reaper.GetSetMediaTrackInfo_String(mine, "P_NAME", "Mine", true)
    local can = function(u, name) return u == "Laptop" or name == "Mine" end
    for _ = 1, 3 do watch(pb, B, can) end
    -- a bandmate's track moved here: it's put back, which shifts mine
    reaper.SetOnlyTrackSelected(reaper.GetTrack(pb, 0))
    reaper.ReorderSelectedTracks(reaper.CountTracks(pb), 0)
    local n1 = sent("James")
    for _ = 1, 6 do watch(pb, B, can); hold(0.1) end
    local n2 = sent("James")
    for _ = 1, 10 do watch(pb, B, can); hold(0.1) end
    check(sent("James") == n2, string.format("then it stops: %d sent settling, 0 after", n2 - n1))
    -- moving my own track myself still goes out
    reaper.SetOnlyTrackSelected(mine)
    reaper.ReorderSelectedTracks(reaper.CountTracks(pb), 0)
    local n3 = sent("James")
    watch(pb, B, can)
    check(sent("James") > n3, "moving my own track still goes out")
    for _ = 1, 3 do watch(pb, B, can) end
    recv(pa, A)
    local names = {}
    for i = 0, reaper.CountTracks(pa) - 1 do names[#names + 1] = select(2, reaper.GetTrackName(reaper.GetTrack(pa, i))) end
    check(names[#names] == "Mine", "and the bandmate's list follows: " .. table.concat(names, ","))
  end

  -- plug-ins added to someone else's track, that have never gone out: said once, not every look
  do
    reaper.SelectProjectInstance(pb)
    local other
    for i = 0, reaper.CountTracks(pb) - 1 do
      if select(2, reaper.GetTrackName(reaper.GetTrack(pb, i))) == "Three" then other = reaper.GetTrack(pb, i) end
    end
    reaper.TrackFX_AddByName(other, "ReaEQ", false, -1)
    local before = put_back_n()
    local t0 = reaper.time_precise()
    while reaper.time_precise() - t0 < 5 do watch(pb, B, only_laptop); hold(0.3) end
    check(put_back_n() - before <= 1, "a chain that isn't theirs to send is put back or noted once: " .. (put_back_n() - before))
  end

  -- a track's volume automation isn't baked into its print
  do
    reaper.SelectProjectInstance(pa)
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local te = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.TrackFX_AddByName(te, "ReaSynth", false, -1)
    local ie = reaper.CreateNewMIDIItemInProj(te, 0, 2, false)
    local tke = reaper.GetActiveTake(ie)
    for n = 0, 3 do reaper.MIDI_InsertNote(tke, false, false, n * 480, n * 480 + 400, 0, 60 + n, 110, true) end
    reaper.MIDI_Sort(tke)
    local media = sync.room_dir(A, song, room) .. "/media"
    reaper.RecursiveCreateDirectory(media, 0)
    local plain = sync.print_item(pa, ie, tke, media, "env-plain", nil, false, true)
    reaper.SetOnlyTrackSelected(te)
    reaper.Main_OnCommand(40406, 0) -- Track: Toggle track volume envelope visible
    local env = reaper.GetTrackEnvelopeByName(te, "Volume")
    reaper.InsertEnvelopePoint(env, 0, 10, 0, 0, false, true)
    reaper.InsertEnvelopePoint(env, 3, 10, 0, 0, false, true)
    reaper.Envelope_SortPoints(env)
    local _, before_chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    local withenv = sync.print_item(pa, ie, tke, media, "env-auto", nil, false, true)
    local _, after_chunk = reaper.GetEnvelopeStateChunk(env, "", false)
    local a, c = band.size(plain), band.size(withenv)
    check(a and c and math.abs(a - c) < a * 0.1, string.format("automation stays out of a print (%d and %d bytes)", a or 0, c or 0))
    check(before_chunk == after_chunk, "and the envelope is as it was")
    reaper.DeleteTrack(te)
  end

  -- a comp on a part with a wet take becomes lanes
  do
    reaper.SelectProjectInstance(pa)
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local tc = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.GetSetMediaTrackInfo_String(tc, "P_NAME", "Comp", true)
    reaper.TrackFX_AddByName(tc, "ReaSynth", false, -1)
    local ic = reaper.CreateNewMIDIItemInProj(tc, 0, 2, false)
    local t1 = reaper.GetActiveTake(ic)
    reaper.MIDI_InsertNote(t1, false, false, 0, 400, 0, 60, 110, true); reaper.MIDI_Sort(t1)
    watch(pa, A); hold(3.2); watch(pa, A); watch(pa, A); watch(pa, A)
    local _, wet = prints.takes(ic)
    check(wet ~= nil, "the part has its wet take")
    local t2 = reaper.AddTakeToMediaItem(ic)
    reaper.SetMediaItemTake_Source(t2, reaper.GetMediaItemTake_Source(t1))
    reaper.SetActiveTake(t2)
    local d = prints.takes_to_lanes(pa, function() return true end)
    check(d == 1 and reaper.GetMediaTrackInfo_Value(tc, "I_FREEMODE") == 2, "taken into lanes though it has a wet take")
    local n_items = reaper.CountTrackMediaItems(tc)
    check(n_items >= 2, "one item per take: " .. n_items)
    -- comping again elsewhere on the track mustn't silence the rest of it
    local function playing_lanes()
      local t = {}
      for l = 0, reaper.GetMediaTrackInfo_Value(tc, "I_NUMFIXEDLANES") - 1 do
        if reaper.GetMediaTrackInfo_Value(tc, "C_LANEPLAYS:" .. l) > 0 then t[#t + 1] = l end
      end
      return t
    end
    local before_lanes = playing_lanes()
    local lanes0 = reaper.GetMediaTrackInfo_Value(tc, "I_NUMFIXEDLANES")
    local played = 0
    for j = 0, reaper.CountTrackMediaItems(tc) - 1 do
      if reaper.GetMediaItemInfo_Value(reaper.GetTrackMediaItem(tc, j), "I_FIXEDLANE") == before_lanes[1] then played = played + 1 end
    end
    local i2 = reaper.CreateNewMIDIItemInProj(tc, 10, 12, false)
    local a1 = reaper.GetActiveTake(i2)
    reaper.MIDI_InsertNote(a1, false, false, 0, 400, 0, 62, 110, true); reaper.MIDI_Sort(a1)
    reaper.SetMediaItemInfo_Value(i2, "I_FIXEDLANE", before_lanes[1])
    local a2 = reaper.AddTakeToMediaItem(i2)
    reaper.SetMediaItemTake_Source(a2, reaper.GetMediaItemTake_Source(a1))
    reaper.SetActiveTake(a2)
    prints.takes_to_lanes(pa, function() return true end)
    local after_lanes = playing_lanes()
    check(#after_lanes == 1 and reaper.GetSetMediaTrackInfo_String(tc, "P_LANENAME:" .. after_lanes[1], "", false) and
      select(2, reaper.GetSetMediaTrackInfo_String(tc, "P_LANENAME:" .. after_lanes[1], "", false)) == "C1", "comping again: C1 still plays alone: " .. table.concat(after_lanes, ","))
    local now_played, at10 = 0, false
    for j = 0, reaper.CountTrackMediaItems(tc) - 1 do
      local x = reaper.GetTrackMediaItem(tc, j)
      if after_lanes[1] and reaper.GetMediaItemInfo_Value(x, "I_FIXEDLANE") == after_lanes[1] then
        now_played = now_played + 1
        if math.abs(reaper.GetMediaItemInfo_Value(x, "D_POSITION") - 10) < 0.01 then at10 = true end
      end
    end
    check(now_played == played + 1 and at10, string.format("and holds the old part and the new one (%d, was %d)", now_played, played))
    reaper.DeleteTrack(tc)
    watch(pa, A); watch(pa, A)
  end

  -- a part that lands before its plug-ins: its take is chosen again when they do
  do
    reaper.SelectProjectInstance(pb)
    local tr
    for i = 0, reaper.CountTracks(pb) - 1 do
      if select(2, reaper.GetTrackName(reaper.GetTrack(pb, i))) == "Two" then tr = reaper.GetTrack(pb, i) end
    end
    local it2 = reaper.GetTrackMediaItem(tr, 0)
    local mid, wet = prints.takes(it2)
    reaper.SetActiveTake(mid)
    local oid = "F" .. mirror.track_oid(tr):sub(2)
    local chain = '<FXCHAIN\nBYPASS 0 0 0\n<VST "VST3i: Nobody Has This (Nobody)" "Nobody Has This.vst3" 0 "" 123456789{ABCDEF0123456789ABCDEF0123456789} ""\nAAAAAAAAAAAA\n>\nWAK 0 0\n>\n'
    mirror.apply(pb, { obj = "fx", oid = oid, track = mirror.track_oid(tr), state = chain, hash = "abcd1234" }, sync.room_dir(B, song, room) .. "/media", false)
    check(reaper.GetActiveTake(it2) == wet, "plug-ins it can't load land: the part plays its wet take")
    local rev0, h0 = mirror.known(pb, oid)
    local n5 = sent("James")
    local t5 = reaper.time_precise()
    while reaper.time_precise() - t5 < 1 do watch(pb, B, only_laptop); hold(0.2) end
    check(sent("James") == n5, "and nothing goes out for it")
  end

  -- going back keeps what a bandmate added since, and what you removed you can bring back
  do
    reaper.SelectProjectInstance(pb)
    reaper.InsertTrackInProject(pb, reaper.CountTracks(pb), 0)
    local jt = reaper.GetTrack(pb, reaper.CountTracks(pb) - 1)
    reaper.GetSetMediaTrackInfo_String(jt, "P_NAME", "James new", true)
    local ji = reaper.CreateNewMIDIItemInProj(jt, 40, 42, false)
    reaper.MIDI_InsertNote(reaper.GetActiveTake(ji), false, false, 0, 400, 0, 60, 100, true)
    local can_james = function(u) return u == "Laptop" or u == "James" end
    watch(pb, B, can_james); watch(pb, B, can_james)
    recv(pa, A)
    local toid, ioid = mirror.track_oid(jt), select(2, reaper.GetSetMediaItemInfo_String(ji, "P_EXT:band_oid", "", false))
    reaper.SelectProjectInstance(pa)
    local msg = mirror.revert(pa, A, song, room, { [toid] = false, [ioid] = false }, { can = yes, mode = "claims" })
    check(mirror.find(pa, "track", toid) ~= nil and mirror.find(pa, "item", ioid) ~= nil, "the driver going back keeps a bandmate's new track and item")
    check(msg:find("kept what collaborators added", 1, true) ~= nil and msg:find("James new", 1, true) ~= nil, "and says so: " .. msg)
    -- my own, gone by going back, comes back though someone's claim now stands
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local lt = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.GetSetMediaTrackInfo_String(lt, "P_NAME", "Laptop new", true)
    watch(pa, A); watch(pa, A)
    local loid = mirror.track_oid(lt)
    local _, _, levid = mirror.known(pa, loid)
    local lev = band.read_json(events .. "/" .. levid .. ".json")
    mirror.revert(pa, A, song, room, { [loid] = false }, { can = yes, mode = "claims" })
    check(mirror.find(pa, "track", loid) == nil, "my own new track goes when I go back")
    local nobody = function() return false end
    mirror.revert(pa, A, song, room, { [loid] = lev }, { can = nobody, mode = "claims" })
    check(mirror.find(pa, "track", loid) ~= nil, "and forward brings it back, even if a claim says otherwise now")
    watch(pa, A); recv(pb, B)
  end

  -- a track back from being gone, its plug-ins not here yet: "none" isn't a change of this machine's
  do
    reaper.SelectProjectInstance(pa)
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local gt = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.GetSetMediaTrackInfo_String(gt, "P_NAME", "Gone and back", true)
    reaper.TrackFX_AddByName(gt, "ReaEQ", false, -1)
    watch(pa, A); hold(3.2); watch(pa, A); watch(pa, A)
    recv(pb, B)
    local oid, foid = mirror.track_oid(gt), "F" .. mirror.track_oid(gt):sub(2)
    check(mirror.find(pb, "track", oid) and reaper.TrackFX_GetCount(mirror.find(pb, "track", oid)) == 1, "the bandmate has the track and its plug-in")
    local _, _, tev = mirror.known(pa, oid)
    local tstate = band.read_json(events .. "/" .. tev .. ".json")
    -- going back takes both; forward brings the track, and its plug-ins haven't landed yet when the bandmate next looks
    reaper.SelectProjectInstance(pa)
    mirror.revert(pa, A, song, room, { [oid] = false, [foid] = false }, { can = yes, mode = "claims" })
    recv(pb, B)
    check(mirror.find(pb, "track", oid) == nil, "gone for the bandmate")
    reaper.SelectProjectInstance(pa)
    mirror.revert(pa, A, song, room, { [oid] = tstate }, { can = yes, mode = "claims" })
    recv(pb, B)
    check(mirror.find(pb, "track", oid) ~= nil, "back for the bandmate")
    mirror.unsent[tostring(pb) .. foid] = true -- (as a burst leaves it)
    for _ = 1, 3 do watch(pb, B, yes); hold(0.1) end
    check(mirror.unsent[tostring(pb) .. foid] == nil, "nothing of ours waits, so the band's chain can land")
    local empty = false
    for _, f in ipairs(band.files(events, ".json")) do
      if f:sub(1, 6) == "James-" then
        local e = band.read_json(events .. "/" .. f)
        if e and e.obj == "fx" and e.state == "" and e.oid == foid then empty = true end
      end
    end
    check(not empty, "no empty chain goes out for a track just back")
  end

  -- going back the whole song brings the tempo too
  do
    reaper.SelectProjectInstance(pa)
    local was = band.capture_tempo(pa)
    reaper.SetCurrentBPM(pa, 77, false)
    local changed = sync.restore_timeline(pa, A, song, room, { { kind = "timeline", tempo = was, markers = {} } }, 1, nil)
    check(changed and math.abs(reaper.TimeMap2_GetDividedBpmAtTime(pa, 0) - 77) > 1, "the tempo goes back with the whole song")
  end

  -- Hold my changes renders nothing
  reaper.SelectProjectInstance(pa)
  local _, p0 = prints.takes(it)
  local k0 = p0 and select(2, reaper.GetSetMediaItemTakeInfo_String(p0, "P_EXT:" .. prints.KEY, "", false)) or ""
  local _, _, m, a, b2, c, _, v = reaper.MIDI_GetNote(tk, 0)
  reaper.MIDI_SetNote(tk, 0, false, m, a, b2, c, 70, v, false)
  local n1 = sent("Laptop")
  for _ = 1, 4 do watch(pa, A, yes, true); hold(0.1) end
  local _, p1 = prints.takes(it)
  check((p1 and select(2, reaper.GetSetMediaItemTakeInfo_String(p1, "P_EXT:" .. prints.KEY, "", false)) or "") == k0 and sent("Laptop") == n1, "Hold: nothing goes out and nothing renders")
  for _ = 1, 4 do watch(pa, A); hold(0.1) end
  local _, p2 = prints.takes(it)
  check((p2 and select(2, reaper.GetSetMediaItemTakeInfo_String(p2, "P_EXT:" .. prints.KEY, "", false)) or "") ~= k0 and sent("Laptop") > n1, "released: it goes out and prints")

  -- a plug-in that isn't installed isn't "here", though REAPER says it isn't offline
  do
    reaper.SelectProjectInstance(pa)
    reaper.InsertTrackInProject(pa, reaper.CountTracks(pa), 0)
    local tm = reaper.GetTrack(pa, reaper.CountTracks(pa) - 1)
    reaper.TrackFX_AddByName(tm, "ReaSynth", false, -1)
    check(prints.fx_here(tm, 0), "a real plug-in is here")
    local _, ch = reaper.GetTrackStateChunk(tm, "", false)
    local gone = ch:gsub('<VST "VSTi: ReaSynth %(Cockos%)" [^\n]*', '<VST "VST3i: Nobody Has This (Nobody)" "Nobody Has This.vst3" 0 "" 123456789{ABCDEF0123456789ABCDEF0123456789} ""')
    reaper.SetTrackStateChunk(tm, gone, false)
    check(reaper.TrackFX_GetCount(tm) == 1 and not reaper.TrackFX_GetOffline(tm, 0), "REAPER shows the missing one, not as offline")
    check(not prints.fx_here(tm, 0) and not prints.track_plays(tm), "but BandSync knows it isn't here: no silent print, and Auto plays the wet take")
    reaper.DeleteTrack(tm)
  end

  -- a file name with a " in it is written between ` : it's still copied, and goes out as the band's file
  do
    local path = root .. "/quoted source.wav"
    local f = io.open(path, "wb"); f:write("RIFF"); f:close()
    local media = sync.room_dir(A, song, room) .. "/media"
    local out2 = mirror.share_media("<SOURCE WAVE\nFILE `" .. path .. "`\n>\n", media)
    check(out2:find('FILE "{media:main}/', 1, true) ~= nil and not out2:find("`", 1, true), "any quote: copied and pointed at the copy: " .. out2:gsub("\n", " "))
  end

  -- a bandmate's claimed item can't be sent in from a side room
  do
    reaper.RecursiveCreateDirectory(sync.room_dir(A, song, room) .. "/claims", 0)
    band.write_json(sync.claims_path(A, song, room, "James"), { user = "James", time = "2026-11-01T00:00:00Z", tracks = { "Two" } })
    local list = { { obj = "item", oid = "I-LAPTOP-1-1", track = "T-JAMES-1-1", name = "Two", pos = 0 }, { obj = "item", oid = "I-LAPTOP-1-2", track = "T-JAMES-1-1", name = "One", pos = 0 } }
    local keep, refused = mirror.allowed_into(A, song, room, list, { host = "Laptop" })
    check(#keep == 1 and keep[1].name == "One" and refused == 1, "Send selected leaves out what someone else has claimed (" .. #keep .. " kept, " .. refused .. " refused)")
    os.remove(sync.claims_path(A, song, room, "James"))
  end

  -- a log line doesn't search every window each time
  do
    local t = reaper.time_precise()
    for i = 1, 20 do band.log("limit test line " .. i) end
    check((reaper.time_precise() - t) / 20 < 0.03, string.format("a log line is quick (%.1f ms each)", (reaper.time_precise() - t) / 20 * 1000))
  end

  -- a job known to be stuck doesn't render in front
  reaper.SetExtState(band.SECTION, "bg render", "on", false)
  local name = "print-X-1-abcdef01-Laptop"
  bg.stuck[name] = true
  local called = false
  local path = prints.render("X-1", name, sync.room_dir(A, song, room) .. "/media", { t1 }, function() called = true; return "x" end)
  check(path == nil and not called, "a stuck print waits for a change instead of rendering in front")
  bg.stuck[name] = nil
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
reaper.SetExtState(band.SECTION, "put back", was_put, false)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")

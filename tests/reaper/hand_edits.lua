-- Run inside REAPER (ReaScript). What a hand edit in the MIDI editor leaves behind (0.40.3): opening the editor and
-- selecting notes aren't changes; undoing a move finds the old print by its notes, selected or not; a print made
-- under the old fingerprint stays current; a new track is claimed by its maker, whose claim shows and can be released;
-- a maker no longer beats a bandmate's claim; and a bandmate's edit can open in the MIDI editor here.
-- Two scratch tabs, a scratch shared folder; both saved there and closed at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "json", "midiview" }) do package.loaded[m] = nil end
local band, sync, mirror, prints, midiview = require("band"), require("sync"), require("mirror"), require("prints"), require("midiview")
local root = D .. "/hroot_" .. os.time()
local song, room = "HandLab", "main"
local A, B = { user = "Laptop", root = root }, { user = "James", root = root }
local events = sync.room_dir(A, song, room) .. "/events"
reaper.RecursiveCreateDirectory(events, 0)
reaper.RecursiveCreateDirectory(root .. "/plugins", 0)
local out, fails = {}, 0
local function say(s) out[#out + 1] = s end
local function check(ok, what) if not ok then fails = fails + 1 end; say((ok and "PASS " or "FAIL ") .. what) end
local function sent(who) local n = 0; for _, f in ipairs(band.files(events, ".json")) do if f:sub(1, #who + 1) == who .. "-" then n = n + 1 end end; return n end
local yes = function() return true end
local front = reaper.EnumProjects(-1)
local was_bg, was_view = reaper.GetExtState(band.SECTION, "bg render"), reaper.GetExtState(band.SECTION, "show midi edits")
reaper.SetExtState(band.SECTION, "bg render", "off", false) -- (in front: audio_prints covers the background)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pb = reaper.EnumProjects(-1)
local function watch(p, cfg, can)
  reaper.SelectProjectInstance(p)
  return (mirror.watch(p, cfg, song, room, { can = can or yes, mode = "claims", here = { [cfg.user] = true } }))
end
local function recv(p, cfg) reaper.SelectProjectInstance(p); for _ = 1, 3 do sync.receive(p, cfg, song, room, yes) end end
local function hold(s) local w = reaper.time_precise(); while reaper.time_precise() - w < s do end end
local function print_of(it) local _, p = prints.takes(it); return p and select(2, reaper.GetSetMediaItemTakeInfo_String(p, "P_EXT:" .. prints.KEY, "", false)) or "" end
local function file_of(it) local _, p = prints.takes(it); return p and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(p), "") or "" end
local ok, err = pcall(function()
  sync.driver_name = "Laptop" -- (its first tracks: the driver's, unclaimed)
  reaper.SelectProjectInstance(pa)
  reaper.InsertTrackInProject(pa, 0, 0)
  local ta = reaper.GetTrack(pa, 0)
  reaper.GetSetMediaTrackInfo_String(ta, "P_NAME", "Bass", true)
  reaper.TrackFX_AddByName(ta, "ReaSynth", false, -1)
  local it = reaper.CreateNewMIDIItemInProj(ta, 0, 2, false)
  local tk = reaper.GetActiveTake(it)
  for i = 0, 3 do reaper.MIDI_InsertNote(tk, false, false, i * 480, i * 480 + 400, 0, 40 + i, 100, true) end
  reaper.MIDI_Sort(tk)
  watch(pa, A); hold(3.3); watch(pa, A); watch(pa, A); watch(pa, A)
  local h0, f0 = print_of(it), file_of(it)
  check(h0 ~= "", "the part has its print")

  -- a new track is claimed by whoever made it, once it goes out named
  sync.driver_name = "James"
  reaper.InsertTrackInProject(pa, 1, 0)
  local tn = reaper.GetTrack(pa, 1)
  watch(pa, A)
  local c = sync.my_claims(A, song, room)
  check(#(c.tracks or {}) == 0, "an unnamed new track isn't claimed yet")
  reaper.GetSetMediaTrackInfo_String(tn, "P_NAME", "Pad", true)
  watch(pa, A)
  c = sync.my_claims(A, song, room)
  check(c.tracks and c.tracks[1] == "Pad", "named, it's claimed by its maker")
  c.tracks = {}
  sync.set_claims(A, song, room, c)
  reaper.GetSetMediaTrackInfo_String(tn, "P_NAME", "Pad 2", true)
  watch(pa, A)
  c = sync.my_claims(A, song, room)
  check(#(c.tracks or {}) == 0, "released, it isn't claimed again")
  sync.driver_name = "Laptop"
  reaper.InsertTrackInProject(pa, 2, 0)
  reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(pa, 2), "P_NAME", "Drv", true)
  watch(pa, A)
  c = sync.my_claims(A, song, room)
  check(#(c.tracks or {}) == 0, "the driver's new track isn't claimed: it's theirs anyway")
  sync.driver_name = nil
  watch(pa, A); hold(3.3); watch(pa, A)
  recv(pb, B)

  -- a maker doesn't beat a bandmate's claim, but may change what nobody has claimed
  local can = sync.authority(A, song, room, { host = "James" })
  check(sync.maker_may("T-LAPTOP-20261101000000-1", "Laptop", "Bass", 0, "claims"), "the maker may change their unclaimed track")
  check(not sync.maker_may("T-LAPTOP-20261101000000-1", "Laptop", "Bass", 0, "driver"), "not in Driver only")
  sync.claim_tracks(B, song, room, { "Bass" })
  can = sync.authority(A, song, room, { host = "James" })
  check(not can("Laptop", "Bass", 0) and not sync.maker_may("T-LAPTOP-20261101000000-1", "Laptop", "Bass", 0, "claims"), "someone else's claim beats the maker")
  local cb = sync.my_claims(B, song, room); cb.tracks = {}; sync.set_claims(B, song, room, cb)
  sync.authority(A, song, room, { host = "James" })

  -- opening the editor (its lane line) and selecting notes aren't changes
  reaper.SelectProjectInstance(pa)
  local n0 = sent("Laptop")
  local _, chunk = reaper.GetItemStateChunk(it, "", false)
  chunk = chunk:gsub("(HASDATA[^\n]*\n)", "%1VELLANE 64 100 0 0 1\n", 1)
  reaper.SetItemStateChunk(it, chunk, false)
  tk = prints.takes(it)
  reaper.MIDI_SetNote(tk, 3, true, nil, nil, nil, nil, nil, nil, false)
  watch(pa, A); watch(pa, A)
  check(sent("Laptop") == n0, "the editor's lanes and a selected note send nothing")
  check(print_of(it) == h0, "and render nothing")

  -- move a note and undo it by hand: the moved note stays selected, the old print comes back without a render
  local _, _, m, a, b, ch, _, v = reaper.MIDI_GetNote(tk, 3)
  reaper.MIDI_SetNote(tk, 3, true, m, a, b, ch, 50, v, false)
  watch(pa, A); watch(pa, A); watch(pa, A)
  local h1 = print_of(it)
  check(h1 ~= h0 and sent("Laptop") > n0, "a moved note goes out, with a new print")
  local ev_sel = false
  for _, f in ipairs(band.files(events, ".json")) do
    local e = band.read_json(events .. "/" .. f)
    if e and e.obj == "item" and type(e.state) == "string" and (e.state:find("\ne ", 1, true) or e.state:find("VELLANE", 1, true)) then ev_sel = true end
  end
  check(not ev_sel, "no event carries a selected note or the editor's lanes")
  reaper.MIDI_SetNote(tk, 3, true, m, a, b, ch, 43, v, false)
  local before = reaper.time_precise()
  watch(pa, A); watch(pa, A); watch(pa, A)
  check(print_of(it) == h0 and file_of(it) == f0, "put back with the note still selected: the first print, no new file")
  say(string.format("     going back took %.2f s", reaper.time_precise() - before))

  -- a print made under the old fingerprint stays current until the notes change
  local mid = select(2, reaper.MIDI_GetHash(tk, false, ""))
  local fx = select(2, prints.source(it, tk, "x"))
  check(fx == mirror.hash(mid .. "x" .. string.format("%.6f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))), "the second value is the old fingerprint")
  check(select(1, prints.source(it, tk, "x")) == select(1, (function()
    reaper.MIDI_SetNote(tk, 0, true, nil, nil, nil, nil, nil, nil, false)
    local h = prints.source(it, tk, "x")
    reaper.MIDI_SetNote(tk, 0, false, nil, nil, nil, nil, nil, nil, false)
    return h
  end)()), "selecting a note doesn't change the fingerprint")
  check(select(2, prints.source(it, tk, "x")) == fx, "(and the note's back unselected)")
  reaper.MIDI_SetNote(tk, 3, false, nil, nil, nil, nil, nil, nil, false)
  watch(pa, A); watch(pa, A)

  -- a bandmate's edit: off, nothing opens; on, it opens with the changed note selected
  recv(pb, B)
  local ib = reaper.GetTrackMediaItem(reaper.GetTrack(pb, 0), 0)
  check(ib ~= nil, "James has the part")
  reaper.SelectProjectInstance(pa)
  reaper.MIDI_SetNote(tk, 1, false, nil, nil, nil, nil, 55, nil, false)
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  check(reaper.MIDIEditor_GetActive() == nil, "off: nothing opens")
  reaper.SetExtState(band.SECTION, "show midi edits", "on", false)
  reaper.SelectProjectInstance(pa)
  reaper.MIDI_SetNote(tk, 1, false, nil, nil, nil, nil, 57, nil, false)
  watch(pa, A); watch(pa, A)
  recv(pb, B)
  local ed = reaper.MIDIEditor_GetActive()
  local shown = ed and reaper.MIDIEditor_GetTake(ed)
  check(shown ~= nil and reaper.GetMediaItemTake_Item(shown) == reaper.GetTrackMediaItem(reaper.GetTrack(pb, 0), 0), "on: the part opens here")
  if shown then
    local sel, pitch = {}, {}
    for i = 0, select(2, reaper.MIDI_CountEvts(shown)) - 1 do
      local _, s, _, _, _, _, p = reaper.MIDI_GetNote(shown, i)
      pitch[#pitch + 1] = p
      if s then sel[#sel + 1] = p end
    end
    check(#sel == 1 and sel[1] == 57, "with just the changed note selected: " .. table.concat(sel, ","))
    reaper.MIDIEditor_OnCommand(ed, 2) -- (close it)
  end
  local n1 = sent("James")
  watch(pb, B); watch(pb, B)
  check(sent("James") == n1, "selecting it there sends nothing back")
end)
if not ok then fails = fails + 1; say("ERROR " .. tostring(err)) end
reaper.SetExtState(band.SECTION, "bg render", was_bg, false)
reaper.SetExtState(band.SECTION, "show midi edits", was_view, false)
for _, p in ipairs({ pb, pa }) do
  reaper.SelectProjectInstance(p)
  reaper.Main_SaveProjectEx(p, root .. "/" .. tostring(p):gsub("%W", "") .. ".rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
reaper.SelectProjectInstance(front)
say(fails == 0 and "ALL PASS" or (fails .. " FAILED"))
return table.concat(out, "\n")

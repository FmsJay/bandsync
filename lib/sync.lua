-- BandSync sync engine: printing and sending takes, reprinting them when their sound changes, and keeping
-- everyone's project in step with the session driver's changes (deletes, moves/trims/lane moves, which
-- take or lane plays). Changes travel as small event files; each person writes only files named after
-- themselves, so a sync client never sees two people writing the same file.
local band = require("band")
local sync = {
  SNAP = "BandSync.snap",       -- id -> "<original-case id>|pos|len|offs|lane" as last seen/applied
  PLAYS = "BandSync.plays",     -- track name -> ids audible on it, as last seen/applied
  APPLIED = "BandSync.applied", -- event id -> "1"
  SENTKEYS = "BandSync.sent",   -- source file|offset|length -> id: never send the same audio twice
  REV = "BandSync.rev",         -- id -> revision this project holds
  TRACKS = "BandSync.tracks",   -- track GUID -> "name|mute|solo|colour|icon" as last seen/applied
  ITEMS = "BandSync.items",     -- id -> item state chunk of our own sent takes (recall points rebuild them)
  PENDING = "BandSync.pending", -- id -> where a revived take must sit once it has been imported again
  PRINTER = "BandSync.printer", -- id -> who made the current print (someone may print a take with their own instrument)
  MIDIHASH = "BandSync.midi",   -- id -> hash of the MIDI copy's notes as last seen/applied
  SNAPQN = "BandSync.snapqn",   -- id -> position in quarter notes as last seen/applied (tells tempo moves from edits)
  MIN_LEN = 0.5,                -- shorter items are recording slivers, not takes
  TAIL = 2,                     -- seconds of FX tail kept past the end of a wet print
  TAILS = "BandSync.tail",      -- id -> seconds of tail this project's print of it carries (items are that much longer)
  NEWEST = "BandSync.newest",   -- "take:<id>" / "track:<name>" -> time..id of the newest change made or applied here
}

local function ext(proj, sec, key) return select(2, reaper.GetProjExtState(proj, sec, key)) end
-- Seconds since an ISO UTC time ("2026-10-28T07:05:36Z"); huge if it can't be read.
local function iso_age(iso)
  local y, mo, d, h, mi, s = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return math.huge end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  local utc_now = os.date("!*t")
  utc_now.isdst = false
  return os.time(utc_now) - t
end
local function setext(proj, sec, key, v) reaper.SetProjExtState(proj, sec, key, v) end
sync.ext, sync.setext = ext, setext

function sync.room_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room end

-- Two changes to one take (or track) made at once on two machines arrive in opposite orders, so applying each as it
-- comes left every machine with the other's (2026-10-28 break round 2). The one stamped latest (time, then id) wins
-- everywhere: an older one arriving after it is skipped.
local function newest_key(ev, name)
  if ev.type == "edit" and ev.take then return "take:" .. ev.take:lower() end
  if ev.type == "track" and (name or ev.track) then return "track:" .. (name or ev.track):lower() end
end
-- The order is time..id, except that a change made here always comes after the newest one seen here (a machine
-- whose clock runs ahead would otherwise win over every later change to that take).
local function order(ev) return ev.order or (ev.time .. ev.id) end
local function stamp(proj, ev)
  for _, name in ipairs({ ev.track or false, ev.was or false }) do
    local k = newest_key(ev, name or nil)
    if k and order(ev) > ext(proj, sync.NEWEST, k) then setext(proj, sync.NEWEST, k, order(ev)) end
  end
end
local function superseded(proj, ev)
  local k = newest_key(ev, ev.was)
  return k ~= nil and ext(proj, sync.NEWEST, k) > order(ev)
end

-- Events anyone may send, whoever drives or owns what: they change no take, track or timeline.
sync.ANYONE = { start = true, stop = true, note = true, like = true }
-- A take's author, from its id (<user>-YYYYMMDD-HHMMSSZ-n), normalised like user names in ids.
function sync.author(id) local who = (id or ""):match("^(.-)%-%d+%-%d+Z"); return who and who:lower():gsub("_", " ") end
function sync.author_of(user) return (user or ""):lower():gsub("_", " ") end

-- ---- state chunks: a top-level block (e.g. <FXCHAIN ... >) of a track's chunk -----------------------------
local function chunk_lines(s)
  local t = {}
  for l in ((s or "") .. "\n"):gmatch("(.-)\r?\n") do t[#t + 1] = l end
  if t[#t] == "" then t[#t] = nil end
  return t
end
local function find_block(L, tag)
  local depth, first = 0, nil
  for i, l in ipairs(L) do
    local t = l:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "<" then
      depth = depth + 1
      if depth == 2 and not first and (t == "<" .. tag or t:sub(1, #tag + 2) == "<" .. tag .. " ") then first = i end
    elseif t == ">" then
      if first and depth == 2 then return first, i end
      depth = depth - 1
    end
  end
end
-- The block's text (with its <TAG and > lines), or nil. Pure.
function sync.chunk_block(chunk, tag)
  local L = chunk_lines(chunk)
  local a, z = find_block(L, tag)
  return a and table.concat(L, "\n", a, z) or nil
end
-- The chunk with that block replaced by `block` (inserted before the track's end if absent; removed if nil). Pure.
function sync.chunk_set_block(chunk, tag, block)
  local L = chunk_lines(chunk)
  local a, z = find_block(L, tag)
  local out = {}
  if a then
    for i = 1, a - 1 do out[#out + 1] = L[i] end
    if block then out[#out + 1] = block end
    for i = z + 1, #L do out[#out + 1] = L[i] end
  else
    for i = 1, #L - 1 do out[#out + 1] = L[i] end
    if block then out[#out + 1] = block end
    out[#out + 1] = L[#L]
  end
  return table.concat(out, "\n")
end

-- ---- the timeline: tempo map and markers/regions ---------------------------------------------------
-- The driver's tempo or marker changes travel as one "timeline" event; every machine applies the same map and
-- REAPER moves (and, in its default "beats (position, length, rate)" timebase, stretches) each item exactly as it
-- would for a local tempo change. Positions also travel in quarter notes, so a take that crosses paths with a
-- tempo change still lands on its beat.
local function timeline_sig(proj) return band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj) }) end
sync.timeline_sig = timeline_sig

-- Whether this project follows the beat (REAPER's default) rather than the clock: then positions travel in beats.
function sync.beats(proj) return reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false) ~= 0 end
-- A position sent in seconds (pos) and quarter notes (qn), placed by beat when this project follows the beat.
function sync.here(proj, pos, qn)
  if qn and sync.beats(proj) then return reaper.TimeMap2_QNToTime(proj, qn) end
  return pos
end
function sync.qn(proj, pos) return reaper.TimeMap2_timeToQN(proj, pos) end

-- All band audio in the project (takes, prints, stems, live placeholders) follows tempo changes by REAPER's
-- auto-stretch when the project stretches audio (band.follow_tempo); existing items get it here, at Live sync start
-- and before a received tempo change.
function sync.audio_follow_tempo(proj)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local tr = reaper.GetMediaItem_Track(it)
    if tk and (band.take_id(tk) or band.item_ext(it, "band_live") ~= "" or band.track_ext(tr, "band_stem") ~= "") then
      band.follow_tempo(it, tk)
    end
  end
end

-- ---- arrangement: insert or remove time for everyone (the driver's edit; claims don't block it) ---------
-- Insert `len` seconds at `at` (len > 0), or remove [at, at - len) (len < 0): items, tempo markers, markers and
-- regions after it move; removed time's items, tempo markers and markers go. Stems and live placeholders stay.
-- Takes that play across an edit point are split there by whoever recorded them (opts.split(it) -> true), each on
-- their own machine: the left part keeps its id and
-- goes out as a trim, the right part is new material and goes out as a new take, already in its moved place.
-- Everyone else leaves such a take where it is until those arrive. opts.keep(it, tk) -> true keeps a moved take's
-- old snapshot, so Live sync posts its new place as an edit (a take that reaches someone late still lands right).
local function shiftable(it)
  local tr = reaper.GetMediaItem_Track(it)
  return band.track_ext(tr, "band_stem") == "" and band.item_ext(it, "band_live") == ""
end
function sync.crossing(proj, at, len)
  local out, cut_to = {}, len < 0 and (at - len) or at
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local e = p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if shiftable(it) then
      for _, x in ipairs({ at, cut_to }) do
        if p < x - 1e-6 and e > x + 1e-6 then out[#out + 1] = it; break end
      end
    end
  end
  return out
end
-- split_crossing's test: takes `me` recorded (and anything not sent yet). The author splits, so both parts stay
-- theirs and land on their tracks everywhere; the left part's trim goes out under the author's own-take right.
function sync.recorded_by(me)
  return function(it)
    local tk = reaper.GetActiveTake(it)
    local id = tk and band.take_id(tk)
    return not id or sync.author(id) == sync.author_of(me)
  end
end
-- Split without losing anything: REAPER's split trims a MIDI item's notes away for good (seen 7.83: a restore
-- that lengthened the left half again found bars 9-12 empty). Here both halves keep the whole source, trimmed.
local function split_keep(it, x)
  local ok, chunk = reaper.GetItemStateChunk(it, "", false)
  if not ok then return nil end
  -- the copy gets its own identity (and its own MIDI data, not pooled with the original)
  chunk = chunk:gsub("\n%s*IGUID [^\n]*", ""):gsub("\n%s*GUID [^\n]*", ""):gsub("\n%s*POOLEDEVTS [^\n]*", "")
  local p, l = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
  local right = reaper.AddMediaItemToTrack(reaper.GetMediaItem_Track(it))
  if not reaper.SetItemStateChunk(right, chunk, false) then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(right), right); return nil end
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", x - p)
  reaper.SetMediaItemInfo_Value(right, "D_POSITION", x)
  reaper.SetMediaItemInfo_Value(right, "D_LENGTH", p + l - x)
  for k = 0, reaper.CountTakes(right) - 1 do
    local tk = reaper.GetTake(right, k)
    reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") + (x - p) * reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE"))
  end
  reaper.UpdateItemInProject(it)
  reaper.UpdateItemInProject(right)
  return right
end
-- Split `it` at x (lossless); the right part is new material: none of the left part's sent/take marks.
local function split_piece(it, x)
  local right = split_keep(it, x)
  if right then
    for k = 0, reaper.CountTakes(right) - 1 do
      for _, key in ipairs({ "band_sent", "band_take", "band_fxhash", "band_base_offs", "band_base" }) do
        band.set_take_ext(reaper.GetTake(right, k), key, "")
      end
    end
    band.set_item_ext(right, "band_take", "")
    band.set_item_ext(right, "band_group", "")
    band.set_item_ext(right, "band_split", "1") -- made by a split, not played: "take back my last take" skips it
  end
  return right
end

local function split_crossing(proj, at, len, mine, stale)
  local n = 0
  for _, x in ipairs(len < 0 and { at, at - len } or { at }) do
    for _, it in ipairs(sync.crossing(proj, x, 0)) do
      local tk = reaper.GetActiveTake(it)
      -- a "(MIDI)" copy is never split: two copies of one take would each post their notes as that take's
      -- (seen 2026-10-28: a midi event every 2 s). It stays as it is; the take it copies is what's split.
      if mine(it) and not (tk and band.take_ext(tk, "band_midi") ~= "") then
        reaper.SetMediaItemInfo_Value(it, "C_LOCK", 0)
        local id = tk and band.take_id(tk)
        if id then stale[id] = stale[id] or ext(proj, sync.SNAP, id) end -- the left part's trim must go out as an edit
        if split_piece(it, x) then n = n + 1 end -- the left part keeps the id; the right part is new
      end
    end
  end
  return n
end
function sync.shift(proj, at, len, opts)
  opts = opts or {}
  local cut_to = len < 0 and (at - len) or at
  local stale = {}
  local split = opts.split and split_crossing(proj, at, len, opts.split, stale) or 0
  local cross = {}
  for _, it in ipairs(sync.crossing(proj, at, len)) do cross[it] = true end
  local items, kept = {}, {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id = tk and band.take_id(tk)
    -- replaying an old insert/remove (someone joining later), takes made after it are already where they belong
    local born = id and id:match("%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z%-")
    local newer = false
    if born and opts.before then
      local y, mo, d, h, mi, s = id:match("%-(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z%-")
      newer = string.format("%s-%s-%sT%s:%s:%sZ", y, mo, d, h, mi, s) > opts.before
    end
    if shiftable(it) and not cross[it] and not newer then
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      items[#items + 1] = { it, p, p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") }
      if id and opts.keep and p >= cut_to - 1e-6 and opts.keep(it, tk) then kept[id] = ext(proj, sync.SNAP, id) end
    end
  end
  for _, x in ipairs(items) do
    local it, p, e = x[1], x[2], x[3]
    if len < 0 and p >= at - 1e-6 and e <= cut_to + 1e-6 then
      reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    elseif p >= cut_to - 1e-6 then
      reaper.SetMediaItemInfo_Value(it, "D_POSITION", p + len)
    end
  end
  local tempo = band.capture_tempo(proj)
  local nt = {}
  for _, m in ipairs(tempo) do
    if m.time < at - 1e-6 or m.time == 0 then nt[#nt + 1] = m
    elseif m.time >= cut_to - 1e-6 then m.time = m.time + len; nt[#nt + 1] = m end
  end
  local marks, nm = band.capture_markers(proj), {}
  for _, m in ipairs(marks) do
    local p, e = m.pos, m["end"]
    if len < 0 and p >= at - 1e-6 and p < cut_to - 1e-6 and not (m.region and e > cut_to) then -- inside the cut: gone
    else
      if p >= cut_to - 1e-6 then p = p + len end
      if m.region then
        if e >= cut_to - 1e-6 then e = e + len elseif len < 0 and e > at then e = at end
        if len > 0 and m.pos < at and m["end"] > at then e = m["end"] + len end -- a region around the insert grows
      end
      m.pos, m["end"] = p, e
      nm[#nm + 1] = m
    end
  end
  -- the event carries the map it left (0.8.4+): setting it outright is right however often it's replayed
  band.apply_tempo(proj, opts.tempo or nt)
  band.apply_markers(proj, opts.markers or nm)
  setext(proj, band.SECTION, "timeline", timeline_sig(proj))
  sync.resnap(proj)
  for id, snap in pairs(kept) do setext(proj, sync.SNAP, id, snap) end -- these go out as edits
  for id, snap in pairs(stale) do if snap ~= "" then setext(proj, sync.SNAP, id, snap) end end -- and these trims
  reaper.UpdateArrange()
  return true, split
end

-- The driver's new timeline goes into session.json too: refreshing, or a bandmate joining later, gets it.
function sync.session_timeline(cfg, song, tempo, markers)
  local sp = band.session_path(cfg, song)
  local s = band.read_json(sp)
  if s then
    s.first_timeline = s.first_timeline or { tempo = s.tempo, markers = s.markers } -- history restores before this need it
    s.tempo, s.markers = tempo, markers
    band.write_json(sp, s)
  end
end

-- Everything REAPER moved for a tempo change is where it should be: take new snapshots, so none of it is sent
-- as an edit. With only_tempo, an item whose beat position changed too (say "insert time" moved items and tempo
-- markers together) keeps its old snapshot, so the next look sends it as a real edit.
function sync.resnap(proj, only_tempo)
  for id, hit in pairs(band.take_index(proj)) do
    local tid = band.take_id(hit[2]) or id
    local was = tonumber(ext(proj, sync.SNAPQN, tid))
    local now = sync.qn(proj, reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION"))
    if not only_tempo or not was or math.abs(now - was) < 1e-6 then sync.remember(proj, tid, hit[1], hit[2]) end
  end
end

-- The driver is whoever holds control of a room: the host, until someone runs "Take control".
function sync.driver(cfg, song, room, s)
  local d = band.read_json(sync.room_dir(cfg, song, room) .. "/driver.json")
  return d and d.driver or (s and s.host)
end
function sync.set_driver(cfg, song, room, user)
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room), 0)
  band.write_json(sync.room_dir(cfg, song, room) .. "/driver.json", { driver = user, since = os.date("!%Y-%m-%dT%H:%M:%SZ") })
end

-- ---- who may change what ------------------------------------------------------------------------
-- People claim tracks and regions, each in their own file (rooms/<room>/claims/<user>.json: never two
-- writers on one file). A take may be changed by the owner of its track; else by the owner of the region
-- it starts in; else by the driver. The newest claim on a track or region wins.

local function base_name(track) return track and (track:gsub(" %(band%)$", "")) end
sync.base_name = base_name

function sync.claims_path(cfg, song, room, user)
  return sync.room_dir(cfg, song, room) .. "/claims/" .. (user:gsub("[^%w%-_ ]", "")) .. ".json"
end
-- nil + why when the file exists but can't be read right now (mid-sync, locked): callers must not write then,
-- or every other claim in it is lost (the likely end of a claim nobody released, 2026-10-28)
function sync.my_claims(cfg, song, room)
  local path = sync.claims_path(cfg, song, room, cfg.user)
  local c = band.read_json(path)
  if c then return c end
  if reaper.file_exists(path) then return nil, "your claims file is busy (syncing?): try again in a moment" end
  return { tracks = {}, regions = {}, times = {} }
end
function sync.set_claims(cfg, song, room, claims)
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  -- each track/region keeps the date it was claimed: claiming something else later mustn't re-date (and so win
  -- back) an older contested claim
  local old = band.read_json(sync.claims_path(cfg, song, room, cfg.user)) or {}
  local since = {}
  for _, k in ipairs({ "tracks", "regions" }) do
    for _, name in ipairs(claims[k] or {}) do
      since[k .. ":" .. name:lower()] = (old.since or {})[k .. ":" .. name:lower()] or now
    end
  end
  claims.since = since
  claims.user, claims.time = cfg.user, now
  reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/claims", 0)
  band.write_json(sync.claims_path(cfg, song, room, cfg.user), claims)
end

-- Returns can(user, track, pos, take) -> bool, plus { driver, tracks, regions, times, owner(track, pos) } for display.
-- Who owns a take: its track's claimant, else the newest claim on a stretch of time it starts in (a time selection),
-- else the claimant of the named region it starts in, else the driver. A take's author may change it (move, trim,
-- mute) wherever nobody has claimed it that way.
function sync.authority(cfg, song, room, s)
  local driver = sync.driver(cfg, song, room, s)
  local tracks, regions, times = {}, {}, {} -- lower name -> { user, time }; times: { user, time, from, to }
  local dir = sync.room_dir(cfg, song, room) .. "/claims"
  for _, f in ipairs(band.files(dir, ".json")) do
    local c = band.read_json(dir .. "/" .. f)
    if c and c.user and c.time then
      for _, t in ipairs(c.times or {}) do
        if tonumber(t.from) and tonumber(t.to) and t.to > t.from then times[#times + 1] = { user = c.user, time = t.at or c.time, from = t.from, to = t.to } end
      end
      for _, list in ipairs({ { c.tracks, tracks }, { c.regions, regions } }) do
        for _, name in ipairs(list[1] or {}) do
          local k = name:lower()
          local t = (c.since or {})[(list[2] == tracks and "tracks:" or "regions:") .. k] or c.time
          local o = list[2][k] -- newest wins; the same second goes to the later name, so every machine agrees
          if not o or o.time < t or (o.time == t and o.user < c.user) then list[2][k] = { user = c.user, time = t, name = name } end
        end
      end
    end
  end
  local spans = {} -- the song's regions, from the publish
  for _, m in ipairs((s and s.markers) or {}) do
    if m.region then spans[#spans + 1] = { name = m.name:lower(), from = m.pos, to = m["end"] } end
  end
  table.sort(times, function(x, y) -- the newest claim on a stretch wins (same second: the later name, as for tracks)
    if x.time ~= y.time then return x.time > y.time end
    return x.user > y.user
  end)
  local function in_time(pos)
    for _, t in ipairs(pos and times or {}) do if pos >= t.from and pos < t.to then return t end end
  end
  local function owner(track, pos, drv)
    local t = base_name(track)
    if t and tracks[t:lower()] then return tracks[t:lower()].user end
    local tc = in_time(pos)
    if tc then return tc.user end
    if pos then
      for _, sp in ipairs(spans) do
        if pos >= sp.from and pos < sp.to and regions[sp.name] then return regions[sp.name].user end
      end
    end
    return drv or driver
  end
  local function claimed(track, pos)
    local t = base_name(track)
    if t and tracks[t:lower()] then return true end
    if in_time(pos) then return true end
    for _, sp in ipairs(pos and spans or {}) do
      if pos >= sp.from and pos < sp.to and regions[sp.name] then return true end
    end
  end
  sync.owner_of = owner -- for messages ("... is James's to change")
  return function(user, track, pos, take, drv) -- drv: the driver to judge by (an event's own time), else today's
      if owner(track, pos, drv) == user then return true end
      return take ~= nil and sync.author(take) == sync.author_of(user) and not claimed(track, pos)
    end,
    { driver = driver, tracks = tracks, regions = regions, times = times, owner = owner, spans = spans }
end

-- Show the time claims as regions named "[claimed: <user>]" (this machine only; see band.CLAIM_MARK). Redrawn
-- only when they change.
function sync.draw_claims(proj, times)
  local want, have = {}, {}
  for _, t in ipairs(times or {}) do want[#want + 1] = string.format("%s%s]|%.6f|%.6f", band.CLAIM_MARK, t.user, t.from, t.to) end
  table.sort(want)
  for i = 0, reaper.CountProjectMarkers(proj) - 1 do
    local _, rgn, p, e, name = reaper.EnumProjectMarkers3(proj, i)
    if rgn and band.is_claim_mark(name) then have[#have + 1] = string.format("%s|%.6f|%.6f", name, p, e) end
  end
  table.sort(have)
  if table.concat(want, "\n") == table.concat(have, "\n") then return false end
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, _, _, _, name = reaper.EnumProjectMarkers3(proj, i)
    if band.is_claim_mark(name) then reaper.DeleteProjectMarkerByIndex(proj, i) end
  end
  for _, t in ipairs(times or {}) do
    reaper.AddProjectMarker2(proj, true, t.from, t.to, band.CLAIM_MARK .. t.user .. "]", -1, reaper.ColorToNative(230, 150, 40) | 0x1000000)
  end
  return true
end

-- ---- where a take sits ---------------------------------------------------------------------------

-- REAPER's lane play state isn't per lane (verified 7.83): setting a lane to 1 plays it exclusively and
-- silences the others, setting any lane to 2 makes every lane play. A track plays one lane, or all.
local function set_lanes_playing(tr, lanes)
  local n = reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES")
  if #lanes == 0 then
    for l = 0, n - 1 do reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l, 0) end
  elseif #lanes == 1 then
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 1)
  else
    reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lanes[1], 2)
  end
end
local function lanes_playing(tr)
  local on = {}
  for l = 0, reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") - 1 do
    if reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. l) ~= 0 then on[#on + 1] = l end
  end
  return on
end

local function lane_of(it)
  local tr = reaper.GetMediaItem_Track(it)
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 or reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < 2 then return nil end
  return math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
end
local function track_name(it) return base_name(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it)))) end
-- The name the band knows this item's track by: its last synced name (a rename this person may not send stays
-- local; 2026-10-28: a guest renamed an unclaimed track and its takes' edits split them across two tracks).
local function band_track_name(proj, it)
  local tr = reaper.GetMediaItem_Track(it)
  local known = ext(proj, "BandSync.tracks", select(2, reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)))
  local name = known:match("^([^|]*)|")
  return (name and name ~= "") and name or track_name(it)
end
local function shape(it, tk)
  return string.format("%.6f|%.6f|%.6f|%s|%d|%s", reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
    reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"), tostring(lane_of(it)), reaper.GetMediaItemInfo_Value(it, "B_MUTE"), track_name(it))
end
function sync.remember(proj, id, it, tk, chunk_only)
  if not chunk_only then
    setext(proj, sync.SNAP, id, id .. "|" .. shape(it, tk))
    setext(proj, sync.SNAPQN, id, string.format("%.9f", sync.qn(proj, reaper.GetMediaItemInfo_Value(it, "D_POSITION"))))
    setext(proj, "BandSync.base", id, string.format("%.9f", band.base_offs(tk))) -- (a take that comes back is trimmed as it was)
  end
  -- our own takes also keep a copy of the whole item (source, take FX, fades), so a recall point can bring
  -- back the real item after a delete instead of its print
  if band.take_ext(tk, "band_sent") ~= "" then
    local ok, chunk = reaper.GetItemStateChunk(it, "", false)
    if ok then setext(proj, sync.ITEMS, id, chunk) end
  end
end

-- One BandSync track per name speaks for it: our real "Vox", not the "Vox (band)" mirror beside it.
local function speaks_for_name(proj, tr)
  if band.track_ext(tr, "band_mirror") == "" then return true end
  local name = select(2, reaper.GetTrackName(tr))
  return not band.find_track(proj, base_name(name), true) or base_name(name) == name
end
sync.speaks_for_name = speaks_for_name

function sync.midi_seen(proj, id, tk) setext(proj, sync.MIDIHASH, id, select(2, reaper.MIDI_GetHash(tk, false, ""))) end

-- Everything that changes how a print sounds: FX (names, bypass, every parameter), volumes, pan, fades.
-- Track-level parts only matter for wet prints.
-- legacy: the pre-0.10.1 form, numbers as Lua prints them. A tempo change makes REAPER recompute item values
-- (a fade of 0.01 came back as 0.010000000000001), which looked like a new sound and reprinted every take
-- (2026-10-28: 8 reprints, REAPER frozen 15 s); numbers are now rounded.
local function fxhash(it, tk, wet, legacy)
  local tr = reaper.GetMediaItem_Track(it)
  local function n(v) return legacy and v or string.format("%.5f", v) end
  local parts = { n(reaper.GetMediaItemInfo_Value(it, "D_VOL")), n(reaper.GetMediaItemTakeInfo_Value(tk, "D_VOL")),
    n(reaper.GetMediaItemInfo_Value(it, "D_FADEINLEN")), n(reaper.GetMediaItemInfo_Value(it, "D_FADEOUTLEN")),
    n(reaper.GetMediaItemTakeInfo_Value(tk, "D_PITCH")), n(reaper.GetMediaItemTakeInfo_Value(tk, "B_PPITCH")) }
  if not reaper.TakeIsMIDI(tk) then parts[#parts + 1] = n(reaper.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")) end
  local function fx(count, name, en, np, pv, obj)
    for f = 0, count(obj) - 1 do
      parts[#parts + 1] = select(2, name(obj, f)) .. (en(obj, f) and "+" or "-")
      for p = 0, np(obj, f) - 1 do parts[#parts + 1] = string.format("%.4f", pv(obj, f, p)) end
    end
  end
  fx(reaper.TakeFX_GetCount, reaper.TakeFX_GetFXName, reaper.TakeFX_GetEnabled, reaper.TakeFX_GetNumParams, reaper.TakeFX_GetParamNormalized, tk)
  if reaper.TakeIsMIDI(tk) then
    parts[#parts + 1] = select(2, reaper.MIDI_GetHash(tk, false, "")) -- edited notes sound different
    -- and so does a tempo change over them: it changes the item's length in seconds (only items it reaches), so
    -- the owner reprints them at the new tempo
    parts[#parts + 1] = string.format("%.4f", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
  end
  if wet then
    parts[#parts + 1] = n(reaper.GetMediaTrackInfo_Value(tr, "I_FXEN")) -- fader/pan aren't printed (shared mix)
    for e = 0, reaper.CountTrackEnvelopes(tr) - 1 do -- automation of FX parameters is printed
      local env = reaper.GetTrackEnvelope(tr, e)
      for p = 0, reaper.CountEnvelopePoints(env) - 1 do
        local _, t, v, shape = reaper.GetEnvelopePoint(env, p)
        parts[#parts + 1] = string.format("%.4f:%.4f:%d", t, v, shape)
      end
    end
    fx(reaper.TrackFX_GetCount, reaper.TrackFX_GetFXName, reaper.TrackFX_GetEnabled, reaper.TrackFX_GetNumParams, reaper.TrackFX_GetParamNormalized, tr)
  end
  local s, h = table.concat(parts, ";"), 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

sync.fxhash = fxhash

-- ---- our own takes ------------------------------------------------------------------------------

local function content_key(it, tk) -- position included: a pasted copy is the same audio, somewhere else
  local fn = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(tk))
  return string.format("%s|%.4f|%.4f|%.4f", fn:match("[^/\\]+$") or fn, reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"),
    reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), reaper.GetMediaItemInfo_Value(it, "D_POSITION"))
end

-- Copy/paste, duplicate and split copy an item's P_EXT, so two takes end up carrying one BandSync id.
-- The one still where the snapshot last saw it keeps the id (else the first); the others are new
-- material: their tags are cleared, so Live sync prints and sends them as takes of their own.
-- (After a split, the left half usually keeps the id and goes out as a trim; the right half is new.)
function sync.split_copies(proj)
  local by_id, n = {}, 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        local l = id:lower()
        by_id[l] = by_id[l] or {}
        table.insert(by_id[l], { it, tk, id })
      end
    end
  end
  for _, list in pairs(by_id) do
    if #list > 1 then
      local keep = 1
      for j, u in ipairs(list) do
        if ext(proj, sync.SNAP, u[3]) == u[3] .. "|" .. shape(u[1], u[2]) then keep = j end
      end
      for j, u in ipairs(list) do
        if j ~= keep then
          local mine = band.take_ext(u[2], "band_sent") ~= "" -- a copy of a bandmate's take stays theirs (not sent)
          for _, key in ipairs({ "band_sent", "band_take", "band_fxhash", "band_base_offs", "band_base" }) do band.set_take_ext(u[2], key, "") end
          band.set_item_ext(u[1], "band_take", "")
          band.set_item_ext(u[1], "band_group", "")
          if mine then n = n + 1 end
        end
      end
    end
  end
  return n
end

-- Everything already in a guest's project when sync first runs is baseline (earlier experiments): never
-- auto-sent. A host shares everything instead (Publish marks the project "shared"). Returns count marked.
function sync.mark_baseline(proj)
  if ext(proj, band.SECTION, "baseline") ~= "" then return 0 end
  local n = 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      if not band.take_id(tk) then band.set_take_ext(tk, "band_base", "1"); n = n + 1 end
    end
  end
  setext(proj, band.SECTION, "baseline", os.date("!%Y-%m-%dT%H:%M:%SZ"))
  return n
end

-- {item, take} pairs this project recorded itself: not stems, not received, not dry twins.
-- opts.all: every take of each item (else the active one); opts.unsent: skip sent, baseline and
-- already-sent audio; opts.selected: selected items only; opts.min_len: skip shorter items.
function sync.own_takes(proj, opts)
  local out = {}
  local n = opts.items and #opts.items or opts.selected and reaper.CountSelectedMediaItems(proj) or reaper.CountMediaItems(proj)
  for i = 0, n - 1 do
    local it = opts.items and opts.items[i + 1] or opts.selected and reaper.GetSelectedMediaItem(proj, i) or reaper.GetMediaItem(proj, i)
    if band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") == "" and band.item_ext(it, "band_take") == ""
        and band.item_ext(it, "band_live") == "" then -- live placeholders are someone else's audio, never ours to send
      local legacy = band.item_ext(it, "band_sent") -- 0.2 marked the item: carry it to the take that was active
      if legacy ~= "" then
        local a = reaper.GetActiveTake(it)
        if a and band.take_ext(a, "band_sent") == "" then band.set_take_ext(a, "band_sent", legacy) end
        band.set_item_ext(it, "band_sent", "")
      end
      local function add(tk)
        if not tk or band.take_ext(tk, "band_take") ~= "" or band.take_ext(tk, "band_dry") ~= "" or band.take_ext(tk, "band_midi") ~= "" then return end
        if reaper.GetMediaItemInfo_Value(it, "D_LENGTH") < (opts.min_len or 0) then
          if band.take_ext(tk, "band_sliver") == "" then
            band.log(string.format("a %.2f s sliver on %s wasn't sent (shorter than %.1f s)", reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), track_name(it), opts.min_len))
            band.set_take_ext(tk, "band_sliver", "1")
          end
          return
        end
        if reaper.TakeIsMIDI(tk) and select(2, reaper.MIDI_CountEvts(tk)) == 0 then -- an empty MIDI recording isn't a take
          if band.take_ext(tk, "band_empty") == "" then
            band.log("an empty MIDI take on " .. track_name(it) .. " wasn't sent")
            band.set_take_ext(tk, "band_empty", "1")
          end
          return
        end
        -- a pasted/duplicated copy of a bandmate's take plays their file (named after its id): it's their recording,
        -- never ours to send (2026-10-28: a paste went out as the paster's take)
        local src = reaper.GetMediaItemTake_Source(tk)
        local file = (src and reaper.GetMediaSourceFileName(src) or ""):match("[^/\\]+$") or ""
        local who = file:match("^(.-)%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ%-%d+")
        who = who and who:gsub("^takes_", "") -- Solo edit's media copies are named takes_<id>
        if who and opts.me and sync.author_of(who) ~= sync.author_of(opts.me) then
          if band.take_ext(tk, "band_copied") == "" then
            band.log(string.format("a copy of %s's take on %s stays here: someone else's recording isn't sent as yours", who:gsub("_", " "), track_name(it)))
            band.set_take_ext(tk, "band_copied", "1")
          end
          return
        end
        if opts.unsent then
          if band.take_ext(tk, "band_sent") ~= "" or band.take_ext(tk, "band_base") ~= "" then return end
          -- the same audio at the same place went out before, unless that take has since been deleted
          -- (delete a paste, paste it back: it must go out again)
          local before = ext(proj, sync.SENTKEYS, content_key(it, tk))
          if before ~= "" and band.take_state(proj, before) ~= "deleted" then return end
        end
        out[#out + 1] = { it, tk }
      end
      if opts.all then
        for k = 0, reaper.CountTakes(it) - 1 do add(reaper.GetTake(it, k)) end
      else
        add(reaper.GetActiveTake(it))
      end
    end
  end
  return out
end

-- Send selection: what's highlighted. Selected items, every item on selected tracks, and with opts.everything every
-- item; with opts.from/to only what overlaps that stretch, and items of ours crossing its edges are split there
-- (lossless), so only the inside goes. Takes the band already has are left alone (edits and reprints carry their
-- changes). Returns the units for sync.send, the inside items (to select), and how many already-sent ones were left.
-- opts.dry: only look (nothing is split; the units are the whole items).
function sync.selection_units(proj, opts)
  local list, seen = {}, {}
  local function want(it)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local e = p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
    if opts.from and (p >= opts.to - 1e-6 or e <= opts.from + 1e-6) then return end
    if not seen[it] then seen[it] = true; list[#list + 1] = it end
  end
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do want(reaper.GetSelectedMediaItem(proj, i)) end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if opts.everything or reaper.IsTrackSelected(tr) then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do want(reaper.GetTrackMediaItem(tr, j)) end
    end
  end
  local ours = {} -- our own recordings only: bandmates' prints, MIDI copies and pasted copies of theirs are never cut
  for _, u in ipairs(sync.own_takes(proj, { items = list, all = true, me = opts.me })) do ours[u[1]] = true end
  local inside, had = {}, 0
  for _, it in ipairs(list) do
    if not ours[it] then goto next end
    local with_band = false -- a take the band has (and hasn't deleted): not ours to cut up or send again
    for k = 0, reaper.CountTakes(it) - 1 do
      local id = band.take_ext(reaper.GetTake(it, k), "band_sent")
      if id ~= "" and band.take_state(proj, id) ~= "deleted" then with_band = true end
    end
    if with_band then
      had = had + 1
    else
      if opts.from and not opts.dry then
        local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
        if p < opts.from - 1e-6 then it = split_piece(it, opts.from) or it end -- the left part stays here
        local e = reaper.GetMediaItemInfo_Value(it, "D_POSITION") + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
        if it and e > opts.to + 1e-6 then split_piece(it, opts.to) end -- and so does the right
      end
      inside[#inside + 1] = it
    end
    ::next::
  end
  local units = sync.own_takes(proj, { items = inside, all = opts.all_takes, unsent = true, min_len = sync.MIN_LEN, me = opts.me })
  return units, inside, had
end

local function dirs(proj, cfg, b)
  local out = (select(2, reaper.EnumProjects(-1)):match("^(.*)[/\\]") or reaper.GetResourcePath()):gsub("\\", "/") .. "/band-out"
  local takes = band.takes_dir(cfg, b.song, b.room)
  reaper.RecursiveCreateDirectory(out, 0)
  reaper.RecursiveCreateDirectory(takes, 0)
  return out, takes
end

-- Render one take as the song prints it and post it as revision `rev` of `id`.
--   wet: through its track's FX, volume and pan, at the item's exact extent
--   dry: take FX, fades and item volume only        both: wet, plus the dry print as a twin
-- Render source 32 ("selected media items") runs the item through its TRACK (FX, volume, pan; verified
-- 7.83), so a dry print bypasses the track's FX and neutralises its volume/pan for the render.
-- Works on the active tab only (REAPER renders the active project).
-- `twin`: printing someone's MIDI copy with our own instrument; it's the original track's name.
local function selection(proj)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedMediaItem(proj, i) end
  return sel
end

-- Render item `it` (its active take, which must be selected alone) to <out>/<name>.flac (+ .opus).
local function render_item(it, take, out, name, wet, tail)
  local tr = reaper.GetMediaItem_Track(it)
  local nch = reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take))
  do
    os.remove(out .. "/" .. name .. ".flac") -- leftovers would make REAPER stop on a modal "files exist" warning
    os.remove(out .. "/" .. name .. ".opus")
    local keys = { "B_MUTE", "I_FXEN", "D_VOL", "D_PAN" }
    local saved, imute, lane = {}, reaper.GetMediaItemInfo_Value(it, "B_MUTE"), lane_of(it)
    for _, k in ipairs(keys) do saved[k] = reaper.GetMediaTrackInfo_Value(tr, k) end
    local playing = lane and lanes_playing(tr)
    -- an alternate in a silent lane, or a muted item/track, must still print
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", 0)
    if lane then reaper.SetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" .. lane, 1) end
    if not wet then reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0) end
    -- the track's fader and pan aren't printed: they travel as the shared mix (track events), so moving a fader
    -- never re-renders anything, and everyone's mirror track carries the same setting
    reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1)
    reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0)
    -- the print is this item only: whatever else feeds the track (a synth routed in to record it) stays out of it
    -- (2026-10-28: Keys/Lead prints carried their source synth too, so they played twice on everyone else's machine)
    local receives = {}
    for r = 0, reaper.GetTrackNumSends(tr, -1) - 1 do
      receives[r] = reaper.GetTrackSendInfo_Value(tr, -1, r, "B_MUTE")
      reaper.SetTrackSendInfo_Value(tr, -1, r, "B_MUTE", 1)
    end
    band.render({ RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = wet and 2 or math.min(nch, 2),
      RENDER_TAILFLAG = tail and 16 or 0, RENDER_TAILMS = tail and math.floor(tail * 1000) or 0, -- 16: tail for selected items
      RENDER_ADDTOPROJ = 0 }, -- &32: selected media items, through their track
      { RENDER_FILE = out, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
    for _, k in ipairs(keys) do reaper.SetMediaTrackInfo_Value(tr, k, saved[k]) end
    for r, m in pairs(receives) do reaper.SetTrackSendInfo_Value(tr, -1, r, "B_MUTE", m) end
    reaper.SetMediaItemInfo_Value(it, "B_MUTE", imute)
    if lane then set_lanes_playing(tr, playing) end
    return out .. "/" .. name
  end
end

-- Print one take through its track (wet) to <out>/<name>.flac, leaving selection and the playing take as they
-- were. Returns the .flac path, or nil. Active tab only. (Solo edit keeps wet prints beside dry recordings.)
function sync.print_item(proj, it, take, out, name, tail)
  local sel, playing = selection(proj), reaper.GetActiveTake(it)
  reaper.SetActiveTake(take)
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  local path = render_item(it, take, out, name, true, tail) .. ".flac"
  reaper.SetActiveTake(playing)
  reaper.SelectAllMediaItems(proj, false)
  for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaItem*") then reaper.SetMediaItemSelected(s, true) end end
  return reaper.file_exists(path) and path or nil
end

-- "Share this sound": a bandmate's dry recording, through the plug-ins on our copy of their track (theirs in "Dry +
-- their plug-ins", or our own), rendered and sent as a NEW take based on theirs. It lands as an extra take in the
-- item holding the original, on every machine (the owner's too), never changing what plays: the owner picks it if
-- they like it. Their dry recording is untouched, so any sound can be made again. Returns how many went, or nil + why.
function sync.share_sound(proj, cfg, b, tr)
  if reaper.TrackFX_GetCount(tr) == 0 then return nil, "there are no plug-ins on this track to share" end
  local out, takes = dirs(proj, cfg, b)
  local stamp, seq, sent = os.date("!%Y%m%d-%H%M%SZ"), 0, 0
  local tail = band.track_has_fx(tr) and sync.TAIL or nil
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local dry = reaper.GetActiveTake(it)
    local orig = dry and band.take_ext(dry, "band_dry")
    local m0 = orig and orig ~= "" and band.read_json(takes .. "/" .. orig .. ".json")
    if m0 then
      local id
      repeat
        seq = seq + 1
        id = string.format("%s-%s-%d", (cfg.user:gsub(" ", "_")), stamp, seq)
      until not reaper.file_exists(takes .. "/" .. id .. ".json")
      local path = sync.print_item(proj, it, dry, out, id, tail)
      if path then
        band.copy_atomic(path, takes .. "/" .. id .. ".flac")
        band.write_json(takes .. "/" .. id .. ".json", {
          format = band.FORMAT, bandsync = band.VERSION, id = id, rev = 1, user = cfg.user, printed_by = cfg.user, room = b.room,
          track = m0.track, pos = m0.pos, qn = m0.qn, len = m0.len + (tail or 0), tail = tail, sent = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          full = id .. ".flac", print = "wet", wet = true, group = m0.group, lane = m0.lane, lane_name = m0.lane_name,
          session_version = m0.session_version, based_on = m0.id, sound = cfg.user .. "'s sound",
          origin = { pos = m0.pos, len = m0.len, track = m0.track, lane = m0.lane, sent = os.date("!%Y-%m-%dT%H:%M:%SZ") },
        })
        sent = sent + 1
      end
    end
  end
  if sent == 0 then return nil, "nothing to share: switch the part to Dry (or Dry + their plug-ins) and put the plug-ins you want on it" end
  return sent
end

local function print_take(proj, cfg, b, it, take, id, rev, mode, out, takes, twin)
  local tr = reaper.GetMediaItem_Track(it)
  local suffix = rev > 1 and ("-r" .. rev) or ""
  local playing = reaper.GetActiveTake(it)
  reaper.SetActiveTake(take) -- renders render the item's active take
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  local wet = mode ~= "dry" or reaper.TakeIsMIDI(take) -- MIDI without its instrument is silence: always print it wet
  -- reverbs and delays ring past the item's end: the wet print keeps 2 s of that (receivers extend the item by it)
  local tail = wet and band.track_has_fx(tr) and sync.TAIL or nil
  local main = render_item(it, take, out, id .. suffix, wet, tail)
  -- a MIDI take's dry is its notes (they travel as .midibuf); rendering it without the instrument is silence
  local dry = mode == "both" and not reaper.TakeIsMIDI(take) and render_item(it, take, out, id .. "-dry" .. suffix, false)
  reaper.SetActiveTake(playing)
  if not reaper.file_exists(main .. ".flac") then band.log("render failed for take " .. id); return nil end

  local lane = lane_of(it)
  local m = {
    format = band.FORMAT, bandsync = band.VERSION, id = id, rev = rev, user = cfg.user, room = b.room,
    track = select(2, reaper.GetTrackName(tr)), pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"),
    qn = sync.qn(proj, reaper.GetMediaItemInfo_Value(it, "D_POSITION")),
    len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), session_version = tonumber(b.version),
    sent = os.date("!%Y-%m-%dT%H:%M:%SZ"), full = id .. suffix .. ".flac", print = mode, wet = wet,
    group = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), -- passes of one item stay one item
    lane = lane, lane_name = lane and select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. lane, "", false)) or nil,
    printed_by = cfg.user, tail = tail,
  }
  local old = rev > 1 and band.read_json(takes .. "/" .. id .. ".json")
  if twin and old then -- printed from a MIDI copy: still the original's take (whose, which track, lane, item)
    for _, k in ipairs({ "user", "room", "track", "group", "lane", "lane_name", "session_version" }) do m[k] = old[k] end
  elseif twin then
    m.track = twin
  end
  -- where it first landed: the history replays edits from here (later revisions rewrite pos/len)
  m.origin = old and old.origin or { pos = m.pos, len = m.len, track = base_name(m.track), lane = m.lane, sent = old and old.sent or m.sent }
  if reaper.TakeIsMIDI(take) then -- the notes travel with the print, so anyone may edit them or print them with their own instrument
    local ok, buf = reaper.MIDI_GetAllEvts(take, "")
    if ok then
      band.write_atomic(takes .. "/" .. id .. suffix .. ".midibuf", buf)
      m.midi, m.midi_offs = id .. suffix .. ".midibuf", reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      local map = band.track_ext(tr, "band_drummap") -- the notes are in this drum map; receivers translate
      m.drummap = map ~= "" and map or nil
      m.no_instrument = reaper.TrackFX_GetInstrument(tr) < 0 or nil -- its print is silent: receivers say so
    end
  end
  if (band.size(main .. ".opus") or math.huge) < band.size(main .. ".flac") then -- a preview only helps if smaller
    band.copy_atomic(main .. ".opus", takes .. "/" .. id .. suffix .. ".opus")
    m.preview = id .. suffix .. ".opus"
  end
  if dry and reaper.file_exists(dry .. ".flac") then
    band.copy_atomic(dry .. ".flac", takes .. "/" .. id .. "-dry" .. suffix .. ".flac")
    m.dry = id .. "-dry" .. suffix .. ".flac"
  end
  if rev > 1 then -- the previous revision's shared files move to _trash (receivers keep local copies; if a new print
    -- turns out wrong, the old one is still there to bring back)
    local old = rev > 2 and ("-r" .. (rev - 1)) or ""
    local trash = sync.room_dir(cfg, b.song, b.room) .. "/_trash"
    reaper.RecursiveCreateDirectory(trash, 0)
    for _, f in ipairs({ id .. old .. ".flac", id .. old .. ".opus", id .. "-dry" .. old .. ".flac", id .. old .. ".midibuf" }) do
      if reaper.file_exists(takes .. "/" .. f) then band.to_trash(takes, trash, f) end
    end
  end
  local ok_c, chunk = reaper.GetTrackStateChunk(tr, "", false)
  local chain = ok_c and sync.chunk_block(chunk, "FXCHAIN")
  if chain then -- the track's plug-ins with their settings, for dry mode on other machines (lib/tools.lua)
    local function safe(s) return (s:gsub("[^%w%-_ ]", function(c) return string.format("%%%02X", c:byte()) end)) end -- reversible: no collisions
    local rel = "fx/" .. safe(cfg.user) .. "/" .. safe(base_name(m.track)) .. ".fxchain"
    reaper.RecursiveCreateDirectory(sync.room_dir(cfg, b.song, b.room) .. "/" .. rel:match("^(.*)/"), 0)
    band.write_atomic(sync.room_dir(cfg, b.song, b.room) .. "/" .. rel, chain)
    m.fxchain = rel
  end
  band.write_json(takes .. "/" .. id .. ".json", m) -- one manifest per take, rewritten for each revision
  band.copy_atomic(main .. ".flac", takes .. "/" .. m.full)
  setext(proj, sync.REV, id, tostring(rev))
  setext(proj, sync.PRINTER, id, cfg.user)
  band.set_take_ext(take, "band_fxhash", fxhash(it, take, wet))
  if reaper.TakeIsMIDI(take) then sync.midi_seen(proj, id, take) end
  if twin then -- a MIDI copy printed with our instrument stays a copy; the print we hold becomes ours
    band.update_take(proj, m, takes .. "/" .. m.full, m.dry and (takes .. "/" .. m.dry))
    return m
  end
  band.set_take_ext(take, "band_sent", id)
  band.mark_base(take)
  band.follow_tempo(it, take)
  band.set_take_state(proj, id, "full") -- this project already has it: its own sync must not re-import it
  setext(proj, sync.SENTKEYS, content_key(it, take), id)
  -- a new revision (rev > 1) keeps the old shape snapshot: if it was moved, trimmed or muted too, that goes out
  -- as an edit, so History knows it (2026-10-28: a split's trim travelled only in a reprint, and a restore undid it)
  sync.remember(proj, id, it, take, rev > 1)
  if reaper.GetMediaItemInfo_Value(it, "B_MUTE") ~= 0 then -- manifests don't carry mute: the next look sends it as an edit
    setext(proj, sync.SNAP, id, (ext(proj, sync.SNAP, id):gsub("|1|([^|]*)$", "|0|%1")))
  end
  return m
end

local function finish(proj, sel)
  reaper.SelectAllMediaItems(proj, false)
  for _, it in ipairs(sel) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end end
  reaper.UpdateArrange()
  if select(2, reaper.EnumProjects(-1)) ~= "" then reaper.Main_SaveProject(proj, false) end -- sent marks survive a crash
end

-- Print and post {item, take} pairs as new takes. Returns how many went out.
function sync.send(proj, cfg, b, units, mode)
  local out, takes = dirs(proj, cfg, b)
  local sel, stamp, seq, sent = selection(proj), os.date("!%Y%m%d-%H%M%SZ"), 0, 0
  for _, u in ipairs(units) do
    local id
    repeat -- per-second ids must not collide when two sends land in one second
      seq = seq + 1
      id = string.format("%s-%s-%d", (cfg.user:gsub(" ", "_")), stamp, seq)
    until not reaper.file_exists(takes .. "/" .. id .. ".json")
    if print_take(proj, cfg, b, u[1], u[2], id, 1, mode or "wet", out, takes) then sent = sent + 1 end
  end
  if sent > 0 then finish(proj, sel) end
  return sent
end

-- Reprint our sent takes whose sound changed (FX added/changed/bypassed, volume, pan, fades) as their
-- next revision; everyone's copy updates in place. Returns how many were reprinted.
function sync.reprint(proj, cfg, b, mode)
  local todo = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id, twin = band.take_ext(tk, "band_sent"), nil
      if id == "" then -- a MIDI copy we printed with our own instrument: we keep that print current
        id, twin = band.take_ext(tk, "band_midi"), band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")
      end
      local printer = id ~= "" and ext(proj, sync.PRINTER, id) or ""
      -- once someone else has printed this take with their own instrument, their print stands: we don't
      -- overwrite it with ours (our note edits still reach them as MIDI)
      -- a MIDI copy only reprints through a real instrument: without one its print is silence, and it would replace
      -- the take's audible print for everyone (2026-10-28)
      local silent = twin and reaper.TrackFX_GetInstrument(reaper.GetMediaItem_Track(it)) < 0
      if id ~= "" and not silent and (printer == cfg.user or (printer == "" and not twin)) then
        local wet = mode ~= "dry" or reaper.TakeIsMIDI(tk)
        local have, now = band.take_ext(tk, "band_fxhash"), fxhash(it, tk, wet)
        if have ~= now then
          if have == fxhash(it, tk, wet, true) then band.set_take_ext(tk, "band_fxhash", now) -- same sound, older fingerprint
          else todo[#todo + 1] = { it, tk, id, twin } end
        end
      end
    end
  end
  if #todo == 0 then return 0 end
  local out, takes = dirs(proj, cfg, b)
  local sel, n = selection(proj), 0
  for i, u in ipairs(todo) do
    if i > 2 then break end -- each print blocks REAPER for a moment: two per pass, the rest on the next ones
    local rev = (tonumber(ext(proj, sync.REV, u[3])) or 1) + 1
    if print_take(proj, cfg, b, u[1], u[2], u[3], rev, mode, out, takes, u[4]) then n = n + 1 end
  end
  finish(proj, sel)
  return n
end

-- Our sent takes whose files vanished from the shared folder (deleted by hand, a sync conflict) are printed
-- again: their fingerprint is cleared, so the next reprint pass sends a fresh revision. Returns how many.
function sync.check_own_files(proj, cfg, b)
  local takes, n = band.takes_dir(cfg, b.song, b.room), 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_ext(tk, "band_sent")
      local m = id ~= "" and band.take_state(proj, id) ~= "deleted" and band.read_json(takes .. "/" .. id .. ".json")
      if m and m.full and not reaper.file_exists(takes .. "/" .. m.full) and band.take_ext(tk, "band_fxhash") ~= "" then
        band.set_take_ext(tk, "band_fxhash", "")
        band.log(string.format("%s's print is missing from the shared folder: printing it again", id))
        n = n + 1
      end
    end
  end
  return n
end

-- "Print my MIDI": render MIDI copies through this person's "(MIDI)" track and instrument, and post each
-- as the take's next revision; everyone hears the new print, and they keep it current from then on.
-- units: { item, take, id, original track name }.
function sync.print_midi(proj, cfg, b, units, mode)
  local out, takes = dirs(proj, cfg, b)
  local sel, n = selection(proj), 0
  for _, u in ipairs(units) do
    local rev = (tonumber(ext(proj, sync.REV, u[3])) or 1) + 1
    if print_take(proj, cfg, b, u[1], u[2], u[3], rev, mode, out, takes, u[4]) then n = n + 1 end
  end
  finish(proj, sel)
  return n
end

-- ---- events -------------------------------------------------------------------------------------

local ev_seq = 0
-- With `proj`, an edit or track change is ordered after the newest change to it seen here, and remembered as that.
function sync.post(cfg, song, room, ev, proj)
  ev_seq = ev_seq + 1
  ev.format, ev.user, ev.time = band.FORMAT, cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  ev.id = string.format("%s-%s-%05d-%04d", (cfg.user:gsub(" ", "_")), os.date("!%Y%m%d-%H%M%SZ"), ev_seq, math.random(0, 9999))
  local k = proj and newest_key(ev, ev.was)
  if k then
    local seen = ext(proj, sync.NEWEST, k)
    if seen >= ev.time .. ev.id then ev.order = seen .. "+" end
  end
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  reaper.RecursiveCreateDirectory(dir, 0)
  band.write_json(dir .. "/" .. ev.id .. ".json", ev)
  if proj then stamp(proj, ev) end
  return ev.id
end

-- A deleted take's files back from the room's _trash (an undone delete): everyone imports it again.
function sync.untrash(cfg, song, room, id)
  local to, from, lid = band.takes_dir(cfg, song, room), sync.room_dir(cfg, song, room) .. "/_trash", id:lower()
  for _, f in ipairs(band.files(from)) do
    local lf = f:lower()
    if lf:sub(1, #lid + 1) == lid .. "." or lf:sub(1, #lid + 1) == lid .. "-" then os.rename(from .. "/" .. f, to .. "/" .. f) end
  end
end

-- Move a deleted take's files to the room's _trash, so nobody imports it later and nothing is lost.
function sync.trash(cfg, song, room, id)
  local from, to = band.takes_dir(cfg, song, room), sync.room_dir(cfg, song, room) .. "/_trash"
  reaper.RecursiveCreateDirectory(to, 0)
  for _, f in ipairs(band.files(from)) do
    if f:lower():sub(1, #id + 1) == (id .. "."):lower() or f:lower():sub(1, #id + 1) == (id .. "-"):lower() then
      band.to_trash(from, to, f)
    end
  end
end

-- Delete a take and its dry twin; the whole item when nothing else is in it. Deleting one take can
-- rebuild the item (SWS's NF_DeleteTakeFromItem left the old item pointer invalid), so after every
-- delete the item is found again by GUID and the next doomed take by its BandSync tags. Without SWS,
-- single takes go through an action on the active tab only: false means retry later.
local function delete_take(proj, it, tk, id)
  local lid = id:lower()
  local function doomed(t2) return (band.take_id(t2) or ""):lower() == lid or band.take_ext(t2, "band_dry"):lower() == lid end
  local others = 0
  for k = 0, reaper.CountTakes(it) - 1 do if not doomed(reaper.GetTake(it, k)) then others = others + 1 end end
  if others == 0 then
    reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it)
    return true
  end
  -- single takes can only be removed in the active tab: the action needs it, and SWS's NF_DeleteTakeFromItem
  -- rejects items of a background project with a modal "expected MediaItem*" error that pcall can't catch
  if reaper.EnumProjects(-1) ~= proj then return false end
  local guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false))
  local playing = select(2, reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(it), "GUID", "", false))
  local function find_item()
    for i = 0, reaper.CountMediaItems(proj) - 1 do
      local it2 = reaper.GetMediaItem(proj, i)
      if select(2, reaper.GetSetMediaItemInfo_String(it2, "GUID", "", false)) == guid then return it2 end
    end
  end
  local sel = selection(proj)
  for _ = 1, 8 do -- a take and its twin; bounded so a take that won't delete can't spin forever
    local item = find_item()
    if not item then break end
    local k
    for j = 0, reaper.CountTakes(item) - 1 do if doomed(reaper.GetTake(item, j)) then k = j; break end end
    if not k then break end
    if reaper.NF_DeleteTakeFromItem then
      reaper.NF_DeleteTakeFromItem(item, k)
    else
      reaper.SelectAllMediaItems(proj, false)
      reaper.SetMediaItemSelected(item, true)
      reaper.SetActiveTake(reaper.GetTake(item, k))
      reaper.Main_OnCommand(40129, 0) -- Take: Delete active take from items
    end
  end
  local item = find_item()
  if item then -- keep what was playing, if it survived
    for j = 0, reaper.CountTakes(item) - 1 do
      local t2 = reaper.GetTake(item, j)
      if select(2, reaper.GetSetMediaItemTakeInfo_String(t2, "GUID", "", false)) == playing then reaper.SetActiveTake(t2) end
    end
  end
  reaper.SelectAllMediaItems(proj, false)
  for _, s in ipairs(sel) do if reaper.ValidatePtr2(proj, s, "MediaItem*") then reaper.SetMediaItemSelected(s, true) end end
  return true
end

-- Which BandSync takes are audible on a track: the active take of each item in a playing lane.
-- Returns whether the track holds any BandSync takes, and their sorted ids.
function sync.audible(tr)
  local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
  local any, ids = false, {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local active = reaper.GetActiveTake(it)
    local lane_on = not lanes or reaper.GetMediaTrackInfo_Value(tr, "C_LANEPLAYS:" ..
      math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))) ~= 0
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then
        any = true
        if tk == active and lane_on then ids[#ids + 1] = id:lower() end
      elseif tk == active and lane_on and band.take_ext(tk, "band_dry") ~= "" then -- dry mode plays the dry twin: same take
        ids[#ids + 1] = band.take_ext(tk, "band_dry"):lower()
      end
    end
  end
  table.sort(ids)
  return any, table.concat(ids, ",")
end

-- Make exactly `list` (ids) audible on a track. With `local_only`, the snapshot isn't updated, so Live sync
-- sees the change and posts it as this person's own (that's how a recall point restores lane choices).
local function apply_plays(proj, trackname, list, local_only)
  local want, idx = {}, band.take_index(proj)
  for _, id in ipairs(list) do
    want[id:lower()] = true
    -- wait until every take it names is here (unless deleted), or the lanes it names don't exist yet
    if not idx[id:lower()] and band.take_state(proj, id) ~= "deleted" then return false end
  end
  for _, n in ipairs({ trackname, trackname .. " (band)" }) do -- wet prints may sit on a mirror track
    local tr = band.find_track(proj, n, true)
    if tr then
      local lanes = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") == 2
      local lane_band, lane_want = {}, {}
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local lane = math.floor(reaper.GetMediaItemInfo_Value(it, "I_FIXEDLANE"))
        for k = 0, reaper.CountTakes(it) - 1 do
          local tk = reaper.GetTake(it, k)
          local id = band.take_id(tk)
          if id then
            lane_band[lane] = true
            if want[id:lower()] then
              lane_want[lane] = true
              reaper.SetActiveTake(sync.dry_mode_take(tr, it, tk) or tk)
            end
          end
        end
      end
      if lanes and next(lane_band) then -- the lanes holding the driver's choice play (one lane, or all)
        local on = {}
        for lane in pairs(lane_want) do on[#on + 1] = lane end
        table.sort(on)
        set_lanes_playing(tr, on)
      end
      if not local_only then setext(proj, sync.PLAYS, n, select(2, sync.audible(tr))) end
    end
  end
  return true
end
sync.set_plays = function(proj, trackname, list) return apply_plays(proj, trackname, list, true) end

-- On a track in dry mode (lib/tools.lua), the dry twin of take tk plays instead of the print; nil otherwise.
function sync.dry_mode_take(tr, it, tk)
  local mode = band.track_ext(tr, "band_drymode")
  if mode ~= "1" and mode ~= "raw" then return nil end -- (dry through their plug-ins, or plain dry)
  local id = band.take_id(tk)
  for k = 0, reaper.CountTakes(it) - 1 do
    local t2 = reaper.GetTake(it, k)
    if id and band.take_ext(t2, "band_dry"):lower() == id:lower() then return t2 end
  end
end
sync.delete_take = delete_take -- recall points delete locally; Live sync then posts it
sync.lane_of, sync.track_name = lane_of, track_name

-- Track properties that follow whoever owns the track: name, mute, solo, colour, icon (by file name: icons
-- live in REAPER's own folder, so the same built-in icon exists everywhere).
local function track_props(tr)
  local icon = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", "", false))
  return string.format("%s|%d|%d|%d|%s|%.2f|%.2f", base_name(select(2, reaper.GetTrackName(tr))), reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
    reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"), reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"), icon:match("[^/\\]+$") or icon,
    20 * math.log(math.max(reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), 1e-9), 10), reaper.GetMediaTrackInfo_Value(tr, "D_PAN"))
end
local function track_guid(tr) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)) end
local function holds_takes(tr)
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    for k = 0, reaper.CountTakes(it) - 1 do if band.take_id(reaper.GetTake(it, k)) then return true end end
  end
  return false
end

local function apply_track(proj, ev)
  local from, found = ev.was or ev.track, false
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local name = select(2, reaper.GetTrackName(tr))
    if band.track_ext(tr, "band_stem") == "" and base_name(name):lower() == from:lower() then
      local suffix = name:match(" %(band%)$") or ""
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", ev.track .. suffix, true)
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", ev.mute or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_SOLO", ev.solo or 0)
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", ev.color or 0)
      reaper.GetSetMediaTrackInfo_String(tr, "P_ICON", ev.icon or "", true)
      if ev.vol then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", ev.vol) end -- the shared mix (0.8+)
      if ev.pan then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", ev.pan) end
      setext(proj, sync.TRACKS, track_guid(tr), track_props(tr)) -- so this isn't seen as a local change
      found = true
    end
  end
  reaper.TrackList_AdjustWindows(false)
  return found -- no such track here yet (its takes are still coming): try again later
end

-- A note on an item shows on every take of it (the print, its dry twin in dry mode, ...), at song position pos.
function sync.mark_item(it, pos, text)
  local ipos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    reaper.SetTakeMarker(tk, -1, text, math.max(0, (pos or ipos) - ipos + reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")))
  end
  reaper.UpdateItemInProject(it)
end

-- Apply one event from whoever may make it. False means retry later (its take hasn't arrived, or a
-- delete needs this tab in front).
-- `dir`: the room's folder (where "midi" events keep their note files); `root`: the shared folder (drum maps).
function sync.apply(proj, ev, dir, root, can, me)
  if ev.type == "plays" then return apply_plays(proj, ev.track, ev.takes or {}) end
  if ev.type == "track" then return apply_track(proj, ev) end
  if ev.type == "timeline" then -- REAPER moves the items for the new map, as it would for a local change
    sync.audio_follow_tempo(proj)
    band.apply_tempo(proj, ev.tempo or {})
    band.apply_markers(proj, ev.markers or {})
    setext(proj, band.SECTION, "timeline", timeline_sig(proj))
    sync.resnap(proj)
    return true
  end
  if ev.type == "shift" then -- the driver inserted or removed time: same edit here, on every track
    sync.shift(proj, ev.at, ev.len, { split = sync.recorded_by(me), before = ev.time, tempo = ev.tempo, markers = ev.markers })
    setext(proj, "BandSync.shifts", ev.id, "1") -- edits that came of it wait for this
    return true
  end
  if ev.type == "start" or ev.type == "stop" then -- Live sync's tick fires it at the right moment (lib/together.lua)
    reaper.SetExtState(band.SECTION, "transport " .. tostring(proj), band.json_encode(ev), false)
    return true
  end
  if ev.type == "note" or ev.type == "like" then
    local it2 = ev.take and band.find_take(proj, ev.take)
    if it2 then sync.mark_item(it2, ev.pos, (ev.type == "like" and "+1 " or "") .. ev.user .. (ev.text and (": " .. ev.text) or "")) end
    return true -- notes without a take live in the panel's Notes list (and History)
  end
  if not ev.take then return true end -- "driver" and other take-less events: nothing to change in the project
  local it, tk = band.find_take(proj, ev.take)
  local mit, mtk = band.find_midi(proj, ev.take)
  if it then reaper.SetMediaItemInfo_Value(it, "C_LOCK", 0) end -- view-only locks are for people, not for sync
  if mit then reaper.SetMediaItemInfo_Value(mit, "C_LOCK", 0) end
  if ev.type == "midi" then -- someone edited the notes: our MIDI copy follows, and so does the original's source
    local buf = dir and band.read(dir .. "/midi/" .. ev.file)
    if not buf then return false end -- not synced here yet
    for _, t2 in pairs({ mtk or false, tk and reaper.TakeIsMIDI(tk) and tk }) do
      if t2 then
        reaper.MIDI_SetAllEvts(t2, band.to_track_map(root, buf, ev.drummap, reaper.GetMediaItem_Track(reaper.GetMediaItemTake_Item(t2))))
        reaper.MIDI_Sort(t2)
        sync.midi_seen(proj, ev.take, t2) -- applied, not a local edit (Live sync reprints if the print is ours)
      end
    end
    return true
  end
  if ev.type == "delete" then
    band.set_take_state(proj, ev.take, "deleted") -- also stops a late arrival from being imported
    if mit then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(mit), mit) end
    if not it then return true end
    return delete_take(proj, it, tk, ev.take)
  elseif ev.type == "undelete" then -- a recall point brought it back: import it again
    if band.take_state(proj, ev.take) == "deleted" then
      local chunk = ext(proj, sync.ITEMS, ev.take)
      if chunk ~= "" and ev.track then -- ours: our real item (source, instrument track) comes back where it was,
        -- not an import of our own print as a "(band)" mirror (2026-10-28: that mirror then reprinted silent)
        local tr = band.find_track(proj, ev.track, true) or band.new_track(proj, ev.track)
        local it2 = tr and reaper.AddMediaItemToTrack(tr)
        if it2 and reaper.SetItemStateChunk(it2, chunk, false) then
          band.set_take_state(proj, ev.take, "full")
          local hit = band.take_index(proj)[ev.take:lower()]
          if hit then sync.remember(proj, ev.take, hit[1], hit[2]) end
          return true
        end
      end
      band.set_take_state(proj, ev.take, "")
    end
    return true
  elseif ev.type == "edit" then
    if ev.after and ext(proj, "BandSync.shifts", ev.after) == "" and ext(proj, sync.APPLIED, ev.after) == "" and iso_age(ev.time) < 600 then
      return false -- the insert/remove it came from hasn't arrived yet (after 10 minutes it goes ahead anyway)
    end
    if not it then return band.take_state(proj, ev.take) == "deleted" end
    if ev.track and track_name(it):lower() ~= ev.track:lower() then -- moved to another track
      local dest = band.dest_track(proj, ev.track, band.take_ext(tk, "band_wet") == "1")
      if not dest then return false end -- needs this tab in front on REAPER < 7.18
      reaper.MoveMediaItemToTrack(it, dest)
    end
    ev.pos = sync.here(proj, ev.pos, ev.qn)
    reaper.SetMediaItemInfo_Value(it, "D_POSITION", ev.pos)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", ev.len + (tonumber(ext(proj, sync.TAILS, ev.take)) or 0))
    if ev.mute then reaper.SetMediaItemInfo_Value(it, "B_MUTE", ev.mute) end
    local offs = band.base_offs(tk) + (ev.offs or 0) -- offsets travel relative to where each print was placed
    for k = 0, reaper.CountTakes(it) - 1 do
      local t2 = reaper.GetTake(it, k)
      if t2 == tk or band.take_ext(t2, "band_dry"):lower() == ev.take:lower() then reaper.SetMediaItemTakeInfo_Value(t2, "D_STARTOFFS", offs) end
    end
    if ev.lane then
      local tr = reaper.GetMediaItem_Track(it)
      if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2) end
      if reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < ev.lane + 1 then reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", ev.lane + 1) end
      reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", ev.lane)
    end
    reaper.UpdateItemInProject(it)
    sync.remember(proj, band.take_id(tk) or ev.take, it, tk) -- so this change isn't seen as a local edit
    if mit then -- the MIDI copy keeps sitting under its print
      reaper.SetMediaItemInfo_Value(mit, "D_POSITION", ev.pos)
      reaper.SetMediaItemInfo_Value(mit, "D_LENGTH", ev.len)
      reaper.SetMediaItemTakeInfo_Value(mtk, "D_STARTOFFS", band.base_offs(mtk) + (ev.offs or 0))
      reaper.UpdateItemInProject(mit)
    end
    return true
  end
  return true -- unknown types from newer versions are skipped
end

-- Compare the project with its snapshots and post what changed, for whatever `can` says this person may
-- change (track owner, region owner or driver). Changes they may not make stay local (and are locked in
-- the first place, see apply_locks). Hold sync doesn't call this at all: the snapshots keep the last
-- synced state, so releasing the hold sends the net result once.
function sync.watch(proj, cfg, song, room, can)
  local me = cfg.user
  -- tempo map / markers first: if they changed, REAPER has just moved items for it, and those moves aren't edits
  local sig, seen = timeline_sig(proj), ext(proj, band.SECTION, "timeline")
  if seen ~= sig then
    if seen ~= "" then
      if can(me, nil, nil) then -- the song's timeline is the driver's
        local tempo, markers = band.capture_tempo(proj), band.capture_markers(proj)
        sync.post(cfg, song, room, { type = "timeline", tempo = tempo, markers = markers })
        sync.session_timeline(cfg, song, tempo, markers)
        band.log("sent the new tempo map and markers to the band")
        local from = math.huge -- where the map first differs: audio past there keeps its recorded speed
        local before = band.json_decode(seen) or {}
        for i, m in ipairs(tempo) do
          local o = (before[1] or {})[i]
          if not o or o.time ~= m.time or o.bpm ~= m.bpm or o.num ~= m.num or o.denom ~= m.denom then from = math.min(from, m.time) end
        end
        if #(before[1] or {}) > #tempo then from = math.min(from, (before[1][#tempo + 1] or {}).time or from) end
        local n = 0
        for _, hit in pairs(band.take_index(proj)) do
          local p = reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION")
          if not reaper.TakeIsMIDI(hit[2]) and p + reaper.GetMediaItemInfo_Value(hit[1], "D_LENGTH") > from then n = n + 1 end
        end
        if n > 0 then
          band.log(string.format("%d audio take(s) play past the tempo change at %.2f s: REAPER stretches them there (MIDI parts are reprinted at the new tempo instead); re-record those bars for the best sound", n, from))
        end
      else
        band.log("tempo or markers changed here, but only the driver's changes go to the band (Take control first)")
      end
    end
    setext(proj, band.SECTION, "timeline", sig)
    sync.resnap(proj, true)
  end
  local idx = band.take_index(proj)
  local i = 0
  while true do
    local ok, key, state = reaper.EnumProjExtState(proj, band.TAKES, i)
    if not ok then break end
    i = i + 1
    local undone = state == "deleted" and ext(proj, "BandSync.mydel", ext(proj, sync.SNAP, key):match("^([^|]+)") or key) ~= ""
      and idx[(ext(proj, sync.SNAP, key):match("^([^|]+)") or key):lower()]
    if undone then -- a delete we sent, undone here (Ctrl+Z): it comes back for the band too (break round 2: only here)
      local sid = ext(proj, sync.SNAP, key):match("^([^|]+)") or key
      local pos, track = reaper.GetMediaItemInfo_Value(undone[1], "D_POSITION"), band_track_name(proj, undone[1])
      setext(proj, "BandSync.mydel", sid, "")
      if can(me, track, pos, sid) or sync.author(sid) == sync.author_of(me) then
        sync.untrash(cfg, song, room, sid)
        band.set_take_state(proj, sid, "full")
        sync.post(cfg, song, room, { type = "undelete", take = sid, track = track, pos = pos })
        setext(proj, sync.SNAP, sid, sid .. "|") -- so the next look sends where it sits (an edit, applied once it's back)
        band.log("'" .. sid .. "' is back (undo): back for the band too")
      elseif delete_take(proj, undone[1], undone[2], sid) then
        band.log("'" .. sid .. "' stays deleted for the band (it's " .. tostring(sync.owner_of and sync.owner_of(track, pos) or "someone else") .. "'s now): removed here again")
      end
    elseif state ~= "deleted" then
      local snap = ext(proj, sync.SNAP, key)
      local sid = snap:match("^([^|]+)") or key
      local hit = idx[sid:lower()]
      if not hit then
        local f = {}
        for v in (snap .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end -- id|pos|len|offs|lane|mute|track
        local pos, track = tonumber(f[2]), f[7]
        band.set_take_state(proj, sid, "deleted")
        local mit = band.find_midi(proj, sid) -- its MIDI copy goes with it
        if mit then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(mit), mit) end
        if can(me, track, pos) or sync.author(sid) == sync.author_of(me) then -- your own take you may always take back
          sync.post(cfg, song, room, { type = "delete", take = sid, track = track, pos = pos })
          sync.trash(cfg, song, room, sid)
          setext(proj, "BandSync.mydel", sid, "1") -- if it reappears here, that's an undo of this delete
          sync.need_save = true -- saved at once: after a crash the deleted take came back here (Mac, 2026-10-28)
        else -- not yours to delete: it comes back with the next import (the band still has it), placed, trimmed and
          -- muted as it was here: the manifest only knows how it was sent (break round 2: a re-import lost a mute)
          band.set_take_state(proj, sid, "")
          if pos then
            setext(proj, sync.PENDING, sid, band.json_encode({ track = track ~= "" and track or nil, pos = pos,
              len = (tonumber(f[3]) or 0) - (tonumber(ext(proj, sync.TAILS, sid)) or 0), lane = tonumber(f[5]), mute = tonumber(f[6]),
              offs = (tonumber(f[4]) or 0) - (tonumber(ext(proj, "BandSync.base", sid)) or 0) }))
          end
          band.log(string.format("'%s' on %s is %s's to delete: it comes back", sid, tostring(track), tostring(sync.owner_of and sync.owner_of(track, pos) or "someone else")))
        end
      else
        local id = band.take_id(hit[2]) or sid -- the take's own id keeps its case; state keys may be upper-cased
        if snap == "" then
          sync.remember(proj, id, hit[1], hit[2]) -- first look at a take placed before snapshots existed
        elseif snap ~= id .. "|" .. shape(hit[1], hit[2]) then
          local pos, track = reaper.GetMediaItemInfo_Value(hit[1], "D_POSITION"), band_track_name(proj, hit[1])
          if can(me, track, pos, id) then
            local after = ext(proj, band.SECTION, "last_shift") -- set by Insert/Remove bars: receivers apply that first
            local ev = { type = "edit", take = id, after = after ~= "" and after or nil, pos = pos, qn = sync.qn(proj, pos), track = track,
              len = reaper.GetMediaItemInfo_Value(hit[1], "D_LENGTH") - (tonumber(ext(proj, sync.TAILS, id)) or 0), lane = lane_of(hit[1]),
              mute = reaper.GetMediaItemInfo_Value(hit[1], "B_MUTE"),
              offs = reaper.GetMediaItemTakeInfo_Value(hit[2], "D_STARTOFFS") - band.base_offs(hit[2]) }
            sync.post(cfg, song, room, ev, proj)
            sync.remember(proj, id, hit[1], hit[2])
            local mit, mtk = band.find_midi(proj, id) -- its MIDI copy keeps sitting under it here too, as when the change comes from the band
            if mit then
              reaper.SetMediaItemInfo_Value(mit, "D_POSITION", pos)
              reaper.SetMediaItemInfo_Value(mit, "D_LENGTH", ev.len)
              reaper.SetMediaItemTakeInfo_Value(mtk, "D_STARTOFFS", band.base_offs(mtk) + ev.offs)
              reaper.UpdateItemInProject(mit)
            end
          else -- not yours to change (someone's claim, or the driver's): put it back where the band has it, and say so
            local f = {}
            for v in (snap .. "|"):gmatch("([^|]*)|") do f[#f + 1] = v end -- id|pos|len|offs|lane|mute|track
            local it, tk = hit[1], hit[2]
            if f[7] and f[7] ~= "" and track_name(it):lower() ~= f[7]:lower() then
              local back = band.find_track(proj, f[7], true)
              if back then reaper.MoveMediaItemToTrack(it, back) end
            end
            reaper.SetMediaItemInfo_Value(it, "D_POSITION", tonumber(f[2]) or 0)
            reaper.SetMediaItemInfo_Value(it, "D_LENGTH", tonumber(f[3]) or reaper.GetMediaItemInfo_Value(it, "D_LENGTH"))
            reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", tonumber(f[4]) or 0)
            if tonumber(f[5]) then reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", tonumber(f[5])) end
            reaper.SetMediaItemInfo_Value(it, "B_MUTE", tonumber(f[6]) or 0)
            reaper.UpdateItemInProject(it)
            local owner = sync.owner_of and sync.owner_of(track, pos) or "someone else"
            band.log(string.format("'%s' on %s is %s's to change: put back (claim it, or take control)", id, f[7] or track, owner))
            if snap ~= id .. "|" .. shape(it, tk) then sync.remember(proj, id, it, tk) end -- couldn't land exactly: don't fight it every pass
          end
        end
      end
    end
  end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if band.track_ext(tr, "band_stem") == "" and holds_takes(tr) and speaks_for_name(proj, tr) then
      local full = select(2, reaper.GetTrackName(tr))
      local name = base_name(full)
      local any, ids = sync.audible(tr)
      if any and ids ~= ext(proj, sync.PLAYS, full) then
        if can(me, name, nil) then
          local list = {}
          for id in ids:gmatch("[^,]+") do list[#list + 1] = id end
          sync.post(cfg, song, room, { type = "plays", track = name, takes = list })
        end
        setext(proj, sync.PLAYS, full, ids)
      end
      local guid, props = track_guid(tr), track_props(tr)
      local before = ext(proj, sync.TRACKS, guid)
      if before ~= props then
        local was = before:match("^([^|]*)")
        local changed = {} -- what actually changed, so History says "colour changed", not "unmuted"
        local bf, nf = {}, {}
        for v in (before .. "|"):gmatch("([^|]*)|") do bf[#bf + 1] = v end
        for v in (props .. "|"):gmatch("([^|]*)|") do nf[#nf + 1] = v end
        for k, field in ipairs({ "name", "mute", "solo", "color", "icon", "vol", "pan" }) do
          if bf[k] ~= nf[k] and not (k > 5 and bf[k] == nil) then changed[#changed + 1] = field end -- (snapshots before 0.8 had no fader)
        end
        -- colour/icon alone don't go out: they're cosmetic, and auto-colouring (SWS) recolours tracks whenever tracks
        -- are added, which filled History with changes nobody made; they still travel with a real change
        local real = false
        for _, f in ipairs(changed) do if f ~= "color" and f ~= "icon" then real = true end end
        if real and before ~= "" and can(me, (was and was ~= "") and was or name, nil) then
          local ev = { type = "track", track = name, was = (was ~= name) and was or nil, changed = changed,
            mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"), solo = reaper.GetMediaTrackInfo_Value(tr, "I_SOLO"),
            color = reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"), icon = nf[5],
            vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL"), pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN") }
          sync.post(cfg, song, room, ev, proj)
        elseif before ~= "" and was and was ~= "" and was ~= name then
          -- not yours to rename: the band's takes for it would arrive on a new track of the old name. Mute, solo and
          -- level stay yours to change locally (listening); the name goes back.
          local full = select(2, reaper.GetTrackName(tr))
          reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", was .. (full:match(" %(band%)$") or ""), true)
          band.log(string.format("'%s' is %s's track to rename: name put back", was, tostring(sync.owner_of and sync.owner_of(was) or "someone else")))
          props = track_props(tr)
        end
        setext(proj, sync.TRACKS, guid, props)
      end
    end
  end
  -- note edits: on a MIDI copy, or on our own MIDI take once someone else prints it (else our reprint carries them)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id, track = tk and band.take_ext(tk, "band_midi") or "", nil
    if id ~= "" then
      track = band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")
    elseif tk and reaper.TakeIsMIDI(tk) and band.take_ext(tk, "band_sent") ~= "" then
      id = band.take_ext(tk, "band_sent")
      local printer = ext(proj, sync.PRINTER, id)
      if printer ~= "" and printer ~= me then track = track_name(it) end
    end
    local before = track and ext(proj, sync.MIDIHASH, id)
    if before and before ~= select(2, reaper.MIDI_GetHash(tk, false, "")) then
      local pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      if before ~= "" and can(me, track, pos, id) then
        local ok, buf = reaper.MIDI_GetAllEvts(tk, "")
        local file = string.format("%s-%s-%s.midibuf", id, (me:gsub("[^%w%-_]", "_")), os.date("!%Y%m%d-%H%M%S"))
        if ok then
          reaper.RecursiveCreateDirectory(sync.room_dir(cfg, song, room) .. "/midi", 0)
          band.write_atomic(sync.room_dir(cfg, song, room) .. "/midi/" .. file, buf)
          local map = band.track_ext(reaper.GetMediaItem_Track(it), "band_drummap")
          sync.post(cfg, song, room, { type = "midi", take = id, track = track, pos = pos, file = file, drummap = map ~= "" and map or nil })
        end
      end
      sync.midi_seen(proj, id, tk)
    end
  end
end

-- View-only: lock (item lock) the BandSync takes this person may not change, so nothing silently diverges;
-- unlock them when they may (took control, claimed the track). Only locks BandSync set are ever removed.
function sync.apply_locks(proj, can, me)
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local name = tk and (band.take_id(tk) and track_name(it) or band.take_ext(tk, "band_midi") ~= "" and
      band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")) -- MIDI copies belong to their print's track
    if name then
      local allowed = can(me, name, reaper.GetMediaItemInfo_Value(it, "D_POSITION"), band.take_id(tk) or band.take_ext(tk, "band_midi"))
      local lock = math.floor(reaper.GetMediaItemInfo_Value(it, "C_LOCK"))
      local ours = band.item_ext(it, "band_locked") ~= ""
      if not allowed and lock & 1 == 0 then
        reaper.SetMediaItemInfo_Value(it, "C_LOCK", lock | 1)
        band.set_item_ext(it, "band_locked", "1")
      elseif allowed and ours then
        reaper.SetMediaItemInfo_Value(it, "C_LOCK", lock & ~1)
        band.set_item_ext(it, "band_locked", "")
      end
    end
  end
end

-- Apply events this project hasn't applied yet, oldest first, from whoever may make each one.
function sync.receive(proj, cfg, song, room, can)
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local pending = {}
  local drivers = sync.driver_history(proj, cfg, song, room)
  for _, f in ipairs(band.files(dir, ".json")) do
    if ext(proj, sync.APPLIED, f:sub(1, -6)) == "" then
      local ev = band.read_json(dir .. "/" .. f)
      -- a malformed or half-synced file must not stop everything behind it
      if type(ev) == "table" and type(ev.id) == "string" and type(ev.time) == "string" and type(ev.user) == "string" and type(ev.type) == "string" then
        pending[#pending + 1] = ev
        if ev.type == "driver" then drivers[ev.id] = { time = ev.time, user = ev.driver or ev.user } end
      end
    end
  end
  table.sort(pending, function(a, x) return (a.time .. a.id) < (x.time .. x.id) end)
  local function driver_at(t) -- who drove when this happened
    local best
    for id, d in pairs(drivers) do -- two handovers in the same second: the later id, so every machine agrees
      if d.time <= t and (not best or d.time > best.time or (d.time == best.time and id > best.id)) then best = d; best.id = id end
    end
    return best and best.user
  end
  -- only the newest "plays" per track matters; an older one still waiting for its takes must never
  -- be applied after a newer one
  local newest = {}
  for _, ev in ipairs(pending) do if ev.type == "plays" then newest[ev.track or ""] = ev.id end end
  local applied, done, undo_open = 0, {}, false
  for _, ev in ipairs(pending) do
    if (ev.type == "plays" and newest[ev.track or ""] ~= ev.id) or superseded(proj, ev) then
      setext(proj, sync.APPLIED, ev.id, "1") -- superseded
    elseif ev.user == cfg.user then
      setext(proj, sync.APPLIED, ev.id, "1") -- our own: already true here
      stamp(proj, ev) -- and what we change next comes after it, even one stamped while our clock ran ahead
    elseif not (sync.ANYONE[ev.type] or can(ev.user, ev.was or ev.track, ev.pos, ev.type ~= "plays" and ev.take or nil, driver_at(ev.time))
        or (ev.type == "delete" and sync.author(ev.take) == sync.author_of(ev.user))) then
      -- not theirs to change, as far as this machine knows: their claim (or the handover) may simply not have
      -- synced here yet, so it waits a while before it's dropped
      if iso_age(ev.time) > 600 then setext(proj, sync.APPLIED, ev.id, "1") else sync.deferred[ev.id] = true end
    else
      if not undo_open then reaper.Undo_BeginBlock2(proj); undo_open = true end -- one undo point per pass, only when needed
      -- one bad event must never block everything behind it (2026-10-28: a take-less "driver" event threw on every
      -- pass, so the handover's edits and tempo change never applied): log it and move on
      local ok, res = pcall(sync.apply, proj, ev, sync.room_dir(cfg, song, room), cfg.root, can, cfg.user)
      if not ok then
        band.log("skipped a change from " .. tostring(ev.user) .. " that BandSync couldn't apply (" .. tostring(ev.type) .. "): " .. tostring(res))
        setext(proj, sync.APPLIED, ev.id, "1")
      elseif res then
        setext(proj, sync.APPLIED, ev.id, "1")
        stamp(proj, ev)
        applied = applied + 1
        local what = ({ plays = "now playing on " .. tostring(ev.track), track = "changed track " .. tostring(ev.track),
          delete = "deleted " .. tostring(ev.take), undelete = "brought back " .. tostring(ev.take),
          midi = "edited the notes of " .. tostring(ev.take), timeline = "changed the tempo map / markers",
          start = (ev.rec and "record" or "play") .. " together at " .. tostring(ev.pos), stop = "stop together",
          note = "note: " .. tostring(ev.text), like = "liked " .. tostring(ev.take),
          shift = ((ev.len or 0) > 0 and "inserted " or "removed ") .. string.format("%.2f s at %.2f s", math.abs(ev.len or 0), ev.at or 0) })[ev.type]
        done[#done + 1] = ev.user .. ": " .. (what or ("moved/trimmed " .. tostring(ev.take)))
      end
    end
  end
  if undo_open then reaper.Undo_EndBlock2(proj, "BandSync: changes from the band", -1) end
  for _, d in ipairs(done) do band.log(d) end
  return applied
end

-- ---- status receipts ----------------------------------------------------------------------------

-- What this project holds: { [lower id] = rev }. Written to rooms/<room>/status/<user>.json so everyone
-- can see who has what (the Status window).
function sync.holdings(proj)
  local have, i = {}, 0
  while true do
    local ok, key, state = reaper.EnumProjExtState(proj, band.TAKES, i)
    if not ok then break end
    i = i + 1
    if state == "full" or state == "preview" then
      local id = (ext(proj, sync.SNAP, key):match("^([^|]+)") or key):lower()
      have[id] = (tonumber(ext(proj, sync.REV, key)) or 1) + (state == "preview" and -0.5 or 0)
    end
  end
  return have
end

-- How many of the room's events this project hasn't applied (or set aside) yet.
function sync.pending_events(proj, cfg, song, room)
  local n = 0
  for _, f in ipairs(band.files(sync.room_dir(cfg, song, room) .. "/events", ".json")) do
    local id = f:sub(1, -6)
    if ext(proj, sync.APPLIED, id) == "" and not sync.deferred[id] then n = n + 1 end -- waiting on a claim isn't "behind"
  end
  return n
end

-- Events refused for now (authority not synced here yet): retried until 10 minutes old. And the room's driver
-- changes, read once and then kept up to date from incoming events: { [id] = { time, user } }.
sync.deferred = {}
local driver_cache = {}
function sync.driver_history(proj, cfg, song, room)
  local key = song .. "/" .. room
  if driver_cache[key] then return driver_cache[key] end
  local list, dir = {}, sync.room_dir(cfg, song, room) .. "/events"
  for _, f in ipairs(band.files(dir, ".json")) do
    if f:find("-", 1, true) then
      local ev = band.read_json(dir .. "/" .. f)
      if type(ev) == "table" and ev.type == "driver" and type(ev.time) == "string" then list[ev.id or f] = { time = ev.time, user = ev.driver or ev.user } end
    end
  end
  local s = band.read_json(band.session_path(cfg, song))
  if s and s.host then list["(host)"] = { time = "", user = s.host } end -- the host drives until the first handover
  driver_cache[key] = list
  return list
end

function sync.write_status(proj, cfg, song, room, info)
  local dir = sync.room_dir(cfg, song, room) .. "/status"
  reaper.RecursiveCreateDirectory(dir, 0)
  info.user, info.time, info.version, info.room = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ"), band.VERSION, room
  info.takes = sync.holdings(proj)
  band.write_json(dir .. "/" .. (cfg.user:gsub("[^%w%-_ ]", "")) .. ".json", info)
end

return sync

-- Google Drive as the band's post box. Syncthing only moves files while two machines are on at the same time; a
-- copy of each room on Drive carries what someone did alone (and every end-of-session restore point) to the others
-- whenever they next open the song, and keeps the band's history off any one machine.
--   <drive root>/<Song>/rooms/<room>/{events,recall,midi,fx,takes,_trash}   same layout as the shared folder
-- Nothing is lost on either side (a file is only removed from one place once it's in the right one). Events, restore points and MIDI are written once, so copying what's
-- missing both ways is enough. A take's files move between takes/ and _trash/ (a delete, an undone delete, a new
-- revision), so where each one belongs is worked out from the room's events and manifests, and both sides end up so.
local band = require("band")
local drive = {}

-- Where the Drive copy lives, or nil (no Drive on this machine, or turned off: ExtState drive_root = "off").
-- Looking is cached for 5 minutes: listing My Drive asks Google's servers, and doing it every Live sync poll and
-- panel frame on two machines of one account ran into Drive's rate limit (2026-10-28: 600+ "userRateLimitExceeded"
-- in an hour, uploads held back for many minutes, "Can't add file" messages).
-- The band's folder is a Drive folder one person shares with everyone (Editor), each on their own Google account,
-- added to each person's My Drive as a shortcut named BandSync. It's only ever found, never made: making it in a My
-- Drive without the shortcut would copy everything into a private folder nobody else sees.
-- First My Drive (of `places`, in order) holding a BandSync folder -> its path; else nil, plus the first My Drive
-- seen (so the panel can say the shortcut is missing). `subdirs(dir)` lists folder names; `has(path)`, if given, says
-- whether a folder is there even when a listing leaves it out (on a Mac the shortcut is a symlink into
-- .shortcut-targets-by-id, 2026-10-31). Pure.
function drive.find(places, subdirs, has, name)
  name = name or "BandSync" -- (each band its own Drive folder: band.info)
  local missing
  for _, md in ipairs(places) do
    if has and has(md .. "/" .. name) then return md .. "/" .. name end
    local dirs = subdirs(md)
    for _, d in ipairs(dirs) do
      if d:lower() == name:lower() then return md .. "/" .. d end
    end
    if dirs[1] and not missing then missing = md end
  end
  return nil, missing
end

-- Where Google Drive for desktop may put My Drive: a drive letter on Windows (G: unless it's taken; one per
-- signed-in account), the user folder (Windows mirroring), ~/Library/CloudStorage/GoogleDrive-<account> on macOS.
local function places()
  local out = {}
  if reaper.GetOS():find("^Win") then -- (drive letters only on Windows: a Mac looked at 23 that can't exist)
    out[1] = "G:/My Drive"
    for c = ("D"):byte(), ("Z"):byte() do
      if c ~= ("G"):byte() then out[#out + 1] = string.char(c) .. ":/My Drive" end
    end
  end
  local up = os.getenv("USERPROFILE")
  if up then out[#out + 1] = up:gsub("\\", "/") .. "/My Drive" end
  local cs = (os.getenv("HOME") or "") .. "/Library/CloudStorage"
  for _, d in ipairs(band.subdirs(cs)) do
    if d:match("^GoogleDrive%-") then out[#out + 1] = cs .. "/" .. d .. "/My Drive" end
  end
  return out
end

local looked = {} -- per band (its Drive folder's name): { found, at, missing, away }
drive.missing = nil -- a My Drive with no BandSync folder in it (the shared folder isn't added yet), for the panel
function drive.root(cfg)
  local r = reaper.GetExtState(band.SECTION, "drive_root")
  if r == "off" then return nil end
  if r ~= "" then return r end
  local info = band.info(cfg and cfg.root)
  local l = looked[info.drive] or { at = -math.huge }
  looked[info.drive] = l
  if reaper.time_precise() - l.at >= 300 then
    l.at = reaper.time_precise()
    l.found, l.missing = drive.find(places(), band.subdirs,
      function(p) return reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil end, info.drive)
    -- the band's Drive was here and isn't now: that Google account signed out, or Drive switched to another one (Mac,
    -- 2026-10-31: a personal and a band account on one machine). Said, not guessed at: drive.away, for the panel.
    local key = "drive_seen" .. (info.id == "bandsync" and "" or (" " .. info.id)) -- (the first band keeps its old key)
    local seen = reaper.GetExtState(band.SECTION, key)
    l.away = nil
    if l.found then
      if seen ~= l.found then reaper.SetExtState(band.SECTION, key, l.found, true) end
    elseif seen ~= "" then l.away, l.missing = seen, nil end
  end
  drive.missing, drive.away = l.missing, l.away -- (this band's, for the panel)
  return l.found
end

-- A take file's name -> take id, revision (1 for the first print), and whether it's the manifest. Pure.
--   James-20261028-032515Z-2.flac / -dry.flac / -r6.opus / -dry-r6.flac / .json / .midibuf
function drive.parse(name)
  local base, ext = name:match("^(.+)%.([^.]+)$")
  if not base then return nil end
  local id = base:match("^(.+%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ%-%d+)")
  if not id then return nil end
  return id, tonumber(base:match("%-r(%d+)$")) or 1, ext:lower() == "json"
end

-- Where a take file belongs: "_trash" if its take is deleted or it's an older revision's, else "takes". Pure.
function drive.place(name, trashed, cur_rev)
  local id, rev, manifest = drive.parse(name)
  if not id then return nil end
  if trashed[id:lower()] then return "_trash" end
  if not manifest and rev < (cur_rev[id:lower()] or rev) then return "_trash" end
  return "takes"
end

-- Which takes are deleted: the newest delete/undelete event for each take says. `events` = { {type, take, time, id} }. Pure.
function drive.trashed(events)
  local last = {}
  for _, ev in ipairs(events) do
    if (ev.type == "delete" or ev.type == "undelete") and type(ev.take) == "string" then
      local k, key = ev.take:lower(), (ev.time or "") .. (ev.id or "")
      if not last[k] or key > last[k].key then last[k] = { key = key, del = ev.type == "delete" } end
    end
  end
  local out = {}
  for k, v in pairs(last) do if v.del then out[k] = true end end
  return out
end

-- Whose each recording in a room's media folder is: the author of the first change that used it (a recording's file
-- is named by REAPER, not after anyone, so the name can't say; later changes by others only move it). Media used
-- from another room's folder is that room's. `events` = { {user, time, id, media = { {room, file} }} }. Pure.
function drive.media_owners(events, room)
  local first = {}
  for _, ev in ipairs(events) do
    local key = (ev.time or "") .. (ev.id or "")
    for _, m in ipairs(ev.media or {}) do
      if m[1] == room and ev.user and (not first[m[2]] or key < first[m[2]].key) then first[m[2]] = { key = key, user = ev.user } end
    end
  end
  local out = {}
  for f, v in pairs(first) do out[f] = v.user end
  return out
end

local seen_events = {} -- path -> { type, take, time, id, user, media } (events are written once, so read once)
local function read_events(dir)
  local out = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    local e = seen_events[p]
    if not e then
      local ev = band.read_json(p)
      e = ev and { type = ev.type, take = ev.take, time = ev.time, id = ev.id, user = ev.user } or false
      if e and type(ev.state) == "string" then -- (an item's chunk: the recordings it plays)
        e.media = {}
        for room, rel in ev.state:gmatch('FILE "{media:([^}]+)}/([^"]+)"') do e.media[#e.media + 1] = { room, rel } end
      end
      if e then seen_events[p] = e end
    end
    if e then out[#out + 1] = e end
  end
  return out
end

-- What we may write on Drive: only our own files (named after us: takes, events, MIDI and restore points all carry
-- their author's name). Two machines on one Google account writing the same file, even minutes apart (Drive takes
-- a while to show one machine's upload to the other), made Drive keep one and move the other to "Lost and Found"
-- with a "Can't sync file" message each time (2026-10-28). Reading from Drive is anyone's.
-- `wait` (tests only): others' files too, once missing that many seconds.
local first_seen = {} -- path -> when we first saw it missing on Drive
local function mine(f, user)
  local u = (user or ""):gsub("[^%w%-_]", "_")
  return u ~= "" and (f:sub(1, #u + 1) == u .. "-" or f:find("Z-" .. u .. "-", 1, true) ~= nil)
end
local function due(path, f, user, wait)
  if mine(f, user) then return true end
  if not wait then return false end
  local t = reaper.time_precise()
  first_seen[path] = first_seen[path] or t
  return t - first_seen[path] >= wait
end
drive.mine = mine

-- Google's conflict copies ("x (1).json") of a file that's there under its own name, same size: only clutter.
local function tidy(dir)
  local i, gone = 0, {}
  reaper.EnumerateFiles(dir, -1)
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    local orig = f:gsub(" %(%d+%)(%.[^.]+)$", "%1")
    if orig ~= f and band.size(dir .. "/" .. orig) == band.size(dir .. "/" .. f) then gone[#gone + 1] = f end
    i = i + 1
  end
  for _, f in ipairs(gone) do os.remove(dir .. "/" .. f) end
end

-- Changes the history trim took out of the room (lib/trim.lua lists them in trimmed/): Drive's copy still has them.
local seen_trims = {} -- path -> its list (written once)
local function trimmed(dir)
  local out = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    seen_trims[p] = seen_trims[p] or band.read_json(p) or nil
    for _, id in ipairs(type(seen_trims[p]) == "table" and seen_trims[p] or {}) do out[tostring(id) .. ".json"] = true end
  end
  return out
end

local function into_trash_index(dir, f)
  local idx = band.read_json(dir .. "/index.json") or {}
  if not idx[f] then idx[f] = os.date("!%Y-%m-%d"); band.write_json(dir .. "/index.json", idx) end
end

-- One pass for one room. Copying stops once `budget` seconds have gone (big FLACs on a slow link): the next pass
-- carries on. Returns files copied or moved, and whether work is left.
function drive.mirror(here, there, budget, user, wait)
  local t0, n = reaper.time_precise(), 0
  local function out_of_time() return reaper.time_precise() - t0 > (budget or 1.5) end
  local function copy(a, z)
    reaper.RecursiveCreateDirectory(z:match("^(.*)/"), 0)
    band.copy_atomic(a, z)
    n = n + 1
  end
  -- written once: whatever's missing goes across
  local events = read_events(here .. "/events")
  local owners = drive.media_owners(events, here:match("([^/]+)$"))
  for _, sub in ipairs({ "trimmed", "events", "recall", "midi", "media" }) do -- (media: recordings and prints the items use)
    local A, B = band.files(here .. "/" .. sub), band.files(there .. "/" .. sub)
    local inA, inB = {}, {}
    for _, f in ipairs(A) do inA[f] = true end
    for _, f in ipairs(B) do inB[f] = true end
    if sub == "events" then -- trimmed: not brought back from Drive, and gone from it once whoever made them sees that
      for f in pairs(trimmed(here .. "/trimmed")) do -- ("trimmed" goes first: a list may have just come from Drive)
        inA[f], inB[f] = true, true
        if mine(f, user) and reaper.file_exists(there .. "/events/" .. f) then os.remove(there .. "/events/" .. f) end
      end
    end
    for _, f in ipairs(A) do
      if not inB[f] and (sub == "media" and owners[f] == user or due(here .. "/" .. sub .. "/" .. f, f, user, wait)) then
        if out_of_time() then return n, true end
        copy(here .. "/" .. sub .. "/" .. f, there .. "/" .. sub .. "/" .. f)
      end
    end
    tidy(there .. "/" .. sub)
    for _, f in ipairs(B) do if not inA[f] then if out_of_time() then return n, true end; copy(there .. "/" .. sub .. "/" .. f, here .. "/" .. sub .. "/" .. f) end end
  end
  -- plug-in chains: rewritten by their owner, so a differing copy is only refreshed where it's missing (Syncthing
  -- and the owner's own pass keep the rest current)
  local users = {}
  for _, side in ipairs({ here, there }) do for _, u in ipairs(band.subdirs(side .. "/fx")) do users[u] = true end end
  for u in pairs(users) do
    for _, pair in ipairs(mine(u .. "-", user) and { { here, there }, { there, here } } or { { there, here } }) do
      local a, z = pair[1] .. "/fx/" .. u, pair[2] .. "/fx/" .. u
      for _, f in ipairs(band.files(a)) do
        if not reaper.file_exists(z .. "/" .. f) then if out_of_time() then return n, true end; copy(a .. "/" .. f, z .. "/" .. f) end
      end
    end
  end
  -- takes: each file where it belongs, on both sides
  tidy(there .. "/takes"); tidy(there .. "/_trash")
  local trashed = drive.trashed(events)
  local where = {} -- name -> { [side .. "/" .. sub] = true }
  local cur_rev, newest, mrev = {}, {}, {} -- per take: newest manifest's revision and path; per manifest path: its revision
  for _, side in ipairs({ here, there }) do
    for _, sub in ipairs({ "takes", "_trash" }) do
      for _, f in ipairs(band.files(side .. "/" .. sub)) do
        local id, _, manifest = drive.parse(f)
        if id and not f:match("^[.~]") then -- (Syncthing's .syncthing.*.tmp while a file is arriving)
          where[f] = where[f] or {}
          where[f][side .. "/" .. sub] = true
          if manifest then
            local path = side .. "/" .. sub .. "/" .. f
            local m = band.read_json(path)
            mrev[path] = m and tonumber(m.rev) or 1
            if mrev[path] > (cur_rev[id:lower()] or 0) then cur_rev[id:lower()], newest[f] = mrev[path], path end
          end
        end
      end
    end
  end
  for f, at in pairs(where) do
    local dest = drive.place(f, trashed, cur_rev)
    local id, _, manifest = drive.parse(f)
    for _, side in ipairs({ here, there }) do
      local want, other = side .. "/" .. dest, side .. "/" .. (dest == "takes" and "_trash" or "takes")
      local stale = manifest and (mrev[want .. "/" .. f] or 0) < cur_rev[id:lower()] -- an older revision's manifest
      local work = not at[want] or stale or (at[other] and at[want])
      -- on Drive, someone else's take is theirs to file: their machine moves it at once, ours only if it's still
      -- undone 5 minutes on (2026-10-28: both machines moving a just-deleted take at once, Drive refused one with
      -- "Can't add file ... you don't have permission to add files to 'takes'" and kept a "(1)" copy)
      if work and side == there and not due("place:" .. f, f, user, wait) then goto next_side end
      if not at[want] or stale then
        if out_of_time() then return n, true end
        if at[other] and not manifest then -- on this side already: a move
          reaper.RecursiveCreateDirectory(want, 0)
          if os.rename(other .. "/" .. f, want .. "/" .. f) then at[other], n = nil, n + 1 end
        else
          local src = manifest and newest[f] or (function() for k in pairs(at) do return k .. "/" .. f end end)()
          copy(src, want .. "/" .. f)
          mrev[want .. "/" .. f] = manifest and cur_rev[id:lower()] or nil
        end
        at[want] = true
        if dest == "_trash" and side == here then into_trash_index(want, f) end -- (Drive's copy has none: one file both would write)
      end
      if at[other] and at[want] then -- the right place has it, so this copy in the wrong one is only a leftover
        if os.remove(other .. "/" .. f) then at[other] = nil end
      end
      ::next_side::
    end
  end
  return n, false
end

-- Every song here in full keeps its copy on Drive, not only the one open (James, 2026-11-01): a song a bandmate
-- made can then be opened when nobody who has it is online, since opening a song brings its rooms from Drive
-- (Live sync's pass for the open song). One song a pass, in turn, carried on while it has work left. `songs`: the
-- songs here in full; `skip`: the open one (its own pass). Returns files copied, whether that song has more, and it.
local turn = { i = 0 }
function drive.upkeep(cfg, droot, songs, skip, budget)
  local list = {}
  for _, s in ipairs(songs) do if s ~= skip then list[#list + 1] = s end end
  if #list == 0 then return 0, false end
  if not turn.more or not list[turn.i] then turn.i = turn.i % #list + 1 end
  local song, t0, n, more = list[turn.i], reaper.time_precise(), 0, false
  for _, room in ipairs(band.subdirs(band.song_dir(cfg, song) .. "/rooms")) do
    local left = (budget or 1) - (reaper.time_precise() - t0)
    if left <= 0 then more = true; break end
    local k, m = drive.mirror(band.song_dir(cfg, song) .. "/rooms/" .. room, droot .. "/" .. song .. "/rooms/" .. room, left, cfg.user)
    n, more = n + k, more or m
  end
  turn.more = more
  return n, more, song
end

return drive

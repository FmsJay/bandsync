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
function drive.root(cfg)
  local r = reaper.GetExtState(band.SECTION, "drive_root")
  if r == "off" then return nil end
  if r ~= "" then return r end
  if reaper.file_exists("G:/My Drive/desktop.ini") or band.subdirs("G:/My Drive")[1] then return "G:/My Drive/BandSync" end
  local cs = (os.getenv("HOME") or "") .. "/Library/CloudStorage" -- Google Drive for desktop on macOS
  for _, d in ipairs(band.subdirs(cs)) do
    if d:match("^GoogleDrive%-") then return cs .. "/" .. d .. "/My Drive/BandSync" end
  end
  return nil
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

local seen_events = {} -- path -> { type, take, time, id } (events are written once, so read once)
local function read_events(dir)
  local out = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local p = dir .. "/" .. f
    local e = seen_events[p]
    if not e then
      local ev = band.read_json(p)
      e = ev and { type = ev.type, take = ev.take, time = ev.time, id = ev.id } or false
      if e then seen_events[p] = e end
    end
    if e then out[#out + 1] = e end
  end
  return out
end

-- Our own file (named after us), or one another machine wrote: theirs we only carry to Drive once it has waited
-- here a while (their machine puts it there itself if it can; two machines writing the same file in the same
-- minute left Google's "x (1).json" copies). Takes, events, MIDI and restore points all carry their author's name.
local first_seen = {} -- path -> when we first saw it missing on Drive
local function mine(f, user)
  local u = (user or ""):gsub("[^%w%-_]", "_")
  return u ~= "" and (f:sub(1, #u + 1) == u .. "-" or f:find("Z-" .. u .. "-", 1, true) ~= nil)
end
local function due(path, f, user, wait)
  if mine(f, user) then return true end
  local t = reaper.time_precise()
  first_seen[path] = first_seen[path] or t
  return t - first_seen[path] >= (wait or 300)
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
  for _, sub in ipairs({ "events", "recall", "midi" }) do
    local A, B = band.files(here .. "/" .. sub), band.files(there .. "/" .. sub)
    local inA, inB = {}, {}
    for _, f in ipairs(A) do inA[f] = true end
    for _, f in ipairs(B) do inB[f] = true end
    for _, f in ipairs(A) do
      if not inB[f] and due(here .. "/" .. sub .. "/" .. f, f, user, wait) then
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
    for _, pair in ipairs({ { here, there }, { there, here } }) do
      local a, z = pair[1] .. "/fx/" .. u, pair[2] .. "/fx/" .. u
      for _, f in ipairs(band.files(a)) do
        if not reaper.file_exists(z .. "/" .. f) then if out_of_time() then return n, true end; copy(a .. "/" .. f, z .. "/" .. f) end
      end
    end
  end
  -- takes: each file where it belongs, on both sides
  tidy(there .. "/takes"); tidy(there .. "/_trash")
  local trashed = drive.trashed(read_events(here .. "/events"))
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
        if dest == "_trash" then into_trash_index(want, f) end
      end
      if at[other] and at[want] then -- the right place has it, so this copy in the wrong one is only a leftover
        if os.remove(other .. "/" .. f) then at[other] = nil end
      end
      ::next_side::
    end
  end
  return n, false
end

return drive

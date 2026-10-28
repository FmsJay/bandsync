-- Solo edit: one person edits the song's real REAPER project at a time, through a cloud folder (Google Drive).
--   <solo root>/<Song>/solo/project/<Song>.rpp + media    the current version
--   <solo root>/<Song>/solo/lock.json                      who has it checked out, with a heartbeat
--   <solo root>/<Song>/solo/history/<stamp>-<who>.rpp/.json every checked-in version, with what changed
-- Checking out copies the project to this machine (REAPER never edits files on the cloud drive); checking in
-- copies it back, keeps the previous version in history, and releases the lock. Media is only ever added, so
-- every historic version still finds its files.
-- Wet and dry: at check-in every item on a track with FX gets a wet print as an extra take (tagged band_print)
-- beside its dry recording. Whoever lacks one of the track's plugins hears the prints instead (the track's FX
-- are bypassed while they have it); the dry recording stays untouched underneath, and edits move both.
local band = require("band")
local sync = require("sync")
local solo = {}

solo.STALE = 300 -- a lock with no heartbeat for 5 minutes is abandoned (REAPER crashed, laptop closed)

function solo.root(cfg)
  local r = reaper.GetExtState(band.SECTION, "solo_root")
  if r ~= "" then return r end
  if reaper.file_exists("G:/My Drive/desktop.ini") or band.subdirs("G:/My Drive")[1] then return "G:/My Drive/BandSync" end
  local cs = (os.getenv("HOME") or "") .. "/Library/CloudStorage" -- Google Drive for desktop on macOS
  for _, d in ipairs(band.subdirs(cs)) do
    if d:match("^GoogleDrive%-") then return cs .. "/" .. d .. "/My Drive/BandSync" end
  end
  return cfg.root
end
function solo.dir(cfg, song) return solo.root(cfg) .. "/" .. song .. "/solo" end
function solo.local_dir(cfg, song)
  local home = (os.getenv("USERPROFILE") or os.getenv("HOME") or reaper.GetResourcePath()):gsub("\\", "/")
  return home .. "/Documents/BandSync/" .. song
end
local function stamp() return os.date("!%Y%m%d-%H%M%SZ") end
local function iso() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
local function machine() return os.getenv("COMPUTERNAME") or os.getenv("HOSTNAME") or "?" end

-- ---- the lock -----------------------------------------------------------------------------------

-- { user, machine, since, beat, age (s since beat), stale } or nil
function solo.lock(cfg, song)
  local l = band.read_json(solo.dir(cfg, song) .. "/lock.json")
  if not l or not l.user then return nil end
  l.age = band.age(l.beat or l.since)
  l.stale = l.age > solo.STALE
  l.mine = l.user == cfg.user and l.machine == machine()
  return l
end

-- Take the lock. Returns true, or false + who has it. `force` takes over a stale lock.
function solo.take(cfg, song, force)
  local l = solo.lock(cfg, song)
  if l and not l.mine and not (l.stale and force) then return false, l end
  reaper.RecursiveCreateDirectory(solo.dir(cfg, song), 0)
  band.write_json(solo.dir(cfg, song) .. "/lock.json", { user = cfg.user, machine = machine(), since = l and l.mine and l.since or iso(), beat = iso() })
  return true
end
function solo.beat(cfg, song)
  local l = solo.lock(cfg, song)
  if l and l.mine then
    l.beat, l.age, l.stale, l.mine = iso(), nil, nil, nil
    band.write_json(solo.dir(cfg, song) .. "/lock.json", l)
    return true
  end
  return false -- someone took it over (ours went stale): stop and say so
end
function solo.release(cfg, song)
  local l = solo.lock(cfg, song)
  if l and l.mine then os.remove(solo.dir(cfg, song) .. "/lock.json") end
end

-- ---- copying ------------------------------------------------------------------------------------

local SKIP = { [".reapeaks"] = true, [".rpp-bak"] = true, [".rpp-undo"] = true, [".tmp"] = true }
local function skip(name) return name:sub(1, 1) == "." or SKIP[(name:match("%.[^.]+$") or ""):lower()] end

-- Copy files from src to dst (recursively) that are missing there or differ in size. `rpp`: also .rpp files.
local function copy_tree(src, dst, with_rpp)
  local n = 0
  reaper.RecursiveCreateDirectory(dst, 0)
  for _, f in ipairs(band.files(src)) do
    local is_rpp = f:lower():match("%.rpp$")
    if not skip(f) and (with_rpp or not is_rpp) and band.size(src .. "/" .. f) ~= band.size(dst .. "/" .. f) then
      band.copy_atomic(src .. "/" .. f, dst .. "/" .. f)
      n = n + 1
    end
  end
  for _, d in ipairs(band.subdirs(src)) do
    if not skip(d) then n = n + copy_tree(src .. "/" .. d, dst .. "/" .. d, with_rpp) end
  end
  return n
end
solo.copy_tree = copy_tree

-- Bring every file the project uses inside its own folder (media/), so the folder is the whole project.
function solo.consolidate(proj, dir)
  local n = 0
  reaper.RecursiveCreateDirectory(dir .. "/media", 0)
  local ndir = dir:gsub("\\", "/"):lower()
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local src = tk and reaper.GetMediaItemTake_Source(tk)
      local fn = src and reaper.GetMediaSourceFileName(src) or ""
      if fn ~= "" and fn:gsub("\\", "/"):lower():sub(1, #ndir) ~= ndir and reaper.file_exists(fn) then
        local name = fn:match("[^/\\]+$")
        local dst = dir .. "/media/" .. name
        if not reaper.file_exists(dst) or band.size(dst) ~= band.size(fn) then
          if reaper.file_exists(dst) then dst = dir .. "/media/" .. stamp() .. "_" .. name end
          band.copy_atomic(fn, dst)
        end
        band.swap_source(tk, dst)
        n = n + 1
      end
    end
  end
  return n
end

-- ---- what changed between two versions (pure) ----------------------------------------------------

-- Tracks of an .rpp: { [guid] = { name, items = { [iguid] = { pos, len } }, fx = { names } }, order = {guids} }
function solo.parse(text)
  local tracks, order, stack = {}, {}, {}
  local tr, item
  for line in (text or ""):gmatch("[^\r\n]+") do
    local t = line:match("^%s*(.-)%s*$")
    if t:sub(1, 1) == "<" then
      local tag = t:match("^<(%S+)")
      stack[#stack + 1] = tag
      if tag == "TRACK" and #stack == 2 then
        local g = t:match("^<TRACK%s+(%S+)") or ("#" .. (#order + 1))
        tr = { name = "", items = {}, fx = {} }
        tracks[g] = tr
        order[#order + 1] = g
      elseif tag == "ITEM" and tr then
        item = { pos = 0, len = 0 }
      elseif tr and (tag == "VST" or tag == "JS" or tag == "CLAP" or tag == "AU" or tag == "DX" or tag == "LV2" or tag == "VST3") and stack[#stack - 1] == "FXCHAIN" then
        tr.fx[#tr.fx + 1] = t:match('^<%S+%s+"([^"]+)"') or t:match("^<%S+%s+(%S+)") or tag
      end
    elseif t == ">" then
      local tag = table.remove(stack)
      if tag == "ITEM" and item and tr then tr.items[item.guid or ("#" .. tostring(item.pos))] = item; item = nil
      elseif tag == "TRACK" and #stack == 1 then tr = nil end
    elseif tr then
      if item then
        local k, v = t:match("^(%S+)%s+(.*)$")
        if k == "POSITION" then item.pos = tonumber(v) or 0
        elseif k == "LENGTH" then item.len = tonumber(v) or 0
        elseif k == "IGUID" then item.guid = v
        elseif k == "MUTE" then item.mute = (tonumber(v:match("^(%S+)")) or 0) ~= 0 end
      elseif stack[#stack] == "TRACK" then
        local n = t:match('^NAME%s+"(.*)"$') or t:match("^NAME%s+(%S+)$")
        if n then tr.name = n end
        local vol, pan = t:match("^VOLPAN%s+(%S+)%s+(%S+)")
        if vol then tr.vol, tr.pan = tonumber(vol), tonumber(pan) end
        local mute = t:match("^MUTESOLO%s+(%S+)")
        if mute then tr.mute = (tonumber(mute) or 0) ~= 0 end
        local src, rmute = t:match("^AUXRECV%s+(%S+)%s+%S+%s+%S+%s+%S+%s+(%S+)")
        if src then tr.recv = (tr.recv or "") .. src .. (rmute == "1" and "m" or "") .. ";" end
      end
    end
  end
  return { tracks = tracks, order = order }
end

-- Lines saying what changed from `a` to `b` (parsed). Pure.
function solo.diff(a, b)
  local out = {}
  local function label(t) return t.name ~= "" and t.name or "(unnamed track)" end
  for _, g in ipairs(b.order) do
    local tb, ta = b.tracks[g], a.tracks[g]
    if not ta then out[#out + 1] = "added track " .. label(tb)
    else
      local added, removed, moved, muted = 0, 0, 0, 0
      for ig, it in pairs(tb.items) do
        local o = ta.items[ig]
        if not o then added = added + 1
        elseif math.abs(o.pos - it.pos) > 1e-6 or math.abs(o.len - it.len) > 1e-6 then moved = moved + 1
        elseif (o.mute or false) ~= (it.mute or false) then muted = muted + 1 end
      end
      for ig in pairs(ta.items) do if not tb.items[ig] then removed = removed + 1 end end
      local bits = {}
      if ta.name ~= tb.name then bits[#bits + 1] = "renamed from " .. label(ta) end
      if added > 0 then bits[#bits + 1] = added .. " item(s) added" end
      if removed > 0 then bits[#bits + 1] = removed .. " removed" end
      if moved > 0 then bits[#bits + 1] = moved .. " moved/trimmed" end
      if muted > 0 then bits[#bits + 1] = muted .. " item(s) muted/unmuted" end
      local function db(v) return v and v > 0 and string.format("%+.1f dB", 20 * math.log(v, 10)) or "-inf dB" end
      local function pan(v) return not v and "?" or math.abs(v) < 0.005 and "centre" or string.format("%d%% %s", math.floor(math.abs(v) * 100 + 0.5), v < 0 and "L" or "R") end
      if ta.vol and tb.vol and math.abs(ta.vol - tb.vol) > 1e-4 then bits[#bits + 1] = "volume " .. db(ta.vol) .. " -> " .. db(tb.vol) end
      if ta.pan and tb.pan and math.abs(ta.pan - tb.pan) > 1e-4 then bits[#bits + 1] = "pan " .. pan(ta.pan) .. " -> " .. pan(tb.pan) end
      if (ta.mute or false) ~= (tb.mute or false) then bits[#bits + 1] = tb.mute and "muted" or "unmuted" end
      if (ta.recv or "") ~= (tb.recv or "") then bits[#bits + 1] = "routing changed" end
      local fa, fb = table.concat(ta.fx, ", "), table.concat(tb.fx, ", ")
      if fa ~= fb then bits[#bits + 1] = "FX now: " .. (fb ~= "" and fb or "none") end
      if #bits > 0 then out[#out + 1] = label(tb) .. ": " .. table.concat(bits, "; ") end
    end
  end
  for _, g in ipairs(a.order) do if not b.tracks[g] then out[#out + 1] = "removed track " .. label(a.tracks[g]) end end
  return out
end

-- ---- wet and dry -----------------------------------------------------------------------------------

local function has_fx(tr)
  for f = 0, reaper.TrackFX_GetCount(tr) - 1 do if reaper.TrackFX_GetEnabled(tr, f) then return true end end
  return false
end
local function missing_fx(tr)
  for f = 0, reaper.TrackFX_GetCount(tr) - 1 do if reaper.TrackFX_GetOffline(tr, f) then return true end end
  return false
end
local function find_print(it)
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if band.take_ext(tk, "band_print") ~= "" then return tk end
  end
end
local function dry_take(it)
  local a = reaper.GetActiveTake(it)
  if a and band.take_ext(a, "band_print") == "" then return a end
  for k = 0, reaper.CountTakes(it) - 1 do
    local tk = reaper.GetTake(it, k)
    if band.take_ext(tk, "band_print") == "" then return tk end
  end
end

-- Make sure every item on a track with working FX has a current wet print beside its dry take.
-- Returns how many were (re)printed. Active tab only.
function solo.print_wet(proj, dir)
  local n = 0
  reaper.RecursiveCreateDirectory(dir .. "/prints", 0)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if has_fx(tr) and not missing_fx(tr) and band.track_ext(tr, "band_printview") == "" then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local dry = dry_take(it)
        if dry then
          local h = sync.fxhash(it, dry, true) .. (reaper.TakeIsMIDI(dry) and "m" or "")
          local p = find_print(it)
          if not p or band.take_ext(p, "band_print") ~= h then
            local guid = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)):gsub("[{}]", "")
            local path = sync.print_item(proj, it, dry, dir .. "/prints", guid .. "-" .. h)
            if path then
              local playing = reaper.GetActiveTake(it)
              if not p then p = reaper.AddTakeToMediaItem(it) end
              reaper.SetMediaItemTake_Source(p, reaper.PCM_Source_CreateFromFile(path))
              reaper.SetMediaItemTakeInfo_Value(p, "D_STARTOFFS", 0) -- the print starts at the item's start
              reaper.GetSetMediaItemTakeInfo_String(p, "P_NAME", "wet print", true)
              band.set_take_ext(p, "band_print", h)
              reaper.SetActiveTake(playing == p and dry or playing) -- the dry recording stays in front
              n = n + 1
            end
          end
        end
      end
    end
  end
  return n
end

-- After opening: tracks whose plugins are missing here play their wet prints (FX bypassed). Returns tracks switched.
function solo.use_prints_where_needed(proj)
  local n = 0
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if missing_fx(tr) and band.track_ext(tr, "band_printview") == "" then
      local any = false
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local p = find_print(reaper.GetTrackMediaItem(tr, j))
        if p then reaper.SetActiveTake(p); any = true end
      end
      if any then
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_printview", tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_FXEN"))), true)
        reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", 0)
        n = n + 1
      end
    end
  end
  return n
end

-- Before checking in: undo that, so the next person (who may have the plugins) gets dry + FX.
function solo.restore_dry(proj)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local was = band.track_ext(tr, "band_printview")
    if was ~= "" then
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local d = dry_take(it)
        if d then reaper.SetActiveTake(d) end
      end
      reaper.SetMediaTrackInfo_Value(tr, "I_FXEN", tonumber(was) or 1)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_printview", "", true)
    end
  end
end

-- ---- check out / check in --------------------------------------------------------------------------

-- Copy the current version here. Returns the local .rpp path (nil if there's no version yet).
function solo.pull(cfg, song)
  local src, dst = solo.dir(cfg, song) .. "/project", solo.local_dir(cfg, song)
  local rpp = src .. "/" .. song .. ".rpp"
  if not reaper.file_exists(rpp) then return nil end
  copy_tree(src, dst, true)
  return dst .. "/" .. song .. ".rpp"
end

-- History, newest first: { file, user, time, note, changes = {lines} }
function solo.history(cfg, song)
  local dir, out = solo.dir(cfg, song) .. "/history", {}
  local files = band.files(dir, ".json")
  for i = #files, 1, -1 do
    local h = band.read_json(dir .. "/" .. files[i])
    if h then h.file = files[i]:sub(1, -6); out[#out + 1] = h end
  end
  return out
end

-- Save, consolidate, print wet takes, and publish this project as the new version. Returns a summary.
function solo.push(proj, cfg, song, note)
  local here = solo.local_dir(cfg, song)
  local l = solo.lock(cfg, song)
  if not (l and l.mine) then return nil, "You don't have '" .. song .. "' checked out." end
  local media = solo.consolidate(proj, here)
  solo.restore_dry(proj) -- the published file is dry-first, FX on: right for anyone who has the plugins
  local printed = solo.print_wet(proj, here)
  reaper.Main_SaveProjectEx(proj, here .. "/" .. song .. ".rpp", 8) -- 8: save there, no dialog
  local text = band.read(here .. "/" .. song .. ".rpp") or ""
  solo.use_prints_where_needed(proj) -- then back to what this person can hear
  local remote = solo.dir(cfg, song) .. "/project"
  local prev = band.read(remote .. "/" .. song .. ".rpp")
  local changes = solo.diff(solo.parse(prev or ""), solo.parse(text))
  local copied = copy_tree(here, remote, false) -- media and prints first, the project file last
  band.write_atomic(remote .. "/" .. song .. ".rpp", text)
  local hist = solo.dir(cfg, song) .. "/history"
  reaper.RecursiveCreateDirectory(hist, 0)
  local name = stamp() .. "-" .. (cfg.user:gsub("[^%w%-_]", "_"))
  band.write_atomic(hist .. "/" .. name .. ".rpp", text)
  band.write_json(hist .. "/" .. name .. ".json", { user = cfg.user, time = iso(), note = note ~= "" and note or nil,
    changes = changes, printed = printed, media = media })
  return string.format("checked in '%s': %d change(s), %d wet print(s), %d file(s) uploaded", song, #changes, printed, copied)
end

-- Go back to a checked-in version (you must have the song checked out). Where things are now is checked in
-- first, so this is undoable from the same history. Opens the old version in this tab.
function solo.restore(proj, cfg, song, file)
  local hist = solo.dir(cfg, song) .. "/history/" .. file .. ".rpp"
  local text = band.read(hist)
  if not text then return nil, "can't read " .. hist end
  local h = band.read_json(solo.dir(cfg, song) .. "/history/" .. file .. ".json") or {}
  local before, err = solo.push(proj, cfg, song, "before restoring " .. (h.user or "?") .. "'s version of " .. (h.time or file))
  if not before then return nil, err end
  local path = solo.local_dir(cfg, song) .. "/" .. song .. ".rpp"
  band.write_atomic(path, text)
  reaper.Main_openProject(path) -- just saved, so no "save changes?" prompt
  local p2 = reaper.EnumProjects(-1)
  band.bind(p2, { role = "solo", song = song, room = "main" })
  solo.use_prints_where_needed(p2)
  return "restored " .. (h.user or "?") .. "'s version of " .. (h.time or file) .. ". Check in to publish it."
end

-- The open tab holding this song's checkout, if any.
function solo.find_tab(song)
  for i = 0, 512 do
    local p = reaper.EnumProjects(i)
    if not p then return nil end
    local b = band.binding(p)
    if b and b.role == "solo" and b.song == song then return p end
  end
end

return solo

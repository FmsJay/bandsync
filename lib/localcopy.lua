-- Deleting this computer's copy of a project, to free the space: only once it's confirmed somewhere else, and so that nobody else loses
-- anything. The danger is Syncthing: a file deleted in a shared folder is deleted for everyone. So the project goes on this computer's
-- ignore list first (lib/songsync.lua), Syncthing is seen to have read that, and only then do the files go, to the Recycle Bin or Trash.
-- Its listing stays (session.json, chat and the like), so it's still on the Projects page; opening it brings it back.
--   Elsewhere means: Google Drive holds every file of it, or Syncthing says another computer of the group needs nothing of it.
--   /rest/db/remoteneed lists what a computer lacks of what's in the folder, whatever the reason, so one that never downloaded it fails.
local band = require("band")
local copy = {}

local WIN = reaper.GetOS():find("^Win") ~= nil
-- What stays of a project, as the ignore list keeps it (songsync.LISTING).
local KEEP_TOP = { ["session.json"] = true, ["folder.json"] = true, ["live.json"] = true, invites = true, chat = true, rooms = true }
local KEEP_ROOM = { ["room.json"] = true, summary = true, status = true, chat = true }

-- Every file of the project that would go, relative to its folder, and the top-most paths to remove. Reads the folders.
function copy.contents(dir)
  local files, paths = {}, {}
  local function walk(rel)
    for _, f in ipairs(band.files(dir .. "/" .. rel)) do files[#files + 1] = rel .. "/" .. f end
    for _, d in ipairs(band.subdirs(dir .. "/" .. rel)) do walk(rel .. "/" .. d) end
  end
  for _, f in ipairs(band.files(dir)) do
    if not KEEP_TOP[f] then files[#files + 1] = f; paths[#paths + 1] = f end
  end
  for _, d in ipairs(band.subdirs(dir)) do
    if not KEEP_TOP[d] then walk(d); paths[#paths + 1] = d end
  end
  for _, room in ipairs(band.subdirs(dir .. "/rooms")) do
    local r = "rooms/" .. room
    for _, f in ipairs(band.files(dir .. "/" .. r)) do
      if not KEEP_ROOM[f] then files[#files + 1] = r .. "/" .. f; paths[#paths + 1] = r .. "/" .. f end
    end
    for _, d in ipairs(band.subdirs(dir .. "/" .. r)) do
      if not KEEP_ROOM[d] then walk(r .. "/" .. d); paths[#paths + 1] = r .. "/" .. d end
    end
  end
  return files, paths
end

-- Whether `song` shows up in a remoteneed answer. Pure.
function copy.lacks(answer, song)
  return answer:find('"name":"' .. song .. '/', 1, true) ~= nil or answer:find('"name": "' .. song .. '/', 1, true) ~= nil
end
-- Where Drive keeps a room's file: a take may sit in takes or _trash, whichever the group has it in. Everything else at its own path.
function copy.drive_paths(rel)
  local room, sub, f = rel:match("^(rooms/[^/]+)/([^/]+)/(.+)$")
  if room and (sub == "takes" or sub == "_trash") then return { room .. "/takes/" .. f, room .. "/_trash/" .. f } end
  return { rel }
end
-- What the Drive copy doesn't carry, so it isn't asked of it: working files, and each computer's own bits.
function copy.drive_needs(rel)
  local sub = rel:match("^rooms/[^/]+/([^/]+)/")
  return sub == "takes" or sub == "_trash" or sub == "media" or sub == "events" or sub == "midi" or sub == "recall"
end

-- Is a project open in a tab here?
function copy.open_here(root, song)
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then return false end
    local b = band.binding(p)
    if b and b.song == song and band.for_tab({ root = root, user = "" }, b).root == root then return true end
  end
end

-- A job: one project at a time, a slice each frame, so the panel keeps drawing. { songs, root, step, words, ... }
copy.job = nil
function copy.start(root, user, songs)
  for _, s in ipairs(songs) do
    if copy.open_here(root, s) then return nil, "'" .. s .. "' is open in a tab here: close its tab first." end
  end
  copy.job = { root = root, user = user, songs = songs, i = 1, step = "scan", words = "Getting ready", done = {}, skipped = {} }
  return true
end
function copy.cancel() copy.job = nil end

local function enc(s) return (s:gsub("[^%w%-_%.]", function(c) return string.format("%%%02X", c:byte()) end)) end
-- Syncthing has finished looking at the folder?
local function idle(id)
  local a = require("services").ask("/rest/db/status?folder=" .. id, 5)
  return a and a:find('"state":%s*"idle"') ~= nil
end
local function peer_list(id)
  local services, out = require("services"), {}
  local me = services.my_device_id()
  local a = services.ask("/rest/config/folders/" .. id, 5)
  for d in (a or ""):gmatch('"deviceID":%s*"([%w%-]+)"') do if d ~= me then out[#out + 1] = d end end
  return out
end
local function device_name(id)
  local a = require("services").ask("/rest/config/devices/" .. id, 5)
  return a and a:match('"name":%s*"([^"]*)"') or id:sub(1, 7)
end

-- Into the Recycle Bin or Trash. Returns how many paths couldn't go (a file REAPER still has open, usually).
function copy.bin(paths)
  if #paths == 0 then return 0 end
  local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"):gsub("\\", "/"):gsub("/+$", "") .. "/bandsync-bin-" .. os.time()
  local q = function(s) return "'" .. s:gsub("'", "''") .. "'" end
  local cmd
  if WIN then
    local lines = { "Add-Type -AssemblyName Microsoft.VisualBasic", "$fs = [Microsoft.VisualBasic.FileIO.FileSystem]" }
    for _, p in ipairs(paths) do
      local w = p:gsub("/", "\\")
      lines[#lines + 1] = "if (Test-Path -LiteralPath " .. q(w) .. " -PathType Container) { $fs::DeleteDirectory(" .. q(w) .. ", 'OnlyErrorDialogs', 'SendToRecycleBin') } " ..
        "elseif (Test-Path -LiteralPath " .. q(w) .. ") { $fs::DeleteFile(" .. q(w) .. ", 'OnlyErrorDialogs', 'SendToRecycleBin') }"
    end
    band.write_atomic(tmp .. ".ps1", "\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n")
    cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' .. tmp .. '.ps1"'
  else
    local lines = { 'T="$HOME/.Trash"' }
    local sq = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
    for i, p in ipairs(paths) do
      lines[#lines + 1] = string.format('[ -e %s ] && mv %s "$T/StudioSync-%d-%d-$(basename %s)"', sq(p), sq(p), os.time(), i, sq(p))
    end
    band.write_atomic(tmp .. ".sh", table.concat(lines, "\n") .. "\n")
    cmd = "/bin/sh '" .. tmp .. ".sh'"
  end
  reaper.ExecProcess(cmd, 300000)
  os.remove(tmp .. (WIN and ".ps1" or ".sh"))
  local left = 0
  for _, p in ipairs(paths) do
    if reaper.file_exists(p) or reaper.EnumerateFiles(p, 0) or reaper.EnumerateSubdirectories(p, 0) then left = left + 1 end
  end
  return left
end

-- One step of the job. Returns nothing; the job's fields say where it stands. Called each frame by the Projects page.
function copy.tick()
  local j = copy.job
  if not j or j.ask or j.finished then return end
  local services, ss, info = require("services"), require("songsync"), band.info(j.root)
  local song = j.songs[j.i]
  if not song then j.finished = true; return end
  local dir = j.root .. "/" .. song
  if j.step == "scan" then
    j.files, j.paths = copy.contents(dir)
    j.words = "Looking at '" .. song .. "'"
    if #j.files == 0 and #j.paths == 0 then -- only its listing is here
      j.skipped[#j.skipped + 1] = song .. " (nothing but its listing is here)"
      j.i, j.step = j.i + 1, "scan"
      return
    end
    services.rescan(info.id)
    j.since, j.step, j.at, j.places = reaper.time_precise(), "settle", 1, {}
  elseif j.step == "settle" then -- Syncthing has seen every file here (a recording from a minute ago, say)
    if reaper.time_precise() - j.since < 2 then return end
    if idle(info.id) then j.step = "peers"
    elseif reaper.time_precise() - j.since > 30 then j.step = "peers"; j.unsure = true end
  elseif j.step == "peers" then
    j.words = "Checking the group's other computers for '" .. song .. "'"
    if not j.unsure then
      for _, d in ipairs(peer_list(info.id)) do
        local a = services.ask("/rest/db/remoteneed?folder=" .. info.id .. "&device=" .. d .. "&perpage=100000", 15)
        -- (and that it has told us what it has at all: a computer never connected lacks everything, and that's not always how the list reads)
        local c = services.ask("/rest/db/completion?folder=" .. info.id .. "&device=" .. d, 5)
        local pct = c and tonumber(c:match('"completion":%s*([%d%.e%-%+]+)'))
        if a and a:find('"files"', 1, true) and not copy.lacks(a, song) and pct and pct > 0 then j.places[#j.places + 1] = device_name(d) end
      end
    end
    j.step = "drive"
  elseif j.step == "drive" then
    j.droot = j.droot or require("drive").root({ root = j.root }) or false
    if not j.droot or j.drive_bad then j.step = "ask"; return end
    local t0 = reaper.time_precise()
    j.words = string.format("Checking Google Drive for '%s': %d of %d", song, j.at - 1, #j.files)
    while j.at <= #j.files and reaper.time_precise() - t0 < 0.01 do
      local rel = j.files[j.at]
      if copy.drive_needs(rel) then
        local found = false
        for _, p in ipairs(copy.drive_paths(rel)) do found = found or reaper.file_exists(j.droot .. "/" .. song .. "/" .. p) end
        if not found then j.drive_bad = rel; break end
      end
      j.at = j.at + 1
    end
    if j.at > #j.files and not j.drive_bad then j.places[#j.places + 1] = "Google Drive"; j.step = "ask"
    elseif j.drive_bad then j.step = "ask" end
  elseif j.step == "ask" then
    local local_dir = reaper.GetResourcePath() .. "/BandSync/" .. song
    if #j.places == 0 then
      j.skipped[#j.skipped + 1] = song .. " (no other copy confirmed" ..
        (j.unsure and ": Syncthing was still busy" or j.drive_bad and (": Drive lacks " .. j.drive_bad:match("[^/]+$")) or "") .. ")"
      j.i, j.step = j.i + 1, "scan"
      return
    end
    j.ask = string.format("Delete this computer's copy of '%s'?\n\nConfirmed on: %s.\n\nIts files (%d) go to the %s, nothing changes for anyone else, and it stays on the Projects page: opening it brings it back%s.",
      song, table.concat(j.places, ", "), #j.files, WIN and "Recycle Bin" or "Trash", #j.places == 1 and j.places[1] == "Google Drive" and " from Drive" or " from them")
    j.local_dir = local_dir
  elseif j.step == "ignore" then -- first, so the delete can't reach anyone
    local gone = ss.gone()
    gone[song] = true
    ss.save_gone(gone)
    ss.drop({ root = j.root, user = j.user }, song)
    services.rescan(info.id)
    j.step, j.since = "ignored", reaper.time_precise()
    j.words = "Telling Syncthing to leave '" .. song .. "' alone"
  elseif j.step == "ignored" then
    if reaper.time_precise() - j.since < 1.5 then return end
    local probe = j.files[1]
    local a = probe and services.ask("/rest/db/file?folder=" .. info.id .. "&file=" .. enc(song .. "/" .. probe), 5)
    local local_part = a and a:match('"local":%s*(%b{})')
    if idle(info.id) and local_part and local_part:find('"ignored":%s*true') then j.step = "bin"
    elseif reaper.time_precise() - j.since > 45 then -- never delete on a guess
      j.skipped[#j.skipped + 1] = song .. " (Syncthing didn't confirm it would leave it alone, so nothing was deleted)"
      ss.want({ root = j.root, user = j.user }, song)
      j.i, j.step = j.i + 1, "scan"
    end
  elseif j.step == "bin" then
    local list = {}
    for _, p in ipairs(j.paths) do list[#list + 1] = dir .. "/" .. p end
    if reaper.EnumerateFiles(j.local_dir, 0) or reaper.EnumerateSubdirectories(j.local_dir, 0) then list[#list + 1] = j.local_dir end
    reaper.DeleteExtState(band.SECTION, "project file " .. song, true)
    local left = copy.bin(list)
    j.done[#j.done + 1] = song .. (left > 0 and string.format(" (%d still in use: restart REAPER and delete again to free them)", left) or "")
    band.log("deleted this computer's copy of '" .. song .. "': confirmed on " .. table.concat(j.places, ", ") .. ". Open it to bring it back")
    j.i, j.step = j.i + 1, "scan"
  end
end
-- The answer to j.ask.
function copy.answer(yes)
  local j = copy.job
  if not j then return end
  j.ask = nil
  if yes then j.step = "ignore" else j.skipped[#j.skipped + 1] = j.songs[j.i] .. " (you kept it)"; j.i, j.step = j.i + 1, "scan" end
end

-- Save the copy of a whole group that's no longer syncing: straight to the bin (no Syncthing has it any more).
function copy.delete_group(root)
  local left = copy.bin({ root })
  require("groups").forget_old(root)
  local list = {}
  for r in reaper.GetExtState(band.SECTION, "bands"):gmatch("[^|]+") do if r ~= root then list[#list + 1] = r end end
  reaper.SetExtState(band.SECTION, "bands", table.concat(list, "|"), true)
  return left
end

return copy

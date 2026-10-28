-- End-of-session projects on Google Drive: a real REAPER project file for each session's end, which opens in plain
-- REAPER (no BandSync needed) from anyone's Drive.
--   <drive>/<Song>/sessions/<stamp>-<user>-<room>.rpp      the project as it was at the end of the session
--   <drive>/<Song>/sessions/media/<user>/<file>              your own recordings it uses (copied once, never removed)
-- Bandmates' takes aren't copied again: the project points at the room's own copies on Drive
-- (../rooms/<room>/takes/ or _trash/, which the Drive copy keeps forever). Each machine writes only its own files
-- (lib/drive.lua: two machines writing one file on one Google account loses one of them). SonoBus / ReaNINJAM are
-- left out (they carry this machine's identity).
local band = require("band")
local sessionfile = {}

-- media still to copy, per song (persistent ExtState, so a restart carries on): JSON { {from, to} }
local function pending_key(song) return "session_media " .. song end
local function get_pending(song) return band.json_decode(reaper.GetExtState(band.SECTION, pending_key(song))) or {} end
local function set_pending(song, list) reaper.SetExtState(band.SECTION, pending_key(song), band.json_encode(list), true) end

-- The FILE lines of a project's text with their paths changed by `map(path) -> new path or nil` (unchanged). Pure.
function sessionfile.map_files(text, map)
  local out = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = l
    local pre, rest = line:match("^(%s*FILE )(.*)$")
    if pre then
      local path, tail
      if rest:sub(1, 1) == '"' then path, tail = rest:match('^"([^"]*)"(.*)$') else path, tail = rest:match("^(%S+)(.*)$") end
      local new = path and map(path)
      if new then line = pre .. '"' .. new .. '"' .. (tail or "") end
    end
    out[#out + 1] = line
  end
  if out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end

local function exists(p) return reaper.file_exists(p) end

-- Write this machine's end-of-session project to Drive. Returns the file written, or nil + why.
function sessionfile.export(proj, cfg, b, droot, room_dir)
  local path
  for i = 0, 512 do
    local p, f = reaper.EnumProjects(i)
    if not p then break end
    if p == proj then path = f end
  end
  if not path or path == "" then return nil, "the project has never been saved" end
  local projdir = path:gsub("\\", "/"):match("^(.*)/")
  -- a copy as it is now, next to it (so relative paths read the same); the open project and its file are untouched
  local tmp = projdir .. "/.bandsync-session-copy.rpp"
  reaper.Main_SaveProjectEx(proj, tmp, 0)
  local text = band.read(tmp)
  os.remove(tmp)
  if not text then return nil, "couldn't save a copy of the project" end
  local sdir = droot .. "/" .. b.song .. "/sessions"
  local user = (cfg.user:gsub("[^%w%-_]", "_"))
  local pending = get_pending(b.song)
  local function abs(p)
    p = p:gsub("\\", "/")
    if p:match("^%a:/") or p:sub(1, 1) == "/" then return p end
    return projdir .. "/" .. p
  end
  text = sessionfile.map_files(text, function(p)
    local full = abs(p)
    local name = full:match("[^/]+$")
    local band_file = name:match("^takes_(.+)$") -- a bandmate's take, as imported: the room's copy has it
    if band_file then
      for _, sub in ipairs({ "takes", "_trash" }) do
        if exists(droot .. "/" .. b.song .. "/rooms/" .. b.room .. "/" .. sub .. "/" .. band_file)
            or exists(room_dir .. "/" .. sub .. "/" .. band_file) then
          return "../rooms/" .. b.room .. "/" .. sub .. "/" .. band_file
        end
      end
    end
    if not exists(full) then return nil end
    local to = sdir .. "/media/" .. user .. "/" .. name
    if exists(to) and band.size(to) ~= band.size(full) then -- a different file with the same name
      name = os.date("!%Y%m%d-%H%M%SZ") .. "_" .. name
      to = sdir .. "/media/" .. user .. "/" .. name
    end
    if not exists(to) then pending[#pending + 1] = { from = full, to = to } end
    return "media/" .. user .. "/" .. name
  end)
  text = require("solo").strip_live_fx(text)
  reaper.RecursiveCreateDirectory(sdir .. "/media/" .. user, 0)
  local out = string.format("%s/%s-%s-%s.rpp", sdir, os.date("!%Y%m%d-%H%M%SZ"), user, (b.room:gsub("[^%w%-_]", "_")))
  band.write_atomic(out, text)
  set_pending(b.song, pending)
  sessionfile.catch_up(b.song, 1.5)
  return out
end

-- Copy media the exported projects still need, for up to `budget` seconds (called from the Drive pass, so a big
-- first copy is spread out instead of holding up REAPER). Returns how many are left.
function sessionfile.catch_up(song, budget)
  local list = get_pending(song)
  if #list == 0 then return 0 end
  local t0, left = reaper.time_precise(), {}
  for _, m in ipairs(list) do
    if reaper.time_precise() - t0 < (budget or 1.5) and type(m) == "table" and m.from and m.to then
      if not exists(m.to) and exists(m.from) then
        reaper.RecursiveCreateDirectory(m.to:match("^(.*)/"), 0)
        band.copy_atomic(m.from, m.to)
      end
    else
      left[#left + 1] = m
    end
  end
  set_pending(song, left)
  return #left
end

return sessionfile

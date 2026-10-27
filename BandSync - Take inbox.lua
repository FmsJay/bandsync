-- @description BandSync: receive takes into this project (background, toggle to stop)
-- Host: takes from every room land as lanes on the matching track (or per the take landing setting).
-- Guest: takes from bandmates in your room land on "Takes - <name>" tracks, and preview stems are
-- upgraded to full quality as the FLACs arrive. Never touches the project while recording.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end
local host = b.role == "host"
local mode = b.take_mode or (host and (b.comp or "lanes") or "person") -- host: the song's comping style

local _, _, section, cmd = reaper.get_action_context()
local function toggle(v)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, v); reaper.RefreshToolbar2(section, cmd) end
end
toggle(1)
reaper.atexit(function() toggle(0) end)

local sizes, warned_version, last = {}, nil, 0
-- A file is ready once it exists, is non-empty, and its size held still across two polls.
local function ready(path)
  local n = band.size(path)
  local ok = n and n > 0 and sizes[path] == n
  sizes[path] = n
  return ok
end

local function poll()
  local rooms = host and band.subdirs(band.song_dir(cfg, b.song) .. "/rooms") or { b.room }
  for _, room in ipairs(rooms) do
    local tdir = band.takes_dir(cfg, b.song, room)
    for _, f in ipairs(band.files(tdir, ".json")) do
      local t = band.read_json(tdir .. "/" .. f)
      if t and t.id and t.full and (host or t.user ~= cfg.user) then
        band.check_version(t.bandsync, "A take from " .. t.user)
        local state = band.take_state(proj, t.id)
        if state ~= "full" then
          local full, prev = tdir .. "/" .. t.full, t.preview and (tdir .. "/" .. t.preview)
          local want, path
          if ready(full) then want, path = "full", full
          elseif state == "" and prev and ready(prev) then want, path = "preview", prev end
          if want then
            reaper.Undo_BeginBlock2(proj)
            local ok = band.place_take(proj, t, path, mode)
            reaper.Undo_EndBlock2(proj, "BandSync: " .. want .. " take from " .. t.user, -1)
            if ok then
              band.set_take_state(proj, t.id, want)
              band.log(string.format("%s take from %s (%s) -> %s", want, t.user, room, t.track))
            end
          end
        end
      end
    end
  end

  local s = band.read_json(band.session_path(cfg, b.song))
  if s then band.check_version(s.bandsync, "'" .. b.song .. "'") end
  if s and not host then
    if band.sync_stems(proj, cfg, b.song, s, true) > 0 then band.log("upgraded stems to full quality") end
    if tostring(s.version) ~= tostring(b.version) and warned_version ~= s.version then
      warned_version = s.version
      band.log(s.host .. " published v" .. s.version .. ": run 'BandSync - Open session' to refresh")
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

local function tick()
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end -- project closed: stop
  if reaper.time_precise() - last > 2 and reaper.GetPlayStateEx(proj) & 4 == 0 then
    last = reaper.time_precise()
    local ok, err = pcall(poll)
    if not ok then band.log("inbox error: " .. tostring(err)) end
  end
  reaper.defer(tick)
end

band.log(string.format("inbox running for '%s' (%s, room %s, takes -> %s)", b.song, b.role, b.room, mode))
tick()

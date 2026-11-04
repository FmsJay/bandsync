-- History trim (James, 2026-11-01: "can trim history as long as major restore points are saved"). A room's events
-- folder keeps every change ever made; after a while that's thousands of files every machine reads. Trimmed:
-- changes older than `days` that nothing needs any more. Kept, always:
--   each object's newest change (what the song is now, and what a machine that was away catches up to);
--   for each major restore point (kept ones: end of session, "yours before X's work done alone"; and every version
--   someone saved by hand), each object's newest change at or before it, so it still restores exactly;
--   handovers, notes and likes (who drove when decides old changes' authority; notes are people's words).
-- Minor points (the snapshot before a handover) may lose their exact past. Trimmed files leave the band folder (so
-- every machine's copy goes) into <band folder's parent>/StudioSync history archive/<song>/<room>/ on the machine that
-- trimmed, so nothing is lost for good.
local band = require("band")
local trim = {}

-- What one event is about: an object's oid, the timeline, or nil (kept regardless).
local function key_of(ev)
  if ev.type == "obj" and type(ev.oid) == "string" then return ev.oid end
  if ev.type == "timeline" then return "\0timeline" end
  if ev.type == "start" or ev.type == "stop" then return "\0transport" end -- (no state to restore: only age decides)
  return nil
end
local TRANSPORT = "\0transport"
local function later(a, b) -- the same order every machine uses: rev, then time, then id
  if (a.rev or 0) ~= (b.rev or 0) then return (a.rev or 0) > (b.rev or 0) end
  if (a.time or "") ~= (b.time or "") then return (a.time or "") > (b.time or "") end
  return (a.id or "") > (b.id or "")
end
-- A point is major unless it's the snapshot taken before a handover.
function trim.major(p) return p.keep or not tostring(p.label or ""):match("^before .+ took over") end

-- The ids to take away. evs: { { id, type, oid, rev, time } }; points: { { time, keep, label } }; cutoff: ISO time
-- (only older changes go). Pure.
function trim.plan(evs, points, cutoff)
  local keep, newest = {}, {}
  for _, ev in ipairs(evs) do
    local k = key_of(ev)
    if k and k ~= TRANSPORT and (not newest[k] or later(ev, newest[k])) then newest[k] = ev end
  end
  for _, ev in pairs(newest) do keep[ev.id] = true end
  for _, p in ipairs(points) do
    if trim.major(p) and p.time then
      local at = {}
      for _, ev in ipairs(evs) do
        local k = key_of(ev)
        if k and k ~= TRANSPORT and (ev.time or "") <= p.time and (not at[k] or later(ev, at[k])) then at[k] = ev end
      end
      for _, ev in pairs(at) do keep[ev.id] = true end
    end
  end
  local out = {}
  for _, ev in ipairs(evs) do
    if key_of(ev) and not keep[ev.id] and (ev.time or "") < cutoff then out[#out + 1] = ev.id end
  end
  table.sort(out)
  return out
end

-- Trim one room now. Returns how many went. `days`: how old a change has to be (30).
function trim.run(cfg, song, room, days)
  local sync, recall = require("sync"), require("recall")
  local dir = sync.room_dir(cfg, song, room) .. "/events"
  local evs = {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local ev = band.read_json(dir .. "/" .. f)
    if type(ev) == "table" and type(ev.id) == "string" and ev.id .. ".json" == f then evs[#evs + 1] = ev end
  end
  local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - (days or 30) * 86400)
  local gone = trim.plan(evs, recall.list(cfg, song, room), cutoff)
  if #gone == 0 then return 0 end
  local root = cfg.root:gsub("[/\\]+$", "")
  local archive = (root:match("^(.*)[/\\][^/\\]+$") or root) .. "/StudioSync history archive/" .. song .. "/" .. room
  reaper.RecursiveCreateDirectory(archive, 0)
  local n, took = 0, {}
  for _, id in ipairs(gone) do
    local from, to = dir .. "/" .. id .. ".json", archive .. "/" .. id .. ".json"
    if os.rename(from, to) or (band.copy_atomic and band.copy_atomic(from, to) and os.remove(from)) then n, took[#took + 1] = n + 1, id end
  end
  -- what went, for the band: the Google Drive copy still has these, and would bring them back (lib/drive.lua)
  if #took > 0 then
    local list = dir:gsub("/events$", "/trimmed")
    reaper.RecursiveCreateDirectory(list, 0)
    band.write_json(list .. "/" .. cfg.user:gsub("[^%w%-_]", "_") .. "-" .. os.date("!%Y%m%d-%H%M%S") .. ".json", took)
  end
  return n
end

return trim

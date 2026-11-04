-- Renaming a group, leaving one, and temporary sessions. A temporary session is a group for one project: _band/band.json says
-- temporary and who started it, and whoever started it can end it for everyone (_band/ended.json). Leaving keeps your copy: the
-- folder stays on this computer and the project's tab stays open as an ordinary project. A mark tells the others (lib/removal.lua),
-- and this computer's Syncthing lets go a little later, so the mark has time to reach them.
local band = require("band")
local groups = { WAIT = 20 } -- seconds the mark gets to reach the others

local function json_of(root)
  local j = band.read_json(root .. "/_band/band.json")
  return type(j) == "table" and j or {}
end

local seen = {}
-- Is this group a temporary session? -> true or false, and who started it. Read at most every few seconds: the panel asks each frame.
function groups.temporary(root)
  local c = seen[root]
  if not c or reaper.time_precise() - c.at > 5 then
    local j = json_of(root)
    c = { at = reaper.time_precise(), temp = j.temporary == true, by = j.by }
    seen[root] = c
  end
  return c.temp, c.by
end

-- Everyone sees the new name. The ID and the folder names, here and on Drive, stay: changing those would sync it all again.
function groups.rename(root, name)
  name = band.clean(name or "")
  if name == "" then return nil, "Give the group a name." end
  for _, x in ipairs(band.bands()) do
    if x.root ~= root and x.name:lower() == name:lower() then return nil, "You're already in a group called " .. x.name .. "." end
  end
  local info, j = band.info(root), json_of(root)
  j.name, j.id, j.drive = name, info.id, info.drive
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", j)
  require("services").set_folder_label(info.id, "BandSync " .. name)
  return name
end

-- A new temporary session: a group of its own, named as asked, or "name 2" when that's been used (an ended session's folder stays).
function groups.create_session(cfg, name, by)
  local services = require("services")
  name = band.clean(name or "")
  if name == "" then return nil, "Give the session a name." end
  local why
  for n = 1, 20 do
    local root, w = services.new_band(cfg, n == 1 and name or (name .. " " .. n), { temporary = true, by = by })
    if root then seen[root] = nil; return root end
    why = w
    if not (w or ""):find("already", 1, true) then break end
  end
  return nil, why
end

-- The tabs of this group: { proj }.
local function tabs_of(root)
  local list = {}
  local base = { root = reaper.GetExtState(band.SECTION, "sync_root"), user = reaper.GetExtState(band.SECTION, "user") }
  for i = 0, math.huge do
    local p = reaper.EnumProjects(i)
    if not p then break end
    local b = band.binding(p)
    if b and band.for_tab(base, b).root == root then list[#list + 1] = p end
  end
  return list
end

-- This computer out of a group. `ended`: its session is over, so it's allowed to be the last group here, which stays the current one.
function groups.leave(root, me, ended)
  local others = {}
  for _, x in ipairs(band.bands()) do if x.root ~= root then others[#others + 1] = x.root end end
  if #others == 0 and not ended then return nil, "This is your only group. Start or join another first." end
  local tabs = tabs_of(root)
  for _, p in ipairs(tabs) do
    if reaper.GetPlayStateEx(p) & 4 == 4 then return nil, "Stop recording first." end
  end
  local info = band.info(root)
  for _, p in ipairs(tabs) do -- (Live sync sees it isn't a group project any more, and stops)
    reaper.SetProjExtState(p, band.SECTION, "", "")
    reaper.MarkProjectDirty(p)
  end
  local id = require("services").my_device_id()
  if id then require("removal").left(root, me, id) end
  local leaving = band.json_decode(reaper.GetExtState(band.SECTION, "leaving"))
  leaving = type(leaving) == "table" and leaving or {}
  leaving[#leaving + 1] = { id = info.id, at = os.time() }
  reaper.SetExtState(band.SECTION, "leaving", band.json_encode(leaving), true)
  if #others > 0 then
    reaper.SetExtState(band.SECTION, "bands", table.concat(others, "|"), true)
    if reaper.GetExtState(band.SECTION, "sync_root") == root then reaper.SetExtState(band.SECTION, "sync_root", others[1], true) end
  end
  seen[root] = nil
  return true
end

-- Whoever started the session ends it for everyone.
function groups.end_session(root, me)
  local tabs = tabs_of(root)
  for _, p in ipairs(tabs) do
    if reaper.GetPlayStateEx(p) & 4 == 4 then return nil, "Stop recording first." end
  end
  band.write_json(root .. "/_band/ended.json", { by = me, at = os.time() })
  reaper.SetExtState(band.SECTION, "session ended " .. band.info(root).id, "1", true)
  return groups.leave(root, me, true)
end

-- Run from removal.tick, every 30 s or so: Syncthing lets go of what this computer left, and a session someone ended is over here too.
function groups.tick(now)
  local services = require("services")
  local leaving = band.json_decode(reaper.GetExtState(band.SECTION, "leaving"))
  if type(leaving) == "table" and #leaving > 0 then
    local still = {}
    for _, l in ipairs(leaving) do
      if now - (tonumber(l.at) or 0) < groups.WAIT or not services.forget_folder(l.id) then still[#still + 1] = l end
    end
    reaper.SetExtState(band.SECTION, "leaving", #still > 0 and band.json_encode(still) or "", true)
  end
  local me = reaper.GetExtState(band.SECTION, "user")
  for _, g in ipairs(band.bands()) do
    local key = "session ended " .. g.id
    if reaper.GetExtState(band.SECTION, key) == "" then
      local e = band.read_json(g.root .. "/_band/ended.json")
      if type(e) == "table" and e.by then
        local ok = groups.leave(g.root, me, true) -- (not ok: something's recording. The next look does it)
        if ok then
          reaper.SetExtState(band.SECTION, key, "1", true)
          band.log(string.format("%s ended the session %s: nothing syncs any more, and your copy stays in %s", tostring(e.by), g.name, g.root))
        end
      end
    end
  end
end

return groups

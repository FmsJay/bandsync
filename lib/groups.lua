-- Who runs a group, renaming one, leaving one, and closing one. _band/band.json names the owner (whoever started it) and any admins.
-- The owner does everything; admins let people in, rename and remove members; a group from before owners is open to everyone in it.
-- Leaving keeps your copy: the folder stays on this computer and the project's tab stays open as an ordinary project. A mark tells
-- the others (lib/removal.lua), and this computer's Syncthing lets go a little later, so the mark has time to reach them. Closing is
-- the owner ending it for everyone: _band/closed.json, and each computer leaves when it sees that.
-- shortcut: these are files anyone in the group could write, so this trusts the people in it (fine among friends). A group that
-- can't would need signed files.
local band = require("band")
local groups = { WAIT = 20, QUIET_DAYS = 7 } -- seconds the mark gets to reach the others; when nobody's been seen for this long, say so

local function json_of(root)
  local j = band.read_json(root .. "/_band/band.json")
  return type(j) == "table" and j or {}
end

local seen = {}
local function who(root) -- read at most every few seconds: the panel asks each frame
  local c = seen[root]
  if not c or reaper.time_precise() - c.at > 5 then
    local j = json_of(root)
    c = { at = reaper.time_precise(), owner = j.owner, admins = {} }
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do c.admins[a] = true end
    seen[root] = c
  end
  return c
end

-- "owner", "admin", "member"; "open" in a group from before owners.
function groups.role(root, user)
  local c = who(root)
  if not c.owner then return "open" end
  return c.owner == user and "owner" or c.admins[user] and "admin" or "member"
end
-- May let people in, and rename.
function groups.may_manage(root, user) return groups.role(root, user) ~= "member" end
-- May take `target` out: the owner anyone else, an admin only members.
function groups.may_remove(root, by, target)
  if by == target then return false end
  local r, t = groups.role(root, by), groups.role(root, target)
  if r == "open" or r == "owner" then return true end
  return r == "admin" and t == "member"
end

local function save(root, change)
  local info, j = band.info(root), json_of(root)
  j.name, j.id, j.drive = info.name, info.id, info.drive
  change(j)
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/band.json", j)
  seen[root] = nil
end

-- The owner makes someone an admin or a member again. -> true, or nil + why.
function groups.set_admin(root, actor, target, on)
  if groups.role(root, actor) ~= "owner" then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = {}
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target then list[#list + 1] = a end end
    if on then list[#list + 1] = target end
    j.admins = #list > 0 and list or nil
  end)
  return true
end
-- The owner hands the group to someone. They were an admin or not; the old owner stays on as an admin.
function groups.hand_over(root, actor, target)
  if groups.role(root, actor) ~= "owner" or actor == target then return nil, "Only the owner can do that." end
  save(root, function(j)
    local list = { actor }
    for _, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a ~= target and a ~= actor then list[#list + 1] = a end end
    j.owner, j.admins = target, list
  end)
  return true
end

-- Everyone sees the new name. The ID and the folder names, here and on Drive, stay: changing those would sync it all again.
function groups.rename(root, name, by)
  if not groups.may_manage(root, by) then return nil, "Only the owner or an admin can do that." end
  name = band.clean(name or "")
  if name == "" then return nil, "Give it a name." end
  for _, x in ipairs(band.bands()) do
    if x.root ~= root and x.name:lower() == name:lower() then return nil, "You're already in a studio called " .. x.name .. "." end
  end
  local id = band.info(root).id
  save(root, function(j) j.name = name end)
  require("services").set_folder_label(id, "StudioSync " .. name)
  return name
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
local function recording(root)
  for _, p in ipairs(tabs_of(root)) do
    if reaper.GetPlayStateEx(p) & 4 == 4 then return true end
  end
  return false
end

-- Groups this computer has left, or that were closed: nothing syncs, the copy stays until you delete it (the Groups page).
function groups.old()
  local t = band.json_decode(reaper.GetExtState(band.SECTION, "old groups"))
  return type(t) == "table" and t or {}
end
function groups.remember_old(root, name, id)
  local t = groups.old()
  for _, o in ipairs(t) do if o.root == root then return end end
  t[#t + 1] = { root = root, name = name, id = id, at = os.time() }
  reaper.SetExtState(band.SECTION, "old groups", band.json_encode(t), true)
end
-- A folder taken off the list: the copy was deleted, or it stays and nobody needs telling.
function groups.forget_old(root)
  local t = {}
  for _, o in ipairs(groups.old()) do if o.root ~= root then t[#t + 1] = o end end
  reaper.SetExtState(band.SECTION, "old groups", band.json_encode(t), true)
end
function groups.is_old(root)
  for _, o in ipairs(groups.old()) do if o.root == root then return true end end
  return false
end

-- This computer out of a group. `over`: it's closed, or nobody's left in it, so it may be the last group here, which then stays the current one.
function groups.leave(root, me, over)
  if not over and groups.role(root, me) == "owner" then return nil, "You own this. Make someone else the owner first (their card in Who's here), or close it." end
  local others = {}
  for _, x in ipairs(band.bands()) do if x.root ~= root then others[#others + 1] = x.root end end
  if #others == 0 and not over then return nil, "This is your only studio. Start or join another first." end
  if recording(root) then return nil, "Stop recording first." end
  local info = band.info(root)
  for _, p in ipairs(tabs_of(root)) do -- (Live sync sees it isn't a group project any more, and stops)
    reaper.SetProjExtState(p, band.SECTION, "", "")
    reaper.MarkProjectDirty(p)
  end
  local id = require("services").my_device_id()
  if id then require("removal").left(root, me, id) end
  groups.remember_old(root, info.name, info.id)
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

-- The owner ends it for everyone.
function groups.close(root, me)
  if groups.role(root, me) ~= "owner" then return nil, "Only the owner can close it." end
  if recording(root) then return nil, "Stop recording first." end
  band.write_json(root .. "/_band/closed.json", { by = me, at = os.time() })
  reaper.SetExtState(band.SECTION, "group closed " .. band.info(root).id, "1", true)
  return groups.leave(root, me, true)
end

-- Run from removal.tick, every 30 s or so: Syncthing lets go of what this computer left, a closed group is over here too, and a group
-- nobody's been seen in for a week gets a word (closed or removed while this computer was off: nothing can reach it to say so).
local said_quiet = {}
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
    local key = "group closed " .. g.id
    if reaper.GetExtState(band.SECTION, key) == "" and not groups.is_old(g.root) then
      local e = band.read_json(g.root .. "/_band/closed.json")
      if type(e) == "table" and e.by and groups.role(g.root, e.by) ~= "member" then
        if groups.leave(g.root, me, true) then -- (not: something's recording. The next look does it)
          reaper.SetExtState(band.SECTION, key, "1", true)
          band.log(string.format("%s closed %s: nothing syncs any more, and your copy stays in %s", tostring(e.by), g.name, g.root))
        end
      elseif not said_quiet[g.id] then
        local days = services.days_quiet(g.id)
        if days and days >= groups.QUIET_DAYS then
          said_quiet[g.id] = true
          band.log(string.format("nobody in %s has been online for %d days. It may have been closed, or you taken out: you can leave it on the Studios page", g.name, days))
        end
      end
    end
  end
end

return groups

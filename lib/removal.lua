-- Taking someone out of a group. A mark in the shared folder (_band/removed/<name>.json) says who; a minute later every computer in
-- the group stops syncing with theirs, each doing it itself, so nobody has to be online at the same moment. Their claims go free
-- and the driver's seat comes back, on the computer that removed them. What they made stays in the song and on Restore, and they
-- keep the copy they already have. Inviting them again and letting them in clears the mark. Which computer is whose: each computer
-- says so in _band/devices/<name>.json.
-- shortcut: a mark is a file anyone in the group could write, so this trusts the people in it (fine among friends). A group that
-- can't would need signed marks.
local band = require("band")
local removal = { GRACE = 60 }

local function file_name(user) return (tostring(user):gsub("[^%w%-_ ]", "")) .. ".json" end
local function marks(root) return root .. "/_band/removed" end
local function devices(root) return root .. "/_band/devices" end

function removal.mark(root, user)
  local m = band.read_json(marks(root) .. "/" .. file_name(user))
  return type(m) == "table" and m.user and m or nil
end
function removal.device_of(root, user)
  local d = band.read_json(devices(root) .. "/" .. file_name(user))
  return type(d) == "table" and d.device or nil
end
function removal.publish(root, user, id)
  if removal.device_of(root, user) == id then return end
  reaper.RecursiveCreateDirectory(devices(root), 0)
  band.write_json(devices(root) .. "/" .. file_name(user), { user = user, device = id })
end

-- Whether the minute is up. Pure.
function removal.due(m, now) return now - (tonumber(m.at) or 0) >= removal.GRACE end
-- Who's out: names, from their marks. A new computer of theirs, let in since, isn't the one the mark names. Pure over the three lists.
function removal.out(list, device_of, now)
  local out = {}
  for _, m in ipairs(list) do
    local has = device_of(m.user)
    if removal.due(m, now) and (not has or not m.device or has == m.device) then out[m.user] = true end
  end
  return out
end

local function all_marks(root)
  local list = {}
  for _, f in ipairs(band.files(marks(root), ".json")) do
    local m = band.read_json(marks(root) .. "/" .. f)
    if type(m) == "table" and m.user then list[#list + 1] = m end
  end
  return list
end
function removal.gone(root)
  return removal.out(all_marks(root), function(u) return removal.device_of(root, u) end, os.time())
end

function removal.remove(root, user, by)
  local id = removal.device_of(root, user)
  if not id then return nil, user .. "'s computer hasn't said which one it is yet: it does once it has StudioSync 0.46. Until then, remove it in Syncthing's own window." end
  reaper.RecursiveCreateDirectory(marks(root), 0)
  band.write_json(marks(root) .. "/" .. file_name(user), { user = user, device = id, by = by, at = os.time() })
  return true
end
function removal.keep(root, user) os.remove(marks(root) .. "/" .. file_name(user)) end
-- Who a mark says this computer belongs to, if it's been taken out of the group. (Its Syncthing keeps asking: that isn't someone new.)
function removal.who_was(root, device)
  for _, m in ipairs(all_marks(root)) do if m.device == device then return m.user end end
end
-- A computer let in again: whatever mark names it is over.
function removal.let_in(root, device)
  for _, m in ipairs(all_marks(root)) do if m.device == device then removal.keep(root, m.user) end end
end

-- Their claims free and, where they drove, you in the seat: every song and room in the group.
local function free(root, user, me)
  local sync, rooms = require("sync"), require("rooms")
  local cfg = { root = root, user = me }
  for _, song in ipairs(band.subdirs(root)) do
    if reaper.file_exists(root .. "/" .. song .. "/session.json") then
      for _, r in ipairs(rooms.list(cfg, song)) do
        sync.release_claims(cfg, song, r.name, user)
        local d = band.read_json(sync.room_dir(cfg, song, r.name) .. "/driver.json")
        if type(d) == "table" and d.driver == user then sync.set_driver(cfg, song, r.name, me) end
      end
    end
  end
end

-- Run every so often by Autostart and Live sync (at most every 30 s between them). The marks' work on this computer, once each.
function removal.tick(now)
  now = now or os.time()
  if now - (tonumber(reaper.GetExtState(band.SECTION, "removal look")) or 0) < 30 then return end
  reaper.SetExtState(band.SECTION, "removal look", tostring(now), false)
  local services = require("services")
  local me, id = reaper.GetExtState(band.SECTION, "user"), services.my_device_id()
  local told = ""
  for _, g in ipairs(band.bands()) do
    if id and me ~= "" then removal.publish(g.root, me, id) end
    for _, m in ipairs(all_marks(g.root)) do
      if m.user == me or (id and m.device == id) then
        told = string.format("%s took you out of %s: nothing syncs with the group any more, and your copy stays here. Ask to be invited again to come back.", tostring(m.by), g.name)
      elseif removal.due(m, now) and m.device then
        local key = "removal done " .. g.id .. " " .. m.user .. " " .. tostring(m.at)
        if reaper.GetExtState(band.SECTION, key) == "" then
          local ok, why = services.unshare(g.id, m.device)
          if ok then
            reaper.SetExtState(band.SECTION, key, "1", true)
            if m.by == me then pcall(free, g.root, m.user, me) end
            band.log(m.user .. " is out of " .. g.name .. ": this computer no longer syncs with theirs")
          else band.log("couldn't stop syncing with " .. m.user .. ": " .. tostring(why)) end
        end
      end
    end
  end
  reaper.SetExtState(band.SECTION, "removed from", told, false)
end

return removal

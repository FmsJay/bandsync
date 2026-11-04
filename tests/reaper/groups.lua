-- Run inside REAPER (ReaScript). Who runs a group, renaming it, leaving it and closing it, on two computers' worth of settings.
-- Scratch folders and a scratch tab; Syncthing's commands are recorded here, not run, and this computer's own group settings are put
-- back at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "services", "removal", "groups", "sync", "rooms" }) do package.loaded[m] = nil end
local band, services, removal, groups = require("band"), require("services"), require("removal"), require("groups")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local KEYS = { "sync_root", "bands", "user", "leaving", "removal look", "old groups" }
local saved = {}
for _, k in ipairs(KEYS) do saved[k] = reaper.GetExtState(band.SECTION, k) end
local real_exec, real_id, real_st, real_quiet = reaper.ExecProcess, services.my_device_id, services.syncthing_path, services.days_quiet
local ME = "AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA"
local PEER = "BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB"
local cmds, folders = {}, {}
-- a small Syncthing: what the group code asks of it
reaper.ExecProcess = function(c)
  cmds[#cmds + 1] = c
  if c:find("folders list", 1, true) then local t = {}; for f in pairs(folders) do t[#t + 1] = f end; return "0\n" .. table.concat(t, "\n") .. "\n" end
  local f = c:match("folders (%S+) devices list")
  if f then return "0\n" .. table.concat(folders[f] or {}, "\n") .. "\n" end
  f = c:match("folders add %-%-id (%S+)")
  if f then folders[f] = { ME }; return "0\n" end
  f = c:match("folders (%S+) delete")
  if f then folders[f] = nil; return "0\n" end
  return "0\n"
end
services.syncthing_path = function() return "syncthing" end
services.my_device_id = function() return ME end
services.days_quiet = function() return nil end
local function said(s) for _, c in ipairs(cmds) do if c:find(s, 1, true) then return true end end return false end
local base = D .. "/groot_" .. os.time()
local home = base .. "/StudioSync"
local tab
local ended_keys = {}
-- (who's asked is read at most every few seconds: a fresh copy of the module forgets)
local function fresh()
  package.loaded.groups = nil
  groups = require("groups")
end
local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(home .. "/_band", 0)
  band.write_json(home .. "/_band/band.json", { name = "Chilio", id = "bandsync", drive = "StudioSync" })
  reaper.RecursiveCreateDirectory(home .. "/Lantern", 0)
  folders.bandsync = { ME, PEER }
  reaper.SetExtState(band.SECTION, "sync_root", home, false)
  reaper.SetExtState(band.SECTION, "bands", "", false)
  reaper.SetExtState(band.SECTION, "user", "James", false)
  reaper.DeleteExtState(band.SECTION, "leaving", false)
  local cfg = { root = home, user = "James" }

  -- 1. A group from before owners stays open to everyone
  check(groups.role(home, "James") == "open" and groups.may_manage(home, "Sam") and groups.may_remove(home, "Sam", "James"), "a group with no owner works as it did")

  -- 2. A new one: its starter owns it, and the roles do what they say
  local root = services.new_band(cfg, "Lantern")
  check(root == base .. "/StudioSync Lantern", "a new one's folder says StudioSync (" .. tostring(root) .. ")")
  local i = band.info(root)
  check(i.drive == "StudioSync - Lantern" and i.id:match("^studiosync%-lantern%-%x%x%x%x$") ~= nil, "and its Drive folder, with an ID of its own")
  check(said('--label "StudioSync Lantern"'), "and its name in Syncthing")
  check(groups.role(root, "James") == "owner" and groups.role(root, "Sam") == "member", "whoever starts it owns it")
  check(groups.may_manage(root, "Sam") == false and groups.may_remove(root, "Sam", "Alex") == false, "a member can't let people in or remove anyone")
  check(groups.set_admin(root, "Sam", "Sam", true) == nil, "a member can't make themselves an admin")
  check(groups.set_admin(root, "James", "Sam", true) == true, "the owner makes an admin"); fresh()
  check(groups.role(root, "Sam") == "admin" and groups.may_manage(root, "Sam"), "who can then let people in")
  check(groups.may_remove(root, "Sam", "Alex") == true, "and remove a member")
  groups.set_admin(root, "James", "Pat", true); fresh()
  check(groups.may_remove(root, "Sam", "Pat") == false and groups.may_remove(root, "Sam", "James") == false, "but not another admin, or the owner")
  check(groups.may_remove(root, "James", "Sam") == true and groups.may_remove(root, "James", "James") == false, "the owner can remove an admin, and not themselves")
  check(groups.set_admin(root, "Sam", "Alex", true) == nil, "an admin can't make admins")
  groups.set_admin(root, "James", "Pat", false); fresh()
  check(groups.role(root, "Pat") == "member", "the owner can make them a member again")

  -- 3. A removal only counts from someone who may do it
  reaper.RecursiveCreateDirectory(root .. "/_band/devices", 0)
  band.write_json(root .. "/_band/devices/Alex.json", { user = "Alex", device = PEER })
  removal.remove(root, "Alex", "Pat")
  check(removal.mark(root, "Alex") ~= nil and next(removal.gone(root)) == nil, "a member's mark on someone does nothing")
  removal.keep(root, "Alex")

  -- 4. A new name of theirs follows
  band.rename(root, "Sam", "Samuel"); fresh()
  check(groups.role(root, "Samuel") == "admin", "someone who changes their name stays an admin")
  band.rename(root, "James", "Jim"); fresh()
  check(groups.role(root, "Jim") == "owner", "and an owner stays the owner")
  band.rename(root, "Jim", "James"); fresh()

  -- 5. Rename the group
  check(groups.rename(root, "Night", "Pat") == nil, "a member can't rename it")
  check(groups.rename(root, "  ", "James") == nil, "it needs a name")
  check(groups.rename(root, "Chilio", "James") == nil, "not one you're already in")
  check(groups.rename(root, "Night", "Samuel") == "Night", "an admin can")
  i = band.info(root)
  check(i.name == "Night" and i.drive == "StudioSync - Lantern" and i.id:match("^studiosync%-lantern") ~= nil, "only the name changes")
  check(said("label set \"StudioSync Night\""), "Syncthing's label follows"); fresh()
  check(groups.role(root, "James") == "owner", "and who runs it stays")

  -- 6. The owner can't just walk off
  local no, why = groups.leave(root, "James")
  check(no == nil and tostring(why):find("You own this", 1, true) ~= nil, "the owner has to hand it over or close it")
  check(groups.hand_over(root, "Pat", "Pat") == nil, "a member can't take it")
  check(groups.hand_over(root, "James", "Samuel") == true, "the owner hands it over"); fresh()
  check(groups.role(root, "Samuel") == "owner" and groups.role(root, "James") == "admin", "and stays on as an admin")
  check(groups.close(root, "James") == nil, "an admin can't close it")
  groups.hand_over(root, "Samuel", "James"); fresh()

  -- 7. Closing: a tab in it stays open as an ordinary project
  reaper.Main_OnCommand(40859, 0); tab = reaper.EnumProjects(-1)
  band.bind(tab, { role = "host", song = "Lantern", room = "main", version = 1, root = root })
  local id = band.info(root).id
  ended_keys[#ended_keys + 1] = "group closed " .. id
  check(groups.close(root, "James") == true, "the owner closes it")
  check(band.binding(tab) == nil, "its tab is an ordinary project now")
  check(band.read_json(root .. "/_band/closed.json").by == "James", "the others are told")
  check(removal.mark(root, "James").left == true, "and that this computer has gone")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home and reaper.GetExtState(band.SECTION, "bands") == home, "back in the other group")
  check(reaper.file_exists(root .. "/_band/band.json"), "its folder stays here")
  check(folders[id] ~= nil, "Syncthing holds on for a moment, so the news gets out")
  groups.tick(os.time())
  check(folders[id] ~= nil, "still, right away")
  groups.tick(os.time() + groups.WAIT + 1)
  check(folders[id] == nil and reaper.GetExtState(band.SECTION, "leaving") == "", "then it lets go")
  check(folders.bandsync ~= nil and #folders.bandsync == 2, "the other group's folder isn't touched")

  -- 8. On someone else's computer: the owner closed it, and this one follows. Someone else's closed.json doesn't count.
  local two = services.new_band(cfg, "Second")
  local id2 = band.info(two).id
  ended_keys[#ended_keys + 1] = "group closed " .. id2
  folders[id2] = { ME, PEER }
  reaper.SetExtState(band.SECTION, "user", "Laptop", false); fresh()
  band.bind(tab, { role = "guest", song = "Lantern", room = "main", version = 1, root = two })
  band.write_json(two .. "/_band/closed.json", { by = "Laptop", at = os.time() })
  groups.tick(os.time())
  check(band.binding(tab) ~= nil and reaper.GetExtState(band.SECTION, "sync_root") == two, "a member saying it's closed does nothing")
  band.write_json(two .. "/_band/closed.json", { by = "James", at = os.time() })
  groups.tick(os.time())
  check(band.binding(tab) == nil, "when the owner closes it, it's over here too, and the tab stays open")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home, "back in the other group")
  check(removal.mark(two, "Laptop").left == true, "this computer says it's gone too")
  groups.tick(os.time() + groups.WAIT + 1)
  check(folders[id2] == nil, "Syncthing lets go here too")
  check(said("devices " .. PEER .. " delete") == false, "a computer another group still has isn't forgotten")

  -- 9. Forgetting a computer only that folder had
  folders["x-solo"] = { ME, "CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC" }
  check(services.forget_folder("x-solo") == true and said("devices CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC delete"), "a computer only that folder had is forgotten")
  check(services.forget_folder("not-there") == true, "a folder that's gone already is fine")

  -- 10. Leaving as a member, and your only group
  reaper.SetExtState(band.SECTION, "user", "James", false); fresh()
  local three = services.new_band(cfg, "Third")
  groups.hand_over(three, "James", "Sam"); fresh()
  check(groups.leave(three, "James") == true and reaper.GetExtState(band.SECTION, "sync_root") == home, "someone else's group can be left, back to another")
  check(removal.mark(three, "James").left == true, "and it's marked, by the one who left")
  band.write_json(home .. "/_band/band.json", { name = "Chilio", id = "bandsync", drive = "BandSync", owner = "Sam" }); fresh()
  local only, why2 = groups.leave(home, "James")
  check(only == nil and tostring(why2):find("only studio", 1, true) ~= nil, "your only group can't be left")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home, "and nothing changed")

  -- 11. Nobody seen for a while
  local t = os.time({ year = 2026, month = 11, day = 20, hour = 12 })
  local ids = { "x", "y" }
  check(services.quiet_days({ x = { lastSeen = "2026-11-10T12:00:00Z" }, y = { lastSeen = "2026-11-13T12:00:00Z" } }, ids, t) == 7, "days since the most recent of them")
  check(services.quiet_days({ x = { lastSeen = "1970-01-01T00:00:00Z" } }, ids, t) == nil, "someone who's never connected isn't quiet: they're waiting")
  check(services.quiet_days({}, {}, t) == nil, "nobody there yet isn't quiet either")
  local n = 1000 + os.time() % 9000 -- (a number of days no earlier run's line has)
  services.days_quiet = function(id) return id == "bandsync" and n or nil end
  groups.tick(os.time())
  groups.tick(os.time())
  local told = 0
  for _, l in ipairs(band.activity()) do if l:find("has been online for " .. n .. " days", 1, true) then told = told + 1 end end
  check(told == 1, "it says so once (" .. told .. ")")
  services.days_quiet = function() return nil end

  -- 12. Marks from someone who's left count without an admin's say
  check(removal.out({ removal.mark(three, "James") }, function() return nil end, os.time() + removal.GRACE + 1)["James"] == true, "someone who left is out, after the minute")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.ExecProcess, services.my_device_id, services.syncthing_path, services.days_quiet = real_exec, real_id, real_st, real_quiet
for _, k in ipairs(KEYS) do reaper.SetExtState(band.SECTION, k, saved[k], k ~= "removal look" and k ~= "leaving") end
for _, k in ipairs(ended_keys) do reaper.DeleteExtState(band.SECTION, k, true) end
if tab and reaper.ValidatePtr2(0, tab, "ReaProject*") then
  reaper.SelectProjectInstance(tab)
  reaper.Main_SaveProjectEx(tab, base .. "/end.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

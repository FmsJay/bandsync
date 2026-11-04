-- Run inside REAPER (ReaScript). Renaming a group, leaving one, and a temporary session from start to end, on two computers' worth of
-- settings. Scratch folders and a scratch tab; Syncthing's commands are recorded here, not run, and this computer's own group settings
-- are put back at the end.
local D = reaper.GetResourcePath() .. "/BandSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "services", "removal", "groups", "sync", "rooms" }) do package.loaded[m] = nil end
local band, services, removal, groups = require("band"), require("services"), require("removal"), require("groups")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local KEYS = { "sync_root", "bands", "user", "leaving", "removal look" }
local saved = {}
for _, k in ipairs(KEYS) do saved[k] = reaper.GetExtState(band.SECTION, k) end
local real_exec, real_id = reaper.ExecProcess, services.my_device_id
local real_st = services.syncthing_path
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
local function said(s) for _, c in ipairs(cmds) do if c:find(s, 1, true) then return true end end return false end
local base = D .. "/groot_" .. os.time()
local home = base .. "/BandSync"
local tab
local ended_keys = {}
local ok, err = pcall(function()
  reaper.RecursiveCreateDirectory(home .. "/_band", 0)
  band.write_json(home .. "/_band/band.json", { name = "Chilio", id = "bandsync", drive = "BandSync" })
  reaper.RecursiveCreateDirectory(home .. "/Lantern", 0)
  folders.bandsync = { ME, PEER }
  reaper.SetExtState(band.SECTION, "sync_root", home, false)
  reaper.SetExtState(band.SECTION, "bands", "", false)
  reaper.SetExtState(band.SECTION, "user", "James", false)
  reaper.DeleteExtState(band.SECTION, "leaving", false)
  local cfg = { root = home, user = "James" }

  -- 1. Rename
  check(groups.rename(home, "  ") == nil, "a group needs a name")
  check(groups.rename(home, "The Chilios") == "The Chilios", "renaming works")
  local i = band.info(home)
  check(i.name == "The Chilios" and i.id == "bandsync" and i.drive == "BandSync", "only the name changes: the ID and the Drive folder stay")
  check(said("folders bandsync label set"), "Syncthing's label follows")
  groups.rename(home, "Chilio")

  -- 2. A temporary session
  local root = groups.create_session(cfg, "Lantern", "James")
  check(root == base .. "/BandSync Lantern", "a session is a folder of its own (" .. tostring(root) .. ")")
  local temp, by = groups.temporary(root)
  check(temp == true and by == "James", "it knows it's temporary, and who started it")
  check(band.info(root).id:match("^bandsync%-lantern%-%x%x%x%x$") ~= nil, "with an ID of its own")
  check(groups.temporary(home) == false, "a group isn't temporary")
  check(reaper.GetExtState(band.SECTION, "sync_root") == root, "this computer works in it now")

  -- 3. Its project in a tab, then the session ends
  reaper.Main_OnCommand(40859, 0); tab = reaper.EnumProjects(-1)
  band.bind(tab, { role = "host", song = "Lantern", room = "main", version = 1, root = root })
  check(band.binding(tab) ~= nil, "the tab is in the session")
  local id = band.info(root).id
  ended_keys[#ended_keys + 1] = "session ended " .. id
  check(groups.end_session(root, "James") == true, "the starter ends it")
  check(band.binding(tab) == nil, "its tab is an ordinary project now")
  check(band.read_json(root .. "/_band/ended.json").by == "James", "the others are told")
  check(removal.mark(root, "James").left == true, "and that this computer has gone")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home, "back in the group")
  check(reaper.GetExtState(band.SECTION, "bands") == home, "the session's off the list")
  check(reaper.file_exists(root .. "/_band/band.json"), "its folder stays here")
  check(folders[id] ~= nil, "Syncthing holds on for a moment, so the news gets out")
  groups.tick(os.time())
  check(folders[id] ~= nil, "still, right away")
  groups.tick(os.time() + groups.WAIT + 1)
  check(folders[id] == nil, "then it lets go")
  check(reaper.GetExtState(band.SECTION, "leaving") == "", "and that's done with")
  check(folders.bandsync ~= nil and #folders.bandsync == 2, "the group's folder isn't touched")

  -- 4. The same name again: the old folder's still there
  local again = groups.create_session(cfg, "Lantern", "James")
  check(again == base .. "/BandSync Lantern 2", "a new session of the same name gets its own (" .. tostring(again) .. ")")
  local id2 = band.info(again).id
  ended_keys[#ended_keys + 1] = "session ended " .. id2

  -- 5. On someone else's computer: it ended, and this one follows
  band.use_band(again)
  folders[id2] = { ME, PEER }
  reaper.SetExtState(band.SECTION, "user", "Laptop", false)
  band.bind(tab, { role = "guest", song = "Lantern", room = "main", version = 1, root = again })
  band.write_json(again .. "/_band/ended.json", { by = "James", at = os.time() })
  groups.tick(os.time())
  check(band.binding(tab) == nil, "when someone ends it, it's over here too, and the tab stays open")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home, "back in the other group")
  check(removal.mark(again, "Laptop").left == true, "this computer says it's gone too")
  groups.tick(os.time() + groups.WAIT + 1)
  check(folders[id2] == nil, "Syncthing lets go here too")
  check(said("devices " .. PEER .. " delete") == false, "a computer another group still has isn't forgotten")

  -- 6. Forgetting a computer only that folder had
  folders["x-solo"] = { ME, "CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC" }
  check(services.forget_folder("x-solo") == true and said("devices CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC-CCCCCCC delete"), "a computer only that folder had is forgotten")
  check(services.forget_folder("not-there") == true, "a folder that's gone already is fine")

  -- 7. Leaving a group
  reaper.SetExtState(band.SECTION, "user", "James", false)
  local other = services.new_band(cfg, "Night Shift")
  local leave_ok = groups.leave(other, "James")
  check(leave_ok == true and reaper.GetExtState(band.SECTION, "sync_root") == home, "leaving a group goes back to another")
  local only, why = groups.leave(home, "James")
  check(only == nil and tostring(why):find("only group", 1, true) ~= nil, "your only group can't be left")
  check(reaper.GetExtState(band.SECTION, "sync_root") == home, "and nothing changed")

  -- 8. The others' side of someone leaving
  check(removal.gone(again)["Laptop"] == nil, "they still show for the minute")
  check(removal.out({ removal.mark(again, "Laptop") }, function() return nil end, os.time() + removal.GRACE + 1)["Laptop"] == true, "then they're out")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
reaper.ExecProcess, services.my_device_id, services.syncthing_path = real_exec, real_id, real_st
for _, k in ipairs(KEYS) do reaper.SetExtState(band.SECTION, k, saved[k], k ~= "removal look" and k ~= "leaving") end
for _, k in ipairs(ended_keys) do reaper.DeleteExtState(band.SECTION, k, true) end
if tab and reaper.ValidatePtr2(0, tab, "ReaProject*") then
  reaper.SelectProjectInstance(tab)
  reaper.Main_SaveProjectEx(tab, base .. "/end.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

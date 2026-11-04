-- Run inside REAPER (ReaScript). Taking someone out of a group: the minute to change your mind, every computer cutting them off once,
-- their claims and driver's seat freed by whoever removed them, what it says on their own computer, and letting them back in.
-- A scratch folder, and Syncthing stood in for: nothing here touches the real one.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "rooms", "removal", "services" }) do package.loaded[m] = nil end
local band, sync, rooms, removal, services = require("band"), require("sync"), require("rooms"), require("removal"), require("services")
local root = D .. "/rroot_" .. os.time()
local song, room = "RemoveLab", "main"
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local real_user, real_look, real_told = reaper.GetExtState(band.SECTION, "user"), reaper.GetExtState(band.SECTION, "removal look"), reaper.GetExtState(band.SECTION, "removed from")
local cut, fail_next = {}, false
local real_unshare, real_id, real_bands = services.unshare, services.my_device_id, band.bands
services.unshare = function(folder, id)
  if fail_next then fail_next = false; return nil, "Syncthing was busy" end
  cut[#cut + 1] = folder .. " " .. id
  return true
end
services.my_device_id = function() return "MINE" end
band.bands = function() return { { root = root, id = "lab", name = "Lab" } } end
local function tick(now)
  reaper.SetExtState(band.SECTION, "removal look", "0", false)
  removal.tick(now)
end
local done_keys = {}
local ok, err = pcall(function()
  reaper.SetExtState(band.SECTION, "user", "James", false)
  local James, Sam = { root = root, user = "James" }, { root = root, user = "Sam" }
  reaper.RecursiveCreateDirectory(sync.room_dir(James, song, room), 0)
  band.write_json(band.song_dir(James, song) .. "/session.json", { song = song, host = "James", sync = "mirror" })
  sync.set_driver(James, song, room, "Sam")

  -- each computer says which it is
  tick(os.time())
  check(removal.device_of(root, "James") == "MINE", "this computer says which one it is")
  check(removal.remove(root, "Sam", "James") == nil, "someone whose computer hasn't said can't be cut off: it says so")
  removal.publish(root, "Sam", "SAMDEVICE")
  check(removal.device_of(root, "Sam") == "SAMDEVICE", "theirs does too")

  -- the minute
  check(removal.remove(root, "Sam", "James") == true, "removing them leaves the mark")
  local m = removal.mark(root, "Sam")
  check(m and m.device == "SAMDEVICE" and m.by == "James", "it names the computer and who")
  tick(os.time())
  check(#cut == 0, "nothing is cut during the minute")
  check(not removal.gone(root).Sam, "and they're still listed")
  removal.keep(root, "Sam")
  check(removal.mark(root, "Sam") == nil, "Keep them takes the mark away")
  tick(os.time() + 3600)
  check(#cut == 0, "and nothing happens after")

  -- it goes ahead
  removal.remove(root, "Sam", "James")
  m = removal.mark(root, "Sam")
  done_keys[#done_keys + 1] = "removal done lab Sam " .. tostring(m.at)
  local later = m.at + removal.GRACE
  fail_next = true
  tick(later)
  check(#cut == 0 and sync.released(James, song, room).Sam == nil, "Syncthing busy: nothing is taken as done")
  tick(later)
  check(cut[1] == "lab SAMDEVICE", "then this computer stops syncing with theirs: " .. tostring(cut[1]))
  check(sync.released(James, song, room).Sam ~= nil, "their claims go free")
  local d = band.read_json(sync.room_dir(James, song, room) .. "/driver.json")
  check(d and d.driver == "James", "and the seat they drove in comes back")
  tick(later + 60)
  check(#cut == 1, "once only")
  reaper.RecursiveCreateDirectory(sync.room_dir(James, song, room) .. "/status", 0)
  band.write_json(sync.room_dir(James, song, room) .. "/status/Sam.json", { user = "Sam", time = "2026-01-01T00:00:00Z" })
  band.write_json(root .. "/_band/removed/Sam.json", { user = "Sam", device = "SAMDEVICE", by = "James", at = os.time() - removal.GRACE }) -- (the clock here hasn't really moved on)
  check(removal.gone(root).Sam == true, "and they're no longer listed")
  local gathered = require("status").gather(James, { song = song, room = room, root = root }, reaper.EnumProjects(-1))
  local listed = false
  for _, r in ipairs(gathered.rows) do if r.name == "Sam" then listed = true end end
  check(not listed, "Who's here leaves them out")

  -- on another computer, not the remover's: cut off too, but claims are the remover's to free
  sync.set_driver(James, song, room, "Sam")
  reaper.SetExtState(band.SECTION, "user", "Laptop", false)
  removal.keep(root, "Sam")
  band.write_json(root .. "/_band/removed/Sam.json", { user = "Sam", device = "SAMDEVICE", by = "James", at = later + 1 })
  done_keys[#done_keys + 1] = "removal done lab Sam " .. tostring(later + 1)
  tick(later + 100)
  check(#cut == 2, "another computer cuts them off too")
  d = band.read_json(sync.room_dir(James, song, room) .. "/driver.json")
  check(d and d.driver == "Sam", "and leaves the seat to the one who removed them")

  -- on their own computer
  reaper.SetExtState(band.SECTION, "user", "Sam", false)
  local before = #cut
  tick(later + 200)
  check(#cut == before, "their own computer cuts nobody off")
  check(reaper.GetExtState(band.SECTION, "removed from"):find("James took you out of Lab", 1, true) ~= nil, "it tells them: " .. reaper.GetExtState(band.SECTION, "removed from"))

  -- a mark naming this very computer under another name does nothing to it
  reaper.SetExtState(band.SECTION, "user", "James", false)
  band.write_json(root .. "/_band/removed/Odd.json", { user = "Odd", device = "MINE", by = "Sam", at = 1 })
  before = #cut
  tick(later + 300)
  check(#cut == before, "nothing ever cuts this computer off from itself")
  removal.keep(root, "Odd")

  -- back in
  removal.let_in(root, "SAMDEVICE")
  check(removal.mark(root, "Sam") == nil and not removal.gone(root).Sam, "let in again: the mark's gone and they're listed")
  tick(later + 400)
  check(reaper.GetExtState(band.SECTION, "removed from") == "", "and nothing's said any more")
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
services.unshare, services.my_device_id, band.bands = real_unshare, real_id, real_bands
reaper.SetExtState(band.SECTION, "user", real_user, false)
reaper.SetExtState(band.SECTION, "removal look", real_look, false)
reaper.SetExtState(band.SECTION, "removed from", real_told, false)
for _, k in ipairs(done_keys) do reaper.DeleteExtState(band.SECTION, k, true) end
return (fails == 0 and "ALL PASS" or fails .. " FAILED") .. "\n" .. table.concat(out, "\n")

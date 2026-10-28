-- sync.authority: owner by claim > region > driver; a take's author may change it where nobody has claimed (lupa or Lua 5.4)
local claims = { ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" } } }
package.loaded.band = {
  files = function(dir) return dir:match("claims$") and { "Laptop.json" } or {} end,
  read_json = function(path) for k, v in pairs(claims) do if path:sub(-#k) == k then return v end end end,
  song_dir = function(_, song) return "root/" .. song end,
}
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")
local s = { host = "James", markers = { { region = true, name = "Verse", pos = 10, ["end"] = 30 } } }
local can = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Keys", 0), "the driver owns what nobody claimed")
assert(not can("Laptop", "Keys", 0), "a guest doesn't own the driver's tracks")
assert(can("Laptop", "Guitar", 12) and not can("James", "Guitar", 12), "a track claim beats the driver")
assert(can("Laptop", "Pad", 0, "Laptop-20261028-032939Z-1"), "the author may change their own take on an unclaimed track")
assert(not can("Laptop", "Keys", 0, "James-20261028-032515Z-2"), "but not someone else's")
assert(not can("James", "Guitar", 12, "James-20261028-040000Z-1"), "a claim beats authorship")
print("ok")

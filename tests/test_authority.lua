-- sync.authority: owner by claim > region > driver; a take's author may change it where nobody has claimed (lupa or Lua 5.4)
local claims = { ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" } } }
local function with(list) -- swap in another set of claim files
  claims = list
  local names = {}
  for k in pairs(list) do names[#names + 1] = k:match("[^/]+$") end
  package.loaded.band.files = function(dir) return dir:match("claims$") and names or {} end
end
package.loaded.band = {
  files = function(dir) return dir:match("claims$") and { "Laptop.json" } or {} end,
  read_json = function(path) for k, v in pairs(claims) do if path:sub(-#k) == k then return v end end end,
  song_dir = function(_, song) return "root/" .. song end,
}
package.path = "lib/?.lua;" .. package.path
local sync = require("sync")
local s = { host = "James", markers = { { region = true, name = "Verse", pos = 10, ["end"] = 30 } } }
local can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Keys", 0), "the driver owns what nobody claimed")
assert(not can("Laptop", "Keys", 0), "a guest doesn't own the driver's tracks")
assert(can("Laptop", "Guitar", 12) and not can("James", "Guitar", 12), "a track claim beats the driver")
assert(can("Laptop", "Pad", 0, "Laptop-20261028-032939Z-1"), "the author may change their own take on an unclaimed track")
assert(not can("Laptop", "Keys", 0, "James-20261028-032515Z-2"), "but not someone else's")
assert(not can("James", "Guitar", 12, "James-20261028-040000Z-1"), "a claim beats authorship")
-- time selections: newer than a region claim, older than any track claim
with({
  ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" }, regions = { "Verse" } },
  ["claims/James.json"] = { user = "James", time = "2026-10-28T03:30:00Z", times = { { from = 20, to = 25 } } },
})
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(#who.times == 1 and who.times[1].user == "James", "time claim read")
assert(can("James", "Keys", 21) and not can("Laptop", "Keys", 21), "a time claim beats a region claim")
assert(can("Laptop", "Keys", 12) and not can("James", "Keys", 12), "outside the time claim the region claim holds")
assert(can("Laptop", "Guitar", 21) and not can("James", "Guitar", 21), "a track claim beats a time claim")
assert(not can("Laptop", "Pad", 22, "Laptop-20261028-032939Z-1"), "the author can't change their take inside someone's time claim")
-- claims made in the same second: the later name wins, whatever order the folder lists the files in
for _, order in ipairs({ { "claims/James.json", "claims/Laptop.json" }, { "claims/Laptop.json", "claims/James.json" } }) do
  local list = {
    ["claims/James.json"] = { user = "James", time = "2026-10-28T11:12:00Z", tracks = { "Pad" }, times = { { from = 0, to = 5 } } },
    ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T11:12:00Z", tracks = { "Pad" }, times = { { from = 0, to = 5 } } },
  }
  claims = list
  package.loaded.band.files = function(dir) return dir:match("claims$") and { order[1]:match("[^/]+$"), order[2]:match("[^/]+$") } or {} end
  can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
  assert(who.owner("Pad", 0) == "Laptop", "a same-second track claim tie is decided by name")
  assert(who.owner("Keys", 1) == "Laptop", "a same-second time claim tie is decided by name")
end
-- the room's editing mode (mode.json, set by the driver)
with({ ["claims/Laptop.json"] = { user = "Laptop", time = "2026-10-28T03:28:00Z", tracks = { "Guitar" } } })
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "claims", "claims by default")
claims["mode.json"] = { mode = "open" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(who.mode == "open" and can("Laptop", "Keys", 0), "open: anyone changes what nobody claimed")
assert(not can("James", "Guitar", 12), "open: a claim still holds")
assert(not can("Laptop", nil, nil), "open: the tempo map stays the driver's")
claims["mode.json"] = { mode = "driver" }
can, who = sync.authority({ root = "root" }, "Saltmarsh", "main", s)
assert(can("James", "Guitar", 12) and not can("Laptop", "Guitar", 12), "driver only: claims don't count")
assert(not can("Laptop", "Pad", 0, "Laptop-20261028-032939Z-1"), "driver only: not even your own take")
claims["mode.json"] = { mode = "nonsense" }
assert(select(2, sync.authority({ root = "root" }, "Saltmarsh", "main", s)).mode == "claims", "an unknown mode reads as claims")
print("ok")

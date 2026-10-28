-- drive.parse / place / trashed are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local drive = require("drive")
local id, rev, man = drive.parse("James-20261028-032515Z-2-dry-r6.flac")
assert(id == "James-20261028-032515Z-2" and rev == 6 and not man, "dry twin of revision 6")
id, rev, man = drive.parse("Laptop-Mac-20261028-161310Z-12.json")
assert(id == "Laptop-Mac-20261028-161310Z-12" and rev == 1 and man, "a manifest; hyphens in the name are fine")
assert(drive.parse("index.json") == nil and drive.parse("notes.txt") == nil, "not take files")
local trashed = drive.trashed({
  { type = "delete", take = "A-20261028-010101Z-1", time = "2026-10-28T01:00:00Z", id = "x1" },
  { type = "undelete", take = "A-20261028-010101Z-1", time = "2026-10-28T02:00:00Z", id = "x2" },
  { type = "delete", take = "B-20261028-010101Z-1", time = "2026-10-28T02:00:00Z", id = "x3" },
  { type = "edit", take = "C-20261028-010101Z-1", time = "2026-10-28T03:00:00Z", id = "x4" },
})
assert(not trashed["a-20261028-010101z-1"] and trashed["b-20261028-010101z-1"] and not trashed["c-20261028-010101z-1"], "newest delete/undelete wins")
local cur = { ["c-20261028-010101z-1"] = 3 }
assert(drive.place("B-20261028-010101Z-1.flac", trashed, cur) == "_trash", "deleted take's audio")
assert(drive.place("B-20261028-010101Z-1.json", trashed, cur) == "_trash", "and its manifest")
assert(drive.place("C-20261028-010101Z-1-r2.opus", trashed, cur) == "_trash", "an older revision")
assert(drive.place("C-20261028-010101Z-1-r3.opus", trashed, cur) == "takes", "the current revision")
assert(drive.place("C-20261028-010101Z-1.json", trashed, cur) == "takes", "the manifest stays with a live take")
assert(drive.place("D-20261028-010101Z-1.flac", trashed, cur) == "takes", "a take with no manifest yet (still arriving)")
print("ok")

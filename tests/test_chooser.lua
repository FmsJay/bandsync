-- lib/chooser.lua's listing, search and "ago" are pure given band's file reads: stubbed here (lupa or Lua 5.4)
local files = {
  ["root/A/session.json"] = { host = "James", published = "2026-10-01T00:00:00Z" },
  ["root/B/session.json"] = { host = "Laptop", published = "2026-10-20T00:00:00Z" },
  ["root/A/rooms/main/status/James.json"] = { user = "James", time = "2026-10-28T10:00:00Z" },
  ["root/A/rooms/drums/status/Mac.json"] = { user = "Mac", time = "2026-10-28T11:00:00Z" },
}
package.loaded.band = {
  songs = function() return { "B", "A" } end, -- band.songs: newest publish first
  read_json = function(p) return files[p] end,
  session_path = function(_, song) return "root/" .. song .. "/session.json" end,
  song_dir = function(_, song) return "root/" .. song end,
  subdirs = function(d) return d == "root/A/rooms" and { "drums", "main" } or {} end,
  files = function(d) return ({ ["root/A/rooms/main/status"] = { "James.json" }, ["root/A/rooms/drums/status"] = { "Mac.json" } })[d] or {} end,
  age = function(iso, now) return now.secs end,
}
package.path = "lib/?.lua;" .. package.path
local chooser = require("chooser")
local rows = chooser.songs({ root = "root" })
assert(rows[1].song == "A", "most recent activity first, not newest publish")
assert(rows[1].last == "2026-10-28T11:00:00Z", "last activity is the newest receipt")
assert(table.concat(rows[1].rooms, ",") == "main,drums", "main first, then side rooms")
assert(table.concat(rows[1].members, ",") == "James,Mac", "who's in it")
assert(rows[2].song == "B" and rows[2].rooms[1] == "main" and #rows[2].members == 0, "a song nobody joined yet")
assert(#chooser.songs({ root = "root" }, function(s) return s == "B" end) == 1, "keep filters")
assert(chooser.match(rows[1], "mac") and chooser.match(rows[1], "james drums") and not chooser.match(rows[1], "laptop"), "search by any word")
assert(chooser.match(rows[2], ""), "empty search matches")
assert(chooser.ago("x", { secs = 30 }) == "just now" and chooser.ago("x", { secs = 600 }) == "10 min ago"
  and chooser.ago("x", { secs = 7200 }) == "2 h ago" and chooser.ago("x", { secs = 3 * 86400 }) == "3 days ago", "ago")
print("ok")

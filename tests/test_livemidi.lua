-- livemidi.merge / takes are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.loaded.sync = package.loaded.sync or {}
package.loaded.live = package.loaded.live or {}
package.path = "lib/?.lua;" .. package.path
local lm = require("livemidi")
local files = {
  ["A-0001.json"] = { user = "Laptop", since = "A", at = 1, notes = {} },
  ["A-0002.json"] = { user = "Laptop", since = "A", at = 2, notes = { { i = 1, t = "Keys", s = 1.5, p = 60, v = 100 } } },
  ["A-0003.json"] = { user = "Laptop", since = "A", at = 3, notes = { { i = 1, t = "Keys", s = 1.5, e = 2.5, p = 60, v = 100 }, { i = 2, t = "Keys", s = 2.7, p = 64, v = 90 } } },
}
local st = { seen = {}, notes = {} }
assert(lm.merge(st, { "A-0001.json", "A-0003.json" }, function(f) return files[f] end), "files arriving out of step still count")
assert(st.notes[1].e == 2.5 and st.notes[2].p == 64 and st.at == 3, "the newest state of each note")
assert(lm.merge(st, { "A-0001.json", "A-0002.json", "A-0003.json" }, function(f) return files[f] end), "a late file is folded in")
assert(st.notes[1].e == nil and st.at == 3, "shortcut: a late older file can reopen a note until the next file; at never goes back")
assert(not lm.merge(st, { "A-0001.json", "A-0002.json", "A-0003.json" }, function(f) return files[f] end), "nothing new: no redraw")
files["B-0001.json"] = { user = "Laptop", since = "B", at = 9, notes = { { i = 1, t = "Bass", s = 9, p = 40, v = 80 } } }
assert(lm.merge(st, { "B-0001.json" }, function(f) return files[f] end) and st.since == "B" and st.notes[2] == nil, "a new recording starts over")
assert(lm.takes({ dev = 63, chan = 0 }, 3, 0x90) and not lm.takes({ dev = 2, chan = 0 }, 3, 0x90) and not lm.takes({ dev = 3, chan = 2 }, 3, 0x90), "device and channel")
print("ok")

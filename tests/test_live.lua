-- live.ini_set / parse_log are pure: run with lupa or any Lua 5.4 from the repo root
package.loaded.band = {}
package.path = "lib/?.lua;" .. package.path
local live = require("live")

local ini = "[other]\nhost=keep\n[ninjam]\nhost=old.server:2049\nmastervol=0.8\n"
local out = live.ini_set(ini, "ninjam", { host = "100.1.2.3:2049", user = "James" })
assert(out:find("%[other%]\nhost=keep"), "other sections untouched")
assert(out:find("host=100.1.2.3:2049", 1, true) and not out:find("old.server", 1, true), "key replaced")
assert(out:find("mastervol=0.8", 1, true), "unrelated key kept")
assert(out:find("user=James", 1, true), "new key added to the section")
local fresh = live.ini_set("", "ninjam", { host = "h" })
assert(fresh == "[ninjam]\nhost=h\n", "section created: " .. fresh)

local log = 'user {A} "x" 0 "y"\nsessionlog 0123ABCD "Laptop@100.1.2.4" 0 "Laptop" 12.5000000000 2.2500000000\nlocal xyz 0\n'
local c = live.parse_log(log)
assert(#c == 1 and c[1].guid == "0123ABCD" and c[1].user == "Laptop@100.1.2.4" and c[1].st == 12.5 and c[1].len == 2.25, "sessionlog parsed")
print("ok")

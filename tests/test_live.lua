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
-- session folder names are the listener's local time; stamps are UTC, comparable with take ids
local st = live.session_stamp("C:/x/bandsync_live/20261026_2345.ninjam")
assert(st:match("^%d%d%d%d%d%d%d%d%-%d%d%d%d%d%dZ$"), "stamp format: " .. st)
assert(st == os.date("!%Y%m%d-%H%M%SZ", os.time({ year = 2026, month = 10, day = 26, hour = 23, min = 45, sec = 0 })), "local -> UTC")
assert(live.session_stamp("C:/x/20261026_2345_1.ninjam") == st, "suffixed session folder")
-- only the same person's takes recorded after the session started replace its placeholders
assert(live.replaces("James-20261027-055000Z-1", "James", "20261027-054500Z"), "later take replaces")
assert(not live.replaces("James-20261027-032717Z-1", "James", "20261027-054500Z"), "earlier take doesn't")
assert(not live.replaces("Laptop-20261027-055000Z-1", "James", "20261027-054500Z"), "someone else's doesn't")
assert(live.replaces("Mary_Jo-20261027-055000Z-1", "Mary Jo", "20261027-054500Z"), "spaces vs underscores")
assert(not live.replaces("James-20261027-055000Z-1", "James", ""), "unknown session time: never")

-- SonoBus: one group for the band, made once and then kept; the join link is what SonoBus's paste parser reads
reaper = { time_precise = function() return 1.5 end }
local data = {}
local g, p = live.sonobus_group(data)
assert(g:match("^BandSync %w%w%w%w%w%w$") and #p == 12 and data.group == g and data.password == p, g .. " / " .. p)
assert(select(2, live.sonobus_group(data)) == p, "kept once made")
assert(live.sonobus_link("BandSync My Song", "ab&c") ==
  "http://go.sonobus.net/sblaunch?s=aoo.sonobus.net&g=BandSync%20My%20Song&p=ab%26c", live.sonobus_link("BandSync My Song", "ab&c"))
print("ok")

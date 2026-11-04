-- lib/sonobus.lua is pure: run with lupa or any Lua 5.4 from the repo root
package.path = "lib/?.lua;" .. package.path
local sonobus = require("sonobus")

local f = assert(io.open("tests/fixtures/sonobus_1.7.2_state.bin", "rb")) -- a real REAPER vst_chunk, decoded
local raw = f:read("a")
f:close()
local b64 = sonobus.b64encode(raw)
assert(sonobus.b64decode(b64) == raw, "base64 round trip")
assert(sonobus.b64decode("TWFu") == "Man" and sonobus.b64encode("Ma") == "TWE=" and sonobus.b64encode("M") == "TQ==", "base64 padding")

assert(sonobus.state_group(b64) == "BandSync SessionTest 4xt2", tostring(sonobus.state_group(b64)))

local joined = assert(sonobus.join_state(b64, { user = "Mary Jo", group = "StudioSync abcd", password = "pw", now = 1793000000 }))
assert(sonobus.state_group(joined) == "StudioSync abcd", "joins the band's group")
local s = sonobus.b64decode(joined)
local len = string.unpack("<I4", s)
assert(8 + len + 8 == #s, "header length matches the new component state")
assert(s:find("userName\0\1\9\5Mary Jo\0", 1, true), "user name written as SonoBus does")
assert(s:find("serverPort\0\1\5\1" .. string.pack("<i4", 10998), 1, true), "default server port")
assert(s:find("reconnectlast\0value\0\1\9\4" .. string.pack("<d", 1), 1, true), "Reconnect Last on")
assert(s:sub(-8 - 15 - 8, -9):find("JUCEPrivateData", 1, true), "JUCE's private data still at the end")
assert(#s - #raw == (#"Mary Jo" - #"admin 2") + (#"StudioSync abcd" - #"BandSync SessionTest 4xt2") + (#"pw" - #"xjaqdnnap3u4"),
  "only the changed strings changed size")
assert(sonobus.join_state(joined, { user = "x", group = "StudioSync abcd", password = "pw", now = 1 }), "re-joinable")
assert(s:find("defnetauto\0value\0\1\9\4" .. string.pack("<d", 0), 1, true), "jitter buffer: fixed")
assert(s:find("defnetbuf\0value\0\1\9\4" .. string.pack("<d", 0.15), 1, true), "jitter buffer: 150 ms")
assert(sonobus.is_set_up(joined, "StudioSync abcd") and not sonobus.is_set_up(joined, "StudioSync other"), "set up for its group")
assert(sonobus.state_user(joined) == "Mary Jo", tostring(sonobus.state_user(joined)))
assert(sonobus.is_set_up(joined, "StudioSync abcd", "Mary Jo") and not sonobus.is_set_up(joined, "StudioSync abcd", "Mary"), "set up as this bandmate")
assert(not sonobus.is_set_up(b64, "BandSync SessionTest 4xt2"), "right group but SonoBus's own buffer defaults: not set up")
assert(not sonobus.join_state("bm90IGEgc3RhdGU=", { user = "x", group = "g", password = "p" }), "garbage refused")
assert(sonobus.same_user("Laptop 5", "Laptop") and sonobus.same_user("Laptop", "Laptop") and not sonobus.same_user("Laptop 5b", "Laptop")
  and not sonobus.same_user("Laptops", "Laptop") and not sonobus.same_user(nil, "Laptop") and not sonobus.same_user("Mary", "Mary Jo"), "server renames")

-- joined: a join puts a newer entry on top; StudioSync's own written entry has the time it was written
assert(sonobus.joined_since(joined, 1792999999 * 1000) and not sonobus.joined_since(joined, 1793000000 * 1000), "joined after a time")

-- output pairs per bandmate, in SonoBus's own per-person cache (a real one: the laptop's, with "James" and "Laptop 4")
local cf = assert(io.open("tests/fixtures/sonobus_1.7.2_cache.bin", "rb"))
local cache = sonobus.b64encode(cf:read("a"))
cf:close()
assert(sonobus.output_of(cache, "James") == 0 and sonobus.output_of(cache, "Laptop 4") == 0 and not sonobus.output_of(cache, "Laptop"), "cache as saved")
local routed = assert(sonobus.set_outputs(cache, { James = 2, Laptop = 4, Drums = 6 }))
assert(sonobus.output_of(routed, "James") == 2, "an existing entry moves")
assert(sonobus.output_of(routed, "Laptop") == 4 and sonobus.output_of(routed, "Laptop 4") == 4, "a new entry, and the renamed copy follows")
assert(sonobus.output_of(routed, "Drums") == 6 and sonobus.state_group(routed) == "BandSync test", "a new person, nothing else touched")
local d = sonobus.b64decode(routed)
assert(8 + string.unpack("<I4", d) + 8 == #d and d:sub(-8 - 15 - 8, -9):find("JUCEPrivateData", 1, true), "still a whole state")
assert(sonobus.output_of(assert(sonobus.set_outputs(routed, { James = 8 })), "James") == 8, "re-routable")
assert(sonobus.output_of(assert(sonobus.set_outputs(b64, { Mary = 2 })), "Mary") == 2, "a state with no cache yet gets one")
print("ok")

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

local joined = assert(sonobus.join_state(b64, { user = "Mary Jo", group = "BandSync abcd", password = "pw", now = 1793000000 }))
assert(sonobus.state_group(joined) == "BandSync abcd", "joins the band's group")
local s = sonobus.b64decode(joined)
local len = string.unpack("<I4", s)
assert(8 + len + 8 == #s, "header length matches the new component state")
assert(s:find("userName\0\1\9\5Mary Jo\0", 1, true), "user name written as SonoBus does")
assert(s:find("serverPort\0\1\5\1" .. string.pack("<i4", 10998), 1, true), "default server port")
assert(s:find("reconnectlast\0value\0\1\9\4" .. string.pack("<d", 1), 1, true), "Reconnect Last on")
assert(s:sub(-8 - 15 - 8, -9):find("JUCEPrivateData", 1, true), "JUCE's private data still at the end")
assert(#s - #raw == (#"Mary Jo" - #"admin 2") + (#"BandSync abcd" - #"BandSync SessionTest 4xt2") + (#"pw" - #"xjaqdnnap3u4"),
  "only the changed strings changed size")
assert(sonobus.join_state(joined, { user = "x", group = "BandSync abcd", password = "pw", now = 1 }), "re-joinable")
assert(s:find("defnetauto\0value\0\1\9\4" .. string.pack("<d", 1), 1, true), "jitter buffer: Auto-Increase")
assert(s:find("defnetbuf\0value\0\1\9\4" .. string.pack("<d", 0.04), 1, true), "jitter buffer: 40 ms start")
assert(sonobus.is_set_up(joined, "BandSync abcd") and not sonobus.is_set_up(joined, "BandSync other"), "set up for its group")
assert(sonobus.state_user(joined) == "Mary Jo", tostring(sonobus.state_user(joined)))
assert(sonobus.is_set_up(joined, "BandSync abcd", "Mary Jo") and not sonobus.is_set_up(joined, "BandSync abcd", "Mary"), "set up as this bandmate")
assert(not sonobus.is_set_up(b64, "BandSync SessionTest 4xt2"), "right group but SonoBus's own buffer defaults: not set up")
assert(not sonobus.join_state("bm90IGEgc3RhdGU=", { user = "x", group = "g", password = "p" }), "garbage refused")
print("ok")

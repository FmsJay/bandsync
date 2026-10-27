-- drummap.table / translate are pure: run with lupa or any Lua 5.4 from the repo root
package.path = "lib/?.lua;" .. package.path
local drummap = require("drummap")
local gm = drummap.GM_MAP
-- a made-up VST layout: kick on 24, snare on 26, rimshot on 27, closed hat on 30, half-open hat on 31
local vst = { name = "vst", notes = { kick = 24, snare = 26, snare_rimshot = 27, hihat_closed = 30, hihat_half_open = 31 } }

local to_gm = drummap.table(vst, gm)
assert(to_gm[24] == 36 and to_gm[26] == 38 and to_gm[30] == 42, "vst -> gm basics")
assert(to_gm[27] == 38, "rimshot falls back to GM snare")
assert(to_gm[31] == 46, "half-open hat falls back to GM open hat")
local back = drummap.table(gm, vst)
assert(back[36] == 24 and back[38] == 26 and back[42] == 30, "gm -> vst")
assert(back[46] == nil, "GM open hat has no slot in vst and its own GM note stays")
assert(drummap.table(gm, gm) == nil, "same map: no table")
-- two VSTs that both know rimshots keep them as rimshots
local vst2 = { name = "vst2", notes = { snare = 40, snare_rimshot = 41, kick = 35 } }
local t = drummap.table(vst, vst2)
assert(t[27] == 41 and t[26] == 40 and t[24] == 35, "articulation survives between maps that have it")

-- buffer translation: note-on/off rewritten, CC and offsets untouched
local function ev(off, msg) return string.pack("i4Bs4", off, 0, msg) end
local buf = ev(0, string.char(0x90, 24, 100)) .. ev(240, string.char(0xB0, 4, 64)) .. ev(240, string.char(0x80, 24, 0)) .. ev(0, "")
local out = drummap.translate(buf, to_gm)
local pos, got = 1, {}
while pos <= #out do
  local off, _, msg, nxt = string.unpack("i4Bs4", out, pos)
  got[#got + 1] = { off, msg }
  pos = nxt
end
assert(#got == 4, "event count kept")
assert(got[1][2]:byte(2) == 36 and got[3][2]:byte(2) == 36, "note on/off remapped")
assert(got[2][2]:byte(2) == 4 and got[2][1] == 240, "CC untouched, offset kept")
assert(drummap.translate(buf, nil) == buf, "no table: unchanged")
print("ok")

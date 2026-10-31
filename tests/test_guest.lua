-- guest.lateness / click_wav and hear.order are pure: run with lupa or any Lua 5.4 from the repo root
package.loaded.band = {}
package.loaded.live = {}
package.path = "lib/?.lua;" .. package.path
local guest = require("guest")
local hear = require("hear")

-- claps 180 ms after each click, at 8 kHz, with a little noise and one early stray
local sr, beat, t0 = 8000, 60 / 90, 10.0
local beats, s = {}, {}
for k = 1, 8 do beats[k] = 10.2 + (k - 1) * beat end
local n = math.floor((beats[8] + beat - t0) * sr)
math.randomseed(1)
for k = 1, n do s[k] = (math.random() - 0.5) * 0.01 end
for b = 1, 8 do
  local at = math.floor((beats[b] + 0.180 + (b % 3 - 1) * 0.004 - t0) * sr) + 1 -- (a person: 4 ms either way)
  for j = 0, 80 do s[at + j] = 0.6 * math.exp(-j / 20) * (j % 2 == 0 and 1 or -1) end
end
s[math.floor((beats[5] + 0.05 - t0) * sr)] = 0.2 -- (a quiet stray noise before a clap: below half the loudest)
local late, found = guest.lateness(s, sr, t0, beats)
assert(found == 8 and math.abs(late - 0.180) < 0.002, string.format("median lateness %.4f from %d claps", late or -1, found))

local quiet = {}
for k = 1, n do quiet[k] = 0 end
assert(guest.lateness(quiet, sr, t0, beats) == nil, "silence: nothing measured")
local few = {}
for k = 1, n do few[k] = 0 end
for j = 0, 40 do few[math.floor((beats[2] + 0.1 - t0) * sr) + j] = 0.5 end
assert(guest.lateness(few, sr, t0, beats) == nil, "one clap isn't enough")

local wav = guest.click_wav()
assert(wav:sub(1, 4) == "RIFF" and wav:sub(9, 16) == "WAVEfmt ", "a WAV file")
local _, _, ch, rate = string.unpack("<I4I2I2I4", wav, 17)
assert(ch == 1 and rate == 48000, "mono 48 kHz")
assert(#wav - 44 == 2 * math.floor((4 + guest.CLICKS + 1) * 60 / guest.BPM * 48000), "count-in + clicks + a beat to spare")

local o = hear.order({ "Laptop", "James", "Drums", "Keys" }, "James")
assert(o.Drums == 2 and o.Keys == 4 and o.Laptop == 6 and o.James == nil, "bandmates in name order, from pair 2; not yourself")
local many = {}
for k = 1, 10 do many[k] = "P" .. string.format("%02d", k) end
local m = hear.order(many, "x")
local c = 0
for _ in pairs(m) do c = c + 1 end
assert(c == hear.PAIRS - 1 and m.P01 == 2 and m.P07 == 14 and m.P08 == nil, "7 pairs of their own at most")
print("ok")

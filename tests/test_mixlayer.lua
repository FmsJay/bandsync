-- mixlayer.strip / signature are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.loaded.sync = package.loaded.sync or {}
package.path = "lib/?.lua;" .. package.path
local mix = require("mixlayer")
local chunk = table.concat({
  "<TRACK", "  NAME Reverb", "  TRACKID {AAA}", "  AUXRECV 3 0 1 0 0 0 0 0 0 -1:U 0 -1 ''",
  "  <FXCHAIN", "    <VST \"VST: ReaVerbate (Cockos)\" reaverbate.dll 0", "      ZmFrZQ==", "    >", "  >",
  "  <VOLENV2", "    PT 0 1 0", "  >",
  "  <ITEM", "    POSITION 0", "    <SOURCE WAVE", "      FILE \"x.wav\"", "    >", "  >",
  ">" }, "\n")
local s = mix.strip(chunk)
assert(not s:find("AUXRECV") and not s:find("TRACKID"), "receives and the track id go (rebuilt / made on each machine)")
assert(not s:find("<ITEM") and not s:find("x.wav"), "items go, nested blocks and all")
assert(s:find("ReaVerbate", 1, true) and s:find("<VOLENV2", 1, true) and s:find("NAME Reverb", 1, true), "plug-ins, automation and name stay")
assert(select(2, s:gsub("<", "")) == select(2, s:gsub("\n%s*>", "")), "blocks still balance")
local a = { tracks = { { name = "Reverb", chunk = s } }, sends = { { from = "Guitar", to = "Reverb", vol = 0.5, pan = 0, mute = 0, mode = 0 } }, master = nil }
local b = { tracks = { { name = "Reverb", chunk = s } }, sends = { { from = "Guitar", to = "Reverb", vol = 0.5000001, pan = 0, mute = 0, mode = 0 } } }
assert(mix.signature(a) == mix.signature(b), "float noise in a send level isn't a change")
b.sends[1].vol = 0.6
assert(mix.signature(a) ~= mix.signature(b), "a real change is")
print("ok")

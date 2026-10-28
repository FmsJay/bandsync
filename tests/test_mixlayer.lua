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
local chain = table.concat({ "<FXCHAIN", "  WNDRECT 0 0 0 0", "  SHOW 0",
  "  BYPASS 0 0 0", "  <VST \"VST3: SonoBus (Sonosaurus)\" SonoBus.vst3 0", "    dXNlck5hbWU9SmFtZXM=", "  >", "  FXID {S}", "  WAK 0 0",
  "  BYPASS 0 0 0", "  <JS loser/limiter \"\"", "    0 0", "  >", "  FXID {L}", "  WAK 0 0", ">" }, "\n")
local kept, live, head = mix.split_live(chain)
assert(not kept:find("SonoBus") and not kept:find("dXNlck5hbWU9"), "SonoBus and its state (user name, group password) never travel")
assert(kept:find("loser/limiter", 1, true) and kept:find("FXID {L}", 1, true) and kept:find("SHOW 0", 1, true), "the rest of the chain does")
assert(#live == 1 and live[1]:find("FXID {S}", 1, true) and #head == 2, "the live plug-in comes back whole, for the machine to keep")
assert(kept:sub(1, 8) == "<FXCHAIN" and kept:sub(-1) == ">", "still one block")
print("ok")

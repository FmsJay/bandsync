-- solo.parse / solo.diff are pure: run with lupa or any Lua 5.4 from the repo root
package.loaded.band = {}
package.loaded.sync = {}
package.path = "lib/?.lua;" .. package.path
local solo = require("solo")

local A = [[
<REAPER_PROJECT 0.1 "7.83"
  <TRACK {T1}
    NAME Drums
    <FXCHAIN
      <VST "VST3: Addictive Drums 2 (XLN Audio)" ad2.vst3 0
      >
    >
    <ITEM
      POSITION 0
      LENGTH 4
      IGUID {I1}
    >
    <ITEM
      POSITION 4
      LENGTH 4
      IGUID {I2}
    >
  >
  <TRACK {T2}
    NAME "Lead Vox"
  >
>
]]
local B = [[
<REAPER_PROJECT 0.1 "7.83"
  <TRACK {T1}
    NAME Drums
    <FXCHAIN
      <VST "VST3: Addictive Drums 2 (XLN Audio)" ad2.vst3 0
      >
      <JS "ReaComp" ""
      >
    >
    <ITEM
      POSITION 0.5
      LENGTH 4
      IGUID {I1}
    >
    <ITEM
      POSITION 8
      LENGTH 2
      IGUID {I3}
    >
  >
  <TRACK {T3}
    NAME Bass
  >
>
]]
local a, b = solo.parse(A), solo.parse(B)
assert(a.tracks["{T1}"].name == "Drums" and a.tracks["{T2}"].name == "Lead Vox", "names")
assert(#a.tracks["{T1}"].fx == 1 and a.tracks["{T1}"].fx[1]:find("Addictive"), "fx parsed")
local d = table.concat(solo.diff(a, b), "\n")
assert(d:find("Drums: 1 item%(s%) added; 1 removed; 1 moved/trimmed; FX now: VST3: Addictive Drums 2 %(XLN Audio%), ReaComp"), d)
assert(d:find("added track Bass"), d)
assert(d:find("removed track Lead Vox"), d)
assert(#solo.diff(a, a) == 0, "no change, no lines")

-- solo.root: an explicit folder wins, then Drive on G:, then Drive for desktop on macOS, then the band folder
local band, dirs, ext = package.loaded.band, {}, ""
band.SECTION = "BandSync"
band.subdirs = function(p) return dirs[p] or {} end
reaper = { GetExtState = function() return ext end, file_exists = function() return false end }
local home = os.getenv("HOME") or ""
assert(solo.root({ root = "R" }) == "R", "fallback")
dirs[home .. "/Library/CloudStorage"] = { "Dropbox", "GoogleDrive-me@example.com" }
assert(solo.root({ root = "R" }) == home .. "/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/BandSync", "mac drive")
dirs["G:/My Drive"] = { "x" }
assert(solo.root({ root = "R" }) == "G:/My Drive/BandSync", "windows drive")
ext = "X:/set"
assert(solo.root({ root = "R" }) == "X:/set", "explicit")
print("ok")

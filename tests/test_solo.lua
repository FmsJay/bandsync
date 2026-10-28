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
-- a solo copy loses the live plug-ins on the master, and nothing else
local rpp = table.concat({
  "<REAPER_PROJECT 0.1",
  "  <MASTERFXLIST",
  "    SHOW 0",
  "    LASTSEL 0",
  "    BYPASS 0 0 0",
  '    <VST "VST: ReaEQ (Cockos)" reaeq.dll 0 ""',
  "      ZXE=",
  "    >",
  "    FXID {1}",
  "    WAK 0 0",
  "    BYPASS 0 1 1",
  '    <VST "VST3: SonoBus (Sonosaurus) (18ch)" SonoBus.vst3 0 ""',
  "      cAmJ",
  "    >",
  "    FXID {2}",
  "    WAK 0 0",
  "    BYPASS 0 0 0",
  '    <VST "VST: ReaNINJAM (Cockos)" reaninjam.dll 0 ""',
  "      bmlu",
  "    >",
  "    FXID {3}",
  "    WAK 0 0",
  "  >",
  "  <TRACK",
  '    NAME "SonoBus notes"',
  "  >",
  ">" }, "\n")
local stripped = solo.strip_live_fx(rpp)
assert(stripped:find("ReaEQ", 1, true) and stripped:find("FXID {1}", 1, true), "other master plug-ins stay")
assert(not stripped:find("SonoBus.vst3", 1, true) and not stripped:find("FXID {2}", 1, true), "SonoBus goes, with its FXID/WAK lines")
assert(not stripped:find("reaninjam.dll", 1, true) and not stripped:find("FXID {3}", 1, true), "ReaNINJAM goes")
assert(stripped:find('NAME "SonoBus notes"', 1, true), "a track merely named after it is untouched")
assert(stripped:find("  >\n  <TRACK", 1, true), "the master list still closes")
print("ok")

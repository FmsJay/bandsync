-- lib/startup.lua's pure half
package.path = "lib/?.lua;" .. package.path
reaper = reaper or { GetResourcePath = function() return "res" end } -- (only its path is read on loading)
local startup = require("startup")
assert(startup.plan({ { path = "a" }, { path = "b" } }) == nil, "no band song: REAPER opens its tabs as ever")
assert(startup.plan({ { path = "a" }, { path = "b", band = true } }) ~= nil, "a band song among them: opened from here")
assert(startup.no_open(17) == 18 and startup.no_open(1) == 2 and startup.no_open(8) == 10, "new project at start, and only the mode's bits change")
assert(startup.summary(nil) == nil and startup.summary("nothing to report") == nil, "nothing said")
local line = startup.summary("There were 1 files in 1 places in the project that are in an off-line state, reload...\r\n\r\nThe following effects were in the project file and are not available.\r\n\tTrack 7: AU: UADx Neve (UA)\r\n\tTrack 14: AU: UADx Neve (UA)\r\n\tTrack 9: VST3i: GGD (GGD)\r\n")
assert(line:find("2 plug-in(s)", 1, true) and line:find("UADx Neve", 1, true) and line:find("GGD", 1, true) and line:find("1 file(s) missing", 1, true), line)
assert(startup.same_path("D:\\A\\B/song.RPP") == startup.same_path("d:/a/b/SONG.rpp"), "one file however it's written")
assert(startup.hand_over("OSX64", "/Applications", "/a b/c.rpp") == '"/Applications/REAPER.app/Contents/MacOS/REAPER" -nonewinst -ignoreerrors "/a b/c.rpp"', "a Mac's")
assert(startup.hand_over("Win64", "J:\\R", "J:\\a b\\c.rpp") == '"J:\\R\\reaper.exe" -nonewinst -ignoreerrors "J:\\a b\\c.rpp"', "Windows'")
print("ok")

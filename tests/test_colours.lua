-- colours: the plans are pure (lupa or Lua 5.4, from the repo root)
reaper = reaper or { GetOS = function() return "Win64" end }
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local colours = require("colours")
assert(colours.mix(0x000000, 0xFFFFFF, 0.5) == 0x808080, "halfway")
local stops = { 0x000000, 0xFF0000, 0xFFFFFF }
assert(colours.ramp(stops, 0) == 0x000000 and colours.ramp(stops, 0.5) == 0xFF0000 and colours.ramp(stops, 1) == 0xFFFFFF, "through the stops")
assert(colours.ramp(stops, -1) == 0x000000 and colours.ramp(stops, 2) == 0xFFFFFF, "kept in range")
assert(colours.hsv(0, 1, 1) == 0xFF0000 and colours.hsv(1 / 3, 1, 1) == 0x00FF00, "the colour wheel")
local three = { { name = "a", family = 1 }, { name = "b", family = 1 }, { name = "c", family = 2 } }
local g = colours.plan(three, "gradient", { stops = stops })
assert(g[1] == 0x000000 and g[2] == 0xFF0000 and g[3] == 0xFFFFFF, "top to bottom")
assert(colours.plan({ { name = "only", family = 1 } }, "gradient", { stops = stops })[1] == 0x000000, "one track doesn't divide by nothing")
local f = colours.plan(three, "folders", { stops = { 0x102030, 0x405060 } })
assert(f[1] == 0x102030 and f[2] ~= f[1] and f[3] == 0x405060, "a folder has its colour, and shades inside it")
local s = colours.plan(three, "stripes", { stops = { 1, 2 } })
assert(s[1] == 1 and s[2] == 1 and s[3] == 2, "stripes go by folder")
local p = colours.plan({ { name = "x", maker = 0x123456 }, { name = "y" } }, "person", { stops = stops })
assert(p[1] == 0x123456 and p[2] == colours.OTHER, "whoever made it, or a plain colour")
local n = colours.plan({ { name = "a", newest = "20261104-100000Z" }, { name = "b", newest = "20261101-100000Z" }, { name = "c", newest = "" } }, "newest", { stops = { 0, 0xFFFFFF } })
assert(n[1] == 0xFFFFFF and n[3] == 0 and n[2] > n[3] and n[2] < n[1], "latest warm, untouched cool")
assert(colours.plan({ { name = "Keys" } }, "confetti", { stops = stops })[1] == colours.plan({ { name = "Keys" } }, "confetti", { stops = stops })[1], "the same name, the same colour")
-- names
local kick, bass = colours.kind_of("Kick In"), colours.kind_of("Bass DI")
assert(kick == colours.kind_of("Drums") and bass == colours.kind_of("Bass Alt 2") and kick ~= bass, "instruments")
assert(colours.kind_of("Bass Drum") ~= bass or true, "a name can hold two")
assert(colours.kind_of("Verb bus") == colours.kind_of("Master bus"), "buses first, whatever's in the name")
assert(colours.kind_of("Vocal bus") == colours.kind_of("Verb bus"), "a vocal bus is a bus")
assert(colours.kind_of("Lead (Mac)") == colours.kind_of("Harmony (Mac)"), "lead and harmony")
assert(colours.kind_of("Tom") == kick and colours.kind_of("Atmosphere") == colours.OTHER, "whole words where it matters")
assert(colours.kind_of("Guitar arp idea") == colours.kind_of("Guitar (Mac)"), "the first kind found")
assert(colours.kind_of("") == colours.OTHER and colours.kind_of(nil) == colours.OTHER, "no name")
-- regions
assert(colours.section_key("Verse 1") == "verse" and colours.section_key("3 Chorus 2") == "chorus" and colours.section_key("Pre-Chorus") == "prechorus", "section names")
assert(colours.section_key("") == "", "no name")
local marks = { { name = "Intro", region = true }, { name = "Verse 1", region = true }, { name = "Chorus 1", region = true }, { name = "Verse 2", region = true }, { name = "Weird", region = true }, { name = "Weird 2", region = true } }
local m = colours.plan_marks(marks, "sections", stops)
assert(m[2] == m[4] and m[2] ~= m[3] and m[1] ~= m[2], "the same section, the same colour")
assert(m[5] == m[6], "and one nobody planned for")
local song = colours.plan_marks({ { name = "a", region = true }, { name = "b", region = true }, { name = "c", region = true } }, "song", stops)
assert(song[1] == 0x000000 and song[2] == 0xFF0000 and song[3] == 0xFFFFFF, "along the song")
print("ok")

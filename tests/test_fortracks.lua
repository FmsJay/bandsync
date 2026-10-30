-- recall.for_tracks is pure: only the named tracks take the old state, everything else stays as it is now
package.loaded.band = { files = function() return {} end }
package.loaded.sync = { base_name = function(n) return n end }
package.path = "lib/?.lua;" .. package.path
local recall = require("recall")
local now = {
  musical = true,
  takes = { k1 = { track = "Keys", pos = 4 }, k2 = { track = "Keys", pos = 8 }, d1 = { track = "Drums", pos = 0, mute = 1 } },
  plays = { Keys = { "k2" }, Drums = { "d1" } },
  tracks = { Keys = { mute = 1 }, Drums = { mute = 1 } },
}
local old = {
  takes = { k1 = { track = "Keys", pos = 2 }, d1 = { track = "Drums", pos = 0, mute = 0 }, k0 = { track = "keys", pos = 0 } },
  plays = { Keys = { "k1" }, Drums = {} },
  tracks = { Keys = { mute = 0 }, Drums = { mute = 0 } },
  timeline = { tempo = {} },
}
local out = recall.for_tracks(now, old, { keys = true })
assert(out.takes.k1.pos == 2, "Keys take back where it was")
assert(out.takes.k2 == nil, "a Keys take the old state doesn't have goes")
assert(out.takes.k0, "a Keys take only the old state has comes back (any case)")
assert(out.takes.d1.mute == 1, "Drums stay as they are now")
assert(out.plays.Keys[1] == "k1" and out.plays.Drums[1] == "d1", "what plays: Keys old, Drums now")
assert(out.tracks.Keys.mute == 0 and out.tracks.Drums.mute == 1, "mute: Keys old, Drums now")
assert(out.timeline == nil and out.musical, "timeline untouched, lengths musical")
print("ok")

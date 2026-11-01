-- trim.plan is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local trim = require("trim")
local function ev(id, oid, rev, time, typ) return { id = id, oid = oid, rev = rev, time = time, type = typ or "obj" } end
local evs = {
  ev("a1", "I-A", 1, "2026-01-01T00:00:00Z"), ev("a2", "I-A", 2, "2026-01-05T00:00:00Z"), ev("a3", "I-A", 3, "2026-01-20T00:00:00Z"),
  ev("b1", "I-B", 1, "2026-01-02T00:00:00Z"), ev("b2", "I-B", 2, "2026-01-03T00:00:00Z"),
  ev("t1", nil, nil, "2026-01-01T00:00:00Z", "timeline"), ev("t2", nil, nil, "2026-01-04T00:00:00Z", "timeline"),
  ev("d1", nil, nil, "2026-01-01T00:00:00Z", "driver"), ev("n1", nil, nil, "2026-01-01T00:00:00Z", "note"),
  ev("s1", nil, nil, "2026-01-01T00:00:00Z", "start"),
  ev("new", "I-A", 4, "2026-03-01T00:00:00Z"), -- (within the last 30 days of the cutoff below: never trimmed)
}
local points = {
  { time = "2026-01-06T00:00:00Z", keep = true, label = "end of session" }, -- major: needs a2, b2, t2
  { time = "2026-01-02T12:00:00Z", label = "before Laptop took over from James" }, -- minor: needs nothing kept
}
local gone = {}
for _, id in ipairs(trim.plan(evs, points, "2026-02-15T00:00:00Z")) do gone[id] = true end
assert(not gone.new and not gone.b2, "each object's newest change stays (I-A's 'new', I-B's b2)")
assert(not gone.a2 and not gone.t2, "what the end-of-session point stands on stays (a2, t2)")
assert(gone.a1 and gone.a3 and gone.b1 and gone.t1, "older changes nothing needs go (a1, a3, b1, t1)")
assert(not gone.d1 and not gone.n1, "handovers and notes stay")
assert(gone.s1, "an old play/stop goes")
assert(trim.major({ keep = true, label = "x" }) and trim.major({ label = "chorus with double guitars" }), "kept and hand-saved points are major")
assert(not trim.major({ label = "before James took over from Laptop" }), "a handover snapshot is minor")
-- nothing older than the cutoff: nothing goes
assert(#trim.plan(evs, points, "2025-12-01T00:00:00Z") == 0, "nothing old enough")
print("ok")

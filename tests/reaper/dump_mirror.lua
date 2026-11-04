-- Diagnostic: write this machine's mirror of the song in the front tab to <room>/debug/<you>-mirror.json, so two
-- machines' "project differs" can be compared object by object. Run it from REAPER (Actions > Load ReaScript, or
-- the dev hook); it finds StudioSync's lib through the installed Live sync action, so it runs from any folder.
-- known: what this machine recorded per object (rev|hash|event|order); live: each object as scanned now.
local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
local text = kb and kb:read("a") or ""
if kb then kb:close() end
local live = text:match('"[^"]*StudioSync %- Live sync%.lua" "([^"]+)"')
if not live then return reaper.MB("StudioSync's Live sync action isn't registered here.", "dump mirror", 0) end
live = live:gsub("\\", "/")
if not live:match("^/") and not live:match("^%a:") then live = reaper.GetResourcePath() .. "/Scripts/" .. live end
package.path = live:match("^(.*)/") .. "/lib/?.lua;" .. package.path
local band, mirror, sync = require("band"), require("mirror"), require("sync")
local proj = reaper.EnumProjects(-1)
local b, cfg = band.binding(proj), band.settings()
if not b or not cfg then return reaper.MB("The front tab isn't a band song.", "dump mirror", 0) end

local out = { user = cfg.user, version = band.VERSION, reaper = reaper.GetAppVersion(), os = reaper.GetOS(),
  root = mirror.root(proj), drift_last = reaper.GetExtState(band.SECTION, "mirror drift last"), known = {}, live = {} }
local i = 0
while true do
  local ok, oid, v = reaper.EnumProjExtState(proj, mirror.SEC, i)
  if not ok then break end
  out.known[oid:upper()] = v
  i = i + 1
end
local local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
for _, o in ipairs((mirror.scan(proj, cfg.user, sync.room_dir(cfg, b.song, b.room) .. "/media", local_mix))) do
  out.live[#out.live + 1] = { oid = o.oid, kind = o.kind, hash = o.hash, state = o.state }
end
local dir = sync.room_dir(cfg, b.song, b.room) .. "/debug"
reaper.RecursiveCreateDirectory(dir, 0)
local path = dir .. "/" .. cfg.user .. "-mirror.json"
band.write_json(path, out)
reaper.ShowConsoleMsg("mirror dumped: " .. path .. "\n")
return path

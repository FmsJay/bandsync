-- @description BandSync: send takes by hand (Live sync normally sends new recordings by itself)
-- Sends the ACTIVE take of each selected item (resending is allowed), or with nothing selected, every
-- item whose active take hasn't gone out yet. "BandSync - Send all takes" sends every unsent pass.
-- Each take goes out as a small .opus preview first, then the full-quality .flac.
local send_all = BAND_SEND_ALL -- set by "BandSync - Send all takes"
BAND_SEND_ALL = nil
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Run 'BandSync - Open session' first.") end

local items = sync.own_takes(proj, { selected = true, all = send_all, unsent = send_all, me = cfg.user })
local unsent = sync.own_takes(proj, { all = send_all, unsent = true, min_len = sync.MIN_LEN, me = cfg.user })
local chosen, left_out = {}, 0
for _, u in ipairs(items) do chosen[u[2]] = true end
for _, u in ipairs(unsent) do if not chosen[u[2]] then left_out = left_out + 1 end end
-- REAPER leaves the last recorded item selected, so a selection can silently leave other new takes behind
if #items > 0 and left_out > 0 then
  local r = reaper.MB(string.format("%d other take(s) haven't been sent yet.\n\nYes = send all %d unsent, No = only the %d selected.",
    left_out, #unsent, #items), "BandSync", 3)
  if r == 2 then return end
  if r == 6 then items = unsent end
elseif #items == 0 then
  items = unsent
end
if #items == 0 then return band.msg("Nothing to send: record something new, or select an item to resend its active take.") end

local s = band.read_json(band.session_path(cfg, b.song)) or {}
if s.version and tostring(s.version) ~= tostring(b.version) then
  if reaper.MB("The host published v" .. s.version .. " since you opened v" .. b.version ..
      ". If the tempo changed, these takes may land off-grid. Send anyway?", "BandSync", 4) ~= 6 then return end
end
band.msg(string.format("Sent %d take(s) to room '%s' of '%s'.", sync.send(proj, cfg, b, items, s.print or "wet"), b.room, b.song))

-- @description BandSync: print a bandmate's MIDI take with your own instrument (everyone hears your print)
-- MIDI takes arrive as their print plus an editable MIDI copy on a muted "<track> (MIDI)" track. Put your
-- instrument (a better drum VST, say) on that track, select the MIDI items, and run this: each is rendered
-- through your track and replaces the print everyone hears. From then on you keep that print current: your
-- FX changes and any note edits are reprinted by your Live sync, not the original player's.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Run 'BandSync - Open session' first.") end
local s = band.read_json(band.session_path(cfg, b.song)) or {}
local can = sync.authority(cfg, b.song, b.room, s)

local units, refused = {}, {}
for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
  local it = reaper.GetSelectedMediaItem(proj, i)
  local tk = reaper.GetActiveTake(it)
  local id = tk and band.take_ext(tk, "band_midi") or ""
  if id ~= "" then
    local track = band.track_ext(reaper.GetMediaItem_Track(it), "band_midi_track")
    if can(cfg.user, track, reaper.GetMediaItemInfo_Value(it, "D_POSITION")) then
      units[#units + 1] = { it, tk, id, track }
    else
      refused[#refused + 1] = track
    end
  end
end
if #refused > 0 then
  return band.msg("Not yours to reprint: " .. table.concat(refused, ", ") .. ".\n\nClaim the track (or take control) first.")
end
if #units == 0 then return band.msg("Select the MIDI copies to print: items on a '<track> (MIDI)' track.") end
local n = sync.print_midi(proj, cfg, b, units, s.print or "wet")
band.msg(string.format("Printed %d MIDI take(s) with your sound. The band hears your version once it syncs.", n))

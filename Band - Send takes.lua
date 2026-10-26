-- @description Band Session: send recorded takes to the session's room
-- Sends the selected items, or if none are selected, every item not sent yet (stem tracks excluded).
-- Each take goes out as a small .opus preview first, then the full-quality .flac.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Run 'Band - Open session' first.") end

local function sendable(it) return band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") == "" end
local items = {}
for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
  local it = reaper.GetSelectedMediaItem(proj, i)
  if sendable(it) then items[#items + 1] = it end
end
if #items == 0 then
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if sendable(it) and band.item_ext(it, "band_sent") == "" and band.item_ext(it, "band_take") == "" then
      items[#items + 1] = it
    end
  end
end
if #items == 0 then return band.msg("Nothing to send: select takes, or record something new.") end

local s = band.read_json(band.session_path(cfg, b.song)) or {}
if s.version and tostring(s.version) ~= tostring(b.version) then
  if reaper.MB("The host published v" .. s.version .. " since you opened v" .. b.version ..
      ". If the tempo changed, these takes may land off-grid. Send anyway?", "Band Session", 4) ~= 6 then return end
end

local out = select(2, reaper.EnumProjects(-1)):match("^(.*)[/\\]") or reaper.GetResourcePath()
out = band.norm(out) .. "/band-out"
local takes = band.takes_dir(cfg, b.song, b.room)
reaper.RecursiveCreateDirectory(out, 0)
reaper.RecursiveCreateDirectory(takes, 0)

local was_selected = {}
for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do was_selected[#was_selected + 1] = reaper.GetSelectedMediaItem(proj, i) end
local stamp, sent = os.date("%Y%m%d-%H%M%S"), 0

for n, it in ipairs(items) do
  local id = string.format("%s-%s-%d", (cfg.user:gsub(" ", "_")), stamp, n)
  local take = reaper.GetActiveTake(it)
  local nch = take and reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take)) or 2
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  band.render({ RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = math.min(nch, 2),
    RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 0 }, -- &32: selected media items (dry: no track FX)
    { RENDER_FILE = out, RENDER_PATTERN = id, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
  local full, prev = out .. "/" .. id .. ".flac", out .. "/" .. id .. ".opus"
  if reaper.file_exists(full) then
    local tr = reaper.GetMediaItem_Track(it)
    local manifest = {
      format = band.FORMAT, id = id, user = cfg.user, room = b.room, track = select(2, reaper.GetTrackName(tr)),
      pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
      session_version = tonumber(b.version), sent = os.date("!%Y-%m-%dT%H:%M:%SZ"), full = id .. ".flac",
    }
    -- preview first, then the manifest, then the full file: the host can place the take as soon as the small file lands
    if reaper.file_exists(prev) then
      band.copy_atomic(prev, takes .. "/" .. id .. ".opus")
      manifest.preview = id .. ".opus"
    end
    band.write_json(takes .. "/" .. id .. ".json", manifest)
    band.copy_atomic(full, takes .. "/" .. id .. ".flac")
    band.set_item_ext(it, "band_sent", id)
    band.set_take_state(proj, id, "full") -- this project already has it; keep its own inbox from re-importing
    sent = sent + 1
  else
    band.log("render failed for take " .. id)
  end
end

reaper.SelectAllMediaItems(proj, false)
for _, it in ipairs(was_selected) do reaper.SetMediaItemSelected(it, true) end
reaper.UpdateArrange()
band.msg(string.format("Sent %d take(s) to room '%s' of '%s'.", sent, b.room, b.song))

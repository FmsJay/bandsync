-- @description BandSync: send your chosen takes to the session's room
-- Sends the ACTIVE take of each item: record passes until you like one, make it the active take,
-- then send. Selected items only, or if none are selected, every item whose active take hasn't
-- been sent yet (stem tracks and received takes excluded). "BandSync - Send all takes" sends every
-- unsent pass instead. Each take goes out as a small .opus preview first, then the full-quality .flac.
local send_all = BAND_SEND_ALL -- set by "BandSync - Send all takes"
BAND_SEND_ALL = nil
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if not b then return band.msg("Run 'BandSync - Open session' first.") end

-- The unit is a take, not an item: recording over an item adds a new pass to it as another take.
local function own(it, tk) -- not a stem, not something a bandmate sent us
  return band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") == "" and band.take_ext(tk, "band_take") == ""
    and band.item_ext(it, "band_take") == ""
end
local function candidates(it, only_unsent)
  local out = {}
  local function add(tk)
    if tk and own(it, tk) and not (only_unsent and band.take_ext(tk, "band_sent") ~= "") then out[#out + 1] = { it, tk } end
  end
  if send_all then
    for k = 0, reaper.CountTakes(it) - 1 do add(reaper.GetTake(it, k)) end
  else
    add(reaper.GetActiveTake(it))
  end
  return out
end
local items, unsent, chosen = {}, {}, {}
for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do -- explicitly selected: resend allowed (except in send-all)
  for _, u in ipairs(candidates(reaper.GetSelectedMediaItem(proj, i), send_all)) do items[#items + 1] = u; chosen[u[2]] = true end
end
for i = 0, reaper.CountMediaItems(proj) - 1 do
  for _, u in ipairs(candidates(reaper.GetMediaItem(proj, i), true)) do unsent[#unsent + 1] = u end
end
-- REAPER leaves the last recorded item selected, so a selection can silently leave other new takes behind
local left_out = 0
for _, u in ipairs(unsent) do if not chosen[u[2]] then left_out = left_out + 1 end end
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

local out = select(2, reaper.EnumProjects(-1)):match("^(.*)[/\\]") or reaper.GetResourcePath()
out = band.norm(out) .. "/band-out"
local takes = band.takes_dir(cfg, b.song, b.room)
reaper.RecursiveCreateDirectory(out, 0)
reaper.RecursiveCreateDirectory(takes, 0)

local was_selected = {}
for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do was_selected[#was_selected + 1] = reaper.GetSelectedMediaItem(proj, i) end
local stamp, sent = os.date("!%Y%m%d-%H%M%SZ"), 0 -- UTC, like the manifest's "sent"

-- IDs are per second, so two Sends in the same second (pick another take, send again) must not collide:
-- skip IDs already in the room, and clear our own render leftovers, or REAPER stops on a modal "files exist" warning.
local seq = 0
local function next_id()
  local id
  repeat
    seq = seq + 1
    id = string.format("%s-%s-%d", (cfg.user:gsub(" ", "_")), stamp, seq)
  until not reaper.file_exists(takes .. "/" .. id .. ".json")
  os.remove(out .. "/" .. id .. ".flac")
  os.remove(out .. "/" .. id .. ".opus")
  return id
end

for _, u in ipairs(items) do
  local it, take = u[1], u[2]
  local id = next_id()
  local nch = reaper.GetMediaSourceNumChannels(reaper.GetMediaItemTake_Source(take))
  local playing = reaper.GetActiveTake(it)
  reaper.SetActiveTake(take) -- the render below renders the item's active take
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  band.render({ RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = 0, RENDER_CHANNELS = math.min(nch, 2),
    RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 0 }, -- &32: selected media items (dry: no track FX)
    { RENDER_FILE = out, RENDER_PATTERN = id, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS })
  reaper.SetActiveTake(playing)
  local full, prev = out .. "/" .. id .. ".flac", out .. "/" .. id .. ".opus"
  if reaper.file_exists(full) then
    local tr = reaper.GetMediaItem_Track(it)
    local manifest = {
      format = band.FORMAT, bandsync = band.VERSION, id = id, user = cfg.user, room = b.room, track = select(2, reaper.GetTrackName(tr)),
      pos = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), len = reaper.GetMediaItemInfo_Value(it, "D_LENGTH"),
      session_version = tonumber(b.version), sent = os.date("!%Y-%m-%dT%H:%M:%SZ"), full = id .. ".flac",
      group = select(2, reaper.GetSetMediaItemInfo_String(it, "GUID", "", false)), -- passes of one item land together
    }
    -- preview first, then the manifest, then the full file: the host can place the take as soon as the small file lands
    if (band.size(prev) or math.huge) < band.size(full) then -- a preview only helps if it is smaller
      band.copy_atomic(prev, takes .. "/" .. id .. ".opus")
      manifest.preview = id .. ".opus"
    end
    band.write_json(takes .. "/" .. id .. ".json", manifest)
    band.copy_atomic(full, takes .. "/" .. id .. ".flac")
    band.set_take_ext(take, "band_sent", id)
    band.set_take_state(proj, id, "full") -- this project already has it; keep its own inbox from re-importing
    sent = sent + 1
  else
    band.log("render failed for take " .. id)
  end
end

reaper.SelectAllMediaItems(proj, false)
for _, it in ipairs(was_selected) do reaper.SetMediaItemSelected(it, true) end
reaper.UpdateArrange()
-- save so the sent tags survive a crash (otherwise the same takes go out again under new IDs)
if sent > 0 and select(2, reaper.EnumProjects(-1)) ~= "" then reaper.Main_SaveProject(proj, false) end
band.msg(string.format("Sent %d take(s) to room '%s' of '%s'.", sent, b.room, b.song))

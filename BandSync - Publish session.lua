-- @description BandSync: publish this project (tempo map, markers, stems) to the shared folder
-- Whoever publishes a song is its host. Re-run after changing tempo, markers or the arrangement.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj) or {}

local projname = reaper.GetProjectName(proj)
local song = b.song or band.clean(projname:gsub("%.[Rr][Pp][Pp]$", ""))
local MODES = { none = true, mix = true, grouped = true, tracks = true }
local ok, csv = reaper.GetUserInputs("BandSync: publish", 2,
  "Song name,Stems (none/mix/grouped/tracks),separator=|,extrawidth=150", song .. "|" .. (b.stem_mode or "grouped"))
if not ok then return end
local name, mode = csv:match("^(.-)|(.*)$")
song, mode = band.clean(name), mode:lower():gsub("%s", "")
if song == "" or not MODES[mode] then return band.msg("Need a song name and one of: none, mix, grouped, tracks.") end

local sdir = band.song_dir(cfg, song)
local old = band.read_json(band.session_path(cfg, song))
if old and old.host ~= cfg.user and b.role ~= "host" then
  if reaper.MB(old.host .. " is hosting '" .. song .. "'. Take over as host?", "BandSync", 4) ~= 6 then return end
end

-- Stems: render to stems/v<version>/<n>.flac plus an .opus preview that syncs first. A fresh folder per
-- publish, because guests (and sync clients) hold the previous version's files open and Windows locks them.
local version = (old and old.version or 0) + 1
local rel = "stems/v" .. version
local stems_dir = sdir .. "/" .. rel
reaper.RecursiveCreateDirectory(stems_dir, 0)
reaper.RecursiveCreateDirectory(band.takes_dir(cfg, song, "main"), 0)
for _, f in ipairs(band.files(stems_dir)) do os.remove(stems_dir .. "/" .. f) end

local stems = {}
local function add_stem(name, base)
  local st = { name = name, file = rel .. "/" .. base .. ".flac" }
  local prev = stems_dir .. "/" .. base .. ".opus"
  if (band.size(prev) or math.huge) < band.size(stems_dir .. "/" .. base .. ".flac") then
    st.preview = rel .. "/" .. base .. ".opus" -- a preview only helps if it is smaller
  else
    os.remove(prev)
  end
  stems[#stems + 1] = st
end
local length = reaper.GetProjectLength(proj)
local render_n = { RENDER_BOUNDSFLAG = 0, RENDER_STARTPOS = 0, RENDER_ENDPOS = length + 2, RENDER_SRATE = 0,
  RENDER_CHANNELS = 2, RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 2 } -- &2: skip likely-silent files
local render_s = { RENDER_FILE = stems_dir, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = band.OPUS }

if mode == "mix" then
  render_n.RENDER_SETTINGS, render_s.RENDER_PATTERN = 0, "mix"
  band.render(render_n, render_s)
  if reaper.file_exists(stems_dir .. "/mix.flac") then add_stem("Mix", "mix") end
elseif mode ~= "none" then
  -- grouped = each top-level track (a folder renders with its children); tracks = every non-folder track
  local picked, depth = {}, 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local d = reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH")
    if (mode == "grouped" and depth == 0) or (mode == "tracks" and d ~= 1) then picked[#picked + 1] = tr end
    depth = depth + d
  end
  local was_selected = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    was_selected[tr] = reaper.GetMediaTrackInfo_Value(tr, "I_SELECTED")
    reaper.SetMediaTrackInfo_Value(tr, "I_SELECTED", 0)
  end
  for _, tr in ipairs(picked) do reaper.SetMediaTrackInfo_Value(tr, "I_SELECTED", 1) end
  -- 3 is what the Render dialog writes for "Stems (selected tracks)"; 2 alone rendered the master mix on 7.83
  render_n.RENDER_SETTINGS, render_s.RENDER_PATTERN = 3, "$tracknumber"
  band.render(render_n, render_s)
  for tr, v in pairs(was_selected) do reaper.SetMediaTrackInfo_Value(tr, "I_SELECTED", v) end
  local by_number = {} -- $tracknumber is zero-padded to the track count, so match on the number
  for _, f in ipairs(band.files(stems_dir, ".flac")) do
    local n = tonumber(f:match("^(%d+)%.flac$"))
    if n then by_number[n] = f:sub(1, -6) end
  end
  for _, tr in ipairs(picked) do
    local base = by_number[math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))]
    if base then add_stem(select(2, reaper.GetTrackName(tr)), base) end -- silent tracks were skipped
  end
end

local tracks = {}
for i = 0, reaper.CountTracks(proj) - 1 do
  local tr = reaper.GetTrack(proj, i)
  if band.track_ext(tr, "band_stem") == "" then tracks[#tracks + 1] = select(2, reaper.GetTrackName(tr)) end
end

band.write_json(band.session_path(cfg, song), {
  format = band.FORMAT, song = song, host = cfg.user, version = version,
  published = os.date("!%Y-%m-%dT%H:%M:%SZ"), srate = band.srate(proj), length = length,
  stem_mode = mode, tempo = band.capture_tempo(proj), markers = band.capture_markers(proj),
  stems = stems, tracks = tracks,
})
band.bind(proj, { role = "host", song = song, room = "main", version = version, stem_mode = mode })
reaper.MarkProjectDirty(proj)

-- Best effort: drop older stem versions. Files still open somewhere fail to delete and are retried next publish.
local all_stems = sdir .. "/stems"
for _, f in ipairs(band.files(all_stems)) do os.remove(all_stems .. "/" .. f) end -- pre-versioning layout
for _, d in ipairs(band.subdirs(all_stems)) do
  if d ~= "v" .. version then
    for _, f in ipairs(band.files(all_stems .. "/" .. d)) do os.remove(all_stems .. "/" .. d .. "/" .. f) end
  end
end

band.msg(string.format("Published '%s' v%d with %d stem(s).\n\nSave this project, then run 'BandSync - Take inbox' to receive takes.",
  song, version, #stems))

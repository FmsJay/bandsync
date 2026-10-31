-- @description BandSync: publish this project to the shared folder (you become the song's host)
-- New songs are mirror sessions (docs/mirror-design.md): everyone in the room holds the same project, and Live sync
-- carries every track and item. Songs published before 0.30 keep the older take sync when published again.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local cfg = band.settings()
if not cfg then return end
local proj, projfile = reaper.EnumProjects(-1)
local b = band.binding(proj) or {}

-- a new song must be prepared first (takes into lanes, FLAC, unique track names...): much harder to tidy once the
-- band has it, so there is no "publish as it is"
if not b.song then
  local todo = {}
  for _, r in ipairs(require("prep").scan(proj, cfg, nil)) do
    if r.key == "format" and r.todo ~= nil then
      -- only a setting, nothing recorded changes: done here, without a question
      reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", band.FLAC, true)
      reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", band.srate(proj), true)
      reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
    elseif r.todo ~= nil and r.on and r.key ~= "autostart" then todo[#todo + 1] = "  - " .. r.title end
  end
  if #todo > 0 then
    if reaper.MB("This project needs preparing for BandSync first:\n\n" .. table.concat(todo, "\n") ..
        "\n\nOK opens the checklist (you choose what changes). Publish again when it's done.", "BandSync", 1) == 1 then
      local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Prepare session.lua", true)
      if id > 0 then reaper.Main_OnCommand(id, 0) end
    end
    return
  end
end

local projname = reaper.GetProjectName(proj)
local suggested = b.song or band.clean(projname:gsub("%.[Rr][Pp][Pp]$", ""))
local old_for = function(song) return band.read_json(band.session_path(cfg, song)) end
local legacy = b.song and old_for(b.song) and old_for(b.song).sync ~= "mirror"

if not legacy then
  local ok, name = reaper.GetUserInputs("BandSync: publish", 1, "Song name,extrawidth=150", suggested)
  if not ok then return end
  local song = band.clean(name)
  if song == "" then return band.msg("Give the song a name.") end
  local old = old_for(song)
  if old and old.host ~= cfg.user and b.song ~= song then
    return band.msg("There's already a band song called '" .. song .. "' (hosted by " .. tostring(old.host) .. ").\n\n" ..
      "Pick another name, or join theirs with 'BandSync - Open session'.")
  end
  if old and b.song ~= song and reaper.MB("You already published a song called '" .. song .. "' from another project.\n\n" ..
      "Publish this project under that name instead (the band then follows this one)?", "BandSync", 4) ~= 6 then
    return
  end
  -- an untitled project takes the song's name and is saved first; either way a copy as it was before BandSync is kept
  local pdir
  if projfile == "" then
    pdir = reaper.GetResourcePath() .. "/BandSync/" .. song
    reaper.RecursiveCreateDirectory(pdir, 0)
    reaper.Main_SaveProjectEx(proj, pdir .. "/" .. song .. ".rpp", 8) -- &8: becomes this project's file
  else
    pdir = projfile:match("^(.*)[/\\]")
  end
  if not b.song then
    reaper.Main_SaveProjectEx(proj, pdir .. "/" .. song .. " (before BandSync).rpp", 0) -- a copy; History offers it back
    reaper.SetProjExtState(proj, band.SECTION, "before_bandsync", pdir .. "/" .. song .. " (before BandSync).rpp")
  end
  reaper.RecursiveCreateDirectory(band.song_dir(cfg, song) .. "/rooms/main/media", 0)
  local version = (old and old.version or 0) + 1
  band.write_json(band.session_path(cfg, song), {
    format = band.FORMAT, bandsync = band.VERSION, song = song, host = cfg.user, version = version, sync = "mirror",
    published = os.date("!%Y-%m-%dT%H:%M:%SZ"), srate = band.srate(proj),
    tempo = band.capture_tempo(proj), markers = band.capture_markers(proj),
  })
  band.bind(proj, { role = "host", song = song, room = "main", version = version })
  reaper.SetProjExtState(proj, band.SECTION, "timeline", band.json_encode({ band.capture_tempo(proj), band.capture_markers(proj) }))
  reaper.Main_SaveProject(proj, false)
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  if not (beat and reaper.time_precise() - beat < 5) then band.start_live(dir) end
  return band.log(string.format("published '%s': Live sync is sending the project to the band (bandmates join with 'BandSync - Open session')", song))
end

-- ---- older take-sync songs, published again -------------------------------------------------------------------
local song = suggested
-- Print: how every take reaches everyone. wet = through its track's FX (the default), dry = take only,
-- both = wet plus a dry twin to switch to. Everyone's takes and lanes are mirrored as they are.
-- Stems default to none: the host shares its real takes, so stems would only duplicate them.
local MODES, PRINTS = { none = true, mix = true, grouped = true, tracks = true }, { wet = true, dry = true, both = true }
local ok, csv = reaper.GetUserInputs("BandSync: publish", 3,
  "Song name,Stems (none/mix/grouped/tracks),Print takes (wet/dry/both),separator=|,extrawidth=150",
  song .. "|" .. (b.stem_mode or "none") .. "|" .. (b.print or "both")) -- both: the dry recording travels with the wet print, so neither is lost
if not ok then return end
local name, mode, print_mode = csv:match("^(.-)|(.-)|(.*)$")
song, mode, print_mode = band.clean(name), mode:lower():gsub("%s", ""), print_mode:lower():gsub("%s", "")
if song == "" or not MODES[mode] or not PRINTS[print_mode] then
  return band.msg("Need a song name, stems as none/mix/grouped/tracks, and print as wet/dry/both.")
end

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
  format = band.FORMAT, bandsync = band.VERSION, song = song, host = cfg.user, version = version, print = print_mode, share = true,
  published = os.date("!%Y-%m-%dT%H:%M:%SZ"), srate = band.srate(proj), length = length,
  stem_mode = mode, tempo = band.capture_tempo(proj), markers = band.capture_markers(proj),
  stems = stems, tracks = tracks,
})
band.bind(proj, { role = "host", song = song, room = "main", version = version, stem_mode = mode, print = print_mode })
reaper.SetProjExtState(proj, band.SECTION, "baseline", "shared") -- the host shares everything already here
reaper.MarkProjectDirty(proj)

-- Best effort: drop older stem versions. Files still open somewhere fail to delete and are retried next publish.
local all_stems = sdir .. "/stems"
for _, f in ipairs(band.files(all_stems)) do os.remove(all_stems .. "/" .. f) end -- pre-versioning layout
for _, d in ipairs(band.subdirs(all_stems)) do
  if d ~= "v" .. version then
    for _, f in ipairs(band.files(all_stems .. "/" .. d)) do os.remove(all_stems .. "/" .. d .. "/" .. f) end
  end
end

band.msg(string.format("Published '%s' v%d with %d stem(s).\n\nSave this project, then run 'BandSync - Live sync': it sends your new recordings and brings in everyone else's.",
  song, version, #stems))

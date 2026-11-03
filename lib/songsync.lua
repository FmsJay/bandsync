-- Per-song sync (docs/bands-design.md): every machine gets every song's listing (a few KB: what the song chooser
-- shows), and a song in full only once it's opened here. Syncthing's ignore file in the shared folder (.stignore,
-- never synced: each machine its own) holds a block BandSync writes; anything else in that file is left as it is.
--   !/_*  !/plugins  !/drummaps      the band-wide folders, always (a new band-wide folder must be added here)
--   !/<Song>                          each song opened on this machine, in full
--   !/*/session.json ...              every other song's listing
--   /*/*                              the rest of every other song
-- First match wins, and the !-lines come first, so Syncthing still looks inside the songs it skips for their
-- listing. Files already here are never deleted by it: a song stops downloading, its files stay until removed.
-- Song names are plain (band.clean: letters, digits, spaces, - and _), so nothing in them needs escaping.
local band = require("band")
local songsync = {}

local BEGIN, END = "// BandSync: what this computer downloads (written by BandSync, up to the line below)", "// BandSync end"
songsync.BAND_WIDE = { "/_*", "/plugins", "/drummaps" }
songsync.LISTING = { "/*/session.json", "/*/folder.json", "/*/live.json", "/*/invites", "/*/rooms/*/room.json",
  "/*/rooms/*/summary", "/*/rooms/*/status" }

-- The block's lines for the songs wanted here. Pure.
function songsync.block(wanted)
  local out = { BEGIN }
  for _, p in ipairs(songsync.BAND_WIDE) do out[#out + 1] = "!" .. p end
  local list = {}
  for s in pairs(wanted) do list[#list + 1] = s end
  table.sort(list)
  for _, s in ipairs(list) do out[#out + 1] = "!/" .. s end
  for _, p in ipairs(songsync.LISTING) do out[#out + 1] = "!" .. p end
  out[#out + 1] = "(?d)/*/*" -- ((?d): a folder the band deletes goes, its ignored files with it)
  out[#out + 1] = END
  return out
end

-- The ignore file's text with BandSync's block replaced (or added at the end; nil wanted = taken out). Pure.
function songsync.merge(text, wanted)
  local keep, inside = {}, false
  text = (text or ""):gsub("^\239\187\191", "") -- (a byte-order mark would hide the first line: an editor's, or PowerShell's)
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do
    if line == BEGIN then inside = true
    elseif inside and line == END then inside = false
    elseif not inside then keep[#keep + 1] = line end
  end
  while #keep > 0 and keep[#keep] == "" do keep[#keep] = nil end
  if wanted then
    if #keep > 0 then keep[#keep + 1] = "" end
    for _, l in ipairs(songsync.block(wanted)) do keep[#keep + 1] = l end
  end
  return #keep > 0 and (table.concat(keep, "\n") .. "\n") or ""
end

-- This machine's choices (persistent ExtState): the songs opened here, and "keep every song".
local KEY, ALL, SEEN = "projects here", "projects keep all", "projects here checked"
function songsync.keep_all() return reaper.GetExtState(band.SECTION, ALL) ~= "" end
-- Whether a song is here in more than its listing: any changes, takes, media or stems. (0.34.7 looked at events
-- only, and an older song with takes but no events, like CompTest, read as not here: James's PC, 2026-11-01.)
local function here_in_full(cfg, s)
  local dir = band.song_dir(cfg, s)
  if #band.subdirs(dir .. "/stems") > 0 then return true end
  for _, room in ipairs(band.subdirs(dir .. "/rooms")) do
    for _, part in ipairs({ "events", "takes", "media", "_trash" }) do
      if #band.files(dir .. "/rooms/" .. room .. "/" .. part) > 0 then return true end
    end
  end
  return false
end
function songsync.wanted(cfg)
  local raw = reaper.GetExtState(band.SECTION, KEY)
  local set = {}
  for s in raw:gmatch("[^|]+") do set[s] = true end
  -- once per machine: every song already here in full stays (a machine that had everything keeps it)
  if reaper.GetExtState(band.SECTION, SEEN) == "" then
    for _, s in ipairs(band.songs(cfg)) do if here_in_full(cfg, s) then set[s] = true end end
    songsync.save(set)
    reaper.SetExtState(band.SECTION, SEEN, "2", true)
  end
  return set
end
function songsync.save(set)
  local list = {}
  for s in pairs(set) do list[#list + 1] = s end
  table.sort(list)
  reaper.SetExtState(band.SECTION, KEY, #list > 0 and table.concat(list, "|") or "|", true) -- ("|": chosen, none yet)
end

-- Write the ignore file for this machine's choices and have Syncthing look again. Returns true when it changed.
function songsync.apply(cfg)
  if not cfg or not cfg.root or cfg.root == "" then return false end
  local path = cfg.root .. "/.stignore"
  local old = band.read(path) or ""
  local new = songsync.merge(old, not songsync.keep_all() and songsync.wanted(cfg) or nil)
  if new == old then return false end
  band.write_atomic(path, new)
  pcall(function() require("services").rescan(band.info(cfg.root).id) end)
  return true
end

-- A song opened here (open, publish, Live sync): from now on it comes in full.
function songsync.want(cfg, song)
  if not song or song == "" then return end
  local set = songsync.wanted(cfg)
  if not set[song] then set[song] = true; songsync.save(set) end
  songsync.apply(cfg)
end

-- Stop downloading a song here (its files stay until removed by hand).
function songsync.drop(cfg, song)
  local set = songsync.wanted(cfg)
  set[song] = nil
  songsync.save(set)
  songsync.apply(cfg)
end

return songsync

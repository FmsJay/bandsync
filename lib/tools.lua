-- The panel's tools: dry mode with a bandmate's plug-ins, take back my last take, print a MIDI part as an audio
-- take, a Solo edit version's mix into the live session, keep/dismiss live ideas, and starting Live sync with REAPER.
local band = require("band")
local sync = require("sync")
local tools = {}

-- ---- dry mode: play a bandmate's dry recording through their plug-ins ---------------------------------------
-- Each print carries its track's FX chain (sync: m.fxchain). Dry mode loads it onto our band track and plays the
-- dry twins instead of the prints. Plug-ins we have load; the rest stay in the chain as REAPER's "missing" entries,
-- settings kept. A MIDI part's dry is its notes: the chain goes on its "(MIDI)" copy track, which then plays
-- instead of the print. Off: the chain comes off and the prints play again.

local function newest_manifest(cfg, b, tr)
  local best
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    for k = 0, reaper.CountTakes(it) - 1 do
      local id = band.take_id(reaper.GetTake(it, k))
      local m = id and band.read_json(band.takes_dir(cfg, b.song, b.room) .. "/" .. id .. ".json")
      if m and m.fxchain and (not best or (m.sent or "") > (best.sent or "")) then best = m end
    end
  end
  return best
end

local function set_chain(tr, chain)
  local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
  if ok then reaper.SetTrackStateChunk(tr, sync.chunk_set_block(chunk, "FXCHAIN", chain), false) end
end

-- tr: the band track holding someone's prints. Returns a summary, or nil + why.
function tools.dry_mode(proj, cfg, b, tr, on)
  local name = select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", "")
  local midi = band.find_track(proj, name .. " (MIDI)", true)
  if on then
    local m = newest_manifest(cfg, b, tr)
    if not m then return nil, "no plug-in chain came with " .. name .. "'s prints yet (it comes with prints from BandSync 0.8)" end
    local chain = band.read(sync.room_dir(cfg, b.song, b.room) .. "/" .. m.fxchain)
    if not chain then return nil, "the plug-in chain hasn't arrived yet" end
    if m.midi and midi then -- the notes are the dry part: they play through the chain on the copy track
      set_chain(midi, chain)
      reaper.SetMediaTrackInfo_Value(midi, "B_MUTE", 0)
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
      band.set_track_ext(tr, "band_drymode", "midi")
    else
      set_chain(tr, chain)
      band.set_track_ext(tr, "band_drymode", "1")
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        local dry = sync.dry_mode_take(tr, it, reaper.GetActiveTake(it))
        if dry then reaper.SetActiveTake(dry) end
      end
    end
    local missing = {}
    local target = (m.midi and midi) or tr
    for f = 0, reaper.TrackFX_GetCount(target) - 1 do
      local _, fx = reaper.TrackFX_GetFXName(target, f)
      -- a plug-in this machine lacks keeps its slot and settings but loads nothing: no fx_ident (seen 7.83)
      if select(2, reaper.TrackFX_GetNamedConfigParm(target, f, "fx_ident")) == "" then missing[#missing + 1] = fx ~= "" and fx or ("#" .. (f + 1)) end
    end
    reaper.TrackList_AdjustWindows(false)
    return string.format("%s: dry with %s's plug-ins%s", name, tostring(m.printed_by or m.user),
      #missing > 0 and (" (missing here: " .. table.concat(missing, ", ") .. ")") or "")
  end
  local mode = band.track_ext(tr, "band_drymode")
  band.set_track_ext(tr, "band_drymode", "")
  if mode == "midi" and midi then
    set_chain(midi, nil)
    reaper.SetMediaTrackInfo_Value(midi, "B_MUTE", 1)
    reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 0)
  else
    set_chain(tr, nil)
    for j = 0, reaper.CountTrackMediaItems(tr) - 1 do -- the print of whichever take plays
      local it = reaper.GetTrackMediaItem(tr, j)
      local a = reaper.GetActiveTake(it)
      local id = a and band.take_ext(a, "band_dry")
      if id and id ~= "" then
        for k = 0, reaper.CountTakes(it) - 1 do
          local t2 = reaper.GetTake(it, k)
          if (band.take_id(t2) or ""):lower() == id:lower() then reaper.SetActiveTake(t2) end
        end
      end
    end
  end
  reaper.TrackList_AdjustWindows(false)
  return name .. ": back to the print"
end

-- ---- which of a chain's plug-ins this machine has (before turning dry mode on) ---------------------------
-- From the chain text: { { name, have } }. A plug-in counts as here when REAPER's own plug-in lists (the
-- reaper-*plugins*.ini / reaper-clap-*.ini caches next to reaper.ini) or its Effects folder (JSFX) name it.
local known
local function plugin_lists()
  if known then return known end
  local res, parts = reaper.GetResourcePath(), {}
  for i = 0, math.huge do
    local f = reaper.EnumerateFiles(res, i)
    if not f then break end
    local l = f:lower()
    if l:match("^reaper%-.*plugins.*%.ini$") or l:match("^reaper%-clap.*%.ini$") then parts[#parts + 1] = (band.read(res .. "/" .. f) or ""):lower() end
  end
  known = "\n" .. table.concat(parts, "\n")
  return known
end
function tools.chain_plugins(chain)
  local out = {}
  for line in (chain or ""):gmatch("[^\r\n]+") do
    local tag, rest = line:match("^%s*<(%u+%d*)%s+(.*)$")
    if tag == "VST" or tag == "CLAP" or tag == "AU" or tag == "LV2" then
      local name, after = rest:match('^"([^"]*)"%s*(.*)$')
      local file = after and (after:match('^"([^"]+)"') or after:match("^(%S+)"))
      local have = true
      if file then
        local f = file:lower():gsub("^.*[/\\]", "")
        local lists = plugin_lists()
        have = lists:find("\n" .. f, 1, true) ~= nil or lists:find("\n" .. f:gsub(" ", "_"), 1, true) ~= nil or lists:find(f, 1, true) ~= nil
      end
      out[#out + 1] = { name = name or file or tag, have = have }
    elseif tag == "JS" then
      local path = rest:match('^"([^"]+)"') or rest:match("^(%S+)")
      out[#out + 1] = { name = "JS: " .. tostring(path), have = path and reaper.file_exists(reaper.GetResourcePath() .. "/Effects/" .. path) or false }
    end
  end
  return out
end
-- The chain of the newest print on a band track, as text (nil if none came with it).
function tools.chain_of(cfg, b, tr)
  local m = newest_manifest(cfg, b, tr)
  return m and band.read(sync.room_dir(cfg, b.song, b.room) .. "/" .. m.fxchain), m
end

-- ---- take back my last take: delete the newest take I sent (everyone loses it; it's in _trash) ----------------
-- With peek, only says which take that is (id, item). Parts made by an insert/remove split don't count: they
-- weren't played.
function tools.take_back(proj, cfg, peek)
  local newest, nit
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local id = band.take_ext(reaper.GetTake(it, k), "band_sent")
      if id ~= "" and band.item_ext(it, "band_split") == "" and sync.author(id) == sync.author_of(cfg.user) and (not newest or id > newest) then newest, nit = id, it end
    end
  end
  if not nit then return nil, "You haven't sent a take in this song." end
  if peek then return newest, nit end
  reaper.SetMediaItemInfo_Value(nit, "C_LOCK", 0)
  reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(nit), nit)
  reaper.Undo_OnStateChange2(proj, "BandSync: take back " .. newest)
  return newest
end

-- ---- print a MIDI part as an audio take (what "record my synth as audio" means) ------------------------------
-- Renders each selected MIDI item through its track (instrument + FX) onto "<track> audio", where Live sync sends
-- it as an ordinary audio take, with 2 s of release/reverb past the notes. The MIDI item stays, muted (as your own
-- take, the band mutes it too), so the part can still be edited and printed again.
function tools.print_audio(proj, cfg, b)
  local units = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    if tk and reaper.TakeIsMIDI(tk) then units[#units + 1] = { it, tk } end
  end
  if #units == 0 then return nil, "select the MIDI items to print first" end
  local out = reaper.GetProjectPathEx(proj):gsub("\\", "/") .. "/bandsync_prints"
  reaper.RecursiveCreateDirectory(out, 0)
  local n = 0
  for _, u in ipairs(units) do
    local it, tk = u[1], u[2]
    local tr = reaper.GetMediaItem_Track(it)
    local name = select(2, reaper.GetTrackName(tr))
    local path = sync.print_item(proj, it, tk, out, (name:gsub("[^%w%-_ ]", "_")) .. "-" .. os.date("!%Y%m%d-%H%M%S") .. "-" .. n, sync.TAIL)
    if path then
      local dest = band.find_track(proj, name .. " audio", true) or band.new_track(proj, name .. " audio")
      band.add_item(dest, path, reaper.GetMediaItemInfo_Value(it, "D_POSITION"), nil) -- the whole file: the release rings on
      reaper.SetMediaItemInfo_Value(it, "B_MUTE", 1)
      n = n + 1
    end
  end
  reaper.UpdateArrange()
  return n
end

-- ---- a Solo edit version's mix, into the live session ---------------------------------------------------------
-- Levels, pans and mutes of the newest solo version, onto the live session's tracks of the same names (and their
-- band mirrors). With the shared mix, Live sync then sends whatever this person may change.
function tools.solo_mix(cfg, song)
  local solo = require("solo")
  local list = solo.history(cfg, song)
  if not list[1] then return nil, "no Solo edit version of " .. song end
  local text = band.read(solo.dir(cfg, song) .. "/history/" .. list[1].file .. ".rpp")
  if not text then return nil, "can't read the newest Solo edit version" end
  local mix, parsed = {}, solo.parse(text)
  for _, g in ipairs(parsed.order) do
    local t = parsed.tracks[g]
    if t.name ~= "" then mix[t.name:lower()] = t end
  end
  return mix, list[1]
end
function tools.apply_mix(proj, mix)
  local n = 0
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local name = select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", ""):lower()
    local m = mix[name]
    if m and band.track_ext(tr, "band_stem") == "" then
      if m.vol then reaper.SetMediaTrackInfo_Value(tr, "D_VOL", m.vol) end
      if m.pan then reaper.SetMediaTrackInfo_Value(tr, "D_PAN", m.pan) end
      if m.mute ~= nil then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", m.mute and 1 or 0) end
      n = n + 1
    end
  end
  return n
end

-- ---- live ideas (placeholders from Play along) ---------------------------------------------------------------
function tools.ideas(proj)
  local by = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local who = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(it))):gsub(" %(live%)$", "")
      by[who] = (by[who] or 0) + 1
    end
  end
  return by
end
-- Keep: the selected placeholders become ordinary items of ours (no take will ever replace them).
function tools.keep_ideas(proj)
  local n = 0
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do
    local it = reaper.GetSelectedMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      for _, k in ipairs({ "band_live", "band_live_since", "band_live_heard" }) do band.set_item_ext(it, k, "") end
      n = n + 1
    end
  end
  return n
end
-- Dismiss: every placeholder (of `who`, or everyone's) goes.
function tools.dismiss_ideas(proj, who)
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      if not who or select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "") == who then
        reaper.DeleteTrackMediaItem(tr, it)
        n = n + 1
      end
    end
  end
  return n
end

-- ---- Live sync with REAPER: a block in Scripts/__startup.lua runs BandSync - Autostart.lua -------------------
local MARK_A, MARK_Z = "-- BandSync autostart", "-- /BandSync autostart"
local function startup_path() return reaper.GetResourcePath() .. "/Scripts/__startup.lua" end
function tools.autostart_on()
  return (band.read(startup_path()) or ""):find(MARK_A, 1, true) ~= nil
end
function tools.set_autostart(on, dir)
  local text = band.read(startup_path()) or ""
  local a = text:find(MARK_A, 1, true)
  if a then
    local z = text:find(MARK_Z, a, true)
    text = text:sub(1, a - 1) .. (z and text:sub(z + #MARK_Z + 1) or "")
  end
  if on then
    text = text .. (text ~= "" and not text:match("\n$") and "\n" or "") ..
      MARK_A .. "\ndofile([[" .. dir .. "/BandSync - Autostart.lua]])\n" .. MARK_Z .. "\n"
  end
  reaper.RecursiveCreateDirectory(reaper.GetResourcePath() .. "/Scripts", 0)
  return band.write_atomic(startup_path(), text)
end

return tools

-- The band's mix layer: what Live sync's takes and track events don't carry, and Solo edit used to. Effect buses
-- and other tracks without recordings (with their plug-ins and automation), the sends from parts into them, and the
-- master track's plug-ins. Whoever drives shapes it; it reaches everyone by track NAME (a part's send leaves from
-- whichever track holds that part on each machine: our own, or its "(band)" copy).
-- Parts' own plug-ins don't travel here: their sound comes as wet prints, and Dry + their plug-ins loads the chain.
local band = require("band")
local sync = require("sync")
local mix = {}

local function name_of(tr) return (select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)):gsub(" %(band%)$", "")) end
-- The part a track plays: "Keys", "Keys (band)" and "Keys (MIDI)" (its notes, heard in the Dry modes) are all Keys.
local function part_of_name(n) return (n:gsub(" %(band%)$", ""):gsub(" %(MIDI%)$", "")) end
local function part_of(tr) return part_of_name(name_of(tr)) end

-- A FXCHAIN block without SonoBus / ReaNINJAM, and those plug-ins on their own (each "BYPASS" line at the chain's
-- top level starts a plug-in). They belong to live sessions and carry this machine's identity (SonoBus: user name,
-- group and its password), so they never travel with the mix and a machine's own stay where they are. Pure.
-- Returns the block, the live plug-ins' text (list), and the chain's own header lines (list).
function mix.split_live(block)
  if not block then return nil, {}, {} end
  local lines = {}
  for l in (block .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  if lines[#lines] == "" then lines[#lines] = nil end
  local head, groups, depth, cur = {}, {}, 0, nil
  for i = 2, #lines - 1 do -- inside "<FXCHAIN" ... ">"
    local l = lines[i]
    local t = l:match("^%s*(%S*)")
    if depth == 0 and t == "BYPASS" then cur = { l }; groups[#groups + 1] = cur
    elseif cur then cur[#cur + 1] = l
    else head[#head + 1] = l end
    if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
  end
  local out, live = { lines[1] }, {}
  for _, l in ipairs(head) do out[#out + 1] = l end
  for _, g in ipairs(groups) do
    local is_live = false
    for _, l in ipairs(g) do if l:match("^%s*<") and (l:find("SonoBus", 1, true) or l:find("ReaNINJAM", 1, true)) then is_live = true end end
    if is_live then live[#live + 1] = table.concat(g, "\n") else out[#out + 1] = table.concat(g, "\n") end
  end
  out[#out + 1] = lines[#lines]
  return table.concat(out, "\n"), live, head
end

-- Tracks BandSync made (copies of parts, stems, MIDI copies, live placeholders) aren't part of the mix layer.
local function made_by_bandsync(tr)
  if band.track_ext(tr, "band_stem") ~= "" or band.track_ext(tr, "band_midi_track") ~= "" or band.track_ext(tr, "band_mirror") ~= ""
      or band.track_ext(tr, "band_live_track") ~= "" then return true end
  local n = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
  return n:find(" %(band%)$") ~= nil or n:find(" %(MIDI%)$") ~= nil
end

-- A mix track: one without recordings that BandSync didn't make (a bus, an effects return, a track set up ahead).
function mix.is_mix_track(tr)
  return not made_by_bandsync(tr) and reaper.CountTrackMediaItems(tr) == 0
end

-- A track chunk as the band shares it: no receives (they're rebuilt by name on each machine), no items. Pure.
function mix.strip(chunk)
  local out, depth, skip = {}, 0, nil
  for line in (chunk .. "\n"):gmatch("([^\n]*)\n") do
    local t = line:match("^%s*(%S*)")
    if skip then
      if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1; if depth < skip then skip = nil end end
    elseif t == "<ITEM" then
      skip = depth + 1
      depth = depth + 1
    else
      if t:sub(1, 1) == "<" then depth = depth + 1 elseif t == ">" then depth = depth - 1 end
      if t ~= "AUXRECV" and t ~= "TRACKID" then out[#out + 1] = line end
    end
  end
  while out[#out] == "" do out[#out] = nil end
  return table.concat(out, "\n")
end

-- What the mix layer is here now: { tracks = { { name, chunk } }, sends = { {from, to, vol, pan, mute, mode} },
-- master = <FXCHAIN block or nil> }, plus a signature to tell changes by.
function mix.capture(proj)
  local st = { tracks = {}, sends = {} }
  local is_mix = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if mix.is_mix_track(tr) then
      is_mix[tr] = true
      local _, chunk = reaper.GetTrackStateChunk(tr, "", false)
      st.tracks[#st.tracks + 1] = { name = name_of(tr), chunk = mix.strip(chunk) }
    end
  end
  local seen = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_stem") == "" then
      for s = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
        local dest = reaper.GetTrackSendInfo_Value(tr, 0, s, "P_DESTTRACK")
        local key = dest and is_mix[dest] and (part_of(tr) .. "\0" .. name_of(dest))
        if key and not seen[key] then -- (a part on our own track and on its copy: one send in the list)
          seen[key] = true
          st.sends[#st.sends + 1] = { from = part_of(tr), to = name_of(dest), vol = reaper.GetTrackSendInfo_Value(tr, 0, s, "D_VOL"),
            pan = reaper.GetTrackSendInfo_Value(tr, 0, s, "D_PAN"), mute = reaper.GetTrackSendInfo_Value(tr, 0, s, "B_MUTE"),
            mode = reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SENDMODE") }
        end
      end
    end
  end
  table.sort(st.sends, function(a, z) return (a.from .. "\0" .. a.to) < (z.from .. "\0" .. z.to) end)
  local _, master = reaper.GetTrackStateChunk(reaper.GetMasterTrack(proj), "", false)
  st.master = (mix.split_live(sync.chunk_block(master, "FXCHAIN"))) -- never SonoBus / ReaNINJAM (this machine's identity)
  return st, mix.signature(st)
end

-- A short fingerprint of a mix state (same state, same text, on every machine). Pure.
function mix.signature(st)
  local parts = {}
  for _, t in ipairs(st.tracks or {}) do parts[#parts + 1] = t.name .. "\1" .. t.chunk end
  for _, s in ipairs(st.sends or {}) do
    parts[#parts + 1] = string.format("%s>%s:%.4f:%.4f:%d:%d", s.from, s.to, s.vol or 1, s.pan or 0, s.mute or 0, s.mode or 0)
  end
  parts[#parts + 1] = st.master or ""
  local text, h = table.concat(parts, "\2"), 5381
  for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
  return string.format("%08x-%d", h, #text)
end

-- Make this project's mix layer what `st` says. A track of ours with the same name as one of theirs is left alone
-- (never overwritten): theirs isn't added here. Returns how many tracks were set, and the names left out.
function mix.apply(proj, st)
  local mine, by = {}, {} -- name -> our mix-layer track (made by an earlier apply), our own tracks by name
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if band.track_ext(tr, "band_mix") ~= "" then mine[band.track_ext(tr, "band_mix"):lower()] = tr end
    by[name_of(tr):lower()] = by[name_of(tr):lower()] or tr
  end
  local n, wanted, clash = 0, {}, {}
  for _, t in ipairs(st.tracks or {}) do
    local key = t.name:lower()
    wanted[key] = true
    local tr = mine[key]
    if not tr and by[key] then clash[#clash + 1] = t.name end
    if not tr and not by[key] then
      reaper.InsertTrackAtIndex(reaper.CountTracks(proj), false)
      tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
    end
    if tr then
      reaper.SetTrackStateChunk(tr, t.chunk, false)
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", t.name, true)
      band.set_track_ext(tr, "band_mix", t.name)
      mine[key] = tr
      n = n + 1
    end
  end
  for key, tr in pairs(mine) do -- the driver removed it
    if not wanted[key] and reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.DeleteTrack(tr); mine[key] = nil end
  end
  -- sends into the mix tracks: rebuilt from the list, leaving from our own track for a part we play, else its copy
  for _, tr in pairs(mine) do
    if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then
      for r = reaper.GetTrackNumSends(tr, -1) - 1, 0, -1 do reaper.RemoveTrackSend(tr, -1, r) end
    end
  end
  for _, s in ipairs(st.sends or {}) do
    local dest = mine[s.to:lower()]
    for i = 0, reaper.CountTracks(proj) - 1 do -- from every track playing that part here (ours, and/or its copy)
      local src = reaper.GetTrack(proj, i)
      if dest and src ~= dest and part_of(src):lower() == part_of_name(s.from):lower() and band.track_ext(src, "band_stem") == ""
          and (reaper.CountTrackMediaItems(src) > 0 or mine[s.from:lower()] == src) then
        local k = reaper.CreateTrackSend(src, dest)
        if k >= 0 then
          reaper.SetTrackSendInfo_Value(src, 0, k, "D_VOL", s.vol or 1)
          reaper.SetTrackSendInfo_Value(src, 0, k, "D_PAN", s.pan or 0)
          reaper.SetTrackSendInfo_Value(src, 0, k, "B_MUTE", s.mute or 0)
          reaper.SetTrackSendInfo_Value(src, 0, k, "I_SENDMODE", s.mode or 0)
        end
      end
    end
  end
  local m = reaper.GetMasterTrack(proj)
  local _, chunk = reaper.GetTrackStateChunk(m, "", false)
  -- the band's master plug-ins, with this machine's own SonoBus / ReaNINJAM kept (and any that came in a pre-0.14.3
  -- mix taken out: those were the driver's)
  local _, ours, our_head = mix.split_live(sync.chunk_block(chunk, "FXCHAIN"))
  local theirs = st.master and (mix.split_live(st.master))
  local block = theirs
  if #ours > 0 then
    local body = theirs and theirs:match("^[^\n]*\n(.*)\n[^\n]*$") or table.concat(our_head, "\n")
    block = "<FXCHAIN\n" .. (body ~= "" and body .. "\n" or "") .. table.concat(ours, "\n") .. "\n>"
  end
  reaper.SetTrackStateChunk(m, sync.chunk_set_block(chunk, "FXCHAIN", block), false)
  reaper.TrackList_AdjustWindows(false)
  return n, clash
end

return mix

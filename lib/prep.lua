-- "Prepare this project for BandSync": tidy an already busy project before it's published or joined. scan() lists
-- what it would change (each a checkbox in the window); apply() does the chosen ones, after saving a backup copy,
-- as one undo point (file conversions aside: their originals are kept in a backup folder).
local band = require("band")
local prep = {}

local GENERIC = { "^track %d*$", "^audio %d*$", "^midi %d*$", "^untitled", "^new track" }
local CONVERT = { WAVE = true, AIFF = true } -- uncompressed: FLAC holds them exactly at half the size or less

-- Items and tracks BandSync made (the band's prints, stems, live placeholders, MIDI copies) aren't the project's own.
local function bands(it)
  local tk = reaper.GetActiveTake(it)
  return band.track_ext(reaper.GetMediaItem_Track(it), "band_stem") ~= "" or band.item_ext(it, "band_take") ~= ""
    or band.item_ext(it, "band_live") ~= "" or (tk and (band.take_ext(tk, "band_take") ~= "" or band.take_ext(tk, "band_midi") ~= ""))
end
local function track_name(tr) return select(2, reaper.GetTrackName(tr)) end
local function src_file(tk)
  local src = tk and not reaper.TakeIsMIDI(tk) and reaper.GetMediaItemTake_Source(tk)
  if src and reaper.GetMediaSourceType(src, "") == "SECTION" then src = reaper.GetMediaSourceParent(src) end
  return src and reaper.GetMediaSourceFileName(src, ""):gsub("\\", "/") or "", src
end

-- A WAV's sample format: 1 PCM, 3 float (also through WAVE_FORMAT_EXTENSIBLE), and its bits; nil if not a WAV.
function prep.wav_format(head)
  if not head or #head < 44 or (head:sub(1, 4) ~= "RIFF" and head:sub(1, 4) ~= "RF64") or head:sub(9, 12) ~= "WAVE" then return nil end
  local i = 13
  while i + 8 <= #head do
    local id, size = head:sub(i, i + 3), string.unpack("<I4", head, i + 4)
    if id == "fmt " then
      local tag, bits = string.unpack("<I2", head, i + 8), string.unpack("<I2", head, i + 22)
      if tag == 0xFFFE and #head >= i + 33 then tag = string.unpack("<I2", head, i + 32) end
      return tag, bits
    end
    i = i + 8 + size + (size % 2)
  end
end
-- Whether a file converts to FLAC exactly: integer samples up to 24 bits (32-bit and float would clip or lose bits).
function prep.convertible(path, kind)
  if not CONVERT[kind] then return false, "already compressed or not audio" end
  local f = io.open(path, "rb")
  if not f then return false, "missing" end
  local head = f:read(4096)
  f:close()
  if kind == "AIFF" then return head and head:sub(9, 12) == "AIFF", "an AIFF-C (float or compressed)" end
  local tag, bits = prep.wav_format(head)
  if tag ~= 1 or not bits or bits > 24 then return false, (tag == 3 and "32-bit float" or ("a " .. tostring(bits) .. "-bit WAV")) .. ": FLAC would clip or lose detail" end
  return true
end

-- What there is to do: { { key, title, detail, n, on, todo } }, in the order the window shows them.
function prep.scan(proj, cfg, b)
  local out = {}
  local function add(key, title, detail, n, todo, on) out[#out + 1] = { key = key, title = title, detail = detail, n = n, todo = todo, on = on ~= false } end
  local saved = select(2, reaper.EnumProjects(-1)) ~= ""
  local home = saved and (select(2, reaper.EnumProjects(-1)):gsub("\\", "/"):match("^(.*)/")) or nil -- the project's folder
  local root = cfg and band.norm(cfg.root) or nil

  -- takes -> lanes (and lanes for every track that records)
  -- (a track already in lane mode can still hold multi-take items: REAPER can make every new track a lane track)
  local lanes, multi = { set = {}, explode = {} }, 0
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local own, folder = band.track_ext(tr, "band_stem") == "" and not track_name(tr):find(" %(band%)$"), reaper.GetMediaTrackInfo_Value(tr, "I_FOLDERDEPTH") == 1
    if own and not folder then
      local n = 0
      for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
        local it = reaper.GetTrackMediaItem(tr, j)
        if not bands(it) and reaper.CountTakes(it) > 1 then n = n + 1 end
      end
      if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then lanes.set[#lanes.set + 1] = tr
      elseif n > 0 then lanes.explode[#lanes.explode + 1] = tr end
      multi = multi + n
    end
  end
  lanes.n = #lanes.set + #lanes.explode
  if lanes.n > 0 then
    add("lanes", #lanes.set > 0 and string.format("Fixed lanes on %d track(s)%s", #lanes.set, multi > 0 and string.format(", %d multi-take item(s) exploded into lanes", multi) or "")
        or string.format("Explode %d multi-take item(s) into lanes", multi),
      "Takes become lanes (the take that plays keeps playing), and new recordings land in lanes: the band sees every pass the same way.", lanes.n, lanes)
  end

  -- recording format and sample rate
  local fmt = select(2, reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", "", false))
  local s = b and band.read_json(band.session_path(cfg, b.song))
  local want_sr = s and s.srate or band.srate(proj)
  local sr_set = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false) == 1 and reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false) == want_sr
  if fmt ~= band.FLAC or not sr_set then
    add("format", string.format("Record 24-bit FLAC at %d Hz", want_sr),
      "Recordings come out half the size with nothing lost, and the project keeps one sample rate whatever interface is plugged in.", 1, want_sr)
  end

  -- track names: BandSync matches parts to tracks by name
  local seen, dup, blank, generic = {}, {}, {}, {}
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
    if band.track_ext(tr, "band_stem") == "" and not name:find(" %(band%)$") then
      local l = name:lower():match("^%s*(.-)%s*$")
      if l == "" then blank[#blank + 1] = tr
      else
        for _, g in ipairs(GENERIC) do if l:match(g) then generic[#generic + 1] = name; break end end
        if seen[l] then dup[#dup + 1] = tr else seen[l] = true end
      end
    end
  end
  if #blank + #dup > 0 then
    add("names", string.format("Name %d unnamed and %d duplicate-named track(s)", #blank, #dup),
      "BandSync puts each part on the track with the same name, so two tracks called the same thing get each other's takes. " ..
      "Unnamed tracks take their first clip's name; duplicates get a number (Guitar 2).", #blank + #dup, { blank = blank, dup = dup })
  end
  if #generic > 0 then
    add("generic", string.format("%d track(s) with a generic name: %s", #generic, table.concat(generic, ", ")),
      "Not changed: rename them to what's on them (Bass, Vox...) so the band's takes land where they belong.", #generic, nil, false)
  end

  -- audio files: convert to FLAC, copy the rest in from outside the project, report offline ones
  local files, outside, offline, kept = {}, {}, {}, {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    if not bands(it) then
      for k = 0, reaper.CountTakes(it) - 1 do
        local tk = reaper.GetTake(it, k)
        local file, src = src_file(tk)
        if file ~= "" and not (root and file:sub(1, #root) == root) then
          if not reaper.file_exists(file) then offline[file] = true
          elseif not files[file] then
            local ok, why = prep.convertible(file, reaper.GetMediaSourceType(src, ""))
            files[file] = ok and "convert" or (home and file:sub(1, #home + 1) ~= home .. "/" and "copy") or "keep"
            if not ok and why ~= "already compressed or not audio" then kept[#kept + 1] = file:match("[^/]+$") .. " (" .. why .. ")" end
            if files[file] == "copy" then outside[#outside + 1] = file end
          end
        end
      end
    end
  end
  local conv = {}
  for f, what in pairs(files) do if what == "convert" then conv[#conv + 1] = f end end
  table.sort(conv)
  if #conv > 0 then
    add("flac", string.format("Convert %d WAV/AIFF file(s) to FLAC", #conv),
      "Exact copies at half the size or less (checked sample by sample); the originals move to a 'BandSync originals' folder next to the project" ..
      (#kept > 0 and ("; left as they are: " .. table.concat(kept, ", ")) or "") .. ".", #conv, conv, saved)
  end
  if #outside > 0 then
    add("media", string.format("Copy %d file(s) from outside the project folder into it", #outside),
      "So the project is complete wherever it's opened or checked out (Solo edit uploads the project folder).", #outside, outside, saved)
  end
  local off = {}
  for f in pairs(offline) do off[#off + 1] = f:match("[^/]+$") end
  if #off > 0 then
    add("offline", string.format("%d file(s) are missing (offline): %s", #off, table.concat(off, ", ")),
      "Not changed: find them (File > Clean current project directory won't help; use the Media Explorer or re-link in each item) before sending.", #off, nil, false)
  end
  if not saved then
    add("save", "Save the project first", "File conversions and copies need the project's folder: save the project, then open this again.", 0, nil, false)
  end

  -- clutter: empty items and tiny slivers
  local clutter = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local empty = not tk or (not reaper.TakeIsMIDI(tk) and src_file(tk) == "")
    if not bands(it) and (empty or reaper.GetMediaItemInfo_Value(it, "D_LENGTH") < 0.05) then clutter[#clutter + 1] = it end
  end
  if #clutter > 0 then
    add("clutter", string.format("Remove %d empty item(s) and slivers under 50 ms", #clutter),
      "Leftovers from editing: they'd go out to the band as takes of nothing.", #clutter, clutter)
  end

  -- ripple editing moves other people's parts, which BandSync then puts back
  if reaper.GetToggleCommandStateEx(0, 41990) == 1 or reaper.GetToggleCommandStateEx(0, 41991) == 1 then
    add("ripple", "Turn ripple editing off", "Ripple editing moves the clips after an edit, including bandmates', which BandSync puts back: it fights you.", 1, true)
  end

  -- BandSync's own setup
  local live = require("live")
  if b and b.role ~= "solo" and not live.fx(proj, false, live.SONOBUS) then
    add("sonobus", "Put SonoBus on the master (off until you Connect)", "For Listen live: it joins the band's group by itself when you Connect.", 1, true)
  end
  if not require("tools").autostart_on() then
    add("autostart", "Start Live sync with REAPER", "A REAPER restart brings Live sync back for sessions where it was running (otherwise changes quietly stay here).", 1, true)
  end
  return out
end

-- Convert one file to FLAC beside the project: rendered on a temporary, effect-free track at the file's own rate,
-- then compared sample by sample with the original. Returns the new path, or nil + why.
function prep.to_flac(proj, file, dest_dir)
  local src = reaper.PCM_Source_CreateFromFile(file)
  if not src then return nil, "couldn't open" end
  local sr, nch, len = reaper.GetMediaSourceSampleRate(src), reaper.GetMediaSourceNumChannels(src), reaper.GetMediaSourceLength(src)
  local base = file:match("([^/]+)%.[^.]+$")
  local name = base
  for n = 2, 99 do if not reaper.file_exists(dest_dir .. "/" .. name .. ".flac") then break end name = base .. " " .. n end
  reaper.InsertTrackAtIndex(reaper.CountTracks(proj), false)
  local tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
  reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 1)
  reaper.SetMediaTrackInfo_Value(tr, "D_PAN", 0)
  reaper.SetMediaTrackInfo_Value(tr, "D_PANLAW", 1) -- 0 dB: nothing changes level in the middle
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 0)
  reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len)
  reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 0)
  reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", 0)
  reaper.SelectAllMediaItems(proj, false)
  reaper.SetMediaItemSelected(it, true)
  -- rendered at the project's rate the file would be resampled twice (a 44.1 kHz file in a 48 kHz project came back
  -- different): the project runs at the file's own rate for this render
  local was_sr, was_use = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false), reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false)
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", sr, true)
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
  local okr, err = pcall(band.render, { RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = sr, RENDER_CHANNELS = nch, RENDER_TAILFLAG = 0,
    RENDER_ADDTOPROJ = 0, RENDER_DITHER = 0, RENDER_NORMALIZE = 0 },
    { RENDER_FILE = dest_dir, RENDER_PATTERN = name, RENDER_FORMAT = band.FLAC, RENDER_FORMAT2 = "" })
  reaper.DeleteTrack(tr) -- the temporary track never stays behind
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", was_sr, true)
  reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", was_use, true)
  if not okr then return nil, "the render failed: " .. tostring(err) end
  local out = dest_dir .. "/" .. name .. ".flac"
  if not reaper.file_exists(out) then return nil, "the render didn't produce a file" end
  local ok, why = prep.same_audio(proj, file, out)
  if not ok then os.remove(out); return nil, why end
  return out
end

-- Whether two files hold the same audio (to 24 bits: within 1.5/2^23), compared over their whole length. Reads them
-- through takes on a temporary track (audio accessors need a take).
function prep.same_audio(proj, a, b)
  reaper.InsertTrackAtIndex(reaper.CountTracks(proj), false)
  local tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
  local function take_of(file)
    local src = reaper.PCM_Source_CreateFromFile(file)
    if not src then return nil end
    local it = reaper.AddMediaItemToTrack(tr)
    local tk = reaper.AddTakeToMediaItem(it)
    reaper.SetMediaItemTake_Source(tk, src)
    reaper.SetMediaItemInfo_Value(it, "D_LENGTH", reaper.GetMediaSourceLength(src))
    return tk, src
  end
  local ta, sa = take_of(a)
  local tb, sb = take_of(b)
  local okc, ok, why = pcall(function()
  if not ta or not tb then return false, "couldn't read it back to check it" end
  local ok, why = true, nil
  do
    local sr, nch, la = reaper.GetMediaSourceSampleRate(sa), reaper.GetMediaSourceNumChannels(sa), reaper.GetMediaSourceLength(sa)
    local srb, nchb, lb = reaper.GetMediaSourceSampleRate(sb), reaper.GetMediaSourceNumChannels(sb), reaper.GetMediaSourceLength(sb)
    if srb ~= sr or nchb ~= nch or math.abs(la - lb) > 1.5 / sr then
      ok, why = false, string.format("the FLAC came out different (%d Hz, %d ch, %.3f s from %d Hz, %d ch, %.3f s)", srb, nchb, lb, sr, nch, la)
    else
      local acca, accb = reaper.CreateTakeAudioAccessor(ta), reaper.CreateTakeAudioAccessor(tb)
      local chunk, total, pos = 32768, math.floor(la * sr + 0.5), 0
      local ba, bb = reaper.new_array(chunk * nch), reaper.new_array(chunk * nch)
      while ok and pos < total do
        local n = math.min(chunk, total - pos)
        reaper.GetAudioAccessorSamples(acca, sr, nch, pos / sr, n, ba)
        reaper.GetAudioAccessorSamples(accb, sr, nch, pos / sr, n, bb)
        local xa, xb = ba.table(1, n * nch), bb.table(1, n * nch)
        for i = 1, n * nch do
          if math.abs(xa[i] - xb[i]) > 1.5 / 8388608 then
            ok, why = false, string.format("the FLAC differs at %.3f s (%.6f vs %.6f)", (pos + (i - 1) // nch) / sr, xb[i], xa[i])
            break
          end
        end
        pos = pos + n
      end
      reaper.DestroyAudioAccessor(acca)
      reaper.DestroyAudioAccessor(accb)
    end
  end
  return ok, why
  end)
  reaper.DeleteTrack(tr) -- its items and their sources go with it, whatever happened
  if not okc then return false, "checking failed: " .. tostring(ok) end
  return ok, why
end

-- Point every take playing `from` (a file) at `to` instead. Returns how many.
local function repoint(proj, from, to)
  local n = 0
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local old = tk and reaper.GetMediaItemTake_Source(tk)
      -- a section (reversed, a loop of part of a file) wraps the file: left as it is, it keeps working
      if old and reaper.GetMediaSourceType(old, "") ~= "SECTION" and reaper.GetMediaSourceFileName(old, ""):gsub("\\", "/") == from then
        reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(to))
        reaper.PCM_Source_Destroy(old) -- (the take doesn't free it: and it holds the file open)
        n = n + 1
      end
    end
  end
  return n
end

local function project_dir(proj)
  return (select(2, reaper.EnumProjects(-1)):gsub("\\", "/"):match("^(.*)/") or "")
end

-- Do the chosen rows (from scan(), with .on). Saves a backup copy of the project first. Returns summary lines.
function prep.apply(proj, cfg, b, rows, dir)
  local done, on = {}, {}
  for _, r in ipairs(rows) do if r.on then on[r.key] = r end end
  local file = select(2, reaper.EnumProjects(-1))
  local backup
  if file ~= "" then
    backup = file:gsub("%.[Rr][Pp][Pp]$", "") .. " - before BandSync " .. os.date("%Y%m%d-%H%M") .. ".rpp"
    reaper.Main_SaveProjectEx(proj, backup, 0) -- 0: a copy; this tab keeps its own file
    done[#done + 1] = "Backup copy saved: " .. backup:match("[^/\\]+$")
  end
  reaper.Undo_BeginBlock2(proj)
  reaper.PreventUIRefresh(1)
  local sel = {}
  for i = 0, reaper.CountSelectedMediaItems(proj) - 1 do sel[#sel + 1] = reaper.GetSelectedMediaItem(proj, i) end
  -- whatever goes wrong below, REAPER's screen and undo must not be left paused/open (a test run left both stuck)
  local okb, errb = pcall(function()

  if on.clutter then
    local n = 0
    for _, it in ipairs(on.clutter.todo) do
      if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.DeleteTrackMediaItem(reaper.GetMediaItem_Track(it), it); n = n + 1 end
    end
    done[#done + 1] = "Removed " .. n .. " empty item(s) and slivers"
  end

  local media = reaper.GetProjectPathEx(proj, ""):gsub("\\", "/")
  if (on.flac or on.media) and media ~= "" then reaper.RecursiveCreateDirectory(media, 0) end
  if on.flac and media ~= "" then
    local keep = project_dir(proj) .. "/BandSync originals"
    local home = project_dir(proj)
    local n, bad, stuck, moved = 0, {}, 0, {}
    for _, f in ipairs(on.flac.todo) do
      local inside = f:sub(1, #home + 1) == home .. "/"
      local okr, out, why = pcall(prep.to_flac, proj, f, inside and f:match("^(.*)/") or media)
      if not okr then out, why = nil, out end
      if out then
        repoint(proj, f, out)
        n = n + 1
        if inside then -- ours: the original goes to the backup folder (one outside the project stays where it is)
          reaper.RecursiveCreateDirectory(keep, 0)
          local name = f:match("[^/]+$")
          local base, ext = name:match("^(.*)(%.[^.]+)$")
          base, ext = base or name, ext or ""
          local to, k = keep .. "/" .. name, 2
          while reaper.file_exists(to) do to = keep .. "/" .. base .. " " .. k .. ext; k = k + 1 end -- two "take1.wav"s from two folders
          if os.rename(f, to) then moved[f] = to else stuck = stuck + 1 end
          os.remove(f .. ".reapeaks")
        end
      else
        bad[#bad + 1] = f:match("[^/]+$") .. ": " .. tostring(why)
      end
    end
    -- the backup copy plays the originals from where they are now
    local text = backup and next(moved) and band.read(backup)
    if text then
      local function esc(s) return (s:gsub("%p", "%%%0")) end
      for from, to in pairs(moved) do
        local rel = from:sub(#home + 2)
        for _, v in ipairs({ from, (from:gsub("/", "\\")), rel, (rel:gsub("/", "\\")) }) do
          text = text:gsub('FILE "' .. esc(v) .. '"', function() return 'FILE "' .. to .. '"' end)
        end
      end
      band.write_atomic(backup, text)
    end
    done[#done + 1] = string.format("Converted %d file(s) to FLAC (originals in 'BandSync originals')%s%s", n,
      stuck > 0 and string.format("; %d original(s) couldn't be moved yet (in use): move them after closing REAPER", stuck) or "",
      #bad > 0 and ("; kept as they were: " .. table.concat(bad, "; ")) or "")
  end
  if on.media and media ~= "" then
    local n = 0
    for _, f in ipairs(on.media.todo) do
      local base, ext = f:match("([^/]+)(%.[^./]+)$")
      base, ext = base or f:match("[^/]+$"), ext or ""
      local to, k = media .. "/" .. base .. ext, 2
      while reaper.file_exists(to) do to = media .. "/" .. base .. " " .. k .. ext; k = k + 1 end -- never someone else's file of that name
      if pcall(band.copy_atomic, f, to) and repoint(proj, f, to) > 0 then n = n + 1 end
    end
    done[#done + 1] = "Copied " .. n .. " file(s) into the project folder"
  end

  if on.lanes then
    -- the take that plays goes to the top first: exploded, the top lane is the one that plays (so what you hear stays)
    reaper.SelectAllMediaItems(proj, false)
    for _, list in ipairs({ on.lanes.todo.set, on.lanes.todo.explode }) do
      for _, tr in ipairs(list) do
        for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
          local it = reaper.GetTrackMediaItem(tr, j)
          if reaper.CountTakes(it) > 1 and not bands(it) then reaper.SetMediaItemSelected(it, true) end
        end
      end
    end
    reaper.Main_OnCommand(41380, 0) -- Item: Move active takes to top
    reaper.SelectAllMediaItems(proj, false)
    local n = 0
    for _, step in ipairs({ { on.lanes.todo.set, 42661 }, -- Track properties: Set fixed lanes (convert takes to lanes)
        { on.lanes.todo.explode, 42635 } }) do -- Take: Explode takes on selected tracks to fixed lanes
      reaper.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
      local any = false
      for _, tr in ipairs(step[1]) do
        if reaper.ValidatePtr2(proj, tr, "MediaTrack*") then reaper.SetTrackSelected(tr, true); n = n + 1; any = true end
      end
      if any then reaper.Main_OnCommand(step[2], 0) end
    end
    reaper.Main_OnCommand(40297, 0)
    done[#done + 1] = "Lanes on " .. n .. " track(s)"
  end

  if on.names then
    local taken = {}
    for t = 0, reaper.CountTracks(proj) - 1 do taken[select(2, reaper.GetTrackName(reaper.GetTrack(proj, t))):lower()] = true end
    local function free(base)
      local name, k = base, 2
      while taken[name:lower()] do name = base .. " " .. k; k = k + 1 end
      taken[name:lower()] = true
      return name
    end
    local n = 0
    for _, tr in ipairs(on.names.todo.dup) do
      local base = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", free(base), true)
      n = n + 1
    end
    for _, tr in ipairs(on.names.todo.blank) do
      local it = reaper.GetTrackMediaItem(tr, 0)
      local tk = it and reaper.GetActiveTake(it)
      local guess = tk and reaper.GetTakeName(tk):gsub("%.%w+$", ""):gsub("[-_ ]*%d+$", ""):match("^%s*(.-)%s*$") or ""
      reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", free(guess ~= "" and guess or ("Track " .. math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")))), true)
      n = n + 1
    end
    done[#done + 1] = "Named " .. n .. " track(s)"
  end

  if on.format then
    reaper.GetSetProjectInfo_String(proj, "RECORD_FORMAT", band.FLAC, true)
    reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", on.format.todo, true)
    reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 1, true)
    done[#done + 1] = string.format("Recording 24-bit FLAC at %d Hz", on.format.todo)
  end
  if on.ripple then
    reaper.Main_OnCommand(40309, 0) -- Set ripple editing off
    done[#done + 1] = "Ripple editing is off"
  end
  end)
  if not okb then done[#done + 1] = "Stopped partway: " .. tostring(errb) .. " (Undo takes back what was done)" end
  reaper.SelectAllMediaItems(proj, false)
  for _, it in ipairs(sel) do if reaper.ValidatePtr2(proj, it, "MediaItem*") then reaper.SetMediaItemSelected(it, true) end end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock2(proj, "BandSync: prepare this project", -1)

  if on.sonobus then
    local ok, why = require("setup").sonobus(cfg, b, proj, false)
    done[#done + 1] = ok and "SonoBus is on the master (off until you Connect)" or tostring(why)
  end
  if on.autostart then
    done[#done + 1] = require("tools").set_autostart(true, dir) and "Live sync now starts with REAPER" or "Couldn't write Scripts/__startup.lua"
  end
  if file ~= "" then reaper.Main_SaveProject(proj, false) end -- the converted files are what it points at now
  return done
end

return prep

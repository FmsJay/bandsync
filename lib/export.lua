-- A copy of the project outside the group: a plain REAPER project in a folder of its own, with all its media beside it, that opens anywhere
-- with no StudioSync. Nothing about the open project changes. With wav: FLAC and other compressed recordings become WAV files too (rendered
-- in a scratch tab, one file for each, at the project's sample rate).
local band = require("band")
local sessionfile = require("sessionfile")
local ex = {}

ex.WAV24 = "ZXZhdxgAAQ==" -- (REAPER's render format string: 'evaw', 24 bit, PCM)
local COMPRESSED = { flac = true, opus = true, ogg = true, mp3 = true, m4a = true, wv = true }

-- A project's text with the tracks that are this computer's own taken out (Real time, a helper: P_EXT band_local). Pure.
function ex.no_local_tracks(text)
  local lines, out, i = {}, {}, 1
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  if lines[#lines] == "" then lines[#lines] = nil end
  while i <= #lines do
    local ind = lines[i]:match("^(%s*)<TRACK")
    if ind then
      local j, ours = i + 1, false
      while j <= #lines and lines[j] ~= ind .. ">" do
        ours = ours or lines[j]:match("^%s*band_local%s") ~= nil or lines[j]:match("^%s*band_live_track%s") ~= nil
        j = j + 1
      end
      if not ours then for k = i, math.min(j, #lines) do out[#out + 1] = lines[k] end end
      i = j + 1
    else
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end
  return table.concat(out, "\n") .. "\n"
end
-- A source named as FLAC whose file is now a WAV. Pure.
function ex.wave_sources(text)
  return (text:gsub('<SOURCE [%w_]+(\n%s*FILE "[^"\n]+%.wav"[^\n]*)', "<SOURCE WAVE%1"))
end

-- `files`: { { from, to } } to turn into WAVs, in one render in a scratch tab. Returns those that didn't come out.
local function render_wavs(files, proj)
  local front = reaper.EnumProjects(-1)
  reaper.Main_OnCommand(40859, 0) -- File: New project tab (nothing StudioSync: no sync runs on it)
  local tab = reaper.EnumProjects(-1)
  local bad = {}
  local srate = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
  reaper.GetSetProjectInfo(tab, "PROJECT_SRATE", srate, true)
  reaper.GetSetProjectInfo(tab, "PROJECT_SRATE_USE", 1, true)
  for _, ch in ipairs({ 1, 2 }) do
    reaper.SelectAllMediaItems(tab, false)
    local pos, any = 0, false
    for _, f in ipairs(files) do
      local src = reaper.PCM_Source_CreateFromFile(f.from)
      if not src then bad[#bad + 1] = f.from
      elseif (reaper.GetMediaSourceNumChannels(src) == 1) == (ch == 1) then
        reaper.InsertTrackInProject(tab, reaper.CountTracks(tab), 0)
        local tr = reaper.GetTrack(tab, reaper.CountTracks(tab) - 1)
        local it = reaper.AddMediaItemToTrack(tr)
        local tk = reaper.AddTakeToMediaItem(it)
        reaper.SetMediaItemTake_Source(tk, src)
        reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", (f.to:match("([^/]+)%.wav$")), true)
        local len = reaper.GetMediaSourceLength(src)
        reaper.SetMediaItemInfo_Value(it, "D_POSITION", pos)
        reaper.SetMediaItemInfo_Value(it, "D_LENGTH", len)
        reaper.SetMediaItemInfo_Value(it, "D_FADEINLEN", 0)
        reaper.SetMediaItemInfo_Value(it, "D_FADEOUTLEN", 0)
        reaper.SetMediaItemSelected(it, true)
        pos, any = pos + len + 1, true
      end
    end
    if any then
      local dest = files[1].to:match("^(.*)/")
      pcall(band.render, { RENDER_NORMALIZE = 0, RENDER_SETTINGS = 32, RENDER_BOUNDSFLAG = 4, RENDER_SRATE = srate, RENDER_CHANNELS = ch, RENDER_TAILFLAG = 0, RENDER_ADDTOPROJ = 0, RENDER_DITHER = 0 },
        { RENDER_FILE = dest, RENDER_PATTERN = "$item", RENDER_FORMAT = ex.WAV24, RENDER_FORMAT2 = "" })
    end
    for t = reaper.CountTracks(tab) - 1, 0, -1 do reaper.DeleteTrack(reaper.GetTrack(tab, t)) end
  end
  reaper.Main_SaveProjectEx(tab, reaper.GetResourcePath() .. "/BandSync/export-scratch.rpp", 8) -- (a saved tab closes without a question)
  reaper.Main_OnCommand(40860, 0) -- File: Close current project tab
  os.remove(reaper.GetResourcePath() .. "/BandSync/export-scratch.rpp")
  if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
  for _, f in ipairs(files) do if not reaper.file_exists(f.to) then bad[#bad + 1] = f.from end end
  return bad
end

-- The copy, in <parent>/<name>/. -> the .rpp written and how many files it holds, or nil + why.
function ex.project(proj, name, parent, wav)
  local path
  for i = 0, 512 do
    local p, f = reaper.EnumProjects(i)
    if not p then break end
    if p == proj then path = f end
  end
  if not path or path == "" then return nil, "the project has never been saved" end
  parent = parent:gsub("\\", "/"):gsub("/+$", "")
  local projdir = path:gsub("\\", "/"):match("^(.*)/")
  local stamp = os.date("%Y-%m-%d %H%M")
  local dest = string.format("%s/%s (%s)", parent, band.clean(name), stamp)
  reaper.RecursiveCreateDirectory(dest .. "/Media", 0)
  local tmp = projdir .. "/.bandsync-export-copy.rpp"
  reaper.Main_SaveProjectEx(proj, tmp, 0) -- a copy beside it, so relative paths read the same; the open project and its file are untouched
  local text = band.read(tmp)
  os.remove(tmp)
  if not text then return nil, "couldn't save a copy of the project" end
  text = sessionfile.plain(text, require("mixlayer").split_live)
  text = ex.no_local_tracks(text)
  local seen, used, convert, n = {}, {}, {}, 0
  text = sessionfile.map_files(text, function(p)
    local full = p:gsub("\\", "/")
    if not (full:match("^%a:/") or full:sub(1, 1) == "/") then full = projdir .. "/" .. full end
    if seen[full] then return seen[full] end
    if not reaper.file_exists(full) then return nil end
    local base, ext = full:match("([^/]+)%.([^./]+)$")
    if not base then base, ext = full:match("[^/]+$"), "" end
    local to_wav = wav and COMPRESSED[ext:lower()]
    local out_ext = to_wav and "wav" or ext
    local nm, k = base, 2
    while used[(nm .. "." .. out_ext):lower()] do nm = base .. " " .. k; k = k + 1 end
    used[(nm .. "." .. out_ext):lower()] = true
    local rel = "Media/" .. nm .. "." .. out_ext
    n = n + 1
    if to_wav then convert[#convert + 1] = { from = full, to = dest .. "/" .. rel }
    else band.copy_atomic(full, dest .. "/" .. rel) end
    seen[full] = rel
    return rel
  end)
  text = ex.wave_sources(text)
  if #convert > 0 then
    local bad = render_wavs(convert, proj)
    if #bad > 0 then return nil, string.format("%d file(s) didn't convert, the first being %s", #bad, bad[1]:match("[^/]+$")) end
  end
  local out = dest .. "/" .. band.clean(name) .. ".rpp"
  band.write_atomic(out, text)
  return out, n
end

-- Ask where and how, then do it (the panel's button). Remembers the folder.
function ex.ask(proj, name, wav)
  local start = reaper.GetExtState(band.SECTION, "backup folder")
  local ok, folder
  if reaper.JS_Dialog_BrowseForFolder then
    ok, folder = reaper.JS_Dialog_BrowseForFolder("StudioSync: save a copy outside the studio, in...", start)
    ok = ok == 1
  else
    ok, folder = reaper.GetUserInputs("StudioSync: save a copy outside the studio", 1, "In this folder,extrawidth=250", start)
  end
  if not ok or (folder or "") == "" then return end
  reaper.SetExtState(band.SECTION, "backup folder", (folder:gsub("\\", "/")), true)
  local file, n = ex.project(proj, name, folder, wav)
  if file then
    band.log(string.format("saved a plain copy of the project (%d media files) in %s: it opens with no StudioSync", n, file:match("^(.*)/")))
    return file
  end
  band.msg("Couldn't save the copy: " .. tostring(n))
end

return ex

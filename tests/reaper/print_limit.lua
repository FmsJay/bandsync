-- Run inside REAPER (ReaScript). A part too hot for FLAC: its print is limited and not clipped, in front and in the background; a part that
-- isn't hot is left alone; and a project's own render settings come back. Scratch folder and tab, closed at the end.
local D = reaper.GetResourcePath() .. "/StudioSync/tests"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "mirror", "prints", "plugins", "bgrender", "json" }) do package.loaded[m] = nil end
require("prints").SETTLE = 0
local band, prints, plugins = require("band"), require("prints"), require("plugins")
local root = D .. "/lroot_" .. os.time()
local cfg = { user = "James", root = root }
local media = root .. "/LimitLab/rooms/main/media"
reaper.RecursiveCreateDirectory(media, 0)
reaper.RecursiveCreateDirectory(root .. "/plugins", 0)
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function peak(path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  local g = src and reaper.CalculateNormalization(src, 2, 0, 0, 0) or 0
  if src then reaper.PCM_Source_Destroy(src) end
  return g > 0 and -20 * math.log(g, 10) or -999
end
local function sine_wav(path, secs, sr) -- 220 Hz at -12 dBFS, 16-bit mono
  local n = math.floor(secs * sr)
  local t = { "RIFF", string.pack("<I4", 36 + n * 2), "WAVE", "fmt ", string.pack("<I4I2I2I4I4I2I2", 16, 1, 1, sr, sr * 2, 2, 16), "data", string.pack("<I4", n * 2) }
  for i = 0, n - 1 do t[#t + 1] = string.pack("<i2", math.floor(0.25 * 32767 * math.sin(2 * math.pi * 220 * i / sr))) end
  local f = io.open(path, "wb"); f:write(table.concat(t)); f:close()
end
local front = reaper.EnumProjects(-1)
reaper.Main_OnCommand(40859, 0); local pa = reaper.EnumProjects(-1)
local ok, err = pcall(function()
  sine_wav(media .. "/take.wav", 2, 44100)
  reaper.InsertTrackInProject(pa, 0, 0)
  local tr = reaper.GetTrack(pa, 0)
  local fx = reaper.TrackFX_AddByName(tr, "JS: Volume Adjustment", false, -1)
  if fx < 0 then fx = reaper.TrackFX_AddByName(tr, "utility/volume", false, -1) end
  local _, fxname = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_name")
  local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
  band.write_json(root .. "/plugins/James.json", { user = "James", time = now, names = { plugins.key(fxname) } })
  band.write_json(root .. "/plugins/Mac.json", { user = "Mac", time = now, names = {} }) -- (the Mac lacks it, so it needs a print)
  local it = reaper.AddMediaItemToTrack(tr)
  local tk = reaper.AddTakeToMediaItem(it)
  reaper.SetMediaItemTake_Source(tk, reaper.PCM_Source_CreateFromFile(media .. "/take.wav"))
  reaper.SetMediaItemInfo_Value(it, "D_POSITION", 1); reaper.SetMediaItemInfo_Value(it, "D_LENGTH", 2)
  reaper.GetSetMediaItemInfo_String(it, "P_EXT:band_oid", "I-JAMES-20261103000000-1", true)
  reaper.UpdateArrange()
  local dry = prints.audio_take(it)
  local sync = require("sync")

  -- a project's own render settings: they're back after, and don't leak into a print
  reaper.GetSetProjectInfo(pa, "RENDER_NORMALIZE", 1, true)
  reaper.GetSetProjectInfo(pa, "RENDER_NORMALIZE_TARGET", 0.1, true)

  -- not hot: -12 + 6 = -6 dBFS, left exactly alone
  reaper.TrackFX_SetParam(tr, fx, 0, 6)
  local calm = sync.print_item(pa, it, dry, media, "calm", nil, false, true)
  check(calm and math.abs(peak(calm) + 6.02) < 0.1, string.format("a part under full scale keeps its level (%.2f dBFS)", calm and peak(calm) or -999))
  check(reaper.GetSetProjectInfo(pa, "RENDER_NORMALIZE", 0, false) == 1, "the project's own normalize setting is back after")

  -- 24 dB up: 12 dB over full scale
  reaper.TrackFX_SetParam(tr, fx, 0, 24)
  local hot = sync.print_item(pa, it, dry, media, "hot", nil, false, true)
  local ceiling = 20 * math.log(band.LIMIT.RENDER_BRICKWALL, 10)
  check(hot and math.abs(peak(hot) - ceiling) < 0.05, string.format("over full scale, it's limited at %.2f dBFS, not clipped at 0 (%.2f)", ceiling, hot and peak(hot) or -999))

  -- and from the second REAPER, in the background
  local t0, did = reaper.time_precise(), prints.refresh(pa, it, media, "hot fx", nil, cfg)
  while not did and reaper.time_precise() - t0 < 90 do
    local w = reaper.time_precise(); while reaper.time_precise() - w < 0.5 do end
    did = prints.refresh(pa, it, media, "hot fx", nil, cfg)
  end
  local wet = select(2, prints.takes(it))
  local wpath = wet and reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(wet), "") or ""
  local bg_done, bg_failed = require("bgrender").counts()
  check(bg_done >= 1 and bg_failed == 0, string.format("it rendered in the background (%d done, %d failed)", bg_done, bg_failed))
  check(wpath ~= "" and math.abs(peak(wpath) - ceiling) < 0.05, string.format("limited there too (%.2f dBFS)", wpath ~= "" and peak(wpath) or -999))
end)
if not ok then fails = fails + 1; out[#out + 1] = "ERROR " .. tostring(err) end
if reaper.ValidatePtr2(0, pa, "ReaProject*") then
  reaper.SelectProjectInstance(pa)
  reaper.Main_SaveProjectEx(pa, root .. "/print_limit.rpp", 8)
  reaper.Main_OnCommand(40860, 0)
end
if front and reaper.ValidatePtr2(0, front, "ReaProject*") then reaper.SelectProjectInstance(front) end
return (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. "\n" .. table.concat(out, "\n")

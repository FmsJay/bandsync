-- Hearing each other while it happens, through REAPER's own ReaNINJAM and the band's NINJAM server.
-- ReaNINJAM's local channel has three modes (flags, from its source, ninjam/njclient.cpp):
--   synced (4, "session mode"): audio is stamped with the sender's song position; you hear it when YOUR
--           playhead reaches that position. Start playback a bar or two after the sender and you hear them
--           in time with the song. Each clip is also saved with its position, so BandSync drops it on the
--           timeline as a placeholder until the real take arrives.
--   listen (2, "voice chat"): plain live audio, as soon as possible. For hearing an idea, not playing along.
--   jam    (0): classic NINJAM: everyone hears everyone one interval (BPI bars) late.
-- ReaNINJAM keeps its settings in reaninjam.ini, section [ninjam], next to reaper.exe or in the resource
-- folder; BandSync writes them there before ReaNINJAM opens, so connecting is one click.
local band = require("band")
local live = {}

live.FLAGS = { synced = 4, listen = 2, jam = 0 }
live.FX = "ReaNINJAM"
live.TRACK_SUFFIX = " (live)"

function live.ini_path()
  local exe_dir = reaper.GetExePath()
  if reaper.file_exists(exe_dir .. "/reaninjam.ini") then return exe_dir .. "/reaninjam.ini" end
  return reaper.GetResourcePath() .. "/reaninjam.ini"
end

-- Set keys of one [section] in an ini text, keeping everything else. Pure.
function live.ini_set(text, section, keys)
  local lines, out, in_sec, seen, found = {}, {}, false, {}, false
  for line in ((text or "") .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  local function flush()
    for k, v in pairs(keys) do if not seen[k] then out[#out + 1] = k .. "=" .. v end end
  end
  for _, line in ipairs(lines) do
    local sec = line:match("^%s*%[(.-)%]%s*$")
    if sec then
      if in_sec then flush() end
      in_sec = sec:lower() == section:lower()
      found = found or in_sec
      out[#out + 1] = line
    else
      local k = in_sec and line:match("^%s*([^=;#]-)%s*=")
      if k and keys[k] ~= nil then
        if not seen[k] then out[#out + 1] = k .. "=" .. keys[k] end
        seen[k] = true
      else
        out[#out + 1] = line
      end
    end
  end
  if in_sec then flush() end
  if not found then
    out[#out + 1] = "[" .. section .. "]"
    flush()
  end
  return table.concat(out, "\n") .. "\n"
end

-- Point ReaNINJAM at the band's server, as this person, with one local channel in `mode`.
-- `send`: whether this channel goes out (the driver/performer sends; listeners usually don't).
function live.configure(cfg, server, mode, send, sessiondir)
  local path = live.ini_path()
  local keys = {
    host = server, user = cfg.user, anon = "1", pass = "", passrem = "0",
    savelocal = "1", savelocalwav = "0", sessiondir = sessiondir,
    lc_cnt = "1",
    lc_0 = string.format("0 source 0 bc %d mute 0 solo 0 volume 1.000000 pan 0.000000 jesus 0 flag %d outidx 0 br 128 name `%s`",
      send and 1 or 0, live.FLAGS[mode] or 4, (cfg.user:gsub("`", ""))),
  }
  local f = io.open(path, "rb")
  local text = f and f:read("a") or ""
  if f then f:close() end
  f = io.open(path, "wb")
  if not f then return nil, "can't write " .. path end
  f:write(live.ini_set(text, "ninjam", keys))
  f:close()
  return path
end

-- ReaNINJAM on the master track: it sends what you hear (your whole mix) and plays the band into it.
function live.fx(proj, add)
  local master = reaper.GetMasterTrack(proj)
  for i = 0, reaper.TrackFX_GetCount(master) - 1 do
    local _, name = reaper.TrackFX_GetFXName(master, i)
    if name:find(live.FX, 1, true) then return master, i end
  end
  if not add then return nil end
  local i = reaper.TrackFX_AddByName(master, live.FX, false, -1)
  if i < 0 then return nil end
  return master, i
end

-- Parse clipsort.log lines for remote session-mode clips: { guid, user, chan, name, st, len }. Pure.
function live.parse_log(text)
  local out = {}
  for line in (text or ""):gmatch("[^\r\n]+") do
    local guid, user, chan, name, st, len = line:match('^sessionlog (%S+) "(.-)" (%d+) "(.-)" ([%d%.%-]+) ([%d%.%-]+)')
    if guid then
      out[#out + 1] = { guid = guid, user = user, chan = tonumber(chan), name = name, st = tonumber(st), len = tonumber(len) }
    end
  end
  return out
end

-- The newest ReaNINJAM session folder under sessiondir ("YYYYMMDD_HHMM[_n].ninjam").
function live.newest_session(sessiondir)
  local best
  for _, d in ipairs(band.subdirs(sessiondir)) do
    if d:match("%.ninjam$") and (not best or d > best) then best = d end
  end
  return best and (sessiondir .. "/" .. best)
end

-- Drop received session clips on "<user> (live)" tracks at their song position, as placeholders: they show
-- what was played until the real take lands. Returns how many were added. Clips already placed are skipped.
function live.place_clips(proj, sessiondir)
  local dir = live.newest_session(sessiondir)
  if not dir then return 0 end
  local f = io.open(dir .. "/clipsort.log", "rb")
  if not f then return 0 end
  local clips = live.parse_log(f:read("a"))
  f:close()
  local have = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local g = band.item_ext(reaper.GetMediaItem(proj, i), "band_live")
    if g ~= "" then have[g] = true end
  end
  local n = 0
  for _, c in ipairs(clips) do
    if not have[c.guid] and c.len and c.len > 0 then
      local sub = dir .. "/" .. c.guid:sub(1, 1)
      local file
      for _, fn in ipairs(band.files(sub)) do if fn:sub(1, #c.guid) == c.guid then file = sub .. "/" .. fn end end
      if file and (band.size(file) or 0) > 0 then
        local name = c.user:gsub("@.*$", "") .. live.TRACK_SUFFIX -- anonymous users show as name@ip
        local tr = band.find_track(proj, name) or band.new_track(proj, name)
        if tr then
          reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "1", true)
          local it = band.add_item(tr, file, c.st, c.len)
          if it then band.set_item_ext(it, "band_live", c.guid); n = n + 1 end
        end
      end
    end
  end
  return n
end

-- Remove placeholders that a real take now covers: same person, overlapping time.
function live.retire(proj)
  local takes = {} -- user -> { {from, to} }
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id = tk and band.take_id(tk)
    local user = id and id:match("^(.-)%-%d+%-%d+Z")
    if user then
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      takes[user:lower()] = takes[user:lower()] or {}
      table.insert(takes[user:lower()], { p, p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") })
    end
  end
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      local user = select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", ""):gsub("_", " "):lower()
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local e = p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      for _, span in ipairs(takes[user] or takes[user:gsub(" ", "_")] or {}) do
        if span[1] < e and span[2] > p then
          reaper.DeleteTrackMediaItem(tr, it)
          n = n + 1
          break
        end
      end
    end
  end
  return n
end

return live

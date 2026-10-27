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

live.SEEN = "BandSync.live" -- clip GUID (upper case) -> UTC stamp of the live session it came from

-- "…/20261026_2345.ninjam" (the listener's local time) -> "20261027-054500Z", comparable with take ids.
function live.session_stamp(dir)
  local y, mo, d, h, mi = (dir or ""):match("(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)[^/\\]*%.ninjam$")
  if not y then return "" end
  return os.date("!%Y%m%d-%H%M%SZ", os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = 0 }))
end

-- Whether take `id` (from <user>-YYYYMMDD-HHMMSSZ-n) replaces a placeholder of `user` from a session that
-- started at `since`: same person, recorded after the session began. Pure.
function live.replaces(id, user, since)
  local who, stamp = (id or ""):match("^(.-)%-(%d+%-%d+Z)")
  if not who or who:lower():gsub("_", " ") ~= (user or ""):lower():gsub("_", " ") then return false end
  return since ~= "" and stamp >= since
end

-- Drop received session clips on "<user> (live)" tracks at their song position, as placeholders: they show
-- what was played until the real take lands. Returns how many were added. A clip is placed once, ever: one
-- that was retired, or that someone deleted, never comes back.
function live.place_clips(proj, sessiondir)
  local dir = live.newest_session(sessiondir)
  if not dir then return 0 end
  local f = io.open(dir .. "/clipsort.log", "rb") -- ReaNINJAM writes it when the listener disconnects (buffered)
  if not f then return 0 end
  local clips = live.parse_log(f:read("a"))
  f:close()
  local since, n = live.session_stamp(dir), 0
  for _, c in ipairs(clips) do
    local key = c.guid:upper()
    if select(2, reaper.GetProjExtState(proj, live.SEEN, key)) == "" and c.len and c.len > 0 then
      local sub = dir .. "/" .. c.guid:sub(1, 1)
      local file
      for _, fn in ipairs(band.files(sub)) do if fn:sub(1, #c.guid) == c.guid then file = sub .. "/" .. fn end end
      if file and (band.size(file) or 0) > 0 then
        local name = c.user:gsub("@.*$", "") .. live.TRACK_SUFFIX -- anonymous users show as name@ip
        local tr = band.find_track(proj, name) or band.new_track(proj, name)
        if tr then
          reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_live_track", "1", true)
          local it = band.add_item(tr, file, c.st, c.len)
          if it then
            band.set_item_ext(it, "band_live", c.guid)
            band.set_item_ext(it, "band_live_since", since)
            n = n + 1
          end
          reaper.SetProjExtState(proj, live.SEEN, key, since ~= "" and since or "?")
        end
      end
    end
  end
  return n
end

-- Remove placeholders that a real take now covers: the same person's take, recorded after that live session
-- started, overlapping in time. (Older takes of theirs never count.)
function live.retire(proj)
  local takes = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id = tk and band.take_id(tk)
    if id then
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      takes[#takes + 1] = { id, p, p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH") }
    end
  end
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      local user = select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "")
      local since = band.item_ext(it, "band_live_since")
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local e = p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      for _, t in ipairs(takes) do
        if t[2] < e and t[3] > p and live.replaces(t[1], user, since) then
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

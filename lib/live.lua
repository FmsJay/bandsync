-- Hearing each other while it happens, through REAPER's own ReaNINJAM and the band's NINJAM server.
-- ReaNINJAM's local channel has three modes (flags, from its source, ninjam/njclient.cpp):
--   synced (4, "session mode"): audio is stamped with the sender's song position; you hear it when YOUR
--           playhead reaches that position. Start playback a bar or two after the sender and you hear them
--           in time with the song. Each clip is also saved with its position, so BandSync drops it on the
--           timeline as a placeholder until the real take arrives.
--   jam    (0): classic NINJAM: everyone hears everyone one interval (BPI bars) late.
-- ReaNINJAM keeps its settings in reaninjam.ini, section [ninjam], next to reaper.exe or in the resource
-- folder; BandSync writes them there before ReaNINJAM opens, so connecting is one click.
-- "Listen live" uses SonoBus instead (GPLv3, sonobus.net): peer-to-peer, far lower latency than NINJAM's
-- voice-chat mode, and nobody has to host a server. Peers find each other through SonoBus's public
-- connection server by the band's group name and password (lib/sonobus.lua writes them into its state).
local band = require("band")
local live = {}

live.FLAGS = { synced = 4, jam = 0 }
live.FX = "ReaNINJAM"
live.SONOBUS = "SonoBus"
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

-- ReaNINJAM (or SonoBus, fx = live.SONOBUS) on the master track: it sends what you hear (your whole mix) and
-- plays the band into it. SonoBus passes your mix through (its Dry Level is 1 in plugin mode).
-- With add, ReaNINJAM is also taken off every other open project's master first: REAPER runs one ReaNINJAM per
-- process, so a copy in another tab leaves this one "could not be loaded" while still listed on the master
-- (2026-10-28 test: Play along in a second song tab silently did nothing).
function live.fx(proj, add, fx)
  fx = fx or live.FX
  local master = reaper.GetMasterTrack(proj)
  local freed = 0
  if add and fx == live.FX then
    for p = 0, math.huge do
      local other = reaper.EnumProjects(p)
      if not other then break end
      if other ~= proj then
        local m, x = live.fx(other, false)
        if m then reaper.TrackFX_Delete(m, x); freed = freed + 1 end
      end
    end
  end
  for i = 0, reaper.TrackFX_GetCount(master) - 1 do
    local _, name = reaper.TrackFX_GetFXName(master, i)
    if name:find(fx, 1, true) and not name:find("Instrument", 1, true) then
      if freed > 0 then reaper.TrackFX_SetOffline(master, i, true); reaper.TrackFX_SetOffline(master, i, false) end -- load it now that it may
      return master, i
    end
  end
  if not add then return nil end
  local i = reaper.TrackFX_AddByName(master, fx == live.SONOBUS and "VST3:SonoBus (Sonosaurus)" or fx, false, -1)
  if i < 0 and fx == live.SONOBUS then i = reaper.TrackFX_AddByName(master, "SonoBus (Sonosaurus)", false, -1) end -- VST2 / AU
  if i < 0 then return nil end
  return master, i
end

-- The band's SonoBus group: { group, password }, made once and kept in <shared folder>/sonobus.json for everyone
-- (one group for the band, so it's the same in every song). Pure apart from the random password.
function live.sonobus_group(data)
  if data.group and data.password then return data.group, data.password end
  local chars, pw = "abcdefghjkmnpqrstuvwxyz23456789", {}
  math.randomseed(os.time() + math.floor(reaper.time_precise() * 1000))
  for i = 1, 18 do local k = math.random(#chars); pw[i] = chars:sub(k, k) end
  pw = table.concat(pw)
  data.group = "BandSync " .. pw:sub(13) -- group names are global on the public server
  data.password = pw:sub(1, 12)
  return data.group, data.password
end

local function urlenc(s) return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end

-- SonoBus's join link (its own format, from ConnectView::handleSonobusURL), for joining from SonoBus's own app:
-- its paste button reads it from the clipboard and fills in group, password and server. Pure.
function live.sonobus_link(group, password)
  return "http://go.sonobus.net/sblaunch?s=aoo.sonobus.net&g=" .. urlenc(group) .. "&p=" .. urlenc(password)
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

live.HEARD = "BandSync.live_heard" -- clip GUID (upper case) -> UTC stamp of when its file first appeared here.
-- Kept in memory only (non-persistent ExtState): a session writes hundreds of clip files, our own included, and only
-- the placed ones matter; each placeholder keeps its own time (band_live_heard) once placed.

local function secs(stamp) -- "20261027-054500Z" -> seconds (only differences are used)
  local y, mo, d, h, mi, s = (stamp or ""):match("^(%d%d%d%d)(%d%d)(%d%d)%-(%d%d)(%d%d)(%d%d)Z$")
  return y and os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
end

-- Whether take `id` (from <user>-YYYYMMDD-HHMMSSZ-n, stamped when it was sent) replaces a placeholder of `user`.
-- With `heard` (when that clip arrived here) and the take's length: the take must have been recording when the
-- clip was heard, i.e. the clip arrived within the take's length (+ slack for pre-roll and the send delay) before
-- it was sent. Without `heard` (Live sync wasn't watching then): any take of theirs sent after the session began
-- at `since`. Pure.
function live.replaces(id, user, since, heard, take_len)
  local who, stamp = (id or ""):match("^(.-)%-(%d+%-%d+Z)")
  if not who or who:lower():gsub("_", " ") ~= (user or ""):lower():gsub("_", " ") then return false end
  local t, h = secs(stamp), secs(heard)
  if t and h then return h <= t + 5 and h >= t - (take_len or 0) - 30 end
  return since ~= "" and stamp >= since
end

-- Note when each clip file of the current session first appears (ReaNINJAM writes them as they arrive; only its
-- log waits for the disconnect), so placeholders know when they were heard. Call it on every Live sync poll.
function live.note_clips(proj, sessiondir)
  local dir = live.newest_session(sessiondir)
  if not dir then return end
  local now = os.date("!%Y%m%d-%H%M%SZ")
  for _, sub in ipairs(band.subdirs(dir)) do
    for _, fn in ipairs(band.files(dir .. "/" .. sub)) do
      local guid = fn:match("^(%x+)")
      if guid and #guid >= 16 and reaper.GetExtState(live.HEARD, guid:upper()) == "" then
        reaper.SetExtState(live.HEARD, guid:upper(), now, false)
      end
    end
  end
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
          for j = reaper.CountTrackMediaItems(tr) - 1, 0, -1 do -- a newer session's clip replaces an older one's
            local old = reaper.GetTrackMediaItem(tr, j)
            local op = reaper.GetMediaItemInfo_Value(old, "D_POSITION")
            if band.item_ext(old, "band_live") ~= "" and band.item_ext(old, "band_live_since") < since
              and op < c.st + c.len - 0.01 and op + reaper.GetMediaItemInfo_Value(old, "D_LENGTH") > c.st + 0.01 then
              reaper.DeleteTrackMediaItem(tr, old)
            end
          end
          local it = band.add_item(tr, file, c.st, c.len)
          if it then
            band.set_item_ext(it, "band_live", c.guid)
            band.set_item_ext(it, "band_live_since", since)
            band.set_item_ext(it, "band_live_heard", reaper.GetExtState(live.HEARD, key))
            n = n + 1
          end
          reaper.SetProjExtState(proj, live.SEEN, key, since ~= "" and since or "?")
        end
      end
    end
  end
  return n
end

-- Remove placeholders that a real take now covers: the same person's take, overlapping in song position, that was
-- being recorded when the clip was heard (live.replaces).
function live.retire(proj)
  local takes = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    local id = tk and band.take_id(tk)
    if id then
      local p, l = reaper.GetMediaItemInfo_Value(it, "D_POSITION"), reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      takes[#takes + 1] = { id, p, p + l, l }
    end
  end
  local n = 0
  for i = reaper.CountMediaItems(proj) - 1, 0, -1 do
    local it = reaper.GetMediaItem(proj, i)
    if band.item_ext(it, "band_live") ~= "" then
      local tr = reaper.GetMediaItem_Track(it)
      local user = select(2, reaper.GetTrackName(tr)):gsub(" %(live%)$", "")
      local since, heard = band.item_ext(it, "band_live_since"), band.item_ext(it, "band_live_heard")
      local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
      local e = p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH")
      for _, t in ipairs(takes) do
        if t[2] < e and t[3] > p and live.replaces(t[1], user, since, heard, t[4]) then
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

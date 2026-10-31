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

-- What ReaNINJAM's local channel is sending right now, read off its window: "session", "normal", "voice", or
-- nil (no window / js_ReaScriptAPI missing). The ini only counts when ReaNINJAM first loads in a REAPER session,
-- so an instance opened earlier can still be in Normal mode (2026-10-28: Play along streamed normal intervals,
-- heard 0.94 s off the song).
function live.channel_mode()
  if not reaper.JS_Window_Find then return nil end
  local con = reaper.JS_Window_Find("ReaNINJAM", true)
  if not con then return nil end
  if reaper.JS_Window_FindChild(con, "Session Mode", false) then return "session" end
  if reaper.JS_Window_FindChild(con, "Normal NINJAM", false) then return "normal" end
  if reaper.JS_Window_FindChild(con, "Voice Chat", false) then return "voice" end
end

-- ReaNINJAM's metronome mute button (its "metromute" control, id 1014): one click toggles it. Its state isn't
-- readable, so the panel offers a toggle (an instance opened before live.configure ran keeps its own setting).
function live.toggle_click()
  local con = reaper.JS_Window_Find and reaper.JS_Window_Find("ReaNINJAM", true)
  if not con then return false end
  reaper.JS_WindowMessage_Send(con, "WM_COMMAND", 1014, 0, 0, 0)
  return true
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
    -- NINJAM's metronome ticks at the server's tempo all the time you're connected, transport or not: only Jam
    -- (everyone playing to NINJAM's own clock) needs it
    metromute = mode == "jam" and "0" or "1",
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
  -- the master first (where BandSync puts it), then any track (someone may listen on a track of their own)
  for t = -1, reaper.CountTracks(proj) - 1 do
    local tr = t < 0 and master or reaper.GetTrack(proj, t)
    for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, name = reaper.TrackFX_GetFXName(tr, i)
      if name:find(fx, 1, true) and not name:find("Instrument", 1, true) then
        if freed > 0 then reaper.TrackFX_SetOffline(tr, i, true); reaper.TrackFX_SetOffline(tr, i, false) end -- load it now that it may
        return tr, i
      end
    end
  end
  if not add then return nil end
  if fx == live.SONOBUS then -- Real time mode: SonoBus on a track of its own, fed only by what's armed (live.rt_sends)
    local rt = live.rt_track(proj, true)
    local i = reaper.TrackFX_AddByName(rt, "VST3:SonoBus (Sonosaurus)", false, -1)
    if i < 0 then i = reaper.TrackFX_AddByName(rt, "SonoBus (Sonosaurus)", false, -1) end -- VST2 / AU
    if i < 0 then return nil end
    -- its Dry Level passes what it's fed straight through: the armed tracks already reach the master themselves
    for p = 0, reaper.TrackFX_GetNumParams(rt, i) - 1 do
      if select(2, reaper.TrackFX_GetParamName(rt, i, p, "")) == "Dry Level" then reaper.TrackFX_SetParamNormalized(rt, i, p, 0) end
    end
    return rt, i
  end
  local i = reaper.TrackFX_AddByName(master, fx, false, -1)
  if i < 0 then return nil end
  return master, i
end

-- Real time mode's own track: SonoBus sits on it, it hears only what's armed here (sends from those tracks), and what
-- SonoBus brings in (the bandmates' live playing) goes on to the master. This machine's alone: never mirrored.
live.RT_NAME = "BandSync Real time"
function live.rt_track(proj, add)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) == "realtime" then return tr end
  end
  if not add then return nil end
  local idx = reaper.CountTracks(proj)
  reaper.InsertTrackInProject(proj, idx, 0)
  local tr = reaper.GetTrack(proj, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", live.RT_NAME, true)
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "realtime", true)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 1)
  return tr
end

-- Keep Real time mode's sends in step with what's armed: an armed track feeds SonoBus, nothing else does (the
-- backing is everyone's own copy of the song, so sending it too made everyone hear it twice, out of time).
-- Returns how many tracks feed it.
function live.rt_sends(proj)
  local rt = live.rt_track(proj, false)
  if not rt then return 0 end
  -- its receives, in order, by source track number (the chunk's AUXRECV lines: core REAPER can't hand a send's
  -- track to Lua without SWS, which not every bandmate has)
  local _, chunk = reaper.GetTrackStateChunk(rt, "", false)
  local from = {}
  for idx in chunk:gmatch("\n%s*AUXRECV (%d+)") do from[#from + 1] = tonumber(idx) end
  local fed = {}
  for r = #from, 1, -1 do -- from the end, so the receive numbers stay right while removing
    local src = reaper.GetTrack(proj, from[r])
    if src and reaper.GetMediaTrackInfo_Value(src, "I_RECARM") == 1 and not fed[src] then fed[src] = true
    else reaper.RemoveTrackSend(rt, -1, r - 1) end
  end
  local n = 0
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if tr ~= rt and reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then
      n = n + 1
      if not fed[tr] then reaper.CreateTrackSend(tr, rt) end
    end
  end
  return n
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

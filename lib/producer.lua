-- The producer's seat (James, 2026-11-04): one person records on their own grid, and another hears it on theirs, lined up, as it happens, a moment
-- behind, from their own copy of the song. Their transport follows (never records), and the take itself replaces the stream when it lands.
-- Two ways to carry the sound, both by song position:
--   stamp: SonoBus with position bursts (lib/stamp.lua). No server. The default.
--   ninjam: ReaNINJAM's session mode on a mic-only feed. Needs a NINJAM server both can reach, over Tailscale.
-- Producing someone is this computer's own business; their computer sees it in your status file and sends what's needed (producer.answer).
local band = require("band")
local producer = {}

producer.LAG = { stamp = 1.5, ninjam = 4 } -- seconds behind, to start with
producer.MIN_LAG, producer.MAX_LAG = 0.5, 30

local function ext(proj, k) return select(2, reaper.GetProjExtState(proj, band.SECTION, k)) end
local function key(proj) return "produce " .. tostring(proj) end
function producer.who(proj)
  local n = reaper.GetExtState(band.SECTION, key(proj))
  return n ~= "" and n or nil
end
function producer.via(proj) return ext(proj, "produce via") == "ninjam" and "ninjam" or "stamp" end
function producer.set_via(proj, via) reaper.SetProjExtState(proj, band.SECTION, "produce via", via) end
function producer.lag(proj) return tonumber(ext(proj, "produce lag")) or producer.LAG[producer.via(proj)] end
function producer.set_lag(proj, s)
  s = math.max(producer.MIN_LAG, math.min(producer.MAX_LAG, s))
  reaper.SetProjExtState(proj, band.SECTION, "produce lag", string.format("%.1f", s))
end
-- How far behind this tab runs, if it's producing `name` (who the cue is from); else nil.
function producer.behind(proj, name)
  if producer.who(proj) == name then return producer.lag(proj) end
end

local function pair_of(proj, name) return require("hear").pairs(proj)[name] or 0 end

local function talk_track(proj, add)
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    if select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_local", "", false)) == "talkback" then return tr end
  end
  if not add then return nil end
  local tr = require("mirror").add_local_track(proj, "StudioSync talkback", "talkback")
  reaper.SetMediaTrackInfo_Value(tr, "I_RECINPUT", 0) -- (the first input, mono)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMODE", 2) -- (never makes a file, should someone press record)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECMON", 1)
  reaper.SetMediaTrackInfo_Value(tr, "I_RECARM", 1)
  reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0) -- (they don't need to hear themselves)
  reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
  return tr
end
function producer.talking(proj)
  local tr = talk_track(proj, false)
  return tr ~= nil and reaper.GetMediaTrackInfo_Value(tr, "B_MUTE") == 0
end
function producer.talk(proj, on)
  local tr = talk_track(proj, on)
  if tr then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", on and 0 or 1) end
end

-- The NINJAM route: ReaNINJAM in session mode on the Real time track, so what goes out is what's armed, not the whole mix. Connecting is one click in its window.
-- shortcut: its window's Connect stays a person's click: nothing in its ini connects by itself. Not yet tried end to end, for want of a server both can reach.
local function ninjam_on(proj, cfg, b, send)
  local live, setup = require("live"), require("setup")
  local server = (band.read_json(setup.live_file(cfg, b)) or {}).server or ""
  if server == "" then return nil, "There's no NINJAM server set for this song: turn on the Play tab (Settings > Advanced) and set it there, or use the SonoBus route." end
  if b.role == "host" then
    local up, why = require("services").ensure_ninjam() -- (as the Play tab's Connect does)
    if not up then return nil, "NINJAM server: " .. why end
  end
  local sdir = (reaper.GetProjectName(proj) ~= "" and reaper.GetProjectPathEx(proj) or reaper.GetResourcePath()):gsub("\\", "/") .. "/bandsync_live"
  reaper.RecursiveCreateDirectory(sdir, 0)
  reaper.SetProjExtState(proj, band.SECTION, "live_dir", sdir)
  local ok, e = live.configure(cfg, server, "synced", send, sdir)
  if not ok then return nil, e end
  local rt = live.rt_track(proj, true)
  local tr, i = live.fx(proj, false)
  if tr and tr ~= rt then reaper.TrackFX_Delete(tr, i); tr = nil end
  if not tr then
    live.fx(proj, false) -- (REAPER runs one per process: another tab's goes first, as live.fx does)
    for p = 0, math.huge do
      local other = reaper.EnumProjects(p)
      if not other then break end
      if other ~= proj then
        local m, x = live.fx(other, false)
        if m then reaper.TrackFX_Delete(m, x) end
      end
    end
    i = reaper.TrackFX_AddByName(rt, live.FX, false, -1)
    if i < 0 then return nil, "Couldn't add ReaNINJAM to the Real time track." end
    tr = rt
  end
  reaper.TrackFX_Show(tr, i, 3)
  return true
end

-- Start producing `name`: follow their transport, a little behind, and hear them by position.
function producer.start(proj, cfg, b, name)
  local via = producer.via(proj)
  if via == "ninjam" then
    local ok, why = ninjam_on(proj, cfg, b, false)
    if not ok then return nil, why end
  else
    local link, why = require("setup").sonobus(cfg, b, proj, true)
    if not link then return nil, why end
    if not require("stamp").read(proj, true, pair_of(proj, name)) then return nil, "Couldn't put StudioSync's stamp reader on the Real time track." end
  end
  reaper.SetExtState(band.SECTION, key(proj), name, false)
  reaper.SetExtState(band.SECTION, "follow " .. tostring(proj), name, false)
  reaper.SetExtState(band.SECTION, "follow driver", "", true)
  band.log(string.format("producing %s: you follow them about %.1f s behind and hear them on your grid. They needn't do anything", name, producer.lag(proj)))
  return true
end
function producer.stop(proj, cfg, b)
  local name = producer.who(proj)
  reaper.DeleteExtState(band.SECTION, key(proj), false)
  if reaper.GetExtState(band.SECTION, "follow " .. tostring(proj)) == name then reaper.DeleteExtState(band.SECTION, "follow " .. tostring(proj), false) end
  require("stamp").read(proj, false)
  local tr = talk_track(proj, false)
  if tr then reaper.DeleteTrack(tr) end
  producer.quiet_tracks(proj, {})
  local live = require("live")
  local sm, si = live.fx(proj, false, live.SONOBUS)
  if sm and ext(proj, "side") ~= "0" and reaper.GetExtState(band.SECTION, "listen " .. tostring(proj)) == "" and not require("hear").listeners_here then
    reaper.TrackFX_SetOffline(sm, si, true)
  end
  band.log("stopped producing " .. tostring(name))
end

-- What's being sung over stays quiet here while it's sung: pass 1 under pass 2, doubled. Only here: the track's own mute is what's kept and sent.
function producer.quiet_tracks(proj, names)
  local want = {}
  for _, n in ipairs(names) do want[n:gsub(" %(band%)$", ""):gsub(" %(studio%)$", "")] = true end
  for t = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, t)
    local held = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_quiet", "", false))
    local name = select(2, reaper.GetTrackName(tr)):gsub(" %(band%)$", ""):gsub(" %(studio%)$", "")
    local local_one = require("mirror").local_track(tr)
    if want[name] and not local_one then
      if held == "" then
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_quiet", tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"))), true)
        reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
      end
    elseif held ~= "" then
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", tonumber(held) or 0)
      reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_quiet", "", true)
    end
  end
end

-- This computer, about once a second, on both sides of it.
local started_sending = {}
function producer.tick(proj, cfg, b, peers)
  local stamp = require("stamp")
  -- someone's producing me: stamps go out for as long as they do
  local tab, by = tostring(proj), {}
  local through_ninjam = false
  for _, st in ipairs(peers) do
    if st.produce == cfg.user then
      by[#by + 1] = st.user
      through_ninjam = through_ninjam or st.produce_via == "ninjam"
    end
  end
  local now = table.concat(by, ", ")
  local was = reaper.GetExtState(band.SECTION, "produced by " .. tab)
  if now ~= was then
    reaper.SetExtState(band.SECTION, "produced by " .. tab, now, false)
    if now ~= "" then band.log(now .. " is producing you: they hear you on their grid, a moment behind")
    else band.log("nobody's producing you now") end
  end
  if now ~= "" and through_ninjam then
    if was ~= now then
      local ok, why = ninjam_on(proj, cfg, b, true)
      band.log(ok and (now .. " hears you through the NINJAM server: press Connect in ReaNINJAM's window") or (now .. " wants to hear you, but: " .. tostring(why)))
    end
  elseif now ~= "" then
    local live, m, i = require("live"), nil, nil
    m, i = live.fx(proj, false, live.SONOBUS)
    if not m or reaper.TrackFX_GetOffline(m, i) then
      local link, why = require("setup").sonobus(cfg, b, proj, true)
      if not link then return band.log(now .. " wants to hear you, but: " .. tostring(why)) end
      started_sending[tab] = true
    end
    local inp, out = reaper.GetInputOutputLatency()
    local srate = reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
    if srate <= 0 then srate = tonumber(select(2, reaper.GetAudioDeviceInfo("SRATE"))) or 48000 end
    stamp.send(proj, true, ((inp or 0) + (out or 0)) / srate * 1000)
    reaper.SetExtState(band.SECTION, "stamping " .. tab, "1", false)
  elseif was ~= "" then
    stamp.send(proj, false)
    reaper.DeleteExtState(band.SECTION, "stamping " .. tab, false)
    if started_sending[tab] then
      started_sending[tab] = nil
      local live = require("live")
      local m, i = live.fx(proj, false, live.SONOBUS)
      if m and ext(proj, "side") ~= "0" then reaper.TrackFX_SetOffline(m, i, true) end
    end
  end
  -- anyone's stamps on their right channel: everyone else hears their voice, not the bursts
  local hear, pairs_here, mask = require("hear"), require("hear").pairs(proj), 0
  for _, st in ipairs(peers) do
    if st.stamping then
      local start = pairs_here[st.user] or 0
      mask = mask | (1 << (start // 2))
    end
  end
  hear.set_stamped(proj, mask)
  -- I'm producing someone
  local name = producer.who(proj)
  if not name then return end
  stamp.read(proj, producer.via(proj) == "stamp", pair_of(proj, name))
  local them
  for _, st in ipairs(peers) do if st.user == name then them = st end end
  -- what's being sung over goes quiet here while they're recording, and comes back when the take's here
  producer.quiet_tracks(proj, them and them.recording and type(them.armed) == "table" and them.armed or {})
end

-- A start the stream itself told us about: faster than the shared folder. -> a cue like Live sync's own, or nil. Pure. seen: what was last acted on.
-- st: stamp.status(); now: the wall clock; lag: how far behind; playing: this transport's going.
function producer.fast_cue(st, seen, name, now, lag, playing)
  if not st.active or playing or st.count == seen then return nil end
  local from = math.max(0, st.pos - 0.5)
  return { type = "start", at = now - 0.4, pos = from, countin = 0, lead = name, follow = true, lag = lag, id = "stamp-" .. tostring(st.count), from_stream = true }
end

-- What to say, on the producer's side. -> list of { text, kind } (kind: "ok", "wait", "bad"). Pure apart from the reader.
function producer.lines(proj, name, them, st, playing, cursor)
  local out = {}
  local via = producer.via(proj)
  out[#out + 1] = { string.format("Following %s, about %.1f s behind", name, producer.lag(proj)), "ok" }
  if not them or them.state == "offline" then out[#out + 1] = { name .. " isn't here right now", "wait" }; return out end
  if via == "stamp" then
    if st.active and playing then
      local gap = st.written - st.at
      out[#out + 1] = gap >= 0 and { "Hearing them", "ok" } or { "You've caught up with them: more lag would give it room", "bad" }
    elseif st.active then out[#out + 1] = { name .. " is playing: starting", "wait" }
    elseif playing and st.written > st.at then out[#out + 1] = { string.format("They stopped: %.0f s to go", st.written - st.at), "wait" }
    else out[#out + 1] = { "Talkback open", "ok" } end
  end
  if them.mirror and them.my_mirror and them.mirror ~= them.my_mirror then out[#out + 1] = { "Your copy differs from theirs just now", "wait" } end
  return out
end

return producer

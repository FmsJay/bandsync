-- @description BandSync: live sync for this project (runs in the background; run again to stop)
-- Keeps this project in step with the band:
--   * your new recordings go out by themselves a moment after you stop (slivers under 0.5 s are skipped);
--     what was already in the project when sync first ran stays put (send it with "Send takes" if wanted)
--   * everyone's takes arrive in the song's comping style (lanes or takes), preview first, then full quality
--   * the session driver's deletes, moves/trims and which take or lane plays are mirrored here
-- Never touches the project while recording.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")
local live = require("live")
local together = require("together")
local transport -- a pending start/stop (lib/together.lua)
local clip_said -- when we last warned about the master clipping
local due_in = math.huge -- seconds until a pending start/stop fires

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
-- A side-by-side stop fires when our playhead reaches the leader's stop position, on two readings in a row: the
-- play position can read a few hundred ms off for a moment (seen on the laptop: 6.418 -> 6.112 -> 6.446 in 2 ms).
local past = 0
local function reached(t, theirs)
  if not (t.type == "stop" and t.follow and theirs and t.pos and reaper.GetPlayStateEx(proj) & 1 == 1) then past = 0; return false end
  past = reaper.GetPlayPosition2Ex(proj) >= t.pos - 0.005 and past + 1 or 0
  return past >= 2
end
local b = band.binding(proj)
if not b then return band.msg("Publish (host) or open (guest) a session in this project first.") end
local host = b.role == "host"
local s0 = band.read_json(band.session_path(cfg, b.song)) or {}
local mode = b.take_mode or "mirror" -- rebuild each sender's lanes and multi-take items as they are
local baseline = sync.mark_baseline(proj)
sync.audio_follow_tempo(proj) -- band audio follows tempo changes piece by piece (REAPER auto-stretch), never drifting

-- Side by side (panel, Together tab): press play/stop/record as usual; every machine with it on follows, `lag`
-- seconds behind whoever pressed (0 with Listen live; a bar or two with Play along, so you hear them in time with
-- the song). Non-persistent ExtState "side <proj>" = lag in bars ("" = off).
local side = { playing = false, pos = 0, t = 0, quiet_until = 0 }
local function side_bars()
  local v = reaper.GetExtState(band.SECTION, "side " .. tostring(proj))
  return v ~= "" and (tonumber(v) or 0) or nil
end
-- A count-in click: the metronome on until the song reaches `upto` (then back as it was).
local click
local function click_until(upto)
  if reaper.GetToggleCommandStateEx(0, 40364) ~= 1 then
    reaper.Main_OnCommand(40364, 0) -- Options: Toggle metronome
    click = upto
  end
end


-- the shared folder only moves while Syncthing runs: start it if it isn't (a cloud-drive root needs nothing)
for _, d in ipairs(band.subdirs(cfg.root)) do
  if d == ".stfolder" then -- Syncthing marks the folders it shares with this
    local ok, why = require("services").ensure_syncthing()
    if ok == "started" then band.log("started Syncthing") elseif not ok then band.log("Syncthing: " .. why) end
  end
end

local _, _, section, cmd = reaper.get_action_context()
local function toggle(v)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, v); reaper.RefreshToolbar2(section, cmd) end
end
toggle(1)
reaper.atexit(function() toggle(0) end)

local sizes, warned_version, last, recording, stopped_at = {}, nil, 0, false, 0
local last_reprint, last_status, status_json = 0, 0, ""
-- A file is ready once it exists, is non-empty, and its size held still across two polls.
local function ready(path)
  local n = band.size(path)
  local ok = n and n > 0 and sizes[path] == n
  sizes[path] = n
  return ok
end

-- what sync itself just placed or updated is the band's state, not a local edit (else it'd be sent, or put back)
local function remember(id)
  local hit = band.take_index(proj)[id:lower()]
  if hit then sync.remember(proj, id, hit[1], hit[2]) end
end

-- someone else's wet print carries `tail` seconds of reverb/delay past its end: our item is that much longer
-- (returns the path for update_take, or a copy of t with the longer length for place_take)
local function with_tail(t, path)
  sync.setext(proj, sync.TAILS, t.id, tostring(t.tail or 0))
  if path then
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    c.len = t.len + (t.tail or 0)
    return c
  end
  t.len, t.tailed = t.len + (t.tail or 0), true
  return nil
end

local function import(room)
  local tdir = band.takes_dir(cfg, b.song, room)
  for _, f in ipairs(band.files(tdir, ".json")) do
    local t = band.read_json(tdir .. "/" .. f)
    if t and t.id and t.full then
      band.check_version(t.bandsync, "A take from " .. t.user, true)
      t.pos = sync.here(proj, t.pos, t.qn) -- by beat: right even if a tempo change crossed paths with it
      local state = band.take_state(proj, t.id)
      local full, prev = tdir .. "/" .. t.full, t.preview and (tdir .. "/" .. t.preview)
      local dry = t.dry and (tdir .. "/" .. t.dry)
      local rev, held = t.rev or 1, tonumber(sync.ext(proj, sync.REV, t.id)) or 1
      local midi = t.midi and (tdir .. "/" .. t.midi)
      local function place_midi() -- the notes, as an editable MIDI copy under the print
        if not midi or not reaper.file_exists(midi) then return end
        local notes = t
        if t.tailed then -- the copy holds the notes only, without the print's reverb tail
          notes = {}
          for k, v in pairs(t) do notes[k] = v end
          notes.len = t.len - (t.tail or 0)
        end
        local _, mtk = band.place_midi(proj, notes, midi, cfg.root)
        if mtk then sync.midi_seen(proj, t.id, mtk) end
        if mtk and t.no_instrument then
          band.log(string.format("%s's MIDI on '%s' came without an instrument, so its print is silent: put one on '%s (MIDI)' to hear it (Print my MIDI shares that)",
            t.user, t.track, t.track))
        end
      end
      local _, mine = band.find_take(proj, t.id)
      if mine and band.take_ext(mine, "band_sent") == "" then mine = nil end
      if state == "full" and rev > held and mine then -- someone printed our MIDI take with their instrument
        sync.setext(proj, sync.REV, t.id, tostring(rev))
        sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
        band.log(string.format("%s printed your take %s with their own sound: the band hears theirs now", tostring(t.printed_by), t.id))
      elseif state == "full" and rev > held then -- reprinted (FX/volume/note change): update in place
        if ready(full) and (not dry or ready(dry)) then
          reaper.Undo_BeginBlock2(proj)
          local ok = band.update_take(proj, t, (with_tail(t) or full), dry)
          if ok then place_midi(); remember(t.id) end
          reaper.Undo_EndBlock2(proj, "BandSync: updated take from " .. t.user, -1)
          if ok then
            sync.setext(proj, sync.REV, t.id, tostring(rev))
            sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
            band.log(string.format("take from %s updated (revision %d%s) -> %s", t.user, rev,
              (t.printed_by and t.printed_by ~= t.user) and (", printed by " .. t.printed_by) or "", t.track))
          end
        end
      elseif state ~= "full" and state ~= "deleted" then -- "full" also covers takes this project sent itself
        local want, path
        if ready(full) and (not dry or ready(dry)) then want, path = "full", full
        elseif state == "" and prev and ready(prev) then want, path = "preview", prev end
        if want then
          reaper.Undo_BeginBlock2(proj)
          local ok = band.place_take(proj, with_tail(t, path), path, mode, want == "full" and dry or nil)
          if ok then place_midi(); remember(t.id) end
          reaper.Undo_EndBlock2(proj, "BandSync: " .. want .. " take from " .. t.user, -1)
          if ok then
            band.set_take_state(proj, t.id, want)
            sync.setext(proj, sync.REV, t.id, tostring(rev))
            sync.setext(proj, sync.PRINTER, t.id, t.printed_by or "")
            local pending = sync.ext(proj, sync.PENDING, t.id) -- brought back by a recall point: put it where that had it
            if pending ~= "" then
              local p = band.json_decode(pending)
              if p then sync.apply(proj, { type = "edit", take = t.id, track = p.track, pos = p.pos, len = p.len, lane = p.lane, mute = p.mute, offs = p.offs }) end
              sync.setext(proj, sync.PENDING, t.id, "")
            end
            band.log(string.format("%s take from %s (%s) -> %s", want, t.user, room, t.track))
          end
        end
      end
    end
  end
end

local last_driver
local function poll()
  local s = band.read_json(band.session_path(cfg, b.song))
  local can, who = sync.authority(cfg, b.song, b.room, s)
  local driver = who.driver
  if last_driver and driver ~= last_driver then -- handovers are announced, never silent
    band.log(driver == cfg.user and "you're driving now" or (tostring(driver) .. " took control" ..
      (last_driver == cfg.user and ": you're no longer driving (what you don't own is view-only)" or "")))
  end
  last_driver = driver
  local rooms = host and band.subdirs(band.song_dir(cfg, b.song) .. "/rooms") or { b.room }
  for _, room in ipairs(rooms) do
    import(room)
    local room_can = room == b.room and can or sync.authority(cfg, b.song, room, s)
    local n = sync.receive(proj, cfg, b.song, room, room_can)
    if n > 0 then band.log(n .. " change(s) from the band (" .. room .. ")") end
  end

  -- Hold sync: keep working without sending anything; releasing it sends the net result once
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""

  -- our own new recordings go out once the transport has been stopped for a moment, and takes whose
  -- sound changed are reprinted (rendering needs this tab in front and the transport stopped)
  local print_mode = (s and s.print) or "wet"
  local now = reaper.time_precise()
  local copies = sync.split_copies(proj) -- pasted/duplicated/split items: new material, not the original
  if copies > 0 then band.log(copies .. " copied or split item(s) will go out as new takes") end
  if not hold and reaper.EnumProjects(-1) == proj and reaper.GetPlayStateEx(proj) == 0 and now - stopped_at > 1.5 then
    local units = sync.own_takes(proj, { all = true, unsent = true, min_len = sync.MIN_LEN })
    if #units > 0 then band.log("sent " .. sync.send(proj, cfg, b, units, print_mode) .. " new take(s)") end
    if now - last_reprint > 10 then
      last_reprint = now
      local n = sync.reprint(proj, cfg, b, print_mode)
      if n > 0 then band.log("reprinted " .. n .. " take(s) after a sound change") end
    end
  end

  -- live (ReaNINJAM synced mode): received clips land as placeholders until the real takes replace them
  local live_dir = select(2, reaper.GetProjExtState(proj, band.SECTION, "live_dir"))
  if live_dir == "" and reaper.GetProjectName(proj) ~= "" then live_dir = reaper.GetProjectPathEx(proj):gsub("\\", "/") .. "/bandsync_live" end -- set up by hand: the usual place
  if live_dir ~= "" and live.fx(proj, false) then
    live.note_clips(proj, live_dir) -- when each clip arrived, so only takes recorded then replace it
    local added, retired = live.place_clips(proj, live_dir), live.retire(proj)
    if added + retired > 0 then reaper.Undo_OnStateChange2(proj, "BandSync: live placeholders") end -- one undo point, only when something changed
    if added > 0 then band.log(added .. " live clip(s) placed as placeholders") end
    if retired > 0 then band.log(retired .. " placeholder(s) replaced by the real takes") end
  end

  -- what we may change (owned tracks/regions, or everything unclaimed while driving) goes out; the rest
  -- is view-only (locked) so it can't silently drift from the band's version
  if not hold then sync.watch(proj, cfg, b.song, b.room, can) end
  sync.apply_locks(proj, can, cfg.user)

  -- status receipt for the Status window: written when it changes, else every 15 s as a heartbeat
  -- pending + hold let "Take control" wait until everyone has caught up before switching
  local armed = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local info = { driver = driver, role = b.role, song = b.song, hold = hold or nil,
    pending = sync.pending_events(proj, cfg, b.song, b.room), armed = armed, side = side_bars(),
    playing = reaper.GetPlayStateEx(proj) & 1 == 1 or nil }
  local fingerprint = band.json_encode(sync.holdings(proj)) .. tostring(driver) .. info.pending .. tostring(hold) .. band.json_encode(armed) ..
    tostring(info.side) .. tostring(info.playing)
  if fingerprint ~= status_json or now - last_status > 15 then
    status_json, last_status = fingerprint, now
    sync.write_status(proj, cfg, b.song, b.room, info)
  end

  if s then band.check_version(s.bandsync, "'" .. b.song .. "'", true) end
  if s and not host then
    if band.sync_stems(proj, cfg, b.song, s, true) > 0 then band.log("upgraded stems to full quality") end
    if tostring(s.version) ~= tostring(b.version) and warned_version ~= s.version then
      warned_version = s.version
      band.log(s.host .. " published v" .. s.version .. ": run 'BandSync - Open session' to refresh")
    end
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

-- The panel stops us with a flag (re-running the action would raise REAPER's task-control dialog), and sees
-- we're alive from a heartbeat; both live in non-persistent ExtState so the project isn't marked modified.
local key = tostring(proj)
-- Start/stop events: looked for every 0.25 s by name alone (a file listing), read only when new.
local fired, seen_ev, quick_at = {}, {}, 0
-- The newest cue wins: an older one (a second copy arriving through the regular poll, say) is ignored.
local cue_at = -math.huge
local function take_cue(ev)
  if not ev or (ev.id and fired[ev.id]) or (ev.follow and not side_bars()) or (ev.at or 0) < cue_at then return end
  cue_at, transport = ev.at or cue_at, ev
end

local function quick_transport()
  local dir = sync.room_dir(cfg, b.song, b.room) .. "/events"
  local i, found = 0, nil
  reaper.EnumerateFiles(dir, -1) -- re-read the folder (REAPER caches listings)
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    i = i + 1
    if not seen_ev[f] then
      seen_ev[f] = true
      if f:sub(-5) == ".json" and not f:lower():find("^" .. (cfg.user:gsub(" ", "_"):lower():gsub("%p", "%%%0")) .. "%-") then
        local ev = band.read_json(dir .. "/" .. f)
        if ev and (ev.type == "start" or ev.type == "stop") and not fired[ev.id] and together.now() - (ev.at or 0) < 30 then found = ev end
      end
    end
  end
  return found
end
do -- what's already there is history, not a cue
  local dir, i = sync.room_dir(cfg, b.song, b.room) .. "/events", 0
  reaper.EnumerateFiles(dir, -1)
  while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end; seen_ev[f] = true; i = i + 1 end
end
-- BandSync - Autostart.lua restarts us for this project after REAPER restarts, until the person stops us
local autokey = "autosync " .. (select(2, reaper.EnumProjects(-1)) or ""):lower()
if autokey ~= "autosync " then reaper.SetExtState(band.SECTION, autokey, "1", true) end
local function tick()
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end -- project closed: stop
  local now_b = band.binding(proj)
  if not now_b or now_b.role ~= b.role or now_b.song ~= b.song then -- became a solo working copy (or unbound): not ours any more
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    return band.log("live sync stopped: this tab is now " .. (now_b and now_b.role == "solo" and "a Solo edit working copy" or "no longer this session"))
  end
  if reaper.GetExtState(band.SECTION, "stop " .. key) ~= "" then
    reaper.DeleteExtState(band.SECTION, "stop " .. key, false)
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    reaper.DeleteExtState(band.SECTION, autokey, true)
    return band.log("live sync stopped for '" .. b.song .. "'")
  end
  reaper.SetExtState(band.SECTION, "live " .. key, tostring(reaper.time_precise()), false)
  -- the band's takes add up on your master: say so when it clips (at most every 30 s)
  if reaper.EnumProjects(-1) == proj and reaper.GetPlayState() & 1 == 1 then
    local m = reaper.GetMasterTrack(proj)
    local peak = math.max(reaper.Track_GetPeakInfo(m, 0), reaper.Track_GetPeakInfo(m, 1))
    if peak >= 0.999 and reaper.time_precise() - (clip_said or -1e9) > 30 then
      clip_said = reaper.time_precise()
      band.log(string.format("your master is clipping at %.2f s: pull the master (or the loudest tracks) down", reaper.GetPlayPosition2Ex(proj)))
    end
  end
  together.tick()
  local tjson = reaper.GetExtState(band.SECTION, "transport " .. key) -- a start/stop from the panel or the band
  if tjson ~= "" then
    reaper.DeleteExtState(band.SECTION, "transport " .. key, false)
    take_cue(band.json_decode(tjson))
  end
  if not transport and reaper.time_precise() - quick_at > 0.25 then -- a start/stop can't wait for the 2 s poll
    quick_at = reaper.time_precise()
    take_cue(quick_transport())
  end
  if transport then
    local tnow = together.now()
    local theirs = transport.lead and transport.lead ~= cfg.user
    local fire = transport.type == "stop" and ((transport.at or 0) + (theirs and (transport.lag or 0) or 0)) or together.plan(transport, cfg.user, nil)
    if transport.type == "stop" and transport.follow and theirs and transport.pos then fire = fire + 2 end -- the position decides; time is a backstop
    if transport.type == "start" and tnow < fire then reaper.SetExtState(band.SECTION, "together_at " .. key, tostring(fire), false) end
    due_in = fire - tnow -- the regular poll can take 100-200 ms: it waits while a start/stop is close
    if tnow - fire > 30 then -- arrived long after the fact (offline, sync stalled): don't start a song out of nowhere
      band.log(string.format("missed a %s from %s (%.0f s ago)", transport.type, tostring(transport.user), tnow - fire))
      transport = nil
    elseif tnow >= fire or reached(transport, theirs) then -- a follower stops where the leader stopped
      if transport.type == "stop" then
        local at_pos = reaper.GetPlayPosition2Ex(proj)
        reaper.OnStopButtonEx(proj)
        band.log(string.format("stopped together (%s) at %.3f s, %s", tostring(transport.user), at_pos,
          tnow >= fire and "by time" or string.format("by position (theirs: %.3f s)", transport.pos)))
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. "stopped together (" .. tostring(transport.user) .. ")", false)
      else
        local _, from = together.plan(transport, cfg.user, tnow) -- a few ms (or seconds) late: as far in as time has gone
        if reaper.GetPlayStateEx(proj) ~= 0 then reaper.OnStopButtonEx(proj) end
        reaper.SetEditCurPos2(proj, from, false, false)
        if transport.click and (transport.countin or 0) > 0 then click_until(transport.pos or from) end
        if transport.rec and not (transport.follow and theirs) then -- side by side: the one who records records, the rest listen
          reaper.SelectProjectInstance(proj)
          reaper.Main_OnCommand(1013, 0) -- Transport: Record (the active project)
        else
          reaper.OnPlayButtonEx(proj)
        end
        local said = transport.rec and transport.follow and theirs
          and string.format("playing along with %s's recording from %.2f s (%.0f ms after the planned moment)", tostring(transport.user), from, (tnow - fire) * 1000)
          or string.format("%s together from %.2f s (%s; %.0f ms after the planned moment)", transport.rec and "recording" or "playing",
            from, tostring(transport.user), (tnow - fire) * 1000)
        band.log(said)
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. said, false) -- the panel shows it
      end
      if transport.id then fired[transport.id] = true end -- the regular poll applies the same event again later
      reaper.DeleteExtState(band.SECTION, "together_at " .. key, false)
      side.quiet_until = reaper.time_precise() + 1 -- what we just did isn't a press to pass on
      transport = nil
    end
  end
  if click and (reaper.GetPlayStateEx(proj) & 1 == 0 or reaper.GetPlayPosition2Ex(proj) >= click) then
    if reaper.GetToggleCommandStateEx(0, 40364) == 1 then reaper.Main_OnCommand(40364, 0) end
    click = nil
  end
  local lagbars = side_bars()
  if lagbars then
    local ps = reaper.GetPlayStateEx(proj)
    local playing, pos, tp = ps & 1 == 1, reaper.GetPlayPosition2Ex(proj), reaper.time_precise()
    if tp >= side.quiet_until then
      local jumped = playing and side.playing and math.abs(pos - (side.pos + (tp - side.t))) > 0.5 -- a seek while playing
      if playing ~= side.playing or jumped then
        local ev = playing and { type = "start", pos = pos, countin = 0, rec = ps & 4 == 4 or nil }
          or { type = "stop", pos = side.pos + (tp - side.t) } -- where the song was when you stopped
        ev.at, ev.lead, ev.follow = together.now(), cfg.user, true
        ev.lag = together.bars_after(proj, pos, lagbars)
        sync.post(cfg, b.song, b.room, ev)
        fired[ev.id], cue_at = true, math.max(cue_at, ev.at)
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. (playing and string.format("you %s from %.2f s: the band follows %.1f s behind",
          ev.rec and "recorded" or "played", pos, ev.lag) or "you stopped: the band stops too"), false)
      end
    end
    side.playing, side.pos, side.t = playing, pos, tp
  end
  local st = reaper.GetPlayStateEx(proj)
  if st & 4 ~= 0 then recording = true
  elseif recording then recording, stopped_at = false, reaper.time_precise() end
  local now = reaper.time_precise()
  local every = reaper.GetPlayStateEx(proj) & 1 == 1 and 2 -- playing: a pass can stall REAPER ~0.5 s (seen on the laptop)
    or (lagbars or now - stopped_at < 8) and 0.5 or 2 -- side by side, or just after a recording: look often
  if not recording and now - last > every and not (transport and due_in < 1.5) then
    last = reaper.time_precise()
    local ok, err = pcall(poll)
    if not ok then band.log("sync error: " .. tostring(err)) end
  end
  reaper.defer(tick)
end

band.log(string.format("live sync for '%s' (%s, room %s, takes as %s, driver %s)%s", b.song, b.role, b.room, mode,
  tostring(sync.driver(cfg, b.song, b.room, s0)), baseline > 0 and (", " .. baseline .. " existing take(s) left as baseline") or ""))
tick()

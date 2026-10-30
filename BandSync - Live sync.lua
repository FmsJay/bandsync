-- @description BandSync: live sync for this project (runs in the background; the panel's Stop stops it)
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
local files_checked -- when our own prints in the shared folder were last checked

local cfg = band.settings()
if not cfg then return end
local proj = BANDSYNC_LIVE_PROJ or reaper.EnumProjects(-1) -- (set when an update reloads us: our tab, not the front one)
BANDSYNC_LIVE_PROJ = nil
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
-- one Live sync per song tab: triggering this action again while it runs does nothing (no "terminate instances?"
-- box); another tab's runs from a launcher action of its own (band.start_live), and starting it again for this tab
-- only says so
if reaper.set_action_options then reaper.set_action_options(2) end
local beat0 = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
if beat0 and reaper.time_precise() - beat0 < 5 then return band.log("Live sync is already running for '" .. b.song .. "'") end
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
  local v = select(2, reaper.GetProjExtState(proj, band.SECTION, "side")) -- saved with the song: a reopened tab keeps it
  local old = reaper.GetExtState(band.SECTION, "side " .. tostring(proj)) -- (set per tab before 0.11.3: carried over once)
  if old ~= "" then
    reaper.DeleteExtState(band.SECTION, "side " .. tostring(proj), false)
    if v == "" then v = old; reaper.SetProjExtState(proj, band.SECTION, "side", old) end
  end
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
local tune_left, tune_at = 0, 0 -- the folder's live-use settings, tried again while a Syncthing we just started comes up
for _, d in ipairs(band.subdirs(cfg.root)) do
  if d == ".stfolder" then -- Syncthing marks the folders it shares with this
    local services = require("services")
    local ok, why = services.ensure_syncthing()
    if ok == "started" then band.log("started Syncthing") elseif not ok then band.log("Syncthing: " .. why) end
    if ok then -- quick hand-off for live use (lib/services.lua): the live MIDI view a couple of seconds behind
      local set, err = services.tune_band_folder()
      if set and #set > 0 then band.log("Syncthing's band folder tuned for live use: " .. table.concat(set, ", "))
      elseif not set then
        -- just started, it doesn't answer for a few seconds (2026-10-29, laptop): try again for a few minutes
        tune_left, tune_at = 10, reaper.time_precise()
        if ok ~= "started" then band.log("Syncthing: " .. tostring(err)) end
      end
    end
  end
end

-- which plug-ins this machine has goes to the band, and the FX browser's "BandSync (everyone has)" folder follows
-- what everyone has (lib/plugins.lua); a failure here must never stop syncing
do
  local plugins = require("plugins")
  local ok, n, why = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
  if ok and n then band.log(string.format("%d plug-ins everyone in the band has: FX browser folder '%s'", n, plugins.FOLDER))
  elseif not ok then band.log("plug-in list: " .. tostring(n)) end
end

local _, _, section, cmd = reaper.get_action_context()
local function toggle(v)
  if cmd > 0 then reaper.SetToggleCommandState(section, cmd, v); reaper.RefreshToolbar2(section, cmd) end
end
toggle(1)

-- End of session: a restore point kept for good (Empty old trash never removes its audio), so the band's history
-- shows where every session ended. Saved when Live sync stops and after 20 minutes without a change (REAPER might
-- be closed hard), only when something changed since the last one.
local recall = require("recall")
local function event_count() return #band.files(sync.room_dir(cfg, b.song, b.room) .. "/events", ".json") end
local ended_at_n = event_count()
local quiet = { n = ended_at_n, since = reaper.time_precise(), checked = 0 }
local function end_of_session(why)
  local n = event_count()
  if n == ended_at_n or not reaper.ValidatePtr2(0, proj, "ReaProject*") then return end
  ended_at_n = n
  recall.save(proj, cfg, b.song, b.room, "end of session", true)
  band.log("saved an end-of-session restore point (" .. why .. "): it's kept for good")
  local droot = require("drive").root(cfg) -- and the project itself, for anyone to open from Drive (lib/sessionfile.lua)
  if droot then
    local ok, out, err = pcall(require("sessionfile").export, proj, cfg, b, droot, sync.room_dir(cfg, b.song, b.room))
    band.log(ok and out and ("end-of-session project saved to Google Drive: " .. out:match("[^/]+$")) or
      ("couldn't save the end-of-session project to Drive: " .. tostring(ok and err or out)))
  end
end
local reloaded -- this instance handed over to the updated code (which saves the end of session itself)
reaper.atexit(function()
  if not reloaded then pcall(end_of_session, "Live sync stopped") end
  toggle(0)
end)

-- Google Drive copy of the room (lib/drive.lua): what we did alone reaches the band whenever they next open the
-- song, and what they did alone reaches us. A pass every 3 minutes (sooner while a big copy is still going), only
-- while stopped: copying a long FLAC can hold up REAPER's screen for a moment.
local drive = require("drive")
local drive_at, drive_more, drive_said = -math.huge, false, nil

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

local import_failed = {} -- manifests that couldn't be imported: said once
local function import(room)
  local tdir = band.takes_dir(cfg, b.song, room)
  local idx = band.take_index(proj) -- once per pass (it walks every item and take)
  for _, f in ipairs(band.files(tdir, ".json")) do
    -- one bad manifest (truncated, hand-edited, a newer format) mustn't stop every take and event behind it
    local ok, err = pcall(function()
    local t = band.read_json(tdir .. "/" .. f)
    local missing
    for _, k in ipairs({ "id", "full", "user", "track", "pos", "len" }) do if t and t[k] == nil then missing = k; break end end
    if t and missing and missing ~= "id" and missing ~= "full" then error("it has no '" .. missing .. "'", 0) end
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
      local hit = idx[t.id:lower()]
      local mine = hit and hit[2]
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
          if ok then
            place_midi(); remember(t.id)
            if t.based_on then remember(t.based_on) end -- a shared sound grew the original's item: not an edit of it
          end
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
    end)
    if not ok and not import_failed[f] then
      import_failed[f] = true
      band.log("couldn't bring in " .. f .. ": " .. tostring(err))
    end
  end
end

local last_driver
local last_session -- a session.json caught mid-sync reads as nothing: keep the last good one
local joined = {} -- machines this Live sync has already let in
local mix_pending, mix_at -- the driver's mix layer, changed but still settling (a knob being turned)
-- Are we in the middle of editing? (the project changed in the last 2 s): the band's changes wait for a pause, so
-- none lands mid-drag. Never more than 10 s, so a long edit can't hold them up for good.
local change_count, changed_at, held_since = -1, -math.huge, nil
local function editing()
  local c = reaper.GetProjectStateChangeCount(proj)
  local t = reaper.time_precise()
  if c ~= change_count then change_count, changed_at = c, t end
  local busy = t - changed_at < 2
  if busy then held_since = held_since or t else held_since = nil end
  return busy and t - held_since < 10
end

local function poll()
  if tune_left > 0 and reaper.time_precise() - tune_at > 30 then
    tune_left, tune_at = tune_left - 1, reaper.time_precise()
    local set, err = require("services").tune_band_folder()
    if set then
      tune_left = 0
      band.log(#set > 0 and ("Syncthing's band folder tuned for live use: " .. table.concat(set, ", ")) or "Syncthing is answering")
    elseif tune_left == 0 then
      band.log("Syncthing: " .. tostring(err) .. " (Maintenance shows whether the shared folder syncs)")
    end
  end
  local s = band.read_json(band.session_path(cfg, b.song)) or last_session
  last_session = s
  local can, who = sync.authority(cfg, b.song, b.room, s)
  local driver = who.driver
  -- someone else drives and is here (their status receipt is fresh): then the room's mode decides what we may change
  sync.driver_name = driver
  local dst = (driver and driver ~= cfg.user) and band.read_json(sync.room_dir(cfg, b.song, b.room) .. "/status/" .. (driver:gsub("[^%w%-_ ]", "")) .. ".json") or nil
  sync.someone_drives = type(dst) == "table" and band.age(dst.time) < 30
  -- Alone = full control: with no bandmate in the room, everything we change goes out, whoever drives or claimed it
  -- (what Solo edit was for, without a separate copy of the song). Once anyone is here, the band's rules are back.
  local others = sync.present(cfg, b.song, b.room)
  local alone = #others == 0
  if alone ~= sync.alone then
    if alone or sync.alone ~= nil then
      band.log(alone and "nobody else is here: you have full control (what you change still goes to the band, and reaches them when they're back)"
        or (table.concat(others, ", ") .. " joined: the band's rules are back (" .. tostring(driver) .. " drives)"))
    end
    sync.alone = alone
    reaper.SetExtState(band.SECTION, "alone " .. tostring(proj), alone and "1" or "", false)
  end
  local my_can = alone and function() return true end or can
  -- the driver stepped away while others are still here: say so once (anyone here can Take control; the panel shows it)
  local driver_away = not alone and driver and driver ~= cfg.user
  if driver_away then for _, o in ipairs(others) do if o == driver then driver_away = false end end end
  if driver_away ~= sync.driver_away then
    if driver_away then band.log(tostring(driver) .. " is driving but isn't here: anyone can Take control (Session tab) to carry on") end
    sync.driver_away = driver_away
    reaper.SetExtState(band.SECTION, "driver_away " .. tostring(proj), driver_away and tostring(driver) or "", false)
  end
  if last_driver and driver ~= last_driver then -- handovers are announced, never silent
    band.log(driver == cfg.user and "you're driving now" or (tostring(driver) .. " took control" ..
      (last_driver == cfg.user and ": you're no longer driving (what you don't own is view-only)" or "")))
  end
  last_driver = driver
  -- the host's project gathers the rooms bandmates record into (BandSync before side rooms), never a side room:
  -- that's its own tab, brought in when someone chooses to (lib/rooms.lua)
  local rooms = { b.room }
  if host then
    rooms = {}
    for _, r in ipairs(require("rooms").list(cfg, b.song)) do if not r.parent then rooms[#rooms + 1] = r.name end end
  end
  for _, room in ipairs(rooms) do
    import(room)
    local room_can = room == b.room and can or sync.authority(cfg, b.song, room, s)
    local n = 0
    if not editing() then n = sync.receive(proj, cfg, b.song, room, room_can) end
    if n > 0 then band.log(n .. " change(s) from the band (" .. room .. ")") end
  end

  -- the host lets new band machines in: a bandmate's installer pairs with the host's Syncthing, which then asks
  -- here. Over the band's Tailscale (only band machines are on it) they're added and given the band folder at once;
  -- anything else waits for a click in the panel (Bandmates)
  if host then
    local services = require("services")
    local ask = {}
    for _, d in ipairs(services.pending_devices()) do
      if services.on_tailnet(d.address) and not joined[d.id] then
        joined[d.id] = true
        local ok, why = services.add_device(d.id, d.name)
        band.log(ok and string.format("'%s' (%s) joined the band folder: it asked over the band's Tailscale", d.name, d.id:sub(1, 7))
          or ("couldn't add '" .. d.name .. "': " .. tostring(why)))
      elseif not joined[d.id] then
        ask[#ask + 1] = d
      end
    end
    reaper.SetExtState(band.SECTION, "pending_join", band.json_encode(ask), false)
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
    local units = sync.own_takes(proj, { all = true, unsent = true, min_len = sync.MIN_LEN, me = cfg.user })
    if #units > 0 then band.log("sent " .. sync.send(proj, cfg, b, units, print_mode) .. " new take(s)") end
    if now - last_reprint > 10 then
      last_reprint = now
      if now - (files_checked or -1e9) > 60 then files_checked = now; sync.check_own_files(proj, cfg, b) end
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
  if not hold then sync.watch(proj, cfg, b.song, b.room, my_can) end
  -- the driver's mix layer (buses, sends into them, master plug-ins) goes to the band once it has settled; only
  -- while stopped, since automation moves plug-in settings during playback
  if driver == cfg.user and not hold and reaper.GetPlayStateEx(proj) == 0 then
    local mixlayer = require("mixlayer")
    local st, sig = mixlayer.capture(proj)
    if sig ~= select(2, reaper.GetProjExtState(proj, band.SECTION, "mix_sig")) then
      if mix_pending ~= sig then mix_pending, mix_at = sig, now
      elseif now - mix_at > 3 then
        sync.post(cfg, b.song, b.room, { type = "mix", state = st, sig = sig }, proj)
        reaper.SetProjExtState(proj, band.SECTION, "mix_sig", sig)
        mix_pending = nil
        band.log(string.format("your mix went to the band (%d bus/empty track(s), %d send(s)%s)", #st.tracks, #st.sends, st.master and ", master plug-ins" or ""))
      end
    end
  end
  if sync.need_save then -- a delete went out: the project is saved, so a crash can't bring the take back here
    sync.need_save = nil
    for i = 0, 512 do
      local p, fn = reaper.EnumProjects(i)
      if not p then break end
      if p == proj and fn ~= "" then reaper.Main_SaveProject(proj, false) end -- (an unsaved project would ask where)
    end
  end
  if now - quiet.checked > 60 then
    quiet.checked = now
    local n = event_count()
    if n ~= quiet.n then quiet.n, quiet.since = n, now
    elseif now - quiet.since > 1200 then pcall(end_of_session, "20 minutes with no changes") end
  end
  local droot = drive.root(cfg)
  -- every 3 minutes (sooner while a big copy is still going): store-and-forward needs no hurry, and Drive limits
  -- how often one account may change files
  if droot and reaper.GetPlayStateEx(proj) == 0 and now - drive_at > (drive_more and 10 or 180) then
    drive_at = now
    local moved, more = 0, false
    for _, room in ipairs(rooms) do
      local ok, n, m = pcall(drive.mirror, sync.room_dir(cfg, b.song, room), droot .. "/" .. b.song .. "/rooms/" .. room, 1.5, cfg.user)
      if ok then moved, more = moved + n, more or m
      elseif drive_said ~= tostring(n) then drive_said = tostring(n); band.log("Google Drive copy: " .. tostring(n)) end
    end
    pcall(require("sessionfile").catch_up, b.song, 1.0) -- your recordings the end-of-session projects use
    if more and not drive_more then band.log("Google Drive: bringing the band's copy of this room up to date (carries on between passes)") end
    if moved > 0 and not more then band.log(string.format("Google Drive copy up to date (%d file(s) this pass)", moved)) end
    drive_more = more
  end
  sync.apply_locks(proj, my_can, cfg.user)
  sync.draw_claims(proj, who.times) -- who claimed which stretch of time, as regions (this machine only)

  -- status receipt for the Status window: written when it changes, else every 15 s as a heartbeat
  -- pending + hold let "Take control" wait until everyone has caught up before switching
  local armed = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    if reaper.GetMediaTrackInfo_Value(tr, "I_RECARM") == 1 then armed[#armed + 1] = select(2, reaper.GetTrackName(tr)) end
  end
  local info = { driver = driver, role = b.role, song = b.song, hold = hold or nil,
    pending = sync.pending_events(proj, cfg, b.song, b.room), armed = armed, side = side_bars(),
    playing = reaper.GetPlayStateEx(proj) & 1 == 1 or nil, recording = reaper.GetPlayStateEx(proj) & 4 == 4 or nil,
    front = reaper.EnumProjects(-1) == proj }
  local fingerprint = band.json_encode(sync.holdings(proj)) .. tostring(driver) .. info.pending .. tostring(hold) .. band.json_encode(armed) ..
    tostring(info.side) .. tostring(info.playing) .. tostring(info.recording) .. tostring(info.front)
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
-- (our tab's file, not the front one's: an update reloads every tab's Live sync while one tab is in front)
local our_file = ""
for i = 0, 512 do
  local p, f = reaper.EnumProjects(i)
  if not p then break end
  if p == proj then our_file = f or "" end
end
local autokey = "autosync " .. our_file:lower()
if autokey ~= "autosync " then reaper.SetExtState(band.SECTION, autokey, "1", true) end
local tick
local livemidi = require("livemidi")
local midi_view_at, midi_view_err = 0, nil
local undo_since, undo_said -- when you undid one of BandSync's own changes (tick_body waits a while)
local function tick_body() -- returns true to keep going
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then -- project closed: stop, and say so
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    return band.log("live sync stopped: '" .. b.song .. "' was closed (reopened, it starts again by itself if 'Start Live sync with REAPER' is on; otherwise press Start)")
  end
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
  if cmd > 0 then reaper.SetExtState(band.SECTION, "live cmd " .. cmd, tostring(reaper.time_precise()), false) end -- (band.start_live)
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
  -- live MIDI view (lib/livemidi.lua): our notes go out as we play them; bandmates' show up as they play theirs
  if reaper.EnumProjects(-1) == proj then livemidi.send_tick(proj, cfg, b, st & 4 ~= 0) end -- (input goes to the tab in front)
  if st & 4 == 0 and now - midi_view_at > 0.5 then
    midi_view_at = now
    local ok, e = pcall(livemidi.receive_tick, proj, cfg, b)
    if not ok and midi_view_err ~= tostring(e) then midi_view_err = tostring(e); band.log("live MIDI view: " .. tostring(e)) end
  end
  local every = reaper.GetPlayStateEx(proj) & 1 == 1 and 2 -- playing: a pass can stall REAPER ~0.5 s (seen on the laptop)
    or (lagbars or now - stopped_at < 8) and 0.5 or 2 -- side by side, or just after a recording: look often
  local redo = reaper.Undo_CanRedo2(proj)
  if redo and redo:find("^BandSync") then -- you just undid one of BandSync's changes: keep undoing if you like
    undo_since = undo_since or now
    if not undo_said then undo_said = true; band.log("you undid a BandSync change: Live sync waits 30 s (or until you do something else) so you can keep undoing") end
  else
    undo_since, undo_said = nil, nil
  end
  local undoing = undo_since and now - undo_since < 30
  if not recording and not undoing and now - last > every and not (transport and due_in < 1.5) then
    last = reaper.time_precise()
    local ok, err = pcall(poll)
    if not ok then band.log("sync error: " .. tostring(err)) end
  end
  return true
end
-- A running script keeps the code it started with: after an update, running the action again only said "already
-- running", so an old Live sync carried on through two updates (laptop, 2026-10-28: 0.13.3 skipped mix events as
-- unknown and marked them applied). Once the installed version has changed (and held for two looks, so a half-copied
-- update isn't loaded), the new code takes over in place, for this same tab.
local seen_disk, disk_at = nil, 0
local function updated()
  if reaper.time_precise() - disk_at < 5 then return false end
  disk_at = reaper.time_precise()
  local disk = (band.read(dir .. "/lib/band.lua") or ""):match('VERSION = "([^"]+)"')
  local ready = disk and disk ~= band.VERSION and disk == seen_disk
  seen_disk = disk
  return ready
end
-- an error anywhere in a tick (a malformed cue from someone's machine, say) is logged, and Live sync carries on
local said_at = -math.huge
tick = function()
  -- (the tab may have just been closed: check before asking about it, or REAPER stops us with an error box)
  if reaper.ValidatePtr2(0, proj, "ReaProject*") and reaper.GetPlayStateEx(proj) & 4 == 0 and updated() then
    band.log("live sync for '" .. b.song .. "' reloaded for BandSync " .. tostring(seen_disk))
    reloaded = true
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    BANDSYNC_LIVE_PROJ = proj
    return dofile(dir .. "/BandSync - Live sync.lua")
  end
  local ok, go = pcall(tick_body)
  if not ok then
    if reaper.time_precise() - said_at > 30 then said_at = reaper.time_precise(); band.log("live sync error: " .. tostring(go)) end
    go = true
  end
  if go then reaper.defer(tick) end
end

band.log(string.format("live sync for '%s' (%s, room %s, takes as %s, driver %s)%s", b.song, b.role, b.room, mode,
  tostring(sync.driver(cfg, b.song, b.room, s0)), baseline > 0 and (", " .. baseline .. " existing take(s) left as baseline") or ""))
tick()

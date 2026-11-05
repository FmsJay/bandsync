-- @description StudioSync: live sync for this project (runs in the background whenever a StudioSync project is open)
-- Keeps this project identical to the band's (mirror sync, docs/mirror-design.md): every track, item and plug-in
-- chain you may change goes out a moment after you change it; the band's changes come in; a change you may not make
-- (someone else's claim, or the driver's) is put back. Also plays/records together and runs the live modes.
-- Never touches a track while it records.
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
local proj = BANDSYNC_LIVE_PROJ or reaper.EnumProjects(-1) -- (set when an update reloads us: our tab, not the front one)
BANDSYNC_LIVE_PROJ = nil
do -- (Autostart asks for a tab behind the front one by name: starting it never has to bring it forward)
  local asked = reaper.GetExtState(band.SECTION, "live start for")
  if asked ~= "" then
    reaper.DeleteExtState(band.SECTION, "live start for", false)
    for i = 0, 512 do
      local p = reaper.EnumProjects(i)
      if not p then break end
      if tostring(p) == asked then proj = p; break end
    end
  end
end
-- A side-by-side stop fires when our playhead reaches the leader's stop position, on two readings in a row: the
-- play position can read a few hundred ms off for a moment (seen on the laptop: 6.418 -> 6.112 -> 6.446 in 2 ms).
local past = 0
local function reached(t, theirs)
  if not (t.type == "stop" and t.follow and theirs and t.pos and reaper.GetPlayStateEx(proj) & 1 == 1) then past = 0; return false end
  past = reaper.GetPlayPosition2Ex(proj) >= t.pos - 0.005 and past + 1 or 0
  return past >= 2
end
local b = band.binding(proj)
if not b then return band.msg("This project isn't shared yet: share it, or open it from Projects in the StudioSync panel.") end
cfg = band.for_tab(cfg, b) -- (this tab's own band, whichever band this computer is working in now)
require("sync").current_song = b.song -- (whose notices these are: a tab's own)
if not b.root then reaper.SetProjExtState(proj, band.SECTION, "root", cfg.root); b.root = cfg.root end -- (a tab from before bands: its band, from now on)
-- one Live sync per song tab: triggering this action again while it runs does nothing (no "terminate instances?"
-- box); another tab's runs from a launcher action of its own (band.start_live), and starting it again for this tab
-- only says so
if reaper.set_action_options then reaper.set_action_options(2) end
local beat0 = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
if beat0 and reaper.time_precise() - beat0 < 5 then return band.log("Live sync is already running for '" .. b.song .. "'") end
if band.synced_elsewhere(proj) then
  return band.log("'" .. b.song .. "' is already syncing in another tab: work there (this tab is a second copy of the project, and isn't synced)")
end
-- the newest Live sync for a tab owns it: while a dialog is open every script pauses, its heartbeat goes stale, and
-- Autostart may start another one for the tab; when the dialog closes the older one sees it was replaced and stops
-- (2026-10-29, laptop: tabs could end up with two Live syncs after a long dialog)
local my_token = string.format("%.6f-%d", reaper.time_precise(), math.random(1, 1e9))
reaper.SetExtState(band.SECTION, "live owner " .. tostring(proj), my_token, false)
local host = b.role == "host"
pcall(require("songsync").want, cfg, b.song) -- (a song syncing in a tab here comes in full: per-song sync)
local s0 = band.read_json(band.session_path(cfg, b.song)) or {}
local baseline = sync.mark_baseline(proj)
sync.audio_follow_tempo(proj) -- band audio follows tempo changes piece by piece (REAPER auto-stretch), never drifting

-- Side by side (panel, Together): press play/stop/record as usual; every machine with it on follows, `lag`
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
local st_started -- when we started Syncthing: a fresh look 20 s on says whether it really runs
for _, d in ipairs(band.subdirs(cfg.root)) do
  if d == ".stfolder" then -- Syncthing marks the folders it shares with this
    local services = require("services")
    local ok, why = services.ensure_syncthing()
    if ok == "started" then band.log("started Syncthing"); st_started = reaper.time_precise() elseif not ok then band.log("Syncthing: " .. why) end
    if ok then -- quick hand-off for live use (lib/services.lua): the live MIDI view a couple of seconds behind
      local set, err = services.tune_band_folder(band.info(cfg.root).id)
      if set and #set > 0 then band.log("Syncthing's studio folder tuned for live use: " .. table.concat(set, ", "))
      elseif not set then
        -- just started, it doesn't answer for a few seconds (2026-10-29, laptop): try again for a few minutes
        tune_left, tune_at = 10, reaper.time_precise()
        if ok ~= "started" then band.log("Syncthing: " .. tostring(err)) end
      end
    end
  end
end

-- which plug-ins this machine has goes to the band, and the FX browser's "StudioSync (everyone has)" folder follows
-- what everyone has (lib/plugins.lua); a failure here must never stop syncing
do
  local plugins = require("plugins")
  local ok, n, why = pcall(function() plugins.publish(cfg); return plugins.update_folder(cfg) end)
  if ok and n then band.log(string.format("%d plug-ins everyone in the studio has: FX browser folder '%s'", n, plugins.FOLDER))
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
  -- (20 quiet minutes isn't the end of anything: it looked like one in the middle of a session, first in the list: laptop, 0.42.5)
  recall.save(proj, cfg, b.song, b.room, why:find("20 minutes", 1, true) and "20 quiet minutes" or "end of session", true)
  band.log("saved an end-of-session version (" .. why .. "): it's kept for good (Restore > Saved versions)")
  local droot = require("drive").root(cfg) -- and the project itself, for anyone to open from Drive (lib/sessionfile.lua)
  if droot then
    local ok, out, err = pcall(require("sessionfile").export, proj, cfg, b, droot, sync.room_dir(cfg, b.song, b.room))
    band.log(ok and out and ("end-of-session project saved to Google Drive: " .. out:match("[^/]+$")) or
      ("couldn't save the end-of-session project to Drive: " .. tostring(ok and err or out)))
  end
  -- history older than 30 days that nothing needs (lib/trim.lua): the room's driver trims it, at most once a day,
  -- right after this kept version is saved
  local key = "trimmed " .. b.song .. "/" .. b.room
  if sync.driver(cfg, b.song, b.room, s0) == cfg.user and reaper.GetExtState(band.SECTION, key) ~= os.date("!%Y-%m-%d") then
    reaper.SetExtState(band.SECTION, key, os.date("!%Y-%m-%d"), true)
    local ok, gone = pcall(require("trim").run, cfg, b.song, b.room, 30)
    if ok and gone > 0 then band.log(string.format("trimmed %d change(s) older than 30 days that no saved version needs (kept in 'StudioSync history archive')", gone))
    elseif not ok then band.log("couldn't trim old history: " .. tostring(gone)) end
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

local sizes, last, recording, stopped_at = {}, 0, false, 0
local status_info -- (the status as last written: tick_body says "recording" with it, as the pass that writes it waits while recording)
local paint_at = -math.huge -- when tracks were last coloured for who's working on them
local claims_at = -math.huge -- when our claims on gone tracks were last looked for (sync.drop_gone_claims)
local last_status, status_json = 0, ""
local rt_at = 0 -- when Real time mode's sends were last matched to what's armed
local heal_since, healed_at = nil, -math.huge -- since when a caught-up bandmate's project has differed (mirror.heal)
local mirror_took = 0 -- how long the last full look took
local mirror_cc, mirror_at, mirror_due = -1, -math.huge, false -- the project's change count at the last full look, and when
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


local last_driver
local drawings_at = -math.huge -- (when this last looked whether the room has drawings to show)
local last_session -- a session.json caught mid-sync reads as nothing: keep the last good one
local joined = {} -- machines this Live sync has already let in
-- Are we in the middle of editing? (the project changed in the last 2 s, or the mouse button is down): the band's
-- changes wait for a pause, so none lands mid-drag. Never more than 10 s, so a long edit can't hold them up for good.
-- (A drag counts as no change until the drop: laptop, 2026-10-31, a band change applied 2 s into a drag undid it.)
local function mouse_down() return reaper.JS_Mouse_GetState ~= nil and reaper.JS_Mouse_GetState(1) & 1 == 1 end
local change_count, changed_at, held_since = -1, -math.huge, nil
local function editing()
  local c = reaper.GetProjectStateChangeCount(proj)
  local t = reaper.time_precise()
  if c ~= change_count then change_count, changed_at = c, t end
  local busy = t - changed_at < 2 or mouse_down()
  if busy then held_since = held_since or t else held_since = nil end
  return busy and t - held_since < 10
end
-- Something to redo (you just pressed undo): the band's changes wait up to 30 s, as any undo point of theirs would
-- take your redo away (laptop, block K: Ctrl+Z, then Ctrl+Shift+Z did nothing). A new action of yours ends the wait.
local redo_seen, redo_at = nil, 0
local undo_top = reaper.Undo_CanRedo2(proj) -- what was on top of REAPER's redo list at the last look
local function redo_pending()
  local r = reaper.Undo_CanRedo2(proj)
  if r ~= redo_seen then redo_seen, redo_at = r, reaper.time_precise() end
  return r ~= nil and reaper.time_precise() - redo_at < 30
end

local function poll()
  if st_started and reaper.time_precise() - st_started > 20 then
    st_started = nil
    if not require("services").running("syncthing", true) then
      band.log("Syncthing didn't start, so nothing reaches the studio or comes in: start Syncthing yourself (Start menu, or its tray icon), " ..
        "then Live sync carries on by itself")
    end
  end
  if tune_left > 0 and reaper.time_precise() - tune_at > 30 then
    tune_left, tune_at = tune_left - 1, reaper.time_precise()
    local set, err = require("services").tune_band_folder(band.info(cfg.root).id)
    if set then
      tune_left = 0
      band.log(#set > 0 and ("Syncthing's studio folder tuned for live use: " .. table.concat(set, ", ")) or "Syncthing is answering")
    elseif tune_left == 0 then
      band.log("Syncthing: " .. tostring(err) .. " (Settings > Health shows whether the shared folder syncs)")
    end
  end
  local s = band.read_json(band.session_path(cfg, b.song)) or last_session
  last_session = s
  local can, who = sync.authority(cfg, b.song, b.room, s)
  local driver = who.driver
  -- someone else drives and is here (their status receipt is fresh): then the room's mode decides what we may change
  sync.driver_name, sync.room_mode = driver, who.mode -- (put-back messages say who and why)
  local dst = (driver and driver ~= cfg.user) and band.read_json(sync.room_dir(cfg, b.song, b.room) .. "/status/" .. (driver:gsub("[^%w%-_ ]", "")) .. ".json") or nil
  sync.someone_drives = type(dst) == "table" and band.age(dst.time) < 30
  -- Alone = full control: with no bandmate in the room, everything we change goes out, whoever drives or claimed it
  -- (what Solo edit was for, without a separate copy of the song). Once anyone is here, the band's rules are back.
  -- (gone for 90 s before you're alone, back at once: a dialog left open on their machine pauses its status for a
  -- while, and each pause handed the laptop full control for a moment, 2026-10-31)
  local others = sync.present(cfg, b.song, b.room, sync.alone and 45 or 90)
  local alone = #others == 0
  if alone ~= sync.alone then
    if alone or sync.alone ~= nil then
      band.log(alone and "nobody else is here: you have full control (what you change still goes to the others, and reaches them when they're back)"
        or (table.concat(others, ", ") .. " joined: the studio's rules are back (" .. tostring(driver) .. " drives)"))
    end
    sync.alone = alone
    reaper.SetExtState(band.SECTION, "alone " .. tostring(proj), alone and "1" or "", false)
  end
  local my_can = alone and function() return true end or can
  -- the driver stepped away while others are still here: say so once (anyone here can Take control; the panel shows it)
  local driver_away = not alone and driver and driver ~= cfg.user
  if driver_away then for _, o in ipairs(others) do if o == driver then driver_away = false end end end
  if driver_away ~= sync.driver_away then
    if driver_away then band.log(tostring(driver) .. " is driving but isn't here: anyone can Take control (StudioSync panel) to carry on") end
    sync.driver_away = driver_away
    reaper.SetExtState(band.SECTION, "driver_away " .. tostring(proj), driver_away and tostring(driver) or "", false)
  end
  if last_driver and driver ~= last_driver then -- handovers are announced, never silent
    band.log(driver == cfg.user and "you're driving now" or (tostring(driver) .. " is driving now" ..
      (last_driver == cfg.user and ": you're no longer driving (what you don't own is view-only)" or "")))
  end
  last_driver = driver
  -- Hold sync: keep working without sending anything; releasing it sends the net result once
  local hold = select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) ~= ""

  local now = reaper.time_precise()
  -- mirror sync (docs/mirror-design.md): the whole project travels object by object. What changed here goes out
  -- before the band's changes come in, so an edit still unsent is never overwritten unseen
  sync.local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1"
  if not (s and s.sync == "mirror") then -- made with the older take sync: left alone until it's published again
    if not sync.old_said then sync.old_said = true; band.log("'" .. b.song .. "' was made with an older StudioSync: publish it again (StudioSync - Publish session) to sync it") end
  else
    if not hold then
      local tok, terr = pcall(sync.watch_timeline, proj, cfg, b.song, b.room, my_can) -- (before the items: a tempo change moves them)
      if not tok then band.log("tempo/markers: " .. tostring(terr)) end
    end
    -- (with Hold my changes on, the look still runs, sending nothing: it marks what you changed, so the band's
    -- changes to those wait for yours instead of replacing them; mirror.unsent)
    -- a full look reads every track and item: only when REAPER says the project changed, or the band's changes just
    -- came in, and at least every 10 s anyway (anything REAPER doesn't count as a change still gets seen)
    local cc = reaper.GetProjectStateChangeCount(proj)
    -- (not mid-drag: watch would skip it, and the change it skipped mustn't count as seen)
    -- (every second while a print renders in the background: it goes in once done, not up to 10 s later: laptop, 0.40.0)
    -- (and no oftener than a look's own time allows: at 2000 items each takes 1 s, which would be REAPER's whole time)
    local waiting = now - mirror_at > math.max(1, mirror_took * 5) and (require("bgrender").waiting() or require("prints").waiting() or require("mirror").unsettled) -- (or a part waiting its turn, or a plug-in chain to settle)
    -- (at 3,000 items a look holds REAPER up for over a second, even with nothing happening: at most a fifth of its time, unless there's more to send)
    local room_to_look = mirror_due or now - mirror_at > mirror_took * 5
    if room_to_look and (cc ~= mirror_cc or mirror_due or waiting or now - mirror_at > math.max(10, mirror_took * 30)) and not mouse_down() then
      local presence = require("presence")
      local held = function(oid) return presence.holder(presence.peers(cfg, b.song, b.room), oid) end -- (edit holds)
      local here = {} -- (bandmates in the song now: one of them may print what its author can't, lib/prints.lua)
      for _, st in ipairs(presence.peers(cfg, b.song, b.room)) do here[st.user] = true end
      local ok, sent = pcall(require("mirror").watch, proj, cfg, b.song, b.room, { can = my_can, mode = who.mode, local_mix = sync.local_mix,
        held = held, hold = hold, here = here, printers = who.printers })
      if not ok then band.log("mirror sync: " .. tostring(sent))
      elseif sent > 0 then band.log(sent .. " change(s) went to the others") end
      mirror_took = reaper.time_precise() - now
      mirror_cc, mirror_at, mirror_due = reaper.GetProjectStateChangeCount(proj), now, false
      if hold then -- (how many are waiting, for the panel's "Holding N changes")
        local n, key = 0, tostring(proj)
        for k in pairs(require("mirror").unsent) do if k:sub(1, #key) == key then n = n + 1 end end
        reaper.SetExtState(band.SECTION, "held " .. key, tostring(n), false)
      end
    end
  end

  do -- Sync and exit (lib/leave.lua): what's still waiting to go out, and a kept version of the session when it asks
    local leaving = reaper.GetExtState(band.SECTION, "end session " .. tostring(proj))
    if leaving ~= "" then
      reaper.DeleteExtState(band.SECTION, "end session " .. tostring(proj), false)
      pcall(end_of_session, leaving)
      mirror_due = true
    end
    local more = require("mirror").more and "changes" or require("bgrender").waiting() and "prints rendering" or require("prints").waiting() and "prints waiting" or nil
    reaper.SetExtState(band.SECTION, "outbox " .. tostring(proj), band.json_encode({ at = mirror_at, more = more }), false)
  end
  -- what's drawn in a room shows without anyone asking, unless this person hid them: nobody would see a drawing until they
  -- pressed Show drawings on the Chat page (James, 2026-11-02: "other people can see the drawings too, right?")
  if now - drawings_at > 10 and reaper.GetExtState(band.SECTION, "draw hidden") == "" and reaper.JS_Window_FindChildByID and reaper.APIExists("ImGui_GetBuiltinPath") then
    drawings_at = now
    if band.files(sync.room_dir(cfg, b.song, b.room) .. "/drawings", ".json")[1] then band.start_draw(dir) end
  end

  do -- (a suggestion arrived or was answered: lib/suggest.lua)
    local nok, nerr = pcall(require("suggest").notices, proj, cfg, sync.room_dir(cfg, b.song, b.room))
    if not nok then band.log("suggestions: " .. tostring(nerr)) end
  end

  -- the host's project gathers the rooms bandmates record into (StudioSync before side rooms), never a side room:
  -- that's its own tab, brought in when someone chooses to (lib/rooms.lua)
  local rooms = { b.room }
  if host then
    rooms = {}
    for _, r in ipairs(require("rooms").list(cfg, b.song)) do if not r.parent then rooms[#rooms + 1] = r.name end end
  end
  for _, room in ipairs(rooms) do
    local room_can = room == b.room and can or sync.authority(cfg, b.song, room, s)
    local n = 0
    if not editing() and not redo_pending() then n = sync.receive(proj, cfg, b.song, room, room_can) end
    -- a lot came in and it's over: saved, so the next open starts from here and doesn't take it all in again with REAPER held up
    sync.since_save = (sync.since_save or 0) + n
    if n == 0 and sync.since_save >= 100 and reaper.GetPlayStateEx(proj) == 0 then sync.need_save, sync.since_save = true, 0 end
    if n > 0 then band.log(n .. " change(s) from the others (" .. room .. ")"); mirror_due = true end
  end

  -- a bandmate who has every change has had a different project from ours for a minute, and we're caught up too:
  -- something never landed here. Bring it in line with the band's newest version (at most every 5 minutes).
  if s and s.sync == "mirror" and not hold then
    local mine, differs, same = require("mirror").root(proj), false, false
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      if st.mirror and st.pending == 0 and st.mirror ~= mine then differs = true end
      if st.mirror and st.pending == 0 and st.mirror == mine then same = true end
    end
    -- the same project as everyone again: an old "came out different" is history, not news (it kept Health red after
    -- the Mac matched: 0.34.4)
    if same and not differs and reaper.GetExtState(band.SECTION, "mirror drift " .. tostring(proj)) ~= "" then
      reaper.DeleteExtState(band.SECTION, "mirror drift " .. tostring(proj), false)
      reaper.DeleteExtState(band.SECTION, "mirror drift last", false)
    end
    if differs and sync.pending_events(proj, cfg, b.song, b.room) == 0 then heal_since = heal_since or now else heal_since = nil end
    if now - claims_at > 10 then claims_at = now; pcall(sync.drop_gone_claims, proj, cfg, b.song, b.room) end
    if heal_since and now - heal_since > 60 and now - healed_at > 300 and reaper.EnumProjects(-1) == proj then
      healed_at, heal_since = now, nil
      local ok, n = pcall(require("mirror").heal, proj, sync.room_dir(cfg, b.song, b.room), sync.local_mix)
      if not ok then band.log("couldn't bring the project in line with the studio: " .. tostring(n))
      elseif n > 0 then band.log(string.format("brought %d thing(s) in line with the studio's newest version (they hadn't landed here)", n)); mirror_due = true end
    end
  end

  -- new band machines: on the host of a computer in one band, a machine asking over the band's Tailscale (only band
  -- machines are on it) is let in at once; with several bands, never on its own. The rest ask in the panel (tools.join_requests).
  if host and #band.bands() <= 1 and require("groups").may_manage(cfg.root, cfg.user) then
    local services = require("services")
    for _, d in ipairs(services.pending_devices()) do
      if services.on_tailnet(d.address) and not joined[d.id] then
        joined[d.id] = true
        local ok, why = services.add_device(d.id, d.name, band.info(cfg.root).id)
        band.log(ok and string.format("'%s' (%s) joined the studio folder: it asked over the studio's Tailscale", d.name, d.id:sub(1, 7))
          or ("couldn't add '" .. d.name .. "': " .. tostring(why)))
      end
    end
  end

  -- live (ReaNINJAM synced mode): received clips land as placeholders until the real takes replace them
  local live_dir = select(2, reaper.GetProjExtState(proj, band.SECTION, "live_dir"))
  if live_dir == "" and reaper.GetProjectName(proj) ~= "" then live_dir = reaper.GetProjectPathEx(proj):gsub("\\", "/") .. "/bandsync_live" end -- set up by hand: the usual place
  -- (not while producing: they're heard live, and a play-through's clips have no take to replace them, so the next pass plays them twice over)
  if live_dir ~= "" and live.fx(proj, false) and not require("producer").who(proj) and reaper.GetExtState(band.SECTION, "produced by " .. tostring(proj)) == "" then
    live.note_clips(proj, live_dir) -- when each clip arrived, so only takes recorded then replace it
    local added, retired = live.place_clips(proj, live_dir), live.retire(proj)
    if added + retired > 0 then reaper.Undo_OnStateChange2(proj, "StudioSync: live placeholders") end -- one undo point, only when something changed
    if added > 0 then band.log(added .. " live clip(s) placed as placeholders") end
    if retired > 0 then band.log(retired .. " placeholder(s) replaced by the real takes") end
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
    pcall(require("removal").tick) -- (Autostart does this too, where it's on)
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
    if not more then -- then the other songs here, one a pass: each keeps a copy a bandmate can open from Drive
      local ok, n, m = pcall(drive.upkeep, cfg, droot, require("songsync").here(cfg), b.song, 1.0)
      if ok then moved, more = moved + n, more or m
      elseif drive_said ~= tostring(n) then drive_said = tostring(n); band.log("Google Drive copy: " .. tostring(n)) end
    end
    pcall(require("sessionfile").catch_up, b.song, 1.0) -- your recordings the end-of-session projects use
    if more and not drive_more then band.log("Google Drive: bringing the studio's copy of this room up to date (carries on between passes)") end
    if moved > 0 and not more then band.log(string.format("Google Drive copy up to date (%d file(s) this pass)", moved)) end
    drive_more = more
  end
  sync.draw_claims(proj, who.times) -- who claimed which stretch of time, as regions (this machine only)
  do -- bandmates' pings show here; following someone keeps the view on theirs (lib/presence.lua)
    local presence = require("presence")
    local peers = presence.peers(cfg, b.song, b.room)
    presence.pings(proj, peers)
    local follow = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj))
    if follow == "" and reaper.GetExtState(band.SECTION, "follow driver") ~= "" and driver ~= cfg.user then follow = driver or "" end
    if follow ~= "" then presence.follow(proj, peers, follow) end
    -- tracks in the colour of who's working on them, if this machine wants that (lib/people.lua; shown here only)
    if now - paint_at > 1 then paint_at = now; require("people").paint(proj, cfg, peers, who.tracks) end
  end

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
    front = reaper.EnumProjects(-1) == proj, mirror = s and s.sync == "mirror" and require("mirror").root(proj) or nil,
    editing = require("presence").editing(proj), view = require("presence").view(proj), ping = require("presence").my_ping(proj),
    last_track = select(2, reaper.GetProjExtState(proj, band.SECTION, "last_track")),
    follow = reaper.GetExtState(band.SECTION, "follow " .. tostring(proj)), follow_driver = reaper.GetExtState(band.SECTION, "follow driver") ~= "" or nil,
    listen = reaper.GetExtState(band.SECTION, "listen " .. tostring(proj)),
    produce = require("producer").who(proj), produce_via = require("producer").who(proj) and require("producer").via(proj) or nil, stamping = reaper.GetExtState(band.SECTION, "stamping " .. tostring(proj)) ~= "" or nil }
  if info.follow == "" then info.follow = nil end
  if not info.playing then info.cursor = math.floor(reaper.GetCursorPositionEx(proj) * 1000 + 0.5) / 1000 end -- (followers' cursors go here: lib/presence.lua)
  do
    local sm, si = live.fx(proj, false, live.SONOBUS)
    info.rt = sm and not reaper.TrackFX_GetOffline(sm, si) or nil
    if info.rt then -- (which SonoBus group, and who you can't hear: lib/hear.lua hear.check, on their computers)
      local g, who = reaper.GetExtState(band.SECTION, "rt group " .. tostring(proj)), reaper.GetExtState(band.SECTION, "rt silent who " .. tostring(proj))
      if g ~= "" then info.rt = g end
      if who ~= "" then info.rt_silent = who end
    end
  end
  if info.listen == "" then info.listen = nil end
  local fingerprint = tostring(info.follow) .. tostring(info.follow_driver) .. tostring(info.listen) .. tostring(info.rt) .. tostring(info.rt_silent) .. tostring(info.cursor) .. band.json_encode(sync.holdings(proj)) .. tostring(driver) .. info.pending .. tostring(hold) .. band.json_encode(armed) ..
    tostring(info.side) .. tostring(info.playing) .. tostring(info.recording) .. tostring(info.front) .. tostring(info.mirror) ..
    band.json_encode({ info.editing, info.view, info.ping or false }) .. info.last_track
  if fingerprint ~= status_json or now - last_status > 15 then
    status_json, last_status, status_info = fingerprint, now, info
    sync.write_status(proj, cfg, b.song, b.room, info)
  end

  if s then band.check_version(s.bandsync, "'" .. b.song .. "'", true) end
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
local produce_lag, stamp_seen -- (producing someone: how far behind this pass really runs; the stream's start already acted on)
-- Whose play, pause and stop this tab follows: "follow <proj>" holds a name, "follow driver" (kept) means whoever drives. Real time mode's
-- side by side follows everyone. (lib/presence.lua moves the view along too.)
local function follows(name)
  local who_ = reaper.GetExtState(band.SECTION, "follow " .. key)
  if who_ ~= "" then return who_ == name end
  return reaper.GetExtState(band.SECTION, "follow driver") ~= "" and sync.driver_name == name
end
local function take_cue(ev)
  if not ev or (ev.id and fired[ev.id]) or (ev.at or 0) < cue_at then return end
  if ev.follow and not side_bars() and not follows(ev.lead) then return end
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
-- StudioSync - Autostart.lua restarts us for this project after REAPER restarts, until the person stops us
-- (our tab's file, not the front one's: an update reloads every tab's Live sync while one tab is in front)
local our_file = ""
for i = 0, 512 do
  local p, f = reaper.EnumProjects(i)
  if not p then break end
  if p == proj then our_file = f or "" end
end
local autokey = band.autosync_key(our_file)
if autokey ~= "autosync " then reaper.SetExtState(band.SECTION, autokey, "1", true) end
local tick
local livemidi = require("livemidi")
local midi_view_at, midi_view_err = 0, nil
local undo_since, undo_said -- when you undid one of StudioSync's own changes (tick_body waits a while)
local function tick_body() -- returns true to keep going
  if sync.tip_at and reaper.time_precise() - sync.tip_at > 6 then sync.tip_at = nil; reaper.TrackCtl_SetToolTip("", 0, 0, true) end
  if not reaper.ValidatePtr2(0, proj, "ReaProject*") then -- project closed: stop, and say so
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    return band.log("live sync stopped: '" .. b.song .. "'" .. (b.room ~= "main" and (", side room '" .. b.room .. "',") or "") .. " was closed (it starts again by itself when you reopen it)")
  end
  local now_b = band.binding(proj)
  if not now_b or now_b.role ~= b.role or now_b.song ~= b.song then -- became a solo working copy (or unbound): not ours any more
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    return band.log("live sync stopped: this tab is now " .. (now_b and now_b.role == "solo" and "a Solo edit working copy" or "no longer this session"))
  end
  if reaper.GetExtState(band.SECTION, "live owner " .. key) ~= my_token then -- a newer Live sync took this tab over
    return band.log("Live sync restarted for '" .. b.song .. "' (room " .. b.room .. "): nothing to do")
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
    local producing = require("producer").who(proj)
    if not transport and producing and require("producer").via(proj) == "stamp" then -- (the stream says it's started before the shared folder can)
      local st = require("stamp").status()
      if not st.active then stamp_seen = nil
      elseif not stamp_seen then
        local cue = require("producer").fast_cue(st, stamp_seen, producing, together.now(), require("producer").lag(proj), reaper.GetPlayStateEx(proj) & 1 == 1)
        stamp_seen = st.count
        if cue then transport, cue_at = cue, cue.at end
      end
    end
  end
  if transport then
    local tnow = together.now()
    local theirs = transport.lead and transport.lead ~= cfg.user
    local behind = transport.follow and theirs and require("producer").behind(proj, transport.lead)
    if behind then -- (a lag this computer chose; a stop comes as far behind as the pass really was)
      transport.behind, transport.lag = true, transport.type == "stop" and math.max(behind, produce_lag or 0) or behind
    end
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
        if transport.pause and transport.pos then -- (paused: you're where they paused, paused too)
          reaper.SetEditCurPos2(proj, transport.pos, false, false)
          reaper.OnPauseButtonEx(proj)
        end
      else
        local _, from = together.plan(transport, cfg.user, tnow) -- a few ms (or seconds) late: as far in as time has gone
        if transport.behind then produce_lag = tnow - (transport.at or tnow) end
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
  local someone_follows = false -- (a cue file per press only when somebody's there to read it)
  if not lagbars then
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      someone_follows = someone_follows or st.follow == cfg.user or (st.follow_driver and sync.driver_name == cfg.user)
    end
  end
  if lagbars or someone_follows then
    local ps = reaper.GetPlayStateEx(proj)
    local playing, pos, tp = ps & 1 == 1, reaper.GetPlayPosition2Ex(proj), reaper.time_precise()
    if tp >= side.quiet_until then
      local jumped = playing and side.playing and math.abs(pos - (side.pos + (tp - side.t))) > 0.5 -- a seek while playing
      if playing ~= side.playing or jumped then
        local ev = playing and { type = "start", pos = pos, countin = 0, rec = ps & 4 == 4 or nil }
          or { type = "stop", pos = side.pos + (tp - side.t), pause = ps & 2 == 2 or nil } -- where the song was when you stopped
        ev.at, ev.lead, ev.follow = together.now(), cfg.user, true
        ev.lag = together.bars_after(proj, pos, lagbars or 0)
        sync.post(cfg, b.song, b.room, ev)
        fired[ev.id], cue_at = true, math.max(cue_at, ev.at)
        reaper.SetExtState(band.SECTION, "together " .. key, os.date("%H:%M:%S ") .. (playing and string.format("you %s from %.2f s: the others follow %.1f s behind",
          ev.rec and "recorded" or "played", pos, ev.lag) or "you stopped: the others stop too"), false)
      end
    end
    side.playing, side.pos, side.t = playing, pos, tp
  end
  local st = reaper.GetPlayStateEx(proj)
  if st & 4 ~= 0 then
    if not recording and status_info then
      status_info.playing, status_info.recording, status_info.cursor = true, true, nil
      sync.write_status(proj, cfg, b.song, b.room, status_info)
      status_json = nil -- (and the first pass after it says it's over)
    end
    recording = true
  elseif recording then recording, stopped_at = false, reaper.time_precise() end
  local now = reaper.time_precise()
  -- Real time mode: only what's armed feeds SonoBus (lib/live.lua rt_sends), checked about once a second
  if now - rt_at > 1 then
    rt_at = now
    local ok, e = pcall(require("hear").answer_listeners, proj, cfg, b)
    if not ok then band.log("listen: " .. tostring(e)) end
    pcall(require("hear").watch_silence, proj, cfg, require("presence").peers(cfg, b.song, b.room), now)
    pcall(require("hear").check, proj, cfg, require("presence").peers(cfg, b.song, b.room), now)
    pcall(live.rt_sends, proj); pcall(live.join_check, proj); pcall(sync.follow_claims, proj, cfg, b.song, b.room)
    local okp, ep = pcall(require("producer").tick, proj, cfg, b, require("presence").peers(cfg, b.song, b.room))
    if not okp then band.log("producer: " .. tostring(ep)) end
  end
  -- live MIDI view (lib/livemidi.lua): our notes go out as we play them; bandmates' show up as they play theirs
  if reaper.EnumProjects(-1) == proj then livemidi.send_tick(proj, cfg, b, st & 4 ~= 0) end -- (input goes to the tab in front)
  if st & 4 == 0 and now - midi_view_at > 0.5 then
    midi_view_at = now
    local ok, e = pcall(livemidi.receive_tick, proj, cfg, b)
    if not ok and midi_view_err ~= tostring(e) then midi_view_err = tostring(e); band.log("live MIDI view: " .. tostring(e)) end
  end
  local every = reaper.GetPlayStateEx(proj) & 1 == 1 and 2 -- playing: a pass can stall REAPER ~0.5 s (seen on the laptop)
    or (lagbars or now - stopped_at < 8 or require("bgrender").waiting() or require("prints").waiting()) and 0.5 or 2 -- side by side, just after a recording, or with a print on its way: look often
  local redo = reaper.Undo_CanRedo2(proj)
  -- REAPER's own undo (Edit > Undo, or a key not set to StudioSync's) just rolled back a change StudioSync made, a collaborator's or the group's:
  -- that would undo their work too. Put it back, and undo your own last change instead, as Ctrl+Z does.
  if redo and (redo:find("^StudioSync") or redo:find("^BandSync")) and redo ~= undo_top then
    reaper.Undo_DoRedo2(proj)
    local ok, res, why = pcall(function() return require("undo").step(proj, cfg, b, false, {}) end)
    if not ok then band.log("undo: " .. tostring(res)) elseif res then band.log(res) elseif why then band.log(why) end
    redo = reaper.Undo_CanRedo2(proj)
  end
  undo_top = redo
  if redo and (redo:find("^StudioSync") or redo:find("^BandSync")) then -- you just undid one of StudioSync's changes: keep undoing if you like
    undo_since = undo_since or now
    if not undo_said then undo_said = true; band.log("you undid a StudioSync change: Live sync waits 30 s (or until you do something else) so you can keep undoing") end
  else
    undo_since, undo_said = nil, nil
  end
  local undoing = undo_since and now - undo_since < 30
  if not recording and not undoing and now - last > every and not (transport and due_in < 1.5) then
    last = reaper.time_precise()
    local ok, err = pcall(poll)
    if not ok then band.log("sync error: " .. tostring(err)) end
    -- more of the band's changes waiting than one pass applies: the next pass in 0.3 s, not 2 s (320 moved items
    -- took 73 s to land at 2 s a pass; laptop, 0.34.4). Each pass still applies at most a quarter second.
    -- (and when a burst of ours is still going out: mirror.watch sends a quarter second of it per pass)
    if require("mirror").more then mirror_due = true end
    if sync.backlog or require("mirror").more then last = reaper.time_precise() - every + 0.3 end
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
local said_at, sws_at = -math.huge, -math.huge
tick = function()
  -- (the tab may have just been closed: check before asking about it, or REAPER stops us with an error box)
  if reaper.ValidatePtr2(0, proj, "ReaProject*") and reaper.GetPlayStateEx(proj) & 4 == 0 and updated() then
    band.log("live sync for '" .. b.song .. "' reloaded for StudioSync " .. tostring(seen_disk))
    reloaded = true
    reaper.DeleteExtState(band.SECTION, "live " .. key, false)
    for _, f in ipairs(band.files(dir .. "/lib", ".lua")) do package.loaded[f:sub(1, -5)] = nil end
    BANDSYNC_LIVE_PROJ = proj
    return dofile(dir .. "/StudioSync - Live sync.lua")
  end
  if reaper.time_precise() - sws_at > 1 then
    sws_at = reaper.time_precise()
    pcall(band.sws_colours) -- (lib/band.lua)
    pcall(require("mirror").note_open_fx, proj)
    -- (with no audio device REAPER builds no peaks by itself: a bandmate's take stayed a blank box: Mac, 0.57.6)
    if sync.landed_media and reaper.Audio_IsRunning() ~= 1 and reaper.EnumProjects(-1) == proj then
      sync.landed_media = nil
      reaper.Main_OnCommand(40047, 0) -- Peaks: Build any missing peaks
    end
  end
  local ok, go = pcall(tick_body)
  if not ok then
    if reaper.time_precise() - said_at > 30 then said_at = reaper.time_precise(); band.log("live sync error: " .. tostring(go)) end
    go = true
  end
  if go then reaper.defer(tick) end
end

band.log(string.format("live sync for '%s' (%s, room %s, driver %s)%s", b.song, b.role, b.room,
  tostring(sync.driver(cfg, b.song, b.room, s0)), baseline > 0 and (", " .. baseline .. " existing take(s) left as baseline") or ""))
tick()

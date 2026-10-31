-- Setting a project up for the band: what's in place, what's missing, and the fixes that need no human
-- (a loopback cable, a sign-in or a share can't be clicked from a script). The panel's Set up list and its
-- "Set up everything I can" button are a view over this.
local band = require("band")
local live = require("live")
local services = require("services")
local solo = require("solo")
local sonobus = require("sonobus")
local setup = {}

function setup.live_file(cfg, b) return band.song_dir(cfg, b.song) .. "/live.json" end

-- The band's SonoBus group and password, made by whoever needs it first: <shared folder>/sonobus.json.
function setup.sonobus_group(cfg)
  local file = cfg.root .. "/sonobus.json"
  local data = band.read_json(file) or {}
  local had = data.group
  local group, pw = live.sonobus_group(data)
  if not had then band.write_json(file, data) end
  return group, pw
end

-- SonoBus on Real time mode's own track (lib/live.lua rt_track), set to join the band's group by itself: BandSync
-- writes the group, password and your name into its saved state (lib/sonobus.lua), with "Reconnect Last" on, so
-- SonoBus joins whenever it's on. It stays there once added, offline while not in use, so it never joins (or
-- streams anything) until someone connects. With open: brings it online, which joins. Returns the join link (for
-- SonoBus's own app), the track and the FX index; or nil + why.
function setup.sonobus(cfg, b, proj, open)
  local group, pw = setup.sonobus_group(cfg)
  local m, i = live.fx(proj, false, live.SONOBUS)
  if m and m == reaper.GetMasterTrack(proj) then -- the old place (it sent the whole mix): moves to Real time's own track
    reaper.TrackFX_Delete(m, i)
    m = nil
  end
  if not m then
    m, i = live.fx(proj, true, live.SONOBUS)
    if not m then
      return nil, "SonoBus isn't installed here (sonobus.net, free), or REAPER hasn't seen it yet: REAPER finds new plug-ins when it starts, so restart REAPER after installing it."
    end
  end
  reaper.TrackFX_SetOffline(m, i, false) -- its state can only be read and written while it's loaded
  local _, chunk = reaper.TrackFX_GetNamedConfigParm(m, i, "vst_chunk")
  if not sonobus.is_set_up(chunk, group, cfg.user) then
    local new, why = sonobus.join_state(chunk, { user = cfg.user, group = group, password = pw })
    if not new then return nil, "Couldn't set SonoBus up (" .. why .. "): join by hand with its Connect button." end
    reaper.TrackFX_SetNamedConfigParm(m, i, "vst_chunk", new)
    reaper.TrackFX_SetOffline(m, i, true) -- reloading it with that state is what makes it join
  end
  reaper.TrackFX_SetOffline(m, i, not open)
  return live.sonobus_link(group, pw), m, i
end

local function has_subdir(path, name)
  for _, d in ipairs(band.subdirs(path)) do if d == name then return true end end
  return false
end

-- What's in place. Slow-ish (tasklist): call every few seconds, not every frame.
function setup.check(cfg, b, proj)
  local data = band.read_json(setup.live_file(cfg, b)) or {}
  local st = {}
  st.audio = reaper.Audio_IsRunning() == 1 -- a closed device (driver missing, interface unplugged) makes Live and recording silently do nothing
  local syncthing = has_subdir(cfg.root, ".stfolder") -- a cloud-drive root needs nothing
  st.folder = not syncthing or services.running("syncthing")
  if syncthing and st.folder then st.peers, st.devices = services.syncthing_peers() end
  st.connected = not syncthing or (st.peers or 0) > 0
  local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(proj)))
  st.sync = beat ~= nil and reaper.time_precise() - beat < 5
  local ms = tonumber(reaper.GetExtState(band.SECTION, "rec_offset_ms"))
  st.latency, st.latency_ms = ms ~= nil and math.abs(ms) < 1, ms
  st.sonobus = live.fx(proj, false, live.SONOBUS) ~= nil
  st.server = (data.server or "") ~= ""
  st.ninjam = b.role ~= "host" or services.running("ninjamsrv")
  st.solo_root = solo.root(cfg)
  local parent, leaf = st.solo_root:match("^(.*)[/\\]([^/\\]+)$")
  st.solo = parent ~= nil and has_subdir(parent, leaf)
  return st
end

-- Every fix that needs no human. start_sync starts Live sync (an action, so the panel passes how to run it).
-- Returns what it did, as short notes.
function setup.all(cfg, b, proj, st, start_sync)
  local notes = {}
  if not st.folder then
    local ok, why = services.ensure_syncthing()
    notes[#notes + 1] = ok and "Syncthing started" or ("Syncthing: " .. why)
  end
  if not st.sync then
    reaper.DeleteExtState(band.SECTION, "stop " .. tostring(proj), false)
    start_sync()
    notes[#notes + 1] = "Live sync started"
  end
  if b.role == "host" then
    local lfile = setup.live_file(cfg, b)
    local data = band.read_json(lfile) or {}
    if (data.server or "") == "" then
      local ip = services.tailscale_ip()
      if ip then
        data.server, data.by = ip .. ":2049", cfg.user
        band.write_json(lfile, data)
        notes[#notes + 1] = "Live server address set to " .. data.server
      else notes[#notes + 1] = "Tailscale isn't installed or signed in here, so the Live server address is still empty" end
    end
    if not st.ninjam then
      local ok, why = services.ensure_ninjam()
      notes[#notes + 1] = ok and "NINJAM server started" or ("NINJAM server: " .. why)
    end
  end
  if not st.sonobus then
    local link, why = setup.sonobus(cfg, b, proj, false)
    notes[#notes + 1] = link and "SonoBus added to the master track (off until you press Same room)" or why
  end
  return notes
end

return setup

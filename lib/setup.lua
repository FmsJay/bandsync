-- Setting a project up for the band: what's in place, what's missing, and the fixes that need no human
-- (a loopback cable, a sign-in or a share can't be clicked from a script). The panel's Set up list and its
-- "Set up everything I can" button are a view over this.
local band = require("band")
local live = require("live")
local services = require("services")
local solo = require("solo")
local setup = {}

function setup.live_file(cfg, b) return band.song_dir(cfg, b.song) .. "/live.json" end

-- SonoBus on the master track, in the song's group. It stays there once added, set offline while not in use, so it
-- never joins the group (or streams anything) until someone connects. Returns the join link, or nil + why.
-- With open: brings it online. The caller puts the link on the clipboard and shows the window; the first time,
-- SonoBus's paste button fills the group in (verified 1.7.2: Connect..., paste, Connect to Group), and after that
-- "Reconnect Last" rejoins by itself whenever it comes back online.
function setup.sonobus(cfg, b, proj, open)
  local lfile = setup.live_file(cfg, b)
  local data = band.read_json(lfile) or {}
  local had = data.sb_group
  local group, pw = live.sonobus_group(data, b.song)
  if not had then band.write_json(lfile, data) end
  local m, i = live.fx(proj, false, live.SONOBUS)
  if not m then
    m, i = live.fx(proj, true, live.SONOBUS)
    if not m then
      return nil, "SonoBus isn't installed here (sonobus.net, free), or REAPER hasn't seen it yet: REAPER finds new plug-ins when it starts, so restart REAPER after installing it."
    end
    live.sonobus_reconnect(m, i) -- after the first join, it rejoins whenever the project opens (while online)
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
  st.folder = not has_subdir(cfg.root, ".stfolder") or services.running("syncthing") -- a cloud-drive root needs nothing
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
    notes[#notes + 1] = link and "SonoBus added to the master track (off until you Connect in the Live tab)" or why
  end
  return notes
end

return setup

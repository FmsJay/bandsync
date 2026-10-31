-- Who's doing what, at the speed the shared folder carries it (a few seconds): edit holds, following someone's view,
-- and pings. Each machine puts its part in its status file (rooms/<room>/status/<user>.json); Live sync reads the
-- others'.
--   Holds: what someone changed in the last HOLD seconds is theirs for that long. Your own change to it is put back
--     with "<name> is editing that right now" (two people working one item at once was a tug of war).
--   Follow: Who's here can follow a bandmate's view (the arrange view goes where theirs is).
--   Ping: the radial menu's "Ping here" puts a marker at a spot on everyone's timeline for a while.
local band = require("band")
local presence = {}
presence.HOLD = 15       -- seconds a changed object stays held by whoever changed it
presence.PING_SHOWN = 30 -- seconds a ping's marker stays
presence.MARK = "[ping] " -- a ping's marker name starts so (never part of the band's markers: band.is_local_mark)

-- ---- this machine's part --------------------------------------------------------------------------
local touched = {} -- proj -> { oid -> os.time() of our last change }
function presence.touch(proj, oid)
  local k = tostring(proj)
  touched[k] = touched[k] or {}
  touched[k][oid] = os.time()
end
-- The oids we changed within HOLD seconds, sorted (for the status file: it's rewritten when this changes).
function presence.editing(proj)
  local out, now = {}, os.time()
  for oid, t in pairs(touched[tostring(proj)] or {}) do if now - t < presence.HOLD then out[#out + 1] = oid end end
  table.sort(out)
  return out
end
-- The arrange view, rounded (so the status file isn't rewritten for a pixel's scroll).
function presence.view(proj)
  local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
  return { math.floor(a * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2 }
end
-- A ping from here: the spot and when (ExtState, so the radial menu can set it; Live sync puts it in the status).
function presence.ping_here(proj, pos)
  reaper.SetExtState(band.SECTION, "ping " .. tostring(proj), string.format("%.3f %s", pos, os.date("!%Y-%m-%dT%H:%M:%SZ")), false)
  -- (the marker is for the others, so this is the pinger's only sign it went: laptop, 2026-10-31)
  band.log(string.format("pinged %.2f s: everyone in the room sees a marker with your name there for %d seconds", pos, presence.PING_SHOWN))
end
function presence.my_ping(proj)
  local pos, at = reaper.GetExtState(band.SECTION, "ping " .. tostring(proj)):match("^(%S+) (%S+)$")
  return pos and { pos = tonumber(pos), at = at } or nil
end

-- ---- the others' ----------------------------------------------------------------------------------
local peers_at, peers = {}, {}
-- Bandmates' fresh status files (seen in the last 45 s), read at most once a second per room.
function presence.peers(cfg, song, room)
  local key = song .. "/" .. room
  if peers_at[key] and reaper.time_precise() - peers_at[key] < 1 then return peers[key] end
  local dir, out = require("sync").room_dir(cfg, song, room) .. "/status", {}
  for _, f in ipairs(band.files(dir, ".json")) do
    local st = band.read_json(dir .. "/" .. f)
    if type(st) == "table" and type(st.user) == "string" and st.user ~= cfg.user and type(st.time) == "string" and band.age(st.time) < 45 then
      out[#out + 1] = st
    end
  end
  peers_at[key], peers[key] = reaper.time_precise(), out
  return out
end
-- Who else is editing this object right now (nil when nobody is). Pure apart from the peers list.
function presence.holder(list, oid)
  for _, st in ipairs(list) do
    for _, o in ipairs(type(st.editing) == "table" and st.editing or {}) do if o == oid then return st.user end end
  end
end

-- Follow: this machine's arrange view goes where `name`'s is (when it's more than a little off).
function presence.follow(proj, list, name)
  for _, st in ipairs(list) do
    if st.user == name and type(st.view) == "table" and tonumber(st.view[1]) and tonumber(st.view[2]) then
      local a, z = reaper.GetSet_ArrangeView2(proj, false, 0, 0, 0, 0)
      if math.abs(a - st.view[1]) > 0.5 or math.abs(z - st.view[2]) > 0.5 then
        reaper.GetSet_ArrangeView2(proj, true, 0, 0, st.view[1], st.view[2])
      end
      return
    end
  end
end

-- Pings: a bandmate's new ping shows as a marker here (and a line in the Activity list) for PING_SHOWN seconds.
local shown = {} -- proj .. user -> the ping's time, once shown
function presence.pings(proj, list)
  for _, st in ipairs(list) do
    local p = type(st.ping) == "table" and st.ping
    local key = tostring(proj) .. st.user
    if p and tonumber(p.pos) and type(p.at) == "string" and band.age(p.at) < presence.PING_SHOWN and shown[key] ~= p.at then
      shown[key] = p.at
      reaper.AddProjectMarker2(proj, false, p.pos, 0, presence.MARK .. st.user, -1, reaper.ColorToNative(255, 170, 0) | 0x1000000)
      band.log(string.format("%s pinged a spot at %.2f s: their marker shows there for %d seconds", st.user, p.pos, presence.PING_SHOWN))
    end
  end
  -- old pings go
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(proj, i)
    local who = not rgn and name:sub(1, #presence.MARK) == presence.MARK and name:sub(#presence.MARK + 1)
    if who then
      local still = false
      for _, st in ipairs(list) do
        if st.user == who and type(st.ping) == "table" and tonumber(st.ping.pos) and math.abs(st.ping.pos - pos) < 1e-3
            and band.age(st.ping.at or "") < presence.PING_SHOWN then still = true end
      end
      if not still then reaper.DeleteProjectMarkerByIndex(proj, i) end
    end
  end
end

return presence

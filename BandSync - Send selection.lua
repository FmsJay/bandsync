-- @description BandSync: send what's highlighted (items, tracks, a time selection, or any mix) to the band
-- Sends the selected items, every item on the selected tracks, or with nothing selected everything in the time
-- selection. With a time selection you choose whether only its inside goes (items crossing its edges are split
-- there) or whole items. Takes the band already has aren't sent again: their edits and sound changes travel by
-- themselves. Works from a session tab, or from any other project (a sketch you worked on alone): pick the song
-- and its takes land in the band's session at the same bar and beat.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if b and b.role == "solo" then return band.msg("This is a Solo edit copy: check it in instead (BandSync - Check in).") end
local mx, my = reaper.GetMousePosition() -- every menu opens here (a reopened menu mustn't jump to the last click)

local function send_to(song, room) -- a song and room when sending from another project
  if song then
    local s = band.read_json(band.session_path(cfg, song)) or {}
    b = { song = song, room = room or "main", version = s.version, role = "outside" }
    mx, my = reaper.GetMousePosition() -- the menus open where you are now
  end

  local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  local has_time = to - from > 1e-6
  local picked = reaper.CountSelectedMediaItems(proj) > 0 or reaper.CountSelectedTracks(proj) > 0
  local function bars(a, z) -- "bars 5-8" for a stretch (an end on a bar line isn't that bar)
    local x, y = select(2, reaper.TimeMap2_timeToBeats(proj, a + 1e-6)) + 1, select(2, reaper.TimeMap2_timeToBeats(proj, z - 1e-6)) + 1
    return x == y and ("bar " .. x) or ("bars " .. x .. "-" .. y)
  end
  local stretch = has_time and string.format("%s (%.1f-%.1f s)", bars(from, to), from, to)

  local opts = { me = cfg.user }
  local choices, all_takes = {}, false
  if picked and has_time then
    choices = { "What's selected, only inside the time selection: " .. stretch, "What's selected, whole items",
      "Everything inside the time selection (all tracks)" }
  elseif has_time then
    choices = { "Everything inside the time selection (all tracks): " .. stretch }
  elseif picked then
    choices = { "What's selected (whole items)" }
  else
    return band.msg("Select what to send first: items, tracks (all their items), or a time selection (everything in it).")
  end
  local pick
  repeat -- the last line switches between the playing take and every take of each item
    local menu = {}
    for _, c in ipairs(choices) do menu[#menu + 1] = c end
    menu[#menu + 1] = (all_takes and "!" or "") .. "Every take of each item, not just the playing one"
    pick = band.pick(menu, mx, my)
    if pick == menu[#menu] then all_takes = not all_takes end
  until pick ~= menu[#menu]
  if not pick then return end
  if pick:find("^Everything") then opts.everything, opts.from, opts.to = true, from, to
  elseif pick:find("only inside") then opts.from, opts.to = from, to end
  opts.all_takes = all_takes

  -- first only look (nothing is cut until you say yes)
  opts.dry = true
  local units, inside, had = sync.selection_units(proj, opts)
  local function plural(n, one, many) return n == 1 and one or many end
  if #units == 0 then
    return band.msg(had > 0 and string.format("Nothing new to send: the band already has %s (their changes travel by themselves).",
        plural(had, "this one", "these " .. had))
      or "Nothing to send there: no recordings of yours (bandmates' takes are theirs to send).")
  end

  local tracks, names, nitems, seen = {}, {}, 0, {}
  for _, u in ipairs(units) do
    local n = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(u[1])))
    if not tracks[n] then tracks[n] = true; names[#names + 1] = n end
    if not seen[u[1]] then seen[u[1]] = true; nitems = nitems + 1 end
  end
  local what = nitems == #units and string.format("%d %s", #units, plural(#units, "take", "takes"))
    or string.format("%d %s (%d takes, each item's grouped)", nitems, plural(nitems, "item", "items"), #units)
  local s = band.read_json(band.session_path(cfg, b.song)) or {}
  local notes = {}
  if opts.from then
    notes[#notes + 1] = "Only " .. stretch .. " goes: items reaching past it are split at its edges, and the parts outside stay here, unsent."
  end
  if had > 0 then notes[#notes + 1] = plural(had, "1 take the band already has stays as it is.", had .. " takes the band already has stay as they are.") end

  -- the song's position in quarter notes at time t, from its tempo map (steady tempos; a ramp counts as its start tempo)
  local function song_qn(map, t)
    local qn = 0
    for i, m in ipairs(map) do
      local stop = map[i + 1] and math.min(map[i + 1].time, t) or t
      if stop > m.time then qn = qn + (stop - m.time) * m.bpm / 60 end
    end
    return qn
  end
  if b.role == "outside" then
    notes[#notes + 1] = "They land in '" .. b.song .. "' at the same bar and beat, on tracks with the same names."
    -- placed by beat: a sketch at another tempo (a new project is 120 BPM) lands elsewhere and drifts. Only the stretch
    -- that's sent matters (the song may change tempo later on)
    local off
    for _, u in ipairs(units) do
      local p = reaper.GetMediaItemInfo_Value(u[1], "D_POSITION")
      local a, z = math.max(p, opts.from or p), math.min(p + reaper.GetMediaItemInfo_Value(u[1], "D_LENGTH"), opts.to or math.huge)
      for _, t in ipairs({ a, z }) do
        if not off and math.abs(reaper.TimeMap2_timeToQN(proj, t) - song_qn(s.tempo or {}, t)) > 0.01 then off = t end
      end
    end
    if off then
      local theirs = 0
      for _, m in ipairs(s.tempo or {}) do if m.time <= off then theirs = m.bpm end end
      notes[#notes + 1] = string.format("WARNING: at %.1f s this project is at %g BPM but '%s' is at %g BPM, so audio recorded here won't line up there. " ..
        "Set this project to the song's tempo, re-check the parts, then send.", off, reaper.TimeMap_GetDividedBpmAtTime(off), b.song, theirs)
    end
  end
  if b.role ~= "outside" and s.version and tostring(s.version) ~= tostring(b.version) then
    notes[#notes + 1] = "The host published v" .. s.version .. " since you opened v" .. b.version .. ": if the tempo changed, these may land off-grid."
  end
  if b.role ~= "outside" and select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) == "" then
    notes[#notes + 1] = "(Live sync sends your other new recordings by itself; Hold sync keeps them here.)"
  end
  if reaper.MB(string.format("Send %s from %s to '%s' (room %s)?%s", what, table.concat(names, ", "), b.song, b.room,
      #notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or ""), "BandSync", 4) ~= 6 then return end

  opts.dry = nil
  if opts.from then -- the split is one undo point; without a time selection nothing is cut
    reaper.Undo_BeginBlock2(proj)
    reaper.PreventUIRefresh(1)
  end
  units, inside = sync.selection_units(proj, opts)
  if opts.from then
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock2(proj, "BandSync: split at the time selection to send", -1)
  end
  reaper.SelectAllMediaItems(proj, false) -- what went out is what you see selected afterwards
  for _, it in ipairs(inside) do reaper.SetMediaItemSelected(it, true) end
  reaper.UpdateArrange()
  local n = sync.send(proj, cfg, b, units, s.print or "wet")
  band.log(string.format("sent %d take(s) to '%s' (room %s)", n, b.song, b.room))
  band.msg(string.format("Sent %s to '%s' (room %s).", n == #units and what or (n .. " of " .. what), b.song, b.room))
end

if b then return send_to() end
if #band.songs(cfg) == 0 then return band.msg("No BandSync songs in the shared folder yet.") end
require("chooser").open(cfg, { title = "Send the selection to which song?", action = "Send to", rooms = "pick" },
  function(song, room) if song then send_to(song, room) end end)

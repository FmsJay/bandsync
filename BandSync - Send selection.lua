-- @description BandSync: send what's highlighted (items, tracks, a time selection, or any mix) to the band
-- Sends the selected items, every item on the selected tracks, or with nothing selected everything in the time
-- selection. With a time selection you choose whether only its inside goes (items crossing its edges are split
-- there) or whole items. Takes the band already has aren't sent again: their edits and sound changes travel by
-- themselves. Works from a session tab, or from any other project (a sketch you worked on alone): pick the song
-- and its takes land in the band's session at the same positions.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")
local sync = require("sync")

local cfg = band.settings()
if not cfg then return end
local proj = reaper.EnumProjects(-1)
local b = band.binding(proj)
if b and b.role == "solo" then return band.msg("This is a Solo edit copy: check it in instead (BandSync - Check in).") end
if not b then -- another project: which song (and room) do these go to?
  local songs = band.songs(cfg)
  if #songs == 0 then return band.msg("No BandSync songs in the shared folder yet.") end
  local song = band.pick(songs)
  if not song then return end
  local rooms = band.subdirs(band.song_dir(cfg, song) .. "/rooms")
  local room = #rooms > 1 and band.pick(rooms) or rooms[1] or "main"
  if not room then return end
  local s = band.read_json(band.session_path(cfg, song)) or {}
  b = { song = song, room = room, version = s.version, role = "outside" }
end

local from, to = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
local has_time = to - from > 1e-6
local picked = reaper.CountSelectedMediaItems(proj) > 0 or reaper.CountSelectedTracks(proj) > 0
local function bars(a, z) -- "bars 5-8" for a stretch (an end on a bar line isn't that bar)
  local x, y = select(2, reaper.TimeMap2_timeToBeats(proj, a + 1e-6)) + 1, select(2, reaper.TimeMap2_timeToBeats(proj, z - 1e-6)) + 1
  return x == y and ("bar " .. x) or ("bars " .. x .. "-" .. y)
end

local opts = { me = cfg.user }
local choices, all_takes = {}, false
if picked and has_time then
  choices = { "What's selected, only inside the time selection (" .. bars(from, to) .. ")", "What's selected, whole items",
    "Everything inside the time selection" }
elseif has_time then
  choices = { "Everything inside the time selection (" .. bars(from, to) .. ")" }
elseif picked then
  choices = { "What's selected (whole items)" }
else
  return band.msg("Select what to send first: items, tracks (all their items), or a time selection (everything in it).")
end
if #choices > 0 then
  local pick
  repeat -- the last line switches between the playing take and every take of each item
    local menu = {}
    for _, c in ipairs(choices) do menu[#menu + 1] = c end
    menu[#menu + 1] = (all_takes and "!" or "") .. "Every take of each item, not just the playing one"
    pick = band.pick(menu)
    if pick == menu[#menu] then all_takes = not all_takes end
  until pick ~= menu[#menu]
  if not pick then return end
  if pick:find("^Everything") then opts.everything, opts.from, opts.to = true, from, to
  elseif pick:find("only inside") then opts.from, opts.to = from, to end
end
opts.all_takes = all_takes

reaper.Undo_BeginBlock2(proj)
reaper.PreventUIRefresh(1)
local units, inside, had = sync.selection_units(proj, opts)
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock2(proj, "BandSync: split at the time selection to send", -1)
reaper.SelectAllMediaItems(proj, false) -- what goes out is what you see selected afterwards
for _, it in ipairs(inside) do reaper.SetMediaItemSelected(it, true) end
reaper.UpdateArrange()
if #units == 0 then
  return band.msg(had > 0 and string.format("Nothing new to send: the band already has %d of these (their changes travel by themselves).", had)
    or "Nothing to send there: no recordings of yours (bandmates' takes are theirs to send).")
end

local tracks, names = {}, {}
for _, u in ipairs(units) do
  local n = select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(u[1])))
  if not tracks[n] then tracks[n] = true; names[#names + 1] = n end
end
local s = band.read_json(band.session_path(cfg, b.song)) or {}
local notes = {}
if had > 0 then notes[#notes + 1] = string.format("%d the band already has stay as they are.", had) end
if b.role == "outside" then
  notes[#notes + 1] = "They land in '" .. b.song .. "' at the same bar and beat, on tracks with the same names."
  -- placed by beat: a sketch at another tempo (a new project is 120 BPM) would land somewhere else and drift
  local mine, theirs, same = band.capture_tempo(proj), s.tempo or {}, true
  if #mine ~= #theirs then same = false end
  for i, m in ipairs(mine) do
    local t = theirs[i]
    if not t or math.abs(m.time - t.time) > 1e-3 or math.abs(m.bpm - t.bpm) > 1e-3 or m.num ~= t.num or m.denom ~= t.denom then same = false end
  end
  if not same then
    notes[#notes + 1] = string.format("WARNING: this project's tempo (%g BPM) isn't the song's (%g BPM), so audio recorded here won't line up there. " ..
      "Set this project to the song's tempo, re-check the parts, then send.", mine[1] and mine[1].bpm or 0, theirs[1] and theirs[1].bpm or 0)
  end
end
if b.role ~= "outside" and s.version and tostring(s.version) ~= tostring(b.version) then
  notes[#notes + 1] = "The host published v" .. s.version .. " since you opened v" .. b.version .. ": if the tempo changed, these may land off-grid."
end
if b.role ~= "outside" and select(2, reaper.GetProjExtState(proj, band.SECTION, "hold")) == "" then
  notes[#notes + 1] = "(Live sync sends your other new recordings by itself; Hold sync keeps them here.)"
end
if reaper.MB(string.format("Send %d take(s) from %s to '%s' (room %s)?%s", #units, table.concat(names, ", "), b.song, b.room,
    #notes > 0 and ("\n\n" .. table.concat(notes, "\n")) or ""), "BandSync", 4) ~= 6 then return end
local n = sync.send(proj, cfg, b, units, s.print or "wet")
band.log(string.format("sent %d take(s) to '%s' (room %s)", n, b.song, b.room))
band.msg(string.format("Sent %d take(s) to '%s' (room %s).", n, b.song, b.room))

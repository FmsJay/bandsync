-- Run inside REAPER (ReaScript). Admins only, giving claims, what a deleted copy leaves behind, chat's scopes, the plain copy. Scratch folders only.
local D = reaper.GetResourcePath() .. "/BandSync/tests/control"
local lib = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]tests[/\\]reaper[/\\]") .. "/lib/"
package.path = lib .. "?.lua;" .. package.path
for _, m in ipairs({ "band", "sync", "groups", "songsync", "localcopy", "export", "page_chat", "people" }) do package.loaded[m] = nil end
local band, sync, groups, ss, copy, ex, chat, people = require("band"), require("sync"), require("groups"), require("songsync"), require("localcopy"), require("export"), require("page_chat"), require("people")
local out, fails = {}, 0
local function check(ok, what) if not ok then fails = fails + 1 end; out[#out + 1] = (ok and "PASS " or "FAIL ") .. what end
local function write(p, text)
  reaper.RecursiveCreateDirectory(p:match("^(.*)/"), 0)
  local f = assert(io.open(p, "wb")); f:write(text); f:close()
end
local root = D .. "/group"
local SONG, ROOM = "Tune", "main"
local saved = {}
for _, k in ipairs({ "projects gone", "track colours" }) do saved[k] = reaper.GetExtState(band.SECTION, k) end

-- ---- who controls
reaper.RecursiveCreateDirectory(root .. "/_band", 0)
band.write_json(root .. "/_band/band.json", { name = "Control", id = "bandsync-control", owner = "Owner", admins = { "Admin" } })
local cfg = { root = root, user = "Owner" }
reaper.RecursiveCreateDirectory(sync.room_dir(cfg, SONG, ROOM) .. "/claims", 0)
band.write_json(band.session_path(cfg, SONG), { host = "Owner", song = SONG })
os.remove(sync.room_dir(cfg, SONG, ROOM) .. "/mode.json")
sync.set_mode(cfg, SONG, ROOM, "admins", "Owner")
check(sync.mode(cfg, SONG, ROOM) == "admins", "the mode reads back")
local can = sync.authority(cfg, SONG, ROOM, { host = "Owner" })
check(can("Owner", "Keys"), "admins only: the owner changes what's unclaimed")
check(can("Admin", "Keys"), "admins only: an admin does")
check(not can("Member", "Keys"), "admins only: a member doesn't")
sync.give_claims(cfg, SONG, ROOM, "Member", { "Keys" })
can = sync.authority({ root = root, user = "Member" }, SONG, ROOM, { host = "Owner" })
check(can("Member", "Keys"), "a given claim counts at once, before they've seen it")
check(not can("Member", "Bass"), "only what was given")
check(not can("Admin", "Keys"), "an admin doesn't change what's been given to someone else")
check(can("Admin", "Bass"), "an admin still changes the rest")
-- they fold it into their own file, and it stays theirs
local track_proj = reaper.EnumProjects(-1)
sync.follow_claims(track_proj, { root = root, user = "Member" }, SONG, ROOM)
local files = band.files(sync.room_dir(cfg, SONG, ROOM) .. "/claims", ".json")
local gift = false
for _, f in ipairs(files) do gift = gift or f:find("^given") ~= nil end
check(not gift, "the gift file goes once it's folded in")
local mine = sync.my_claims({ root = root, user = "Member" }, SONG, ROOM)
check(mine and mine.tracks and mine.tracks[1] == "Keys", "it's in their own claims now")
can = sync.authority({ root = root, user = "Member" }, SONG, ROOM, { host = "Owner" })
check(can("Member", "Keys"), "and still counts")
sync.set_mode(cfg, SONG, ROOM, "claims", "Owner")
check(sync.MODES.driver and sync.MODES.open and sync.MODES.claims, "the other modes are all there")

-- ---- per-song ignore lines
local plain = ss.merge("mine\n", { Alpha = true })
check(plain:find("!/*/chat", 1, true) and plain:find("!/*/rooms/*/chat", 1, true), "every project's chat comes with its listing")
local some = ss.merge("mine\n", nil, { Beta = true })
check(some:find("(?d)/Beta/*", 1, true) ~= nil, "keeping everything: a deleted project stays away")
check(some:find("!/*/session.json", 1, true) < some:find("(?d)/Beta/*", 1, true), "its listing still comes (first match wins)")
check(some:find("^mine\n") ~= nil, "someone's own ignore lines stay")
check(not ss.merge("mine\n", nil, {}):find("BandSync", 1, true), "nothing deleted, keeping everything: no block")
check(ss.merge(some, nil, nil) == "mine\n", "the block comes out again")
reaper.SetExtState(band.SECTION, "projects gone", "Beta|Gamma", false)
local g = ss.gone()
check(g.Beta and g.Gamma and not g.Tune, "what's deleted here is remembered")
check(not ss.is_here(cfg, "Beta"), "a deleted project isn't here")
ss.want(cfg, "Beta")
check(not ss.gone().Beta and ss.gone().Gamma, "opening it takes it off the list")

-- ---- what goes, and what stays, of a project
local sdir = root .. "/" .. SONG
for _, f in ipairs({ "folder.json", "live.json", "invites/a.json", "chat/msgs/1.json", "rooms/main/room.json", "rooms/main/status/x.json", "rooms/main/summary/x.json",
    "rooms/main/chat/msgs/1.json", "rooms/main/events/e1.json", "rooms/main/media/take.flac", "rooms/main/takes/t.json", "rooms/side/events/e2.json", "stems/x.flac" }) do
  write(sdir .. "/" .. f, "x")
end
local list, paths = copy.contents(sdir)
local has = {}
for _, f in ipairs(list) do has[f] = true end
check(has["rooms/main/media/take.flac"] and has["rooms/main/events/e1.json"] and has["rooms/side/events/e2.json"] and has["stems/x.flac"], "recordings, changes and stems go")
for _, keep in ipairs({ "session.json", "folder.json", "live.json", "invites/a.json", "chat/msgs/1.json", "rooms/main/room.json", "rooms/main/status/x.json", "rooms/main/summary/x.json", "rooms/main/chat/msgs/1.json" }) do
  check(not has[keep], keep .. " stays")
end
local whole = {}
for _, p in ipairs(paths) do whole[p] = true end
check(whole["rooms/main/media"] and whole.stems and not whole.rooms and not whole["rooms/main"], "it removes folders inside the rooms, never a room itself")
-- every path it removes must be ignored by the listing rules, or Syncthing would send the delete out
check(copy.lacks('{"files":[{"name":"Tune/rooms/main/media/a.flac"}]}', "Tune"), "a computer lacking part of it doesn't count")
check(not copy.lacks('{"files":[{"name":"Tuneful/a.flac"}]}', "Tune"), "another project with a longer name isn't mixed up")
check(not copy.lacks('{"files":[]}', "Tune"), "a computer lacking nothing counts")
local dp = copy.drive_paths("rooms/main/takes/t.flac")
check(dp[1] == "rooms/main/takes/t.flac" and dp[2] == "rooms/main/_trash/t.flac", "a take may be in takes or _trash on Drive")
check(copy.drive_paths("rooms/main/media/x.flac")[2] == nil, "media has one place")
check(copy.drive_needs("rooms/main/media/x.flac") and not copy.drive_needs("rooms/main/claims/x.json"), "working files aren't asked of Drive")
-- the bin, for real, on scratch files
write(D .. "/bin/one.txt", "x"); write(D .. "/bin/dir/two.txt", "x")
check(copy.bin({ D .. "/bin/one.txt", D .. "/bin/dir" }) == 0, "files and folders go to the bin")
check(not reaper.file_exists(D .. "/bin/one.txt") and not reaper.file_exists(D .. "/bin/dir/two.txt"), "they've gone")

-- ---- chat's scopes
local b = { song = SONG, room = "main" }
local function wheres(sc)
  local t = {}
  for _, s in ipairs(chat.sources(cfg, b, sc)) do t[s[2]] = s[1] end
  return t
end
local room_s, song_s, band_s = wheres("room"), wheres("song"), wheres("band")
local n = 0
for _ in pairs(room_s) do n = n + 1 end
check(n == 1 and room_s.main == sdir .. "/rooms/main/chat", "this room holds only its own")
check(song_s[SONG] == sdir .. "/chat" and song_s[SONG .. " / main"] and song_s[SONG .. " / side"], "this project holds its own and all its rooms'")
check(band_s.Group == root .. "/_band/chat" and band_s[SONG] and band_s[SONG .. " / side"], "the group holds everything")

-- ---- track colours
reaper.DeleteExtState(band.SECTION, "track colours", false)
check(people.mode() == "working", "show who's working is the default")
check(people.MODES[2][2] == "Group colours + show who's working", "and what it's called")

-- ---- a plain copy's text
local text = [[
<REAPER_PROJECT 0.1
  <TRACK {A}
    NAME Keys
    <ITEM
      <SOURCE FLAC
        FILE "Media/a.wav" 1
      >
    >
  >
  <TRACK {B}
    NAME "Real time"
    <EXT
      band_local realtime
    >
  >
>
]]
local t2 = ex.wave_sources(ex.no_local_tracks(text))
check(t2:find("Keys", 1, true) and not t2:find("Real time", 1, true), "a track that's this computer's own is left out")
check(t2:find('<SOURCE WAVE\n        FILE "Media/a.wav"', 1, true) ~= nil, "a file turned to WAV is read as WAV")
check(select(2, t2:gsub("<TRACK", "")) == 1 and t2:find(">\n>\n$") ~= nil, "the project's blocks still close")

for k, v in pairs(saved) do reaper.SetExtState(band.SECTION, k, v, false) end
-- (scratch: the group's folder, for the next run)
for _, f in ipairs(files) do os.remove(sync.room_dir(cfg, SONG, ROOM) .. "/claims/" .. f) end
out[#out + 1] = string.format("control_parts: fails %d of %d", fails, #out)
return table.concat(out, "\n")

-- BandSync shared library: settings, song folders, session.json, stems and take placement.
-- Pure REAPER API, no extensions required (js_ReaScriptAPI only improves the folder picker).
local json = require("json")
local band = { VERSION = "0.51.6", FORMAT = 1, SECTION = "BandSync", TAKES = "BandSync.takes" }

-- 1 if version a is newer than b, -1 if older, 0 if equal ("0.10.0" > "0.9.1").
function band.compare_versions(a, b)
  local pa, pb = {}, {}
  for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
  for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
  for i = 1, math.max(#pa, #pb) do
    local x, y = pa[i] or 0, pb[i] or 0
    if x ~= y then return x > y and 1 or -1 end
  end
  return 0
end

-- Seconds since an ISO UTC timestamp ("2026-10-27T02:43:22Z"). Both sides are broken-down UTC times
-- run through os.time, which reads them as local time: the offset cancels only if neither applies DST,
-- and os.date("!*t") can carry isdst = true (it did on a UTC-6 laptop in October: every age read +1 h).
function band.age(iso, now)
  local y, m, d, H, M, S = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return math.huge end
  local n = now or os.date("!*t") -- copied: os.time normalises (rewrites) the table it is given
  local t = { year = n.year, month = n.month, day = n.day, hour = n.hour, min = n.min, sec = n.sec, isdst = false }
  return os.time(t) - os.time({ year = y, month = m, day = d, hour = H, min = M, sec = S, isdst = false })
end

-- Warn once per run when a bandmate's file was made with a newer BandSync than this one. Background loops
-- pass quiet = true: a modal dialog would pause every defer script until someone clicks it (it froze a
-- Live sync for 3 minutes), so they log instead and the Status window shows a banner.
local warned = {}
function band.check_version(theirs, what, quiet)
  if theirs and band.compare_versions(theirs, band.VERSION) > 0 and not warned[theirs] then
    warned[theirs] = true
    local text = string.format("%s was made with StudioSync %s; you have %s. Run 'BandSync - Update' so everyone stays compatible.",
      what, theirs, band.VERSION)
    if quiet then band.log(text) else band.msg(text) end
  end
end

-- ---- small helpers --------------------------------------------------------------------------

function band.clean(s) return (s:gsub("[^%w%-_ ]", ""):match("^%s*(.-)%s*$")) end
local function norm(p) return (p:gsub("\\", "/"):gsub("/+$", "")) end
band.norm = norm

function band.msg(text) reaper.MB(text, "StudioSync", 0) end

-- Start Live sync for the tab in front. REAPER runs a script action once at a time (Live sync sets
-- set_action_options(2): triggered again while running, it quietly does nothing), so each further session tab
-- syncing at once gets a launcher action of its own: <resource>/Scripts/BandSync tabs/BandSync - Live sync (tab N).lua.
-- Live sync stamps "live cmd <action>" while it runs, so a free one is found. Returns true if one was started.
function band.start_live(dir)
  local main = dir .. "/BandSync - Live sync.lua"
  for n = 0, 16 do
    local path = main
    if n > 0 then
      local d = reaper.GetResourcePath() .. "/Scripts/BandSync tabs"
      path = d .. "/BandSync - Live sync (tab " .. n .. ").lua"
      if not reaper.file_exists(path) then
        reaper.RecursiveCreateDirectory(d, 0)
        band.write_atomic(path, "-- BandSync: Live sync for one more session tab at once (see group.start_live)\ndofile([[" .. main .. "]])\n")
      end
    end
    local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
    local beat = cmd > 0 and tonumber(reaper.GetExtState(band.SECTION, "live cmd " .. cmd))
    -- (its toggle says whether that one's running: the beat alone goes stale behind any dialog, such as Publish's song name,
    -- and running a script that's already running does nothing, so the new tab stayed "Sync off": PC and laptop, 0.42.2)
    if cmd > 0 and not (beat and reaper.time_precise() - beat < 5) and reaper.GetToggleCommandState(cmd) ~= 1 then
      reaper.Main_OnCommand(cmd, 0)
      return true
    end
  end
  return false
end
-- What BandSync did, for the panel's Activity list (the last 80 lines, this REAPER session). It no longer opens the
-- ReaScript console, which popped up in front on every send and read like an error (Mac, 2026-10-28). Nor does it copy
-- a line there when the console is open: finding that out searched every window, 0.38 s a line, which froze REAPER on
-- every change the band sent (PC, 0.42.2). Setup > Console shows them.
band.LOG_KEY, band.LOG_MAX = "activity", 80
function band.log(text)
  local lines = {}
  for l in reaper.GetExtState(band.SECTION, band.LOG_KEY):gmatch("[^\n]+") do lines[#lines + 1] = l end
  lines[#lines + 1] = os.date("%H:%M ") .. tostring(text):gsub("\n", " ")
  while #lines > band.LOG_MAX do table.remove(lines, 1) end
  reaper.SetExtState(band.SECTION, band.LOG_KEY, table.concat(lines, "\n"), false)
end
-- The Activity lines, newest first.
function band.activity()
  local lines = {}
  for l in reaper.GetExtState(band.SECTION, band.LOG_KEY):gmatch("[^\n]+") do table.insert(lines, 1, l) end
  return lines
end

function band.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a"); f:close()
  return s
end

function band.size(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local n = f:seek("end"); f:close()
  return n
end

-- Write under a temp name, then rename, so a syncing peer never picks up a half-written file.
-- The ".syncthing.*.tmp" name is one Syncthing always ignores; cloud drives may upload it briefly.
-- A write that didn't all reach the disk (a full disk) raises, and the old file stays: renaming a cut-off file into
-- place made it the band's copy (review, 2026-10-31).
local function finish(tmp, path, f, want)
  local ok_close = f:close()
  if not ok_close or band.size(tmp) ~= want then
    os.remove(tmp)
    error("couldn't write " .. path .. " (is the disk full?)")
  end
  if os.rename(tmp, path) then return end -- POSIX: replaces it in one step
  -- Windows won't rename over a file: move the old one aside first (never deleted before the new one is in place;
  -- named so Syncthing ignores it, as it does the .tmp)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local old = dir .. "/.syncthing." .. name .. ".old.tmp"
  os.remove(old)
  os.rename(path, old)
  if not os.rename(tmp, path) then os.rename(old, path); error("cannot replace " .. path) end
  os.remove(old)
end
function band.write_atomic(path, data)
  local dir, name = path:match("^(.*)/([^/]+)$")
  local tmp = dir .. "/.syncthing." .. name .. ".tmp"
  local f = assert(io.open(tmp, "wb"))
  if not f:write(data) then f:close(); os.remove(tmp); error("couldn't write " .. path .. " (is the disk full?)") end
  finish(tmp, path, f, #data)
end

-- A copy, a piece at a time (a long recording or a video read whole took that much memory, and froze REAPER while
-- it did), checked to be complete before it's put in place.
function band.copy_atomic(src, dst)
  local fi = assert(io.open(src, "rb"), "cannot read " .. src)
  local dir, name = dst:match("^(.*)/([^/]+)$")
  local tmp = dir .. "/.syncthing." .. name .. ".tmp"
  local fo = io.open(tmp, "wb")
  if not fo then fi:close(); error("cannot write " .. dst) end
  local total = 0
  while true do
    local chunk = fi:read(1048576)
    if not chunk then break end
    if not fo:write(chunk) then fi:close(); fo:close(); os.remove(tmp); error("couldn't write " .. dst .. " (is the disk full?)") end
    total = total + #chunk
  end
  fi:close()
  if total ~= band.size(src) then fo:close(); os.remove(tmp); error("couldn't read all of " .. src) end
  finish(tmp, dst, fo, total)
end

function band.read_json(path)
  local s = band.read(path)
  if not s then return nil end
  local ok, v = pcall(json.decode, s)
  return ok and type(v) == "table" and v or nil
end

function band.write_json(path, t) band.write_atomic(path, json.encode(t, true)) end
function band.json_encode(t) return json.encode(t) end -- keys sorted: equal tables give equal strings
function band.json_decode(s) local ok, v = pcall(json.decode, s); return ok and v or nil end

local function enum(fn, dir)
  local out, i = {}, 0
  fn(dir, -1) -- invalidate REAPER's directory cache so newly synced files show up
  while true do
    local name = fn(dir, i)
    if not name then break end
    out[#out + 1] = name; i = i + 1
  end
  table.sort(out)
  return out
end

-- Sync conflict copies ("x.sync-conflict-20261028-071122-ABCDEF.json", Drive's "x (1).json") aren't files of
-- ours: a copy of an event would be applied again on every pass (it never counts as applied).
function band.is_conflict_copy(f) return f:find(".sync-conflict-", 1, true) ~= nil or f:match(" %(%d+%)%.[^.]+$") ~= nil end
function band.files(dir, ext)
  local out = {}
  for _, f in ipairs(enum(reaper.EnumerateFiles, dir)) do
    if (not ext or f:lower():sub(-#ext) == ext) and not band.is_conflict_copy(f) then out[#out + 1] = f end
  end
  return out
end

function band.subdirs(dir) return enum(reaper.EnumerateSubdirectories, dir) end

-- Pop a menu at the mouse (or at x, y); returns the chosen string or nil. Lines starting "#" are greyed headers.
function band.pick(items, x, y)
  if #items == 0 then return nil end
  if not x then x, y = reaper.GetMousePosition() end
  gfx.init("", 0, 0, 0, x, y)
  gfx.x, gfx.y = 0, 0
  local i = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  return items[i]
end

-- ---- settings and project binding -----------------------------------------------------------

function band.settings(force)
  local root = reaper.GetExtState(band.SECTION, "sync_root")
  local user = reaper.GetExtState(band.SECTION, "user")
  if force or root == "" or user == "" then
    if root == "" and reaper.JS_Dialog_BrowseForFolder then
      local ok, picked = reaper.JS_Dialog_BrowseForFolder("StudioSync: pick the shared (Syncthing) folder", "")
      if ok == 1 then root = picked end
    end
    local ok, csv = reaper.GetUserInputs("StudioSync settings", 2,
      "Shared folder (Syncthing),Your name,separator=|,extrawidth=250", root .. "|" .. user)
    if not ok then return nil end
    root, user = csv:match("^(.-)|(.*)$")
    root = root:gsub("^~", os.getenv("HOME") or os.getenv("USERPROFILE") or "~")
    root, user = norm(root), band.clean(user)
    if root == "" or user == "" then return nil end
    local probe = root .. "/.bandsync-write-test" -- the folder must exist and be writable
    local f = io.open(probe, "w")
    if not f then
      band.msg("Can't write to " .. root .. ". Check the folder exists (is Syncthing set up?).")
      return nil
    end
    f:close(); os.remove(probe)
    local old = reaper.GetExtState(band.SECTION, "user")
    reaper.SetExtState(band.SECTION, "sync_root", root, true)
    reaper.SetExtState(band.SECTION, "user", user, true)
    if old ~= "" and old ~= user then band.rename(root, old, user) end
  end
  return { root = root, user = user }
end

-- Old names, so a renamed bandmate's tracks stay theirs: <root>/_band/names.json, an old name's tag -> the name now.
-- (Checked by mirror.is_creator; read at most every 10 s.)
local names_at, names = {}, {}
function band.names(root)
  root = root or reaper.GetExtState(band.SECTION, "sync_root")
  if reaper.time_precise() - (names_at[root] or -math.huge) > 10 then
    names_at[root] = reaper.time_precise()
    names[root] = band.read_json(root .. "/_band/names.json") or {}
  end
  return names[root]
end

-- Someone took a new name: everywhere the band's files hold the old one (who drives each room, their claims, their
-- Who's here file) it becomes the new one, and the old name is remembered. Their history keeps the old name.
function band.rename(root, old, new)
  local tag = function(u) return ((u or "x"):gsub("[^%w]", "_")):upper() end
  local file = function(u) return (u:gsub("[^%w%-_ ]", "")) .. ".json" end
  local map = band.read_json(root .. "/_band/names.json") or {}
  for k, v in pairs(map) do if v == old then map[k] = new end end -- (renamed before: those names lead here too)
  map[tag(old)] = new
  map[tag(new)] = nil
  reaper.RecursiveCreateDirectory(root .. "/_band", 0)
  band.write_json(root .. "/_band/names.json", map)
  names_at[root] = nil
  local j = band.read_json(root .. "/_band/band.json") -- (who runs the group: lib/groups.lua)
  if type(j) == "table" and (j.owner == old or type(j.admins) == "table") then
    if j.owner == old then j.owner = new end
    for i, a in ipairs(type(j.admins) == "table" and j.admins or {}) do if a == old then j.admins[i] = new end end
    band.write_json(root .. "/_band/band.json", j)
  end
  local n = 0
  for _, song in ipairs(band.subdirs(root)) do
    for _, room in ipairs(band.subdirs(root .. "/" .. song .. "/rooms")) do
      local rdir = root .. "/" .. song .. "/rooms/" .. room
      local d = band.read_json(rdir .. "/driver.json")
      if d and d.driver == old then d.driver = new; band.write_json(rdir .. "/driver.json", d); n = n + 1 end
      local c = band.read_json(rdir .. "/claims/" .. file(old))
      if c then
        c.user = new
        band.write_json(rdir .. "/claims/" .. file(new), c)
        os.remove(rdir .. "/claims/" .. file(old))
        n = n + 1
      end
      os.remove(rdir .. "/status/" .. file(old)) -- (Live sync writes the new one)
    end
  end
  band.log(string.format("you're %s now (was %s): who drives and your claims moved over in %d place(s); your tracks stay yours. " ..
    "Changes you made as %s stay under that name in Restore (Undo only steps back through changes made as %s).", new, old, n, old, new))
end

-- A project is bound to one song: role (host/guest), song, room, version, take_mode.
function band.binding(proj)
  local b = {}
  for _, k in ipairs({ "role", "song", "room", "version", "take_mode", "stem_mode", "print", "root" }) do
    local _, v = reaper.GetProjExtState(proj, band.SECTION, k)
    b[k] = v ~= "" and v or nil
  end
  return b.song and b or nil
end
-- Another tab already syncing this song's room (the same .rpp opened twice): that tab, or nil. A second copy's Live
-- sync would work on a stale or empty copy of the song (laptop, block K: the panel offered Start in it).
function band.synced_elsewhere(proj)
  local b = band.binding(proj)
  if not b then return nil end
  for k = 0, 512 do
    local p = reaper.EnumProjects(k)
    if not p then break end
    local o = p ~= proj and band.binding(p)
    if o and o.song == b.song and (o.room or "main") == (b.room or "main") then
      local beat = tonumber(reaper.GetExtState(band.SECTION, "live " .. tostring(p)))
      if beat and reaper.time_precise() - beat < 30 then return p end
    end
  end
end

-- Colours travel in one byte order, Windows' (0x01BBGGRR: REAPER's native colour there, so nothing a Windows machine
-- already sent changes). A Mac's native one is 0x01RRGGBB: sent raw, a red track showed blue on the other platform.
-- out: this machine's native -> travelling; in: travelling -> native. The 0x1000000 "colour set" flag is kept.
function band.color_out(c)
  c = math.floor(tonumber(c) or 0)
  if c == 0 or not reaper.ColorFromNative then return c end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return (c & ~0xFFFFFF) | (b << 16) | (g << 8) | r
end
function band.color_in(c)
  c = math.floor(tonumber(c) or 0)
  if c == 0 or not reaper.ColorToNative then return c end
  return (c & ~0xFFFFFF) | reaper.ColorToNative(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF)
end

-- SWS auto track colouring is off while a band song is in front (James, 2026-11-01): its rules recolour every
-- track, so a machine with it on could neither send the band's colours nor keep them. It goes back on when another
-- project comes to the front (Live sync and Autostart both look). "sws colour off": BandSync switched it off, so
-- BandSync switches it back (and only then: someone who has it off themselves keeps it off).
function band.sws_colours()
  local id = reaper.NamedCommandLookup and reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE") or 0
  if id <= 0 then return end
  local front = band.binding(reaper.EnumProjects(-1)) ~= nil
  local on, ours = reaper.GetToggleCommandState(id) == 1, reaper.GetExtState(band.SECTION, "sws colour off") ~= ""
  if front and on then
    reaper.Main_OnCommand(id, 0)
    reaper.SetExtState(band.SECTION, "sws colour off", "1", true)
  elseif not front and ours then
    if not on then reaper.Main_OnCommand(id, 0) end
    reaper.DeleteExtState(band.SECTION, "sws colour off", true)
  end
end

-- ---- bands: each band is its own shared folder (docs/bands-design.md) ----------------------------------------
-- The drawings over the arrange view (BandSync - Draw.lua), if they aren't showing. Running it again would close it.
function band.start_draw(dir)
  local id = reaper.AddRemoveReaScript(true, 0, dir .. "/BandSync - Draw.lua", true)
  if id > 0 and reaper.GetToggleCommandState(id) ~= 1 then reaper.Main_OnCommand(id, 0) end
end
-- <root>/_band/band.json says which band a folder is: { name, id = its Syncthing folder id, drive = its Google Drive
-- folder's name }. A folder without one is the first band BandSync had: id "bandsync", Drive folder "BandSync".
function band.info(root)
  local j = (root and band.read_json(root .. "/_band/band.json")) or {}
  local id = type(j.id) == "string" and j.id ~= "" and j.id or "bandsync"
  return { name = type(j.name) == "string" and j.name ~= "" and j.name or "the group", id = id,
    drive = type(j.drive) == "string" and j.drive ~= "" and j.drive or (id == "bandsync" and "BandSync" or ("BandSync - " .. (j.name or id))) }
end
-- The bands this computer is in (persistent ExtState "bands": their folders), the current one always among them:
-- { { root, name, id, drive } }, by name.
function band.bands()
  local roots, seen, out = {}, {}, {}
  for r in reaper.GetExtState(band.SECTION, "bands"):gmatch("[^|]+") do roots[#roots + 1] = r end
  roots[#roots + 1] = reaper.GetExtState(band.SECTION, "sync_root")
  for _, r in ipairs(roots) do
    if r ~= "" and not seen[r] and band.subdirs(r)[1] then -- (a folder that's gone, or never synced, is left out)
      seen[r] = true
      local i = band.info(r)
      out[#out + 1] = { root = r, name = i.name, id = i.id, drive = i.drive }
    end
  end
  table.sort(out, function(a, z) return a.name:lower() < z.name:lower() end)
  return out
end
-- Make `root` the band this computer works in (new songs, the start screen, the chooser), and remember it.
function band.use_band(root)
  local list = {}
  for _, x in ipairs(band.bands()) do list[#list + 1] = x.root end
  local known = false
  for _, r in ipairs(list) do if r == root then known = true end end
  if not known then list[#list + 1] = root end
  reaper.SetExtState(band.SECTION, "bands", table.concat(list, "|"), true)
  reaper.SetExtState(band.SECTION, "sync_root", root, true)
end
-- The settings for a song tab: its own band's folder, whichever band this computer is working in now. A tab
-- bound before bands (no root) is in the current band. `cfg.base` keeps the computer's own settings.
function band.for_tab(cfg, b)
  local base = cfg and (cfg.base or cfg)
  if not base then return nil end
  local root = b and b.root
  if b and not root and b.song then
    -- a tab bound before bands names no band: the one whose folder has its song (laptop, 0.35.1: a Chilio song read
    -- through Test Band, "nil drives", once the computer worked in Test Band). The current band first.
    local roots = { base.root }
    for _, x in ipairs(band.bands()) do roots[#roots + 1] = x.root end
    for _, r in ipairs(roots) do
      if reaper.file_exists(band.session_path({ root = r }, b.song)) then root = r; break end
    end
  end
  if root and root ~= base.root and band.subdirs(root)[1] then
    return { root = root, user = base.user, base = base }
  end
  return base
end

-- The key that says "start Live sync with REAPER for this project": its path in one spelling (forward slashes, lower
-- case), as REAPER may be handed it with either slash (Recent projects, the browser, a script).
function band.autosync_key(path) return "autosync " .. (path or ""):gsub("\\", "/"):lower() end

function band.bind(proj, b)
  for k, v in pairs(b) do reaper.SetProjExtState(proj, band.SECTION, k, tostring(v)) end
end

function band.song_dir(cfg, song) return cfg.root .. "/" .. song end
function band.session_path(cfg, song) return band.song_dir(cfg, song) .. "/session.json" end
function band.takes_dir(cfg, song, room) return band.song_dir(cfg, song) .. "/rooms/" .. room .. "/takes" end

-- Newest publish first (the song you're working on now is at the top of the menu).
function band.songs(cfg)
  local out, when = {}, {}
  for _, d in ipairs(band.subdirs(cfg.root)) do
    local s = reaper.file_exists(band.session_path(cfg, d)) and band.read_json(band.session_path(cfg, d))
    if s then out[#out + 1], when[d] = d, s.published or "" end
  end
  table.sort(out, function(x, y) if when[x] ~= when[y] then return when[x] > when[y] end return x < y end)
  return out
end

-- ---- timeline: sample rate, tempo map, markers ----------------------------------------------

function band.srate(proj)
  if reaper.GetSetProjectInfo(proj, "PROJECT_SRATE_USE", 0, false) == 1 then
    return reaper.GetSetProjectInfo(proj, "PROJECT_SRATE", 0, false)
  end
  local _, sr = reaper.GetAudioDeviceInfo("SRATE")
  return tonumber(sr) or 48000
end

function band.capture_tempo(proj)
  local out = {}
  for i = 0, reaper.CountTempoTimeSigMarkers(proj) - 1 do
    local _, t, _, _, bpm, num, den, lin = reaper.GetTempoTimeSigMarker(proj, i)
    out[#out + 1] = { time = t, bpm = bpm, num = num, denom = den, linear = lin }
  end
  if #out == 0 or out[1].time > 0 then -- make the project's base tempo explicit at time 0
    local num, den, bpm = reaper.TimeMap_GetTimeSigAtTime(proj, 0)
    table.insert(out, 1, { time = 0, bpm = bpm, num = num, denom = den, linear = false })
  end
  return out
end

function band.apply_tempo(proj, map)
  for i = reaper.CountTempoTimeSigMarkers(proj) - 1, 0, -1 do reaper.DeleteTempoTimeSigMarker(proj, i) end
  for _, m in ipairs(map) do
    reaper.SetTempoTimeSigMarker(proj, -1, m.time, -1, -1, m.bpm, m.num, m.denom, m.linear)
  end
  reaper.UpdateTimeline()
end

-- Regions BandSync draws to show who claimed a stretch of time ("[claimed: James]") are this machine's
-- display only: they're never captured as the song's markers, and applying the band's markers keeps them.
band.CLAIM_MARK = "[claimed: "
function band.is_claim_mark(name) return (name or ""):sub(1, #band.CLAIM_MARK) == band.CLAIM_MARK end
-- A marker or region only this machine shows: a claim, or a bandmate's ping ("[ping] Bee", lib/presence.lua).
function band.is_local_mark(name) return band.is_claim_mark(name) or (name or ""):sub(1, 7) == "[ping] " end

function band.capture_markers(proj)
  local out, i = {}, 0
  while true do
    local n, rgn, pos, rend, name, _, color = reaper.EnumProjectMarkers3(proj, i)
    if n == 0 then break end
    if not band.is_local_mark(name) then
      local m = reaper.GetRegionOrMarker and reaper.GetRegionOrMarker(proj, i, "")
      local lane = m and reaper.GetRegionOrMarkerInfo_Value(proj, m, "I_LANENUMBER") or -1
      out[#out + 1] = { region = rgn, pos = pos, ["end"] = rend, name = name, color = band.color_out(color), lane = lane >= 0 and math.floor(lane) or nil }
    end
    i = i + 1
  end
  return out
end

-- The project's own settings that change how the song plays or reads: title, author, notes, track group names and the
-- timebase (with different timebases one tempo change moves items differently per machine). Travel with the timeline.
function band.capture_project(proj)
  local p = { title = select(2, reaper.GetSetProjectInfo_String(proj, "PROJECT_TITLE", "", false)),
    author = select(2, reaper.GetSetProjectInfo_String(proj, "PROJECT_AUTHOR", "", false)), notes = reaper.GetSetProjectNotes(proj, false, ""),
    groups = {}, timebase = "" }
  for g = 1, 64 do
    local name = select(2, reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, "", false))
    if name ~= "" then p.groups[tostring(g)] = name end
  end
  p.lanes = {}
  for l = 0, math.floor(reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", 0, false)) - 1 do
    local lane = { name = select(2, reaper.GetSetProjectInfo_String(proj, "RULER_LANE_NAME:" .. l, "", false)) }
    for _, k in ipairs(band.LANE_KEYS) do lane[k] = reaper.GetSetProjectInfo(proj, "RULER_LANE_" .. k .. ":" .. l, 0, false) end
    p.lanes[#p.lanes + 1] = lane
  end
  if reaper.SNM_GetIntConfigVarEx then -- (no setter in REAPER's API: SWS reaches the project's own config)
    p.timebase = reaper.SNM_GetIntConfigVarEx(proj, "itemtimelock", -1) .. " " .. reaper.SNM_GetIntConfigVarEx(proj, "tempoenvtimelock", -1)
  end
  return p
end

function band.apply_project(proj, p)
  if type(p) ~= "table" then return end
  for _, kv in ipairs({ { "title", "PROJECT_TITLE" }, { "author", "PROJECT_AUTHOR" } }) do
    if type(p[kv[1]]) == "string" and select(2, reaper.GetSetProjectInfo_String(proj, kv[2], "", false)) ~= p[kv[1]] then
      reaper.GetSetProjectInfo_String(proj, kv[2], p[kv[1]], true)
    end
  end
  if type(p.notes) == "string" and reaper.GetSetProjectNotes(proj, false, "") ~= p.notes then reaper.GetSetProjectNotes(proj, true, p.notes) end
  if type(p.groups) == "table" then
    for g = 1, 64 do
      local want = p.groups[tostring(g)] or ""
      if type(want) == "string" and select(2, reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, "", false)) ~= want then
        reaper.GetSetProjectInfo_String(proj, "TRACK_GROUP_NAME:" .. g, want, true)
      end
    end
  end
  local it, te = tostring(p.timebase or ""):match("^(%-?%d+) (%-?%d+)$")
  if it and reaper.SNM_SetIntConfigVarEx and tonumber(it) >= 0 then
    reaper.SNM_SetIntConfigVarEx(proj, "itemtimelock", tonumber(it))
    reaper.SNM_SetIntConfigVarEx(proj, "tempoenvtimelock", tonumber(te))
  end
  if type(p.lanes) == "table" and #p.lanes > 0 then
    if reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", 0, false) ~= #p.lanes then reaper.GetSetProjectInfo(proj, "RULER_LANE_COUNT", #p.lanes, true) end
    for l, lane in ipairs(p.lanes) do
      if type(lane.name) == "string" then reaper.GetSetProjectInfo_String(proj, "RULER_LANE_NAME:" .. (l - 1), lane.name, true) end
      for _, k in ipairs(band.LANE_KEYS) do
        if tonumber(lane[k]) then reaper.GetSetProjectInfo(proj, "RULER_LANE_" .. k .. ":" .. (l - 1), tonumber(lane[k]), true) end
      end
    end
  end
end
band.LANE_KEYS = { "DEFAULT", "LOCKED", "COLOR", "TIMEBASE" }

function band.apply_markers(proj, list)
  for i = reaper.CountProjectMarkers(proj) - 1, 0, -1 do
    local _, _, _, _, name = reaper.EnumProjectMarkers3(proj, i)
    if not band.is_local_mark(name) then reaper.DeleteProjectMarkerByIndex(proj, i) end
  end
  for _, m in ipairs(list) do reaper.AddProjectMarker2(proj, m.region, m.pos, m["end"], m.name, -1, band.color_in(m.color)) end
  if not reaper.GetRegionOrMarker then return end
  -- each one back in its ruler lane (matched by kind, position and name: AddProjectMarker2 gives no handle)
  for i = 0, reaper.GetNumRegionsOrMarkers(proj) - 1 do
    local mk = reaper.GetRegionOrMarker(proj, i, "")
    local _, rgn, pos, _, name = reaper.EnumProjectMarkers3(proj, i)
    for _, m in ipairs(list) do
      if m.lane and m.region == rgn and math.abs(m.pos - pos) < 1e-9 and m.name == name then
        reaper.SetRegionOrMarkerInfo_Value(proj, mk, "I_LANENUMBER", m.lane)
        break
      end
    end
  end
end

-- ---- rendering ------------------------------------------------------------------------------

local RENDER_N = { "RENDER_TAILMS", "RENDER_SETTINGS", "RENDER_BOUNDSFLAG", "RENDER_STARTPOS", "RENDER_ENDPOS", "RENDER_SRATE",
  "RENDER_CHANNELS", "RENDER_TAILFLAG", "RENDER_ADDTOPROJ", "RENDER_NORMALIZE", "RENDER_BRICKWALL" }
local RENDER_S = { "RENDER_FILE", "RENDER_PATTERN", "RENDER_FORMAT", "RENDER_FORMAT2" }
-- Sink configs read back from REAPER 7.83 and patched: FLAC 24-bit level 5 ("calf", int bits, int level);
-- Opus 64 kbps per channel ("SggO", float kbps/ch, then REAPER's defaults).
band.FLAC, band.OPUS = "Y2FsZhgAAAAFAAAA", "U2dnTwAAgEIACgAAAAAAAAA="

-- REAPER's render limiter: only what goes over is touched, and timing stays as it was (measured, a part 18 dB over: same length, same
-- first sample). FLAC can't hold anything over full scale, so a hot part was clipped for good in its print, on everyone's machine: 9 of
-- Sunset Drive's 287 prints sat at exactly 0 dB (2026-11-03). 64: limit on, and nothing else (a project's own normalizing stayed on for prints).
-- RENDER_BRICKWALL is a gain, not dB: 0.966 is -0.3 dB.
band.LIMIT = { RENDER_NORMALIZE = 64, RENDER_BRICKWALL = 0.966 }

-- Render the active project with temporary settings, then put the user's render settings back.
function band.render(n, s)
  local saved_n, saved_s = {}, {}
  for _, k in ipairs(RENDER_N) do saved_n[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(RENDER_S) do saved_s[k] = select(2, reaper.GetSetProjectInfo_String(0, k, "", false)) end
  for k, v in pairs(band.LIMIT) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
  local job = band.render_job -- (lib/bgrender.lua: a copy set up for this render, rendered by a second REAPER)
  if job then
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", job.dir, true)
    reaper.Main_SaveProjectEx(0, job.copy, 0) -- (0: a copy; the project keeps its own file)
  else
    -- (a print that clips left the render window open until someone clicked it: Mac, 0.42.2. 4: it closes regardless.)
    local keep = reaper.SNM_GetIntConfigVar and reaper.SNM_GetIntConfigVar("renderclosewhendone", -1)
    if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", 4) end
    reaper.Main_OnCommand(42230, 0) -- File: Render project, most recent settings, auto-close dialog
    if keep and keep >= 0 then reaper.SNM_SetIntConfigVar("renderclosewhendone", keep) end
  end
  for k, v in pairs(saved_n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(saved_s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
end

-- ---- _trash: what was deleted or replaced stays recoverable; dated, so old files can be cleaned up ----------
function band.to_trash(from_dir, to_dir, f)
  reaper.RecursiveCreateDirectory(to_dir, 0)
  os.remove(to_dir .. "/" .. f)
  if not os.rename(from_dir .. "/" .. f, to_dir .. "/" .. f) then return false end
  local idx = band.read_json(to_dir .. "/index.json") or {}
  idx[f] = os.date("!%Y-%m-%d")
  band.write_json(to_dir .. "/index.json", idx)
  return true
end
-- Delete trash files older than `days` (by the date they went in), except those `keep(f)` says are needed (kept
-- restore points' audio). Returns how many went.
function band.empty_trash(dir, days, keep)
  local idx = band.read_json(dir .. "/index.json") or {}
  local y, m, d = os.date("!%Y-%m-%d"):match("(%d+)-(%d+)-(%d+)")
  local today = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local n = 0
  for f, date in pairs(idx) do
    local fy, fm, fd = date:match("(%d+)-(%d+)-(%d+)")
    if fy and not (keep and keep(f)) and (today - os.time({ year = tonumber(fy), month = tonumber(fm), day = tonumber(fd), hour = 12 })) / 86400 >= days then
      if os.remove(dir .. "/" .. f) or not reaper.file_exists(dir .. "/" .. f) then idx[f] = nil; n = n + 1 end
    end
  end
  band.write_json(dir .. "/index.json", idx)
  return n
end

-- ---- items, tracks, P_EXT tags --------------------------------------------------------------

function band.track_ext(tr, key) return select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, "", false)) end

-- A track's colour as the band has it (REAPER's native I_CUSTOMCOLOR): a person's colour may be showing in its place
-- here (lib/people.lua), with the band's waiting in P_EXT:band_colour. Everything that sends, saves or restores a
-- track's colour goes through these two.
function band.track_colour(tr)
  local held = band.track_ext(tr, "band_colour")
  if held ~= "" then return tonumber(held) or 0 end
  return reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR")
end
function band.set_track_colour(tr, c)
  if band.track_ext(tr, "band_colour") ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", tostring(math.floor(c)), true)
  else
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c)
  end
end
-- Show `c` (native) on a track here only, or (nil) the band's colour again.
function band.show_colour(tr, c)
  local held = band.track_ext(tr, "band_colour")
  if c then
    if held == "" then reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", tostring(math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR"))), true) end
    if reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") ~= c then reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", c) end
  elseif held ~= "" then
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_colour", "", true)
    reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", tonumber(held) or 0)
  end
end
function band.set_track_ext(tr, key, v) reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:" .. key, v, true) end
function band.item_ext(it, key) return select(2, reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, "", false)) end
function band.set_item_ext(it, key, v) reaper.GetSetMediaItemInfo_String(it, "P_EXT:" .. key, v, true) end
function band.take_ext(tk, key) return select(2, reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. key, "", false)) end
function band.set_take_ext(tk, key, v) reaper.GetSetMediaItemTakeInfo_String(tk, "P_EXT:" .. key, v, true) end

function band.add_item(track, path, pos, len)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local item = reaper.AddMediaItemToTrack(track)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", pos)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len or (reaper.GetMediaSourceLength(src)))
  band.follow_tempo(item, take)
  reaper.UpdateItemInProject(item)
  return item, take
end

-- Band audio follows tempo changes the way the project says, but properly. REAPER's default timebase (beats:
-- position, length, rate) gives a whole item ONE playrate at a tempo change, so a song-long print or pad drifted
-- everywhere before the change (seen: up to 0.8 s). REAPER's own "auto-stretch at tempo changes" stretches each
-- part of the item by the tempo where it plays instead: unchanged before the change, stretched after it, the same
-- on every machine (same map). So in that timebase band audio gets auto-stretch; in "position only" or "time" the
-- project's setting is left alone. MIDI is left alone: its notes follow the beat, and its prints are re-rendered.
function band.follow_tempo(item, take)
  if not take or reaper.TakeIsMIDI(take) then return end
  local proj = reaper.GetItemProjectContext(item)
  local mode = reaper.GetMediaItemInfo_Value(item, "C_BEATATTACHMODE")
  if mode == -1 then mode = reaper.GetSetProjectInfo(proj, "PROJECT_TIMEBASE", 0, false) end
  if mode == 1 and reaper.GetMediaItemInfo_Value(item, "C_AUTOSTRETCH") ~= 1 then
    reaper.SetMediaItemInfo_Value(item, "C_BEATATTACHMODE", 1)
    reaper.SetMediaItemInfo_Value(item, "C_AUTOSTRETCH", 1)
  end
end

-- Point a take at a better file (preview -> full). Length, position and offsets are left alone.
function band.swap_source(take, path)
  local src = take and reaper.PCM_Source_CreateFromFile(path)
  if not src then return false end
  local old = reaper.GetMediaItemTake_Source(take)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.PCM_Source_Destroy(old) -- the API leaves the old source to the caller
  reaper.UpdateItemInProject(reaper.GetMediaItemTake_Item(take))
  return true
end

function band.find_track(proj, name, skip_stems)
  local lname = name:lower()
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, n = reaper.GetTrackName(tr)
    if n:lower() == lname and not (skip_stems and band.track_ext(tr, "band_stem") ~= "") then return tr end
  end
end

-- Append a track to the end of proj, which may be a background tab (the inbox runs on one).
-- Before 7.18 tracks can only be added to the active tab: return nil and the caller retries later.
function band.new_track(proj, name)
  local n = reaper.CountTracks(proj)
  if reaper.InsertTrackInProject then
    reaper.InsertTrackInProject(proj, n, 1)
  elseif proj == reaper.EnumProjects(-1) then
    reaper.InsertTrackAtIndex(n, true)
  else
    return nil
  end
  local tr = reaper.GetTrack(proj, n)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  return tr
end

-- Copy a synced file into proj's recording folder and return the copy's path, so the project never
-- depends on the shared folder: it may mount after REAPER loads, and a sync client can't update files
-- REAPER holds open. "stems/v5/01.flac" becomes "<record path>/bandsync/v5_01.flac". An unsaved
-- project has no folder of its own, so it keeps the original path.
function band.localize(proj, path)
  if reaper.GetProjectName(proj) == "" then return path end
  local dir = norm(reaper.GetProjectPathEx(proj)) .. "/bandsync"
  local parent, name = path:match("([^/]+)/([^/]+)$")
  local dst = dir .. "/" .. parent .. "_" .. name
  if not reaper.file_exists(dst) then
    reaper.RecursiveCreateDirectory(dir, 0)
    band.copy_atomic(path, dst)
  end
  return dst
end

-- ---- stems ----------------------------------------------------------------------------------

local function best(dir, st)
  local full, prev = dir .. "/" .. st.file, st.preview and (dir .. "/" .. st.preview)
  if reaper.file_exists(full) then return full, "full" end
  if prev and reaper.file_exists(prev) then return prev, "preview" end
end

-- ---- takes ----------------------------------------------------------------------------------

function band.take_state(proj, id) return select(2, reaper.GetProjExtState(proj, band.TAKES, id)) end
function band.set_take_state(proj, id, v) reaper.SetProjExtState(proj, band.TAKES, id, v) end

-- A take's BandSync id: received takes carry band_take, our own sent takes band_sent.
function band.take_id(tk)
  local id = band.take_ext(tk, "band_take")
  if id == "" then id = band.take_ext(tk, "band_sent") end
  return id ~= "" and id or nil
end

-- lower(id) -> { item, take } for every BandSync take in proj. Lowercased because REAPER upper-cases
-- ProjExtState keys on save, so ids read back from state can differ in case from the takes' own.
function band.take_index(proj)
  local idx = {}
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    for k = 0, reaper.CountTakes(it) - 1 do
      local tk = reaper.GetTake(it, k)
      local id = band.take_id(tk)
      if id then idx[id:lower()] = { it, tk } end
    end
    local legacy = band.item_ext(it, "band_take") -- 0.2 tagged the item instead of the take
    if legacy ~= "" and not idx[legacy:lower()] then idx[legacy:lower()] = { it, reaper.GetActiveTake(it) } end
  end
  return idx
end

function band.find_take(proj, id)
  local hit = band.take_index(proj)[id:lower()]
  if hit then return hit[1], hit[2] end
end

-- "takes" mode: add the incoming take to the item on the matching track it overlaps most, so a
-- bandmate's passes stack as takes of one item. The item grows to fit; nothing already in it moves
-- (REAPER honours negative take start offsets: silence until the source begins).
-- The track a take for `name` belongs on. A wet print already carries the sender's FX, so it goes on a
-- BandSync mirror track (no FX of ours, never processed twice): `name` itself when we have no track by
-- that name, else "name (band)" beside our own. Dry takes go on our real track, through our FX once.
function band.dest_track(proj, name, wet)
  if not wet then return band.find_track(proj, name, true) or band.new_track(proj, name) end
  for _, n in ipairs({ name, name .. " (band)" }) do
    local tr = band.find_track(proj, n, true)
    if tr and band.track_ext(tr, "band_mirror") ~= "" then return tr end
  end
  local tr = band.new_track(proj, band.find_track(proj, name, true) and (name .. " (band)") or name)
  if tr then reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:band_mirror", "1", true) end
  return tr
end

-- Add take t as another take of item `best`, growing the item to fit without moving anything in it.
local function add_take_to(best, t, path)
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local p = reaper.GetMediaItemInfo_Value(best, "D_POSITION")
  local e = p + reaper.GetMediaItemInfo_Value(best, "D_LENGTH")
  local np, ne = math.min(p, t.pos), math.max(e, t.pos + t.len)
  if np < p then -- grow left: shift every existing take's offset so its audio stays put
    for k = 0, reaper.CountTakes(best) - 1 do
      local tk = reaper.GetTake(best, k)
      reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS") - (p - np))
    end
    reaper.SetMediaItemInfo_Value(best, "D_POSITION", np)
  end
  reaper.SetMediaItemInfo_Value(best, "D_LENGTH", ne - np)
  reaper.SetMediaItemInfo_Value(best, "B_LOOPSRC", 0) -- a grown item must play silence, not repeat a shorter take
  local playing = reaper.GetActiveTake(best)
  local take = reaper.AddTakeToMediaItem(best)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", np - t.pos)
  if playing then reaper.SetActiveTake(playing) end -- never change what is already playing
  reaper.UpdateItemInProject(best)
  return best, take
end

local function add_as_take(proj, t, path)
  local tr = band.dest_track(proj, t.track, t.wet)
  if not tr then return nil end
  local best, overlap = nil, 0
  for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, i)
    local p = reaper.GetMediaItemInfo_Value(it, "D_POSITION")
    local o = math.min(p + reaper.GetMediaItemInfo_Value(it, "D_LENGTH"), t.pos + t.len) - math.max(p, t.pos)
    if o > overlap then best, overlap = it, o end
  end
  if not best then return band.add_item(tr, path, t.pos, t.len) end
  return add_take_to(best, t, path)
end

-- "mirror" (the default): rebuild the sender's structure. Passes of one sender item (same group) stay
-- one item here, in the same lane, on a track with the same lane layout; so takes and lanes coexist
-- exactly as they do for the sender.
local function mirror(proj, t, path)
  if t.based_on then -- a shared sound: an extra take in the band item holding the original. Not in the owner's own
    -- item: that's on their real track, whose plug-ins would process the print a second time; there it goes on the
    -- FX-free mirror track like any print
    local it, tk = band.find_take(proj, t.based_on)
    if it and band.take_ext(tk, "band_take") ~= "" then return add_take_to(it, t, path) end
  end
  local tr = band.dest_track(proj, t.track, t.wet)
  if not tr then return nil end
  if t.lane then
    if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then
      reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
      reaper.UpdateTimeline()
    end
    if reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") < t.lane + 1 then
      reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", t.lane + 1)
    end
  end
  if t.group then
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      if band.item_ext(it, "band_group") == t.group then return add_take_to(it, t, path) end
    end
  end
  local it, tk = band.add_item(tr, path, t.pos, t.len)
  if not it then return nil end
  if t.group then band.set_item_ext(it, "band_group", t.group) end
  if t.lane then
    reaper.SetMediaItemInfo_Value(it, "I_FIXEDLANE", t.lane)
    if t.lane_name and t.lane_name ~= "" then reaper.GetSetMediaTrackInfo_String(tr, "P_LANENAME:" .. t.lane, t.lane_name, true) end
  end
  return it, tk
end

-- Where a take lands. mode: "lanes" (new fixed lane on the matching track), "takes" (see above),
-- "person" ("Takes - <user>" track) or "inbox" (one muted "BandSync inbox" track).
local function target(proj, t, mode)
  if mode == "person" then
    local name = "Takes - " .. t.user
    return band.find_track(proj, name) or band.new_track(proj, name)
  elseif mode == "inbox" then
    local tr = band.find_track(proj, "BandSync inbox")
    if not tr then
      tr = band.new_track(proj, "BandSync inbox")
      if tr then reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1) end
    end
    return tr
  end
  local tr = band.dest_track(proj, t.track, t.wet)
  if not tr or reaper.CountTrackMediaItems(tr) == 0 then return tr end -- first take on an empty part just plays
  if reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE") ~= 2 then
    reaper.SetMediaTrackInfo_Value(tr, "I_FREEMODE", 2)
    reaper.UpdateTimeline()
  end
  local lane = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES"))
  reaper.SetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES", lane + 1)
  return tr, lane
end

-- Offsets are shared relative to where a print was placed ("base"), because each project's take
-- offsets differ (a receiver's take is a print starting at the item, the sender's points into a recording).
function band.mark_base(tk) band.set_take_ext(tk, "band_base_offs", string.format("%.9f", reaper.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS"))) end
function band.base_offs(tk) return tonumber(band.take_ext(tk, "band_base_offs")) or 0 end

-- The dry companion of a "both" print: another take in the same item, tagged band_dry = id.
local function add_dry(item, take, t, dry_path)
  local src = dry_path and reaper.PCM_Source_CreateFromFile(dry_path)
  if not src then return end
  local playing = reaper.GetActiveTake(item)
  local tk = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(tk, src)
  reaper.SetMediaItemTakeInfo_Value(tk, "D_STARTOFFS", reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"))
  reaper.GetSetMediaItemTakeInfo_String(tk, "P_NAME", select(2, reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)) .. " (dry)", true)
  band.set_take_ext(tk, "band_dry", t.id)
  reaper.SetActiveTake(playing or take) -- what was playing keeps playing; the dry print is a click away
end

-- ---- MIDI copies ------------------------------------------------------------------------------
-- A MIDI take's notes travel with its print. Each receiver gets them as an editable MIDI item (tagged
-- band_midi = id) on a muted "<track> (MIDI)" track: edit the notes and everyone follows, or put your own
-- instrument on that track and "Print my MIDI" to replace the print everyone hears.

function band.find_midi(proj, id)
  local lid = id:lower()
  for i = 0, reaper.CountMediaItems(proj) - 1 do
    local it = reaper.GetMediaItem(proj, i)
    local tk = reaper.GetActiveTake(it)
    if tk and band.take_ext(tk, "band_midi"):lower() == lid then return it, tk end
  end
end

-- Notes in drum map `from` (a take's), rewritten into the drum map set on track tr ("" or unset: as they are).
function band.to_track_map(root, buf, from, tr)
  local to = band.track_ext(tr, "band_drummap")
  if not root or (from or "") == "" or to == "" or from == to then return buf end
  local dm = require("drummap")
  return dm.translate(buf, dm.table(dm.load(root, from), dm.load(root, to)))
end

return band

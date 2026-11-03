-- Suggestions: an edit that reaches a part someone else has claimed (a section copied or moved across the whole song,
-- say). REAPER gives a script no way to stop an edit, only to see it afterwards. So the claimed parts go back as the band
-- has them, as always, and what was done to them goes to the part's owner as one line: Accept or Decline. Accepted, it
-- lands on the owner's machine as their own change and goes out from there, so a claim is never released or overruled.
-- rooms/<room>/suggestions/<id>.json        what it is and who it's for (only its sender writes it)
-- rooms/<room>/suggestions/<id>.answer.json what became of it (only whoever answers writes it)
-- rooms/<room>/suggestions/parts/<id>/<oid>.json  each change, as it would have gone out; its sender removes them once answered
-- shortcut: plug-in chains stay out: one can change by itself, and a false suggestion asks an owner about nothing. A plug-in
-- change on a claimed track is put back, as before.
local suggest = {}

suggest.GAP = 15 -- seconds: what's refused this close together is one act, and one line for its owner
suggest.REPEATS = 5 -- the same thing refused this often in 5 minutes is changing by itself, not being edited: no more lines
local ANSWER = "%.answer%.json$"

local function dir_of(room_dir) return room_dir .. "/suggestions" end
local function parts_of(room_dir, id) return dir_of(room_dir) .. "/parts/" .. id end

local open, heads, repeats, cache, done = {}, {}, {}, {}, {} -- (done: answered ones are never read again)
local acts, swept = 0, {}
suggest.note = nil -- the last thing to say on the bar (why Accept can't go ahead yet)

-- What it does, in words. Pure.
function suggest.words(h)
  local bits = {}
  if (h.changes or 0) > 0 then bits[#bits + 1] = "changes " .. h.changes end
  if (h.adds or 0) > 0 then bits[#bits + 1] = "adds " .. h.adds end
  if (h.removes or 0) > 0 then bits[#bits + 1] = "removes " .. h.removes end
  return table.concat(bits, ", ") .. " on " .. table.concat(h.names or {}, ", ")
end
function suggest.count(h) return #(h.oids or {}) end

-- Into the act this person is making for this owner (or a new one). false: not added (it keeps coming back by itself).
function suggest.add(room_dir, me, owner, c)
  local band = require("band")
  local now = reaper.time_precise()
  local r = repeats[c.oid]
  if not r or now - r.at > 300 then r = { n = 0 } end
  if r.n >= suggest.REPEATS then return false end
  r.n, r.at = r.n + 1, now
  repeats[c.oid] = r
  local key = room_dir .. "\0" .. owner
  local a = open[key]
  if not a or now - a.last > suggest.GAP or reaper.file_exists(dir_of(room_dir) .. "/" .. a.head.id .. ".answer.json") then -- (answered already: a new one)
    local tag = require("mirror").user_tag(me) .. "-" .. os.date("!%Y%m%d-%H%M%S")
    acts = acts + 1 -- (two in a second get names of their own)
    a = { dir = room_dir, seen = {}, named = {}, head = { id = tag .. "-" .. acts .. "-" .. require("mirror").user_tag(owner), from = me, owner = owner,
      time = os.date("!%Y-%m-%dT%H:%M:%SZ"), oids = {}, names = {}, changes = 0, adds = 0, removes = 0 } }
    open[key] = a
  end
  a.last = now
  local h = a.head
  reaper.RecursiveCreateDirectory(parts_of(room_dir, h.id), 0)
  band.write_json(parts_of(room_dir, h.id) .. "/" .. c.oid .. ".json", c)
  if not a.seen[c.oid] then
    a.seen[c.oid] = true
    h.oids[#h.oids + 1] = c.oid
    if c.gone then h.removes = h.removes + 1 elseif (c.rev or 0) == 0 then h.adds = h.adds + 1 else h.changes = h.changes + 1 end
    local name = (c.name or "") ~= "" and c.name or "an unnamed track"
    if not a.named[name] then a.named[name] = true; h.names[#h.names + 1] = name end
  end
  heads[key] = a
  return true
end

-- The parts are written as they come; what's listed goes out at the end of the look.
function suggest.flush()
  local band = require("band")
  for key, a in pairs(heads) do
    reaper.RecursiveCreateDirectory(dir_of(a.dir), 0)
    band.write_json(dir_of(a.dir) .. "/" .. a.head.id .. ".json", a.head)
    heads[key] = nil
    cache[a.dir] = nil
  end
end

-- Every suggestion in this room, with its answer if it has one.
function suggest.all(room_dir)
  local band = require("band")
  local c = cache[room_dir]
  if c and reaper.time_precise() - c.at < 2 then return c.list end
  local list, dir = {}, dir_of(room_dir)
  for _, f in ipairs(band.files(dir, ".json")) do
    if not f:find(ANSWER) then
      local path = dir .. "/" .. f
      local h = done[path]
      if not h then
        h = band.read_json(path)
        if type(h) == "table" and type(h.id) == "string" and type(h.oids) == "table" then
          local ans = band.read_json(dir .. "/" .. h.id .. ".answer.json")
          h.answer = type(ans) == "table" and ans or nil
          if h.answer then done[path] = h end
        else h = nil end
      end
      if h then list[#list + 1] = h end
    end
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  cache[room_dir] = { at = reaper.time_precise(), list = list }
  return list
end

-- What waits on this person, and what this person is waiting on.
function suggest.rows(room_dir, me)
  local mine, waiting = {}, {}
  for _, h in ipairs(suggest.all(room_dir)) do
    if not h.answer and h.owner == me then mine[#mine + 1] = h
    elseif not h.answer and h.from == me then waiting[#waiting + 1] = h end
  end
  return mine, waiting
end

function suggest.answer(room_dir, h, me, answer, extra)
  local a = extra or {}
  a.by, a.answer, a.time = me, answer, os.date("!%Y-%m-%dT%H:%M:%SZ")
  require("band").write_json(dir_of(room_dir) .. "/" .. h.id .. ".answer.json", a)
  cache[room_dir] = nil
end

local RANK = { track = 1, recv = 2, misc = 2, env = 2, item = 3 }

-- Accept: every change lands here without being noted as the band's, so Live sync's next look sends it as this person's
-- own, prints and all. In one undo block not named after BandSync, so Ctrl+Z is REAPER's undo and takes the whole of it back.
-- `may(name, pos)`: this person may change that. -> done, changed since, not theirs; or nil and why it can't go yet.
function suggest.accept(proj, cfg, room_dir, h, may, local_mix)
  local band, mirror = require("band"), require("mirror")
  if reaper.GetPlayStateEx(proj) ~= 0 then return nil, "Stop playback first." end
  if reaper.EnumProjects(-1) ~= proj then return nil, "Switch to this song's tab first." end
  local media, list = room_dir .. "/media", {}
  for _, oid in ipairs(h.oids) do
    local c = band.read_json(parts_of(room_dir, h.id) .. "/" .. oid .. ".json")
    if type(c) ~= "table" then return nil, "It's still arriving here: try again in a moment." end
    if c.obj == "item" and not c.gone then
      for _, path in ipairs(mirror.media_needed(c.state, media)) do
        if not reaper.file_exists(path) then return nil, "Its audio is still arriving here: try again in a moment." end
      end
    end
    list[#list + 1] = c
  end
  table.sort(list, function(a, b)
    local ra, rb = RANK[a.obj] or 9, RANK[b.obj] or 9
    if a.gone ~= b.gone then return not a.gone end -- (what goes, after what stays)
    if ra ~= rb then return ra < rb end
    return a.oid < b.oid
  end)
  local did, stale, refused = 0, 0, 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(proj)
  for _, c in ipairs(list) do
    local rev = mirror.known(proj, c.oid)
    if (rev or 0) ~= (c.rev or 0) then stale = stale + 1 -- (changed since it was suggested: what's there now stands)
    elseif not may(c.name, c.pos) then refused = refused + 1
    else
      local ok, res = pcall(mirror.apply, proj, c, media, local_mix)
      if ok and res then did = did + 1 else band.log("couldn't accept a change on " .. tostring(c.name) .. ": " .. tostring(ok and "it can't land here" or res)) end
    end
  end
  -- tracks, items and automation only (plug-ins never come this way): recording everything, undoing it reloaded every plug-in, and
  -- Superior Drummer's saved data read differently, so its chain went out and 7 parts were printed again (PC, 0.42.29)
  reaper.Undo_EndBlock2(proj, "Accept " .. tostring(h.from) .. "'s suggestion", 1 | 4 | 32)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  return did, stale, refused
end

-- What Live sync says when a suggestion arrives or is answered, once. And its sender tidies up: the parts are no longer
-- needed, and a "(yours, not sent)" track an accepted suggestion has emptied goes.
function suggest.notices(proj, cfg, room_dir)
  local band, mirror = require("band"), require("mirror")
  local SEC = "BandSync.suggest"
  for _, h in ipairs(suggest.all(room_dir)) do
    local seen = select(2, reaper.GetProjExtState(proj, SEC, h.id))
    if h.owner == cfg.user and not h.answer and seen == "" then
      band.log(string.format("%s suggests an edit to your parts (%s): Accept or Decline at the top of the panel", tostring(h.from), suggest.words(h)))
      reaper.SetProjExtState(proj, SEC, h.id, "1")
    elseif h.from == cfg.user and h.answer and seen ~= "2" then
      local a = h.answer
      if a.answer == "accepted" then
        band.log(string.format("%s accepted your suggestion (%s)%s", tostring(h.owner), suggest.words(h),
          (a.left or 0) > 0 and string.format("; %d had changed since or weren't theirs, and stay as they are", a.left) or ""))
      elseif a.answer == "declined" then
        band.log(string.format("%s declined your suggestion (%s). Anything new you added is still on your '(yours, not sent)' tracks", tostring(h.owner), suggest.words(h)))
      end
      for _, f in ipairs(band.files(parts_of(room_dir, h.id), ".json")) do os.remove(parts_of(room_dir, h.id) .. "/" .. f) end
      os.remove(parts_of(room_dir, h.id))
      reaper.SetProjExtState(proj, SEC, h.id, "2")
    end
  end
  -- (every few seconds, not on the answer: that can arrive before the changes it brings)
  if reaper.time_precise() - (swept[tostring(proj)] or 0) > 5 then
    swept[tostring(proj)] = reaper.time_precise()
    for t = reaper.CountTracks(proj) - 1, 0, -1 do
      local tr = reaper.GetTrack(proj, t)
      local name = select(2, reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false))
      if mirror.local_track(tr) and name:find(" (yours, not sent)", 1, true) and reaper.CountTrackMediaItems(tr) == 0 then reaper.DeleteTrack(tr) end
    end
  end
end

-- The lines at the top of the panel. Buttons first, on the line itself: a panel docked short shows one line of this (James's PC).
function suggest.bar(ctx, ImGui, proj, cfg, room_dir, can, local_mix)
  local band = require("band")
  local mine, waiting = suggest.rows(room_dir, cfg.user)
  for _, h in ipairs(mine) do
    ImGui.PushID(ctx, h.id)
    if ImGui.SmallButton(ctx, "Accept") then
      local did, stale, refused = suggest.accept(proj, cfg, room_dir, h, function(name, pos) return can(cfg.user, name, pos) end, local_mix)
      if did then
        suggest.note = nil
        suggest.answer(room_dir, h, cfg.user, "accepted", { left = stale + refused })
        band.log(string.format("you accepted %s's suggestion: %d change(s) go to the band as yours%s", tostring(h.from), did,
          stale + refused > 0 and string.format("; %d had changed since or aren't yours, and stay as they are", stale + refused) or ""))
      else suggest.note = stale end
    end
    ImGui.SetItemTooltip(ctx, "It lands on your tracks as your own change and goes to the band from you. Your claim stays. " .. require("undo").key_name() .. " takes it back.")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Decline") then
      suggest.answer(room_dir, h, cfg.user, "declined")
      band.log(string.format("you declined %s's suggestion (%s)", tostring(h.from), suggest.words(h)))
    end
    ImGui.SetItemTooltip(ctx, "Your tracks stay as they are. " .. tostring(h.from) .. " keeps a copy of anything new on a track of their own.")
    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xF2BF40FF)
    ImGui.TextWrapped(ctx, string.format("%s's edit touches your parts: %s", tostring(h.from), suggest.words(h)))
    ImGui.PopStyleColor(ctx)
    ImGui.PopID(ctx)
  end
  for _, h in ipairs(waiting) do
    ImGui.PushID(ctx, h.id)
    if ImGui.SmallButton(ctx, "Withdraw") then suggest.answer(room_dir, h, cfg.user, "withdrawn") end
    ImGui.SetItemTooltip(ctx, "Take the suggestion back. Anything new you added stays on your '(yours, not sent)' tracks.")
    ImGui.SameLine(ctx)
    ImGui.TextWrapped(ctx, string.format("Waiting on %s: %s", tostring(h.owner), suggest.words(h)))
    ImGui.PopID(ctx)
  end
  if suggest.note and #mine > 0 then ImGui.TextWrapped(ctx, suggest.note) end
end

return suggest

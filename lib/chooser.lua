-- Choosing a song (and room): one searchable window instead of a long menu. Most recent activity first; each row
-- shows who hosts it, who's in it and when anyone last was. Songs you hide (right-click) stay hidden on this
-- machine until "Show hidden". Without ReaImGui it falls back to the plain menu.
local band = require("band")
local chooser = {}

-- What the window lists: { song, host, rooms, members, last (ISO time or "") }, most recent activity first.
-- keep(song): only songs it says yes to (Solo edit lists songs with a solo version).
function chooser.songs(cfg, keep)
  local out = {}
  for _, song in ipairs(band.songs(cfg)) do
    if not keep or keep(song) then
      local s = band.read_json(band.session_path(cfg, song)) or {}
      local row, seen = { song = song, host = s.host or "?", rooms = {}, members = {}, last = s.published or "" }, {}
      local rdir = band.song_dir(cfg, song) .. "/rooms"
      for _, room in ipairs(band.subdirs(rdir)) do
        row.rooms[#row.rooms + 1] = room
        for _, f in ipairs(band.files(rdir .. "/" .. room .. "/status", ".json")) do -- each machine's receipt: who, and when
          local st = band.read_json(rdir .. "/" .. room .. "/status/" .. f)
          if type(st) == "table" then
            if type(st.user) == "string" and not seen[st.user] then seen[st.user] = true; row.members[#row.members + 1] = st.user end
            if type(st.time) == "string" and st.time > row.last then row.last = st.time end
          end
        end
      end
      if #row.rooms == 0 then row.rooms = { "main" } end
      table.sort(row.rooms, function(a, z) -- main first, side rooms by name
        if (a == "main") ~= (z == "main") then return a == "main" end
        return a < z
      end)
      table.sort(row.members)
      out[#out + 1] = row
    end
  end
  table.sort(out, function(a, z) if a.last ~= z.last then return a.last > z.last end return a.song < z.song end)
  return out
end

-- Whether a row matches what's typed: every word somewhere in its song, host, bandmates or rooms.
function chooser.match(row, text)
  local hay = (row.song .. " " .. row.host .. " " .. table.concat(row.members, " ") .. " " .. table.concat(row.rooms, " ")):lower()
  for word in (text or ""):lower():gmatch("%S+") do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

-- "5 min ago", "3 h ago", "2 days ago" for an ISO UTC time.
function chooser.ago(iso, now)
  local secs = band.age(iso, now)
  if not secs or secs == math.huge then return "" end
  if secs < 90 then return "just now" end
  if secs < 5400 then return string.format("%d min ago", math.floor(secs / 60 + 0.5)) end
  if secs < 129600 then return string.format("%d h ago", math.floor(secs / 3600 + 0.5)) end
  return string.format("%d days ago", math.floor(secs / 86400 + 0.5))
end

local HIDDEN = "hidden_songs"
local function hidden()
  local set = {}
  for s in reaper.GetExtState(band.SECTION, HIDDEN):gmatch("[^|]+") do set[s] = true end
  return set
end
local function save_hidden(set)
  local list = {}
  for s in pairs(set) do list[#list + 1] = s end
  table.sort(list)
  reaper.SetExtState(band.SECTION, HIDDEN, table.concat(list, "|"), true)
end

-- Opens the chooser. done(song, room) once one is picked, done() if it's closed.
-- opts: title, action (the button: "Open"), rooms = nil (song only) | "pick" (an existing room) | "new" (or a new
-- side room), keep(song).
function chooser.open(cfg, opts, done)
  local rows = chooser.songs(cfg, opts.keep)
  if #rows == 0 then return done() end
  if not reaper.APIExists("ImGui_GetBuiltinPath") then -- no ReaImGui: the plain menus
    local list = {}
    for _, r in ipairs(rows) do list[#list + 1] = r.song end
    local song = band.pick(list)
    if not song then return done() end
    local room
    for _, r in ipairs(rows) do if r.song == song then room = #r.rooms > 1 and opts.rooms and band.pick(r.rooms) or r.rooms[1] end end
    if not room then return done() end
    return done(song, room)
  end
  package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
  local ImGui = require "imgui" "0.10"
  local ctx = ImGui.CreateContext("BandSync: choose")
  local text, sel, room, new_room, show_hidden, hide = "", nil, nil, "", false, hidden()
  local now = os.date("!*t") -- (band.age's "now")
  local function visible_rows()
    local out = {}
    for _, r in ipairs(rows) do
      if (show_hidden or not hide[r.song]) and chooser.match(r, text) then out[#out + 1] = r end
    end
    return out
  end
  local function loop()
    ImGui.SetNextWindowSize(ctx, 680, 440, ImGui.Cond_FirstUseEver)
    ImGui.SetNextWindowBgAlpha(ctx, 1) -- opaque: the arrange view showing through made it hard to read
    local shown, open = ImGui.Begin(ctx, (opts.title or "Choose a song") .. "###bandsync_chooser", true)
    local result -- { song, room } when chosen, false when cancelled
    if shown then
      local list = visible_rows()
      if not sel or not chooser.match(sel, text) then sel = list[1]; room = sel and sel.rooms[1] end -- typing keeps a match selected
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      ImGui.SetNextItemWidth(ctx, -150)
      local _, t = ImGui.InputTextWithHint(ctx, "##find", "Type to search: song, host, bandmate", text)
      text = t
      ImGui.SameLine(ctx)
      local _, sh = ImGui.Checkbox(ctx, "Show hidden", show_hidden)
      show_hidden = sh
      local flags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_Resizable
      if ImGui.BeginTable(ctx, "songs", 4, flags, 0, -64) then
        ImGui.TableSetupScrollFreeze(ctx, 0, 1)
        ImGui.TableSetupColumn(ctx, "Song")
        ImGui.TableSetupColumn(ctx, "Host")
        ImGui.TableSetupColumn(ctx, "Who's in it")
        ImGui.TableSetupColumn(ctx, "Last activity")
        ImGui.TableHeadersRow(ctx)
        for i, r in ipairs(list) do
          ImGui.TableNextRow(ctx)
          ImGui.TableNextColumn(ctx)
          ImGui.PushID(ctx, tostring(i))
          if ImGui.Selectable(ctx, r.song .. (hide[r.song] and "  (hidden)" or ""), sel == r,
              ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowDoubleClick) then
            if sel ~= r then sel, room = r, r.rooms[1] end
            if ImGui.IsMouseDoubleClicked(ctx, 0) then result = { r.song, room } end
          end
          if ImGui.BeginPopupContextItem(ctx) then -- right-click: tidy test songs and old ones out of the list
            if ImGui.MenuItem(ctx, hide[r.song] and "Show in this list again" or "Hide from this list (this machine only)") then
              hide[r.song] = not hide[r.song] or nil
              save_hidden(hide)
            end
            ImGui.EndPopup(ctx)
          end
          ImGui.PopID(ctx)
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, r.host)
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, table.concat(r.members, ", "))
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, r.last ~= "" and chooser.ago(r.last, now) or "")
        end
        ImGui.EndTable(ctx)
      end
      if #list == 0 then ImGui.TextDisabled(ctx, "No song matches '" .. text .. "'.") end
      -- the room, for the selected song
      if sel and opts.rooms then
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, "Room:")
        for _, rm in ipairs(sel.rooms) do
          ImGui.SameLine(ctx)
          if ImGui.RadioButton(ctx, rm, room == rm and new_room == "") then room, new_room = rm, "" end
        end
        if opts.rooms == "new" then
          ImGui.SameLine(ctx)
          ImGui.SetNextItemWidth(ctx, 180)
          local _, nr = ImGui.InputTextWithHint(ctx, "##newroom", "or a new side room", new_room)
          new_room = nr
        end
      else
        ImGui.Dummy(ctx, 0, ImGui.GetFrameHeight(ctx))
      end
      local pick_room = (opts.rooms == "new" and band.clean(new_room) ~= "") and band.clean(new_room) or room
      ImGui.BeginDisabled(ctx, not sel)
      if ImGui.Button(ctx, (opts.action or "Open") .. (sel and (" '" .. sel.song .. "'" .. (opts.rooms and (", room " .. tostring(pick_room)) or "")) or ""))
          or (sel and ImGui.IsKeyPressed(ctx, ImGui.Key_Enter)) then
        result = { sel.song, pick_room }
      end
      ImGui.EndDisabled(ctx)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then result = false end
      ImGui.SameLine(ctx)
      ImGui.TextDisabled(ctx, "Enter opens, Esc cancels; right-click a song to hide it")
      ImGui.End(ctx)
    end
    if result then return done(result[1], opts.rooms and result[2] or nil) end
    if result == false or not open then return done() end
    reaper.defer(loop)
  end
  reaper.defer(loop)
end

return chooser

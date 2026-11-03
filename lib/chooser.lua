-- Choosing a song (and room): one searchable window instead of a long menu. Most recent activity first; each row
-- shows who hosts it, who's in it and when anyone last was. Songs you hide (right-click) stay hidden on this
-- machine until "Show hidden". Without ReaImGui it falls back to the plain menu.
local band = require("band")
local chooser = {}

-- What the window lists: { song, host, rooms, members, last (ISO time or "") }, most recent activity first.
-- keep(song): only songs it says yes to (Solo edit lists songs with a solo version).
function chooser.songs(cfg, keep)
  local out = {}
  local renamed = band.names and band.names(cfg.root) or {} -- (old name's tag -> the name now: _band/names.json)
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
            local who = type(st.user) == "string" and (renamed[(st.user:gsub("[^%w]", "_")):upper()] or st.user)
            if who and not seen[who] then seen[who] = true; row.members[#row.members + 1] = who end
            if type(st.time) == "string" and st.time > row.last then row.last = st.time end
          end
        end
      end
      if #row.members == 0 then -- older songs have no receipts: who sent takes (takes are named <user>-<date>-...)
        for _, room in ipairs(row.rooms) do
          for _, f in ipairs(band.files(rdir .. "/" .. room .. "/takes", ".json")) do
            local who = f:match("^(.-)%-%d%d%d%d%d%d%d%d%-")
            if who and not seen[who] then seen[who] = true; row.members[#row.members + 1] = who:gsub("_", " ") end
          end
        end
      end
      row.folder = (band.read_json(band.song_dir(cfg, song) .. "/folder.json") or {}).folder or ""
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

-- Put a song in a folder ("" = none). The folder lives in the song's own folder.json, so the whole band sees the
-- same folders and two people filing different songs never write the same file.
function chooser.set_folder(cfg, song, folder)
  folder = (folder or ""):gsub("[%c/\\]", ""):match("^%s*(.-)%s*$")
  local path = band.song_dir(cfg, song) .. "/folder.json"
  if folder == "" then os.remove(path) else band.write_json(path, { folder = folder }) end
  return folder
end

-- The rows by folder: { { name, rows } }, folders by name and songs without one last (name ""). Every row of the
-- given list appears once, in its order.
function chooser.groups(rows)
  local by, names = {}, {}
  for _, r in ipairs(rows) do
    local f = r.folder or ""
    if not by[f] then by[f] = {}; names[#names + 1] = f end
    table.insert(by[f], r)
  end
  table.sort(names, function(a, z)
    if (a == "") ~= (z == "") then return z == "" end
    return a:lower() < z:lower()
  end)
  local out = {}
  for _, n in ipairs(names) do out[#out + 1] = { name = n, rows = by[n] } end
  return out
end

-- Whether a row matches what's typed: every word somewhere in its song, folder, host, bandmates or rooms.
function chooser.match(row, text)
  local hay = (row.song .. " " .. (row.folder or "") .. " " .. row.host .. " " .. table.concat(row.members, " ") .. " " .. table.concat(row.rooms, " ")):lower()
  for word in (text or ""):lower():gmatch("%S+") do
    if not hay:find(word, 1, true) then return false end
  end
  return true
end

-- The row to select for what's typed: the song named exactly that, else one whose name starts with it, else one
-- that has it in its name, else the first shown. `groups` as chooser.groups gives them (the order they're shown).
-- (Mac, 2026-10-31: "Mirror Test" typed selected MirrorTest4, the newest of several matches, and Enter opens it.)
function chooser.best(groups, text)
  local t = (text or ""):lower():match("^%s*(.-)%s*$")
  local best, score
  for _, g in ipairs(groups) do
    for _, r in ipairs(g.rows) do
      local n = r.song:lower()
      local s = t == "" and 0 or n == t and 3 or n:sub(1, #t) == t and 2 or n:find(t, 1, true) and 1 or 0
      if not best or s > score then best, score = r, s end
    end
  end
  return best
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
-- A room's preview, from its newest summary (lib/mirror.lua mirror.summary): { text, missing = { plug-in names } }
-- or nil when no machine has written one yet. Cached per song/room for this chooser.
local previews, have = {}, nil
function chooser.preview(cfg, song, room)
  local key = song .. "/" .. tostring(room)
  if previews[key] ~= nil then return previews[key] or nil end
  local dir = cfg.root .. "/" .. song .. "/rooms/" .. tostring(room) .. "/summary"
  local best
  for _, f in ipairs(band.files(dir, ".json")) do
    local s = band.read_json(dir .. "/" .. f)
    if type(s) == "table" and (not best or tostring(s.time) > tostring(best.time)) then best = s end
  end
  if not best then previews[key] = false; return nil end
  if not have then
    have = {}
    local plugins = require("plugins")
    for _, p in ipairs(plugins.installed()) do have[plugins.key(p.name)] = true end
  end
  local missing = {}
  for _, n in ipairs(best.plugins or {}) do
    local js = n:match("^JS: (.+)$")
    local here = js and reaper.file_exists(reaper.GetResourcePath() .. "/Effects/" .. js) or (not js and have[require("plugins").key(n)])
    if not here then missing[#missing + 1] = n end
  end
  local ss = require("songsync")
  local here = ss.keep_all() or ss.wanted(cfg)[song] -- (per-song sync: the rest of a song comes once it's opened)
  local text = string.format("%d tracks, %d MB of audio%s. ", tonumber(best.tracks) or 0, tonumber(best.media_mb) or 0,
    here and "" or ", downloaded when you open it") ..
    (#missing == 0 and "Every plug-in it uses loads here." or string.format("%d plug-in(s) it uses aren't on this machine (hover to see).", #missing))
  previews[key] = { text = text, missing = missing }
  return previews[key]
end

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
  local theme = require("theme")
  local ui_font = ImGui.CreateFont("sans-serif")
  ImGui.Attach(ctx, ui_font)
  local as_folders = reaper.GetExtState(band.SECTION, "chooser view") == "folders" -- (this machine's choice, kept)
  local in_folder -- the folder open in the folder view, nil at the top
  local text, sel, room, new_room, show_hidden, hide = "", nil, nil, "", false, hidden()
  local picked_for -- the text the selection was last picked for: new text picks the best match again
  local new_folder = "" -- typed in a song's right-click menu
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
    theme.push(ctx, ImGui, true)
    ImGui.PushFont(ctx, ui_font, 15)
    local shown, open = ImGui.Begin(ctx, (opts.title or "Choose a project") .. "###bandsync_chooser", true)
    local result -- { song, room } when chosen, false when cancelled
    if shown then
      local list = visible_rows()
      if not sel or not chooser.match(sel, text) or picked_for ~= text then -- what's typed changed: its best match
        sel = text:match("%S") and chooser.best(chooser.groups(list), text) or list[1] -- (nothing typed: the newest song)
        room = sel and sel.rooms[1]
        picked_for = text
      end
      if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
      ImGui.SetNextItemWidth(ctx, -270)
      local _, t = ImGui.InputTextWithHint(ctx, "##find", "Type to search: project, host, collaborator", text)
      text = t
      ImGui.SameLine(ctx)
      local nhidden = 0 -- (a hidden song also leaves its folder's count: say how many there are)
      for _, r in ipairs(rows) do if hide[r.song] then nhidden = nhidden + 1 end end
      local _, sh = ImGui.Checkbox(ctx, nhidden > 0 and ("Show hidden (" .. nhidden .. ")") or "Show hidden", show_hidden)
      show_hidden = sh
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, as_folders and "List" or "Folders") then
        as_folders = not as_folders
        reaper.SetExtState(band.SECTION, "chooser view", as_folders and "folders" or "list", true)
      end
      ImGui.SetItemTooltip(ctx, as_folders and "See every project in one list, with who's in it." or "See folders, as in Google Drive: double-click one to see the projects in it.")
      local folders = {} -- every folder there is, for "Move to folder"
      for _, r in ipairs(rows) do if (r.folder or "") ~= "" then folders[r.folder] = true end end
      local function song_menu(r) -- right-click a song: file it, or hide it here
        if ImGui.BeginPopupContextItem(ctx) then
          if ImGui.BeginMenu(ctx, "Move to folder") then
            local names = {}
            for f in pairs(folders) do names[#names + 1] = f end
            table.sort(names, function(a, z) return a:lower() < z:lower() end)
            for _, f in ipairs(names) do
              if ImGui.MenuItem(ctx, f, nil, r.folder == f) then r.folder = chooser.set_folder(cfg, r.song, f) end
            end
            if r.folder ~= "" and ImGui.MenuItem(ctx, "(no folder)") then r.folder = chooser.set_folder(cfg, r.song, "") end
            ImGui.Separator(ctx)
            ImGui.SetNextItemWidth(ctx, 200)
            local enter, nf = ImGui.InputTextWithHint(ctx, "##newfolder", "New folder: type, then Enter", new_folder, ImGui.InputTextFlags_EnterReturnsTrue)
            new_folder = nf
            if enter and band.clean(nf) ~= "" then
              r.folder = chooser.set_folder(cfg, r.song, nf)
              new_folder = ""
              ImGui.CloseCurrentPopup(ctx)
            end
            ImGui.EndMenu(ctx)
          end
          if ImGui.MenuItem(ctx, hide[r.song] and "Show in this list again" or "Hide from this list (this machine only)") then
            hide[r.song] = not hide[r.song] or nil
            save_hidden(hide)
          end
          ImGui.EndPopup(ctx)
        end
      end
      -- The folder view: a square each, as in Google Drive. Double-click a folder to go in, a song to open it.
      local function tile(id, label, sub, is_folder, selected)
        local w, h = 136, 96
        local x, y = ImGui.GetCursorScreenPos(ctx)
        local clicked = ImGui.InvisibleButton(ctx, id, w, h)
        local hovered = ImGui.IsItemHovered(ctx)
        local dl = ImGui.GetWindowDrawList(ctx)
        ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, selected and 0x34415AFF or hovered and 0x33373DFF or theme.CARD, 10)
        local cx = x + w / 2
        if is_folder then
          ImGui.DrawList_AddRectFilled(dl, cx - 20, y + 12, cx - 4, y + 22, 0xC99A3EFF, 3)
          ImGui.DrawList_AddRectFilled(dl, cx - 20, y + 16, cx + 20, y + 44, 0xE0B050FF, 4)
        else
          ImGui.DrawList_AddRectFilled(dl, cx - 20, y + 12, cx + 20, y + 44, 0x3B4049FF, 4)
          for i, bar in ipairs({ 8, 16, 11, 20, 13, 7 }) do
            local bx = cx - 20 + i * 40 / 7
            ImGui.DrawList_AddLine(dl, bx, y + 28 - bar / 2, bx, y + 28 + bar / 2, theme.ACCENT, 2)
          end
        end
        local function words(text, col, at)
          local shortened = text
          while ImGui.CalcTextSize(ctx, shortened) > w - 12 and #shortened > 1 do shortened = shortened:sub(1, -2) end
          if shortened ~= text then shortened = shortened:sub(1, math.max(1, #shortened - 2)) .. ".." end
          ImGui.DrawList_AddText(dl, cx - ImGui.CalcTextSize(ctx, shortened) / 2, at, col, shortened)
        end
        words(label, 0xE6E8EBFF, y + 52)
        words(sub, theme.MUTED, y + 72)
        if hovered and ImGui.CalcTextSize(ctx, label) > w - 12 then ImGui.SetItemTooltip(ctx, label) end
        return clicked, hovered and ImGui.IsMouseDoubleClicked(ctx, 0)
      end
      local flags = ImGui.TableFlags_ScrollY | ImGui.TableFlags_RowBg | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_Resizable
      if as_folders then
        if ImGui.BeginChild(ctx, "tiles", 0, -74 - ImGui.GetTextLineHeightWithSpacing(ctx)) then
          local searching = text:match("%S") -- (a search looks through every folder)
          if in_folder and not searching then
            if ImGui.SmallButton(ctx, "< All folders") then in_folder = nil end
            ImGui.SameLine(ctx)
            ImGui.Text(ctx, in_folder)
          end
          local per = math.max(1, math.floor((ImGui.GetContentRegionAvail(ctx) + 8) / 144))
          local n = 0
          local function place() n = n + 1; if (n - 1) % per ~= 0 then ImGui.SameLine(ctx, 0, 8) end end
          if not in_folder and not searching then
            for gi, g in ipairs(chooser.groups(list)) do
              if g.name ~= "" then
                place()
                local _, twice = tile("f" .. gi, g.name, #g.rows .. (#g.rows == 1 and " project" or " projects"), true, false)
                if twice then in_folder = g.name end
              end
            end
          end
          for i, r in ipairs(list) do
            if searching or (r.folder or "") == (in_folder or "") then
              place()
              ImGui.PushID(ctx, i)
              local once, twice = tile("s", r.song, r.last ~= "" and chooser.ago(r.last, now) or (r.host or ""), false, sel == r)
              if once then sel, room, new_room = r, r.rooms[1], "" end
              if twice then result = { r.song, r.rooms[1] } end
              song_menu(r)
              ImGui.PopID(ctx)
            end
          end
          ImGui.EndChild(ctx)
        end
      elseif ImGui.BeginTable(ctx, "songs", 4, flags, 0, -74 - ImGui.GetTextLineHeightWithSpacing(ctx)) then
        ImGui.TableSetupScrollFreeze(ctx, 0, 1)
        ImGui.TableSetupColumn(ctx, "Project")
        ImGui.TableSetupColumn(ctx, "Host")
        ImGui.TableSetupColumn(ctx, "Who's in it")
        ImGui.TableSetupColumn(ctx, "Last activity")
        ImGui.TableHeadersRow(ctx)
        local groups = chooser.groups(list)
        local nested = #groups > 1 or (groups[1] and groups[1].name ~= "") -- no folders yet: a plain list
        local TN = ImGui.TreeNodeFlags_SpanAllColumns
        local function cells(host, who, last)
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, host)
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, who)
          ImGui.TableNextColumn(ctx); ImGui.Text(ctx, last)
        end
        for gi, g in ipairs(groups) do
          local open_g = true
          if nested then
            ImGui.TableNextRow(ctx)
            ImGui.TableNextColumn(ctx)
            if text ~= "" then ImGui.SetNextItemOpen(ctx, true) end -- searching: every folder with a match is open
            open_g = ImGui.TreeNodeEx(ctx, "g" .. gi, (g.name ~= "" and g.name or "No folder") .. "  (" .. #g.rows .. ")",
              TN | ImGui.TreeNodeFlags_DefaultOpen)
            cells("", "", "")
          end
          if open_g then
            for i, r in ipairs(g.rows) do
              ImGui.TableNextRow(ctx)
              ImGui.TableNextColumn(ctx)
              ImGui.PushID(ctx, gi .. ":" .. i)
              local several = #r.rooms > 1 -- side rooms show under their song
              local f = TN | (several and ImGui.TreeNodeFlags_OpenOnArrow or (ImGui.TreeNodeFlags_Leaf | ImGui.TreeNodeFlags_NoTreePushOnOpen))
                | ((sel == r and (room == r.rooms[1] or not several)) and ImGui.TreeNodeFlags_Selected or 0)
              local open_s = ImGui.TreeNodeEx(ctx, "s", r.song .. (hide[r.song] and "  (hidden)" or ""), f)
              if ImGui.IsItemClicked(ctx) then
                if sel ~= r then sel = r end
                room, new_room = r.rooms[1], ""
                if ImGui.IsMouseDoubleClicked(ctx, 0) then result = { r.song, room } end
              end
              song_menu(r)
              cells(r.host, table.concat(r.members, ", "), r.last ~= "" and chooser.ago(r.last, now) or "")
              if several and open_s then
                for _, rm in ipairs(r.rooms) do
                  ImGui.TableNextRow(ctx)
                  ImGui.TableNextColumn(ctx)
                  ImGui.TreeNodeEx(ctx, "r" .. rm, "room: " .. rm, TN | ImGui.TreeNodeFlags_Leaf | ImGui.TreeNodeFlags_NoTreePushOnOpen
                    | ((sel == r and room == rm) and ImGui.TreeNodeFlags_Selected or 0))
                  if ImGui.IsItemClicked(ctx) then
                    sel, room, new_room = r, rm, ""
                    if ImGui.IsMouseDoubleClicked(ctx, 0) then result = { r.song, rm } end
                  end
                  cells("", "", "")
                end
                ImGui.TreePop(ctx)
              end
              ImGui.PopID(ctx)
            end
            if nested then ImGui.TreePop(ctx) end
          end
        end
        ImGui.EndTable(ctx)
      end
      if #list == 0 then ImGui.TextDisabled(ctx, "No project matches '" .. text .. "'.") end
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
      -- before you join: how big it is, and the plug-ins it uses that this machine doesn't have
      local pv = sel and chooser.preview(cfg, sel.song, room)
      if pv then ImGui.TextColored(ctx, #pv.missing > 0 and 0xE0B050FF or 0x8D939BFF, pv.text) else ImGui.Dummy(ctx, 0, ImGui.GetTextLineHeight(ctx)) end
      if pv and #pv.missing > 0 then ImGui.SetItemTooltip(ctx, "Missing here:\n" .. table.concat(pv.missing, "\n") ..
        "\n\nTheir tracks open with the plug-in offline (settings kept). The Plugins page can set a translation.") end
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
      ImGui.TextDisabled(ctx, "Enter opens, Esc cancels; right-click a project to file it in a folder or hide it")
      ImGui.End(ctx)
    end
    ImGui.PopFont(ctx)
    theme.pop(ctx, ImGui, true)
    if result then return done(result[1], opts.rooms and result[2] or nil) end
    if result == false or not open then return done() end
    reaper.defer(loop)
  end
  reaper.defer(loop)
end

return chooser

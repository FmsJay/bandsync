-- The panel's Chat page: messages, to-dos and links for the band, this song or this room. Each message or to-do is
-- its own small file in the shared folder (no two people ever write the same file, so Syncthing never conflicts).
local band = require("band")
local chat = {}

local SCOPES = { { "room", "This room" }, { "song", "This project" }, { "band", "Studio" } }
local scope, draft, todo_text, link_title, link_url = "song", "", "", "", ""
local cache, cache_at, cache_key = nil, -math.huge, ""

-- Whose things show (the Chat page's Everyone box; the notes and the drawings go by it too). "" for everyone's.
function chat.only() return reaper.GetExtState(band.SECTION, "show only") end

function chat.dir(cfg, b, sc)
  if sc == "band" then return cfg.root .. "/_band/chat" end
  if sc == "room" then return band.song_dir(cfg, b.song) .. "/rooms/" .. (b.room or "main") .. "/chat" end
  return band.song_dir(cfg, b.song) .. "/chat"
end

local function stamp(cfg) return os.date("!%Y%m%d-%H%M%S") .. "-" .. (cfg.user:gsub("[^%w]", "_")) .. "-" .. math.random(1000, 9999) end

-- The folders a scope shows, each with where it is in words: { { dir, where } }. This room: only its own. This project: the project's and
-- every room's. The group: the group's and every project's, every room's. (A project with only its listing here still has its chat.)
function chat.sources(cfg, b, sc)
  local out = {}
  local function project(song)
    local dir = band.song_dir(cfg, song)
    out[#out + 1] = { dir .. "/chat", song }
    for _, room in ipairs(band.subdirs(dir .. "/rooms")) do out[#out + 1] = { dir .. "/rooms/" .. room .. "/chat", song .. " / " .. room } end
  end
  if sc == "room" then out[1] = { chat.dir(cfg, b, "room"), b.room or "main" }
  elseif sc == "song" then project(b.song)
  else
    out[1] = { cfg.root .. "/_band/chat", "Studio" }
    for _, song in ipairs(band.songs(cfg)) do project(song) end
  end
  return out
end
local function load(cfg, b)
  local key = scope .. (b.song or "") .. (b.room or "")
  if cache and key == cache_key and reaper.time_precise() - cache_at < 3 then return cache end
  local t = { msgs = {}, todo = {}, links = {} }
  for _, src in ipairs(chat.sources(cfg, b, scope)) do
    for kind in pairs(t) do
      for _, f in ipairs(band.files(src[1] .. "/" .. kind, ".json")) do
        local v = band.read_json(src[1] .. "/" .. kind .. "/" .. f)
        if type(v) == "table" then v.file, v.where = src[1] .. "/" .. kind .. "/" .. f, src[2]; t[kind][#t[kind] + 1] = v end
      end
    end
  end
  for kind in pairs(t) do table.sort(t[kind], function(a, x) return (a.time or "") < (x.time or "") end) end
  cache, cache_at, cache_key = t, reaper.time_precise(), key
  return t
end

local function add(cfg, b, kind, v)
  local d = chat.dir(cfg, b, scope) .. "/" .. kind
  reaper.RecursiveCreateDirectory(d, 0)
  v.user, v.time = cfg.user, os.date("!%Y-%m-%dT%H:%M:%SZ")
  band.write_json(d .. "/" .. stamp(cfg) .. ".json", v)
  cache = nil
end

-- Messages newer than the last time this person looked at the song's chat (for the tab's count).
local unread_at, unread_n, unread_song = -math.huge, 0, nil
function chat.unread(cfg, b)
  if not b or not b.song then return 0 end
  if b.song == unread_song and reaper.time_precise() - unread_at < 5 then return unread_n end -- (drawn every frame)
  unread_at, unread_song = reaper.time_precise(), b.song
  unread_n = chat.count_unread(cfg, b)
  return unread_n
end
local function seen_key(b, sc) return "chat seen " .. sc .. " " .. (sc == "band" and "" or b.song) .. (sc == "room" and (" " .. (b.room or "main")) or "") end
function chat.count_unread(cfg, b)
  local n = 0
  for _, sc in ipairs(SCOPES) do
    local seen = reaper.GetExtState(band.SECTION, seen_key(b, sc[1])) -- (each scope has its own: reading one doesn't clear the others)
    for _, f in ipairs(band.files(chat.dir(cfg, b, sc[1]) .. "/msgs", ".json")) do
      if f:sub(1, 15) > seen and not f:find("-" .. (cfg.user:gsub("[^%w]", "_")) .. "-", 1, true) then n = n + 1 end
    end
  end
  return n
end

-- "2026-10-30T21:05:00Z" -> "Thu 21:05" (this machine's time)
local function when(iso)
  local y, mo, d, h, mi, sec = (iso or ""):match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return "" end
  local utc = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec, isdst = false })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now)))
  local t = utc + offset
  return os.date(os.date("%Y%m%d", t) == os.date("%Y%m%d") and "%H:%M" or "%a %d %b %H:%M", t)
end
local function delete_mine(ctx, ImGui, cfg, e)
  if e.user ~= cfg.user then return end
  ImGui.SameLine(ctx)
  if ImGui.GetContentRegionAvail(ctx) < 30 then ImGui.NewLine(ctx) end -- (after a long row it ran off the panel: Mac, 0.51.13)
  if ImGui.SmallButton(ctx, "x") and reaper.MB("Delete this for everyone?", "StudioSync", 4) == 6 then os.remove(e.file); cache = nil end
  ImGui.SetItemTooltip(ctx, "Delete yours (for everyone).")
end

-- A text box with a button beside it. (Not EnterReturnsTrue: with it the text only comes back on Return, so pressing the button lost what was typed and sent
-- nothing: James and the Mac both hit it.) -> Return was pressed in it, the text.
function chat.input(ctx, ImGui, id, hint, text)
  local _, v = ImGui.InputTextWithHint(ctx, id, hint, text)
  return ImGui.IsItemDeactivated(ctx) and (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)), v
end

function chat.draw(ctx, ImGui, cfg, b)
  if not b or not b.song then return ImGui.TextDisabled(ctx, "Open a studio project to chat about it.") end
  -- next to the last thing, or on a new line when `w` more won't fit (the Everyone box ran off the right of the panel)
  local function fits(w, gap)
    ImGui.SameLine(ctx, 0, gap or 8)
    if ImGui.GetContentRegionAvail(ctx) < w then ImGui.NewLine(ctx) end
  end
  local t = load(cfg, b)
  local short = select(2, ImGui.GetContentRegionAvail(ctx)) < 170
  local function switches()
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4, 1)
  for i, sc in ipairs(SCOPES) do
    if i > 1 then fits(ImGui.CalcTextSize(ctx, sc[2]) + 36) end
    if ImGui.RadioButton(ctx, sc[2], scope == sc[1]) then scope, cache = sc[1], nil end
  end
  ImGui.PopStyleVar(ctx)
  ImGui.SetItemTooltip(ctx, "What you see and who you're writing to. This room: only this room's. This project: the project's and all its rooms'. " ..
    "Studio: everything, from every project and room. What you write goes to the one picked here.")
  do -- drawing on the arrange view (StudioSync - Draw.lua): what's drawn there is the room's, seen by everyone in it
    -- (its toggle, from the running script's own beat: asking REAPER for the script's id rewrote its key file every frame this page
    -- was open, the lag on this page: James, 0.42.28)
    local root = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]lib[/\\]") or ""
    local running = reaper.time_precise() - (tonumber(reaper.GetExtState(band.SECTION, "draw alive")) or -60) < 3
    local drawing = reaper.GetExtState(band.SECTION, "draw on") ~= ""
    fits(70, 24)
    if drawing then
      local accent = require("theme").ACCENT
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, accent); ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, accent); ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    end
    if ImGui.SmallButton(ctx, "Draw") then
      if drawing then reaper.DeleteExtState(band.SECTION, "draw on", false)
      else
        reaper.DeleteExtState(band.SECTION, "draw hidden", true)
        reaper.SetExtState(band.SECTION, "draw on", "1", false)
        band.start_draw(root)
      end
    end
    if drawing then ImGui.PopStyleColor(ctx, 3) end
    ImGui.SetItemTooltip(ctx, drawing and "Stop drawing (or Done on the bar, or Esc)." or "Draw on the tracks for everyone in this room: the tools show at the foot of the tracks.\n" ..
      "A drawing stays on its bar and track however anyone scrolls or zooms.")
    fits(130)
    if ImGui.SmallButton(ctx, running and "Hide drawings" or "Show drawings") then
      if running then
        reaper.SetExtState(band.SECTION, "draw hidden", "1", true)
        reaper.DeleteExtState(band.SECTION, "draw on", false)
        reaper.SetExtState(band.SECTION, "draw quit", "1", false)
      else
        reaper.DeleteExtState(band.SECTION, "draw hidden", true)
        band.start_draw(root)
      end
    end
    ImGui.SetItemTooltip(ctx, running and "Stop showing the others' drawings on this computer. They stay for everyone else." or "Show what the others drew, over the arrange view (clicks still go to REAPER).")
  end
  do -- whose: messages, to-dos, links, notes and drawings, one person's or everyone's
    local names, seen, only = { cfg.user }, { [cfg.user] = true }, chat.only()
    for _, list in pairs(t) do
      for _, v in ipairs(list) do
        if type(v.user) == "string" and not seen[v.user] then seen[v.user] = true; names[#names + 1] = v.user end
      end
    end
    for _, st in ipairs(require("presence").peers(cfg, b.song, b.room)) do
      if not seen[st.user] then seen[st.user] = true; names[#names + 1] = st.user end
    end
    table.sort(names)
    fits(150, 24)
    ImGui.SetNextItemWidth(ctx, 150)
    if ImGui.BeginCombo(ctx, "##only", only == "" and "Everyone" or only) then
      if ImGui.Selectable(ctx, "Everyone", only == "") then reaper.DeleteExtState(band.SECTION, "show only", false) end
      for _, n in ipairs(names) do
        if ImGui.Selectable(ctx, n, n == only) then reaper.SetExtState(band.SECTION, "show only", n, false) end
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.SetItemTooltip(ctx, "Show only one person's messages, to-dos, links, notes and drawings, on this computer.")
  end
  end
  local function to_button()
    local now = "?"
    for _, sc in ipairs(SCOPES) do if sc[1] == scope then now = sc[2] end end
    if ImGui.Button(ctx, "To: " .. now .. "...") then ImGui.OpenPopup(ctx, "chat switches") end -- (who you're writing to stays in view)
    ImGui.SetItemTooltip(ctx, "What you see and who you're writing to, and drawing on the tracks.")
    if ImGui.BeginPopup(ctx, "chat switches") then switches(); ImGui.EndPopup(ctx) end
  end
  if not short then switches() end
  local only = chat.only()
  local function shown(v) return only == "" or v.user == only end
  if ImGui.BeginTabBar(ctx, "chat") then
    if ImGui.BeginTabItem(ctx, "Messages") then
      local newest = t.msgs[#t.msgs] and t.msgs[#t.msgs].file:match("[/\\]([^/\\]+)$"):sub(1, 15) or ""
      if reaper.GetExtState(band.SECTION, seen_key(b, scope)) < newest then reaper.SetExtState(band.SECTION, seen_key(b, scope), newest, true) end
      local _, h = ImGui.GetContentRegionAvail(ctx)
      local function typing()
        if short then to_button(); ImGui.SameLine(ctx) end
        ImGui.SetNextItemWidth(ctx, -60)
        local enter
        enter, draft = chat.input(ctx, ImGui, "##draft", "message", draft)
        if enter then ImGui.SetKeyboardFocusHere(ctx, -1) end -- (the next one straight away)
        ImGui.SameLine(ctx)
        if (ImGui.Button(ctx, "Send") or enter) and draft:match("%S") then add(cfg, b, "msgs", { text = draft }); draft = "" end
      end
      -- (with no room for the list and the box, the box comes first: to reach Send in a short docker meant scrolling down to it: Mac, 0.51.9)
      local tight = h < 40 + ImGui.GetFrameHeightWithSpacing(ctx)
      if tight then typing() end
      -- (what's under this is one row: at some scales a row is taller than the 34 this was, and in a short docker the box and Send went out of reach: James)
      if ImGui.BeginChild(ctx, "msgs", 0, tight and 60 or (h - ImGui.GetFrameHeightWithSpacing(ctx)), ImGui.ChildFlags_Borders) then
        if #t.msgs == 0 then ImGui.TextDisabled(ctx, "No messages yet.") end
        for _, m in ipairs(t.msgs) do
          if shown(m) then
            ImGui.PushID(ctx, m.file)
            if m.where and scope ~= "room" then -- (where it was sent from, on the left)
              ImGui.TextColored(ctx, require("theme").ACCENT, m.where)
              ImGui.SameLine(ctx)
            end
            ImGui.TextDisabled(ctx, when(m.time))
            if ImGui.GetContentRegionAvail(ctx) >= 420 then ImGui.SameLine(ctx) end -- (narrow, they took half the column from the words: design review)
            ImGui.TextWrapped(ctx, tostring(m.user) .. ": " .. tostring(m.text))
            delete_mine(ctx, ImGui, cfg, m)
            ImGui.PopID(ctx)
          end
        end
        if ImGui.GetScrollY(ctx) >= ImGui.GetScrollMaxY(ctx) - 20 then ImGui.SetScrollHereY(ctx, 1) end -- follow new ones
        ImGui.EndChild(ctx)
      end
      if not tight then typing() end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "To-do") then
      for _, d in ipairs(t.todo) do
        if shown(d) then
          ImGui.PushID(ctx, d.file)
          local ch, v = ImGui.Checkbox(ctx, tostring(d.text), d.done == true)
          if ch then d.done, d.done_by = v, cfg.user; local f = d.file; d.file = nil; band.write_json(f, d); cache = nil end
          if d.done and d.done_by then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "(" .. d.done_by .. ")") end
          delete_mine(ctx, ImGui, cfg, d)
          ImGui.PopID(ctx)
        end
      end
      ImGui.SetNextItemWidth(ctx, -60)
      local enter
      enter, todo_text = chat.input(ctx, ImGui, "##todo", "add a to-do", todo_text)
      ImGui.SameLine(ctx)
      if (ImGui.Button(ctx, "Add") or enter) and todo_text:match("%S") then add(cfg, b, "todo", { text = todo_text, done = false }); todo_text = "" end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Links") then
      for _, l in ipairs(t.links) do
        if not shown(l) then goto next_link end
        ImGui.PushID(ctx, l.file)
        if ImGui.SmallButton(ctx, "Open") then
          -- a bandmate typed this: web links open in the browser; anything else (a file, a program) is shown first
          local web = l.url:match("^https?://") ~= nil
          if web or reaper.MB("Open this? It isn't a web link:\n\n" .. l.url, "StudioSync", 4) == 6 then
            if reaper.CF_ShellExecute then reaper.CF_ShellExecute(l.url)
            elseif reaper.GetOS():find("^Win") then os.execute('start "" "' .. l.url:gsub('"', "") .. '"')
            -- (single quotes: inside double ones the shell still runs $(...) and `...` from a link someone typed)
            else os.execute("open '" .. l.url:gsub("'", "'\\''") .. "'") end
          end
        end
        ImGui.SetItemTooltip(ctx, l.url)
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, (l.title ~= "" and l.title or l.url) .. "  (" .. tostring(l.user) .. ")")
        delete_mine(ctx, ImGui, cfg, l)
        ImGui.PopID(ctx)
        ::next_link::
      end
      ImGui.SetNextItemWidth(ctx, 160)
      _, link_title = ImGui.InputTextWithHint(ctx, "##lt", "title (lyrics, chart...)", link_title)
      ImGui.SameLine(ctx)
      ImGui.SetNextItemWidth(ctx, -60)
      _, link_url = ImGui.InputTextWithHint(ctx, "##lu", "link or file path", link_url)
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Add##l") and link_url:match("%S") then add(cfg, b, "links", { title = link_title, url = link_url }); link_title, link_url = "", "" end
      ImGui.EndTabItem(ctx)
    end
    ImGui.EndTabBar(ctx)
  end
end

return chat

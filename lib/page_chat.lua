-- The panel's Chat page: messages, to-dos and links for the band, this song or this room. Each message or to-do is
-- its own small file in the shared folder (no two people ever write the same file, so Syncthing never conflicts).
local band = require("band")
local chat = {}

local SCOPES = { { "room", "This room" }, { "song", "This song" }, { "band", "Band" } }
local scope, draft, todo_text, link_title, link_url = "song", "", "", "", ""
local cache, cache_at, cache_key = nil, -math.huge, ""

function chat.dir(cfg, b, sc)
  if sc == "band" then return cfg.root .. "/_band/chat" end
  if sc == "room" then return band.song_dir(cfg, b.song) .. "/rooms/" .. (b.room or "main") .. "/chat" end
  return band.song_dir(cfg, b.song) .. "/chat"
end

local function stamp(cfg) return os.date("!%Y%m%d-%H%M%S") .. "-" .. (cfg.user:gsub("[^%w]", "_")) .. "-" .. math.random(1000, 9999) end

local function load(cfg, b)
  local key = scope .. (b.song or "") .. (b.room or "")
  if cache and key == cache_key and reaper.time_precise() - cache_at < 3 then return cache end
  local d = chat.dir(cfg, b, scope)
  local t = { msgs = {}, todo = {}, links = {} }
  for kind in pairs(t) do
    for _, f in ipairs(band.files(d .. "/" .. kind, ".json")) do
      local v = band.read_json(d .. "/" .. kind .. "/" .. f)
      if type(v) == "table" then v.file = d .. "/" .. kind .. "/" .. f; t[kind][#t[kind] + 1] = v end
    end
    table.sort(t[kind], function(a, x) return (a.time or "") < (x.time or "") end)
  end
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
  if ImGui.SmallButton(ctx, "x") then os.remove(e.file); cache = nil end
  ImGui.SetItemTooltip(ctx, "Delete yours (for everyone).")
end

function chat.draw(ctx, ImGui, cfg, b)
  if not b or not b.song then return ImGui.TextDisabled(ctx, "Open a band song to chat about it.") end
  for i, sc in ipairs(SCOPES) do
    if i > 1 then ImGui.SameLine(ctx) end
    if ImGui.RadioButton(ctx, sc[2], scope == sc[1]) then scope, cache = sc[1], nil end
  end
  ImGui.SetItemTooltip(ctx, "Who sees it: everyone in this room, everyone on this song, or the whole band (every song).")
  local t = load(cfg, b)
  if ImGui.BeginTabBar(ctx, "chat") then
    if ImGui.BeginTabItem(ctx, "Messages") then
      local newest = t.msgs[#t.msgs] and t.msgs[#t.msgs].file:match("[/\\]([^/\\]+)$"):sub(1, 15) or ""
      if reaper.GetExtState(band.SECTION, seen_key(b, scope)) < newest then reaper.SetExtState(band.SECTION, seen_key(b, scope), newest, true) end
      local _, h = ImGui.GetContentRegionAvail(ctx)
      if ImGui.BeginChild(ctx, "msgs", 0, math.max(60, h - 34), ImGui.ChildFlags_Borders) then
        if #t.msgs == 0 then ImGui.TextDisabled(ctx, "No messages yet.") end
        for _, m in ipairs(t.msgs) do
          ImGui.PushID(ctx, m.file)
          ImGui.TextDisabled(ctx, when(m.time))
          ImGui.SameLine(ctx)
          ImGui.TextWrapped(ctx, tostring(m.user) .. ": " .. tostring(m.text))
          delete_mine(ctx, ImGui, cfg, m)
          ImGui.PopID(ctx)
        end
        if ImGui.GetScrollY(ctx) >= ImGui.GetScrollMaxY(ctx) - 20 then ImGui.SetScrollHereY(ctx, 1) end -- follow new ones
        ImGui.EndChild(ctx)
      end
      ImGui.SetNextItemWidth(ctx, -60)
      local enter
      enter, draft = ImGui.InputTextWithHint(ctx, "##draft", "message", draft, ImGui.InputTextFlags_EnterReturnsTrue)
      ImGui.SameLine(ctx)
      if (ImGui.Button(ctx, "Send") or enter) and draft:match("%S") then add(cfg, b, "msgs", { text = draft }); draft = "" end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "To-do") then
      for _, d in ipairs(t.todo) do
        ImGui.PushID(ctx, d.file)
        local ch, v = ImGui.Checkbox(ctx, tostring(d.text), d.done == true)
        if ch then d.done, d.done_by = v, cfg.user; local f = d.file; d.file = nil; band.write_json(f, d); cache = nil end
        if d.done and d.done_by then ImGui.SameLine(ctx); ImGui.TextDisabled(ctx, "(" .. d.done_by .. ")") end
        delete_mine(ctx, ImGui, cfg, d)
        ImGui.PopID(ctx)
      end
      ImGui.SetNextItemWidth(ctx, -60)
      local enter
      enter, todo_text = ImGui.InputTextWithHint(ctx, "##todo", "add a to-do", todo_text, ImGui.InputTextFlags_EnterReturnsTrue)
      ImGui.SameLine(ctx)
      if (ImGui.Button(ctx, "Add") or enter) and todo_text:match("%S") then add(cfg, b, "todo", { text = todo_text, done = false }); todo_text = "" end
      ImGui.EndTabItem(ctx)
    end
    if ImGui.BeginTabItem(ctx, "Links") then
      for _, l in ipairs(t.links) do
        ImGui.PushID(ctx, l.file)
        if ImGui.SmallButton(ctx, "Open") then
          -- a bandmate typed this: web links open in the browser; anything else (a file, a program) is shown first
          local web = l.url:match("^https?://") ~= nil
          if web or reaper.MB("Open this? It isn't a web link:\n\n" .. l.url, "BandSync", 4) == 6 then
            if reaper.CF_ShellExecute then reaper.CF_ShellExecute(l.url)
            elseif reaper.GetOS():find("^Win") then os.execute('start "" "' .. l.url:gsub('"', "") .. '"')
            else os.execute('open "' .. l.url:gsub('"', "") .. '"') end
          end
        end
        ImGui.SetItemTooltip(ctx, l.url)
        ImGui.SameLine(ctx)
        ImGui.TextWrapped(ctx, (l.title ~= "" and l.title or l.url) .. "  (" .. tostring(l.user) .. ")")
        delete_mine(ctx, ImGui, cfg, l)
        ImGui.PopID(ctx)
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

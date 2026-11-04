-- The panel's Groups and Projects pages: every group you're in, and one group's projects with their folders. They work with no project open:
-- they're where the panel starts. (In this file: the panel's main chunk is at Lua's limit of 200 locals.)
--   env = { ctx, ImGui, cfg(), card, card_end, heading, action(name), go(page), reload_cfg() }
local band = require("band")
local groups, chooser, theme = require("groups"), require("chooser"), require("theme")
local pg = { root = nil } -- pg.root: the group the Projects page shows (nil: where you're working)

local WHAT_IS = "A studio is its own shared folder, with its own projects, collaborators and chat.\n\n" ..
  "Use one for a band, or for one song with one person: name it what it is. Nobody in your other studios sees it.\n\n" ..
  "Next you'll share a project with it and invite people. You can close it whenever you're done, and everyone keeps their copy."
local new_name, why_not, join_text = "", nil, ""

-- Live: not left or closed here. -> the groups, and the old ones.
function pg.live_groups()
  local list = {}
  for _, g in ipairs(band.bands()) do
    if not groups.is_old(g.root) and not reaper.file_exists(g.root .. "/_band/closed.json") then list[#list + 1] = g end
  end
  return list
end

-- The name, a few words on what it is, and Start. Then on to its Projects page.
function pg.start_button(env, label)
  local ctx, ImGui = env.ctx, env.ImGui
  if ImGui.Button(ctx, label) then new_name, why_not = "", nil; ImGui.OpenPopup(ctx, "Start a studio") end
  ImGui.SetItemTooltip(ctx, "Its own shared folder, projects and collaborators. You only need another for different people or a project of its own.")
  ImGui.SetNextWindowSize(ctx, 440, 0)
  if ImGui.BeginPopupModal(ctx, "Start a studio", nil, ImGui.WindowFlags_NoResize) then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.Text(ctx, WHAT_IS)
    ImGui.PopTextWrapPos(ctx)
    ImGui.Spacing(ctx)
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, -1)
    local _, v = ImGui.InputTextWithHint(ctx, "##newgroup", "its name (a band, a song, whoever it's with)", new_name)
    new_name = v
    if why_not then ImGui.TextColored(ctx, theme.YELLOW, why_not) end
    do
      local drive = require("drive")
      local ch, on = ImGui.Checkbox(ctx, "Keep a copy on Google Drive", drive.wanted())
      if ch then
        reaper.SetExtState(band.SECTION, "drive make", on and "" or "off", true)
        if on and reaper.GetExtState(band.SECTION, "drive_root") == "off" then reaper.SetExtState(band.SECTION, "drive_root", "", true) end
      end
      ImGui.SetItemTooltip(ctx, "Makes the studio's folder in your My Drive. What someone does alone then reaches the others whenever they next open the project. " ..
        "You share the folder with them at drive.google.com. Change it any time in Settings.")
    end
    local go = ImGui.Button(ctx, "Start") or ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
    if go then
      local root, why = require("services").new_band(env.cfg(), new_name)
      if root then
        band.log("started " .. band.info(root).name .. " in " .. root)
        local drive = require("drive")
        local made = drive.wanted() and drive.make(band.info(root).drive)
        if made then band.log("made " .. band.info(root).drive .. " in your Google Drive: share it with the others at drive.google.com, as Editor") end
        pg.root = root
        env.reload_cfg()
        ImGui.CloseCurrentPopup(ctx)
        env.go("Projects")
      else why_not = tostring(why) end
    end
    ImGui.EndPopup(ctx)
  end
end

local just_cleared = false
-- Someone with StudioSync joining with what they were sent. (What's on the clipboard is filled in when it's a code.)
function pg.join_button(env)
  local ctx, ImGui = env.ctx, env.ImGui
  local services = require("services")
  if ImGui.Button(ctx, "Paste join code") then
    local clip = ImGui.GetClipboardText(ctx) or ""
    local found = services.parse_join(clip)
    join_text, why_not = found and services.join_code(found.id, { id = found.band, name = found.name }) or "", nil
    ImGui.OpenPopup(ctx, "Paste join code")
  end
  ImGui.SetItemTooltip(ctx, "Someone invited you and you already have StudioSync: paste what they sent.")
  ImGui.SetNextWindowSize(ctx, 440, 0)
  if ImGui.BeginPopupModal(ctx, "Paste join code", nil, ImGui.WindowFlags_NoResize) then
    ImGui.PushTextWrapPos(ctx, 0)
    ImGui.Text(ctx, "Paste the message they sent you, or just the line starting studiosync-join. Only use one from someone you know: it connects this computer to theirs.")
    ImGui.PopTextWrapPos(ctx)
    ImGui.Spacing(ctx)
    local code = services.parse_join(join_text)
    if code then
      if ImGui.BeginChild(ctx, "##joinshown", -1, ImGui.GetTextLineHeight(ctx) * 4 + 8, ImGui.ChildFlags_FrameStyle) then
        ImGui.PushTextWrapPos(ctx, 0)
        ImGui.TextDisabled(ctx, services.join_code(code.id, { id = code.band, name = code.name }))
        ImGui.PopTextWrapPos(ctx)
        ImGui.EndChild(ctx)
      end
      if ImGui.SmallButton(ctx, "Clear") then join_text, code, just_cleared = "", nil, true end
      ImGui.SetItemTooltip(ctx, "Paste a different one.")
    else
      if ImGui.IsWindowAppearing(ctx) or just_cleared then ImGui.SetKeyboardFocusHere(ctx) end
      local _, v = ImGui.InputTextMultiline(ctx, "##joincode", join_text, -1, ImGui.GetTextLineHeight(ctx) * 4)
      join_text = v
      code = services.parse_join(join_text)
    end
    just_cleared = join_text == "" and code == nil and not ImGui.IsAnyItemActive(ctx) and just_cleared or false
    if why_not then ImGui.TextColored(ctx, theme.YELLOW, why_not)
    elseif code then ImGui.TextColored(ctx, theme.GREEN, "Join " .. (code.name ~= "" and code.name or code.band))
    elseif join_text ~= "" then ImGui.TextColored(ctx, theme.YELLOW, "That isn't a join code: ask them to press Invite and send it again.") end
    ImGui.BeginDisabled(ctx, not code)
    local go = ImGui.Button(ctx, "Join")
    ImGui.EndDisabled(ctx)
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Cancel") or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then ImGui.CloseCurrentPopup(ctx) end
    if go then
      local root, why = services.join_band(env.cfg(), code)
      if root then
        band.log(why == "already" and ("you're already in " .. band.info(root).name) or
          ("joined " .. band.info(root).name .. ": ask whoever invited you to let you in. Its projects arrive after that."))
        pg.root = root
        env.reload_cfg()
        ImGui.CloseCurrentPopup(ctx)
        env.go("Projects")
      else why_not = tostring(why) end
    end
    ImGui.EndPopup(ctx)
  end
end

local function invite_button(env, g, id)
  local ctx, ImGui = env.ctx, env.ImGui
  local services = require("services")
  local my_id = services.my_device_id()
  ImGui.BeginDisabled(ctx, not my_id)
  if ImGui.SmallButton(ctx, "Invite##" .. id) then
    ImGui.SetClipboardText(ctx, services.invite_text(my_id, band.info(g.root)))
    band.log("an invitation to " .. g.name .. " is on your clipboard: paste it to your collaborator. When they've run it, 'Let them in' shows on Home")
  end
  ImGui.EndDisabled(ctx)
  ImGui.SetItemTooltip(ctx, my_id and "Copies a message to send them: a join code if they have StudioSync, and a line for a Mac and one for Windows if they don't, which installs everything." or "Waiting for Syncthing (it has to be running).")
end

-- This computer out of a group, or the owner closing it for everyone.
local function leave(env, root)
  local info, me = band.info(root), env.cfg().user
  local closing = groups.role(root, me) == "owner"
  local quiet = require("services").days_quiet(info.id)
  local alone = #pg.live_groups() == 1
  if reaper.MB(closing and ("Close " .. info.name .. " for everyone?\n\nEvery computer stops syncing it. Everyone keeps their copy, and its projects stay open as ordinary projects.")
      or ("Leave " .. info.name .. "?\n\nThis computer stops syncing it. Your copy stays in " .. root .. ", and its projects stay open as ordinary projects. Someone can invite you again."),
      "StudioSync", 4) ~= 6 then return end
  local ok, why
  if closing then ok, why = groups.close(root, me)
  else ok, why = groups.leave(root, me, alone or (quiet and quiet >= groups.QUIET_DAYS)) end
  if not ok then return band.msg(tostring(why)) end
  if pg.root == root then pg.root = nil end
  env.reload_cfg()
  band.log((closing and "closed " or "left ") .. info.name .. ": your copy stays in " .. root .. " (Studios: delete it when you like)")
end

local people_at, people_of = {}, {}
local function people_in(root)
  if not people_of[root] or reaper.time_precise() - (people_at[root] or 0) > 10 then
    people_at[root] = reaper.time_precise()
    local names, seen = {}, {}
    for _, f in ipairs(band.files(root .. "/plugins", ".json")) do -- (every computer publishes its plug-in list: the group's members)
      local p = band.read_json(root .. "/plugins/" .. f)
      if type(p) == "table" and type(p.user) == "string" and not seen[p.user] then seen[p.user] = true; names[#names + 1] = p.user end
    end
    table.sort(names)
    people_of[root] = { names = names, projects = #band.songs({ root = root }) }
  end
  return people_of[root]
end

-- From inside a project: the way back to it.
local function back_button(env)
  local song = env.project()
  if not song then return end
  if env.ImGui.SmallButton(env.ctx, "< Back to " .. song) then env.go("Home") end
  env.ImGui.Spacing(env.ctx)
end

function pg.draw_groups(env)
  local ctx, ImGui = env.ctx, env.ImGui
  local cfg = env.cfg()
  local me = cfg.user
  local list = pg.live_groups()
  back_button(env)
  env.heading("Your studios")
  if #list == 0 then ImGui.TextDisabled(ctx, "You're not in a studio yet. Start one, or paste the join code someone sent you.") end
  local base = (cfg.base or cfg).root
  for i, g in ipairs(list) do
    ImGui.PushID(ctx, i)
    if env.card("group") then
      env.heading(g.name, 17)
      local role = groups.role(g.root, me)
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      if g.root == cfg.root then ImGui.TextColored(ctx, theme.GREEN, "you're working in this one")
      elseif role == "owner" or role == "admin" then ImGui.TextDisabled(ctx, role) end
      if g.root == cfg.root and (role == "owner" or role == "admin") then
        ImGui.SameLine(ctx)
        ImGui.TextDisabled(ctx, "(" .. role .. ")")
      end
      local p = people_in(g.root)
      ImGui.TextDisabled(ctx, string.format("%d project%s  ·  %s", p.projects, p.projects == 1 and "" or "s", #p.names > 0 and table.concat(p.names, ", ") or "just you so far"))
      ImGui.SetItemTooltip(ctx, g.root)
      if ImGui.SmallButton(ctx, "Open") then
        pg.root = g.root
        band.use_band(g.root)
        env.reload_cfg()
        env.go("Projects")
      end
      ImGui.SetItemTooltip(ctx, "Its projects, and you're working in this one from here on (new projects go to it).")
      ImGui.SameLine(ctx)
      invite_button(env, g, i)
      if groups.may_manage(g.root, me) and reaper.file_exists(g.root .. "/_band/band.json") then
        ImGui.SameLine(ctx)
        if ImGui.SmallButton(ctx, "Rename") then
          local ok, name = reaper.GetUserInputs("StudioSync: rename", 1, "New name,extrawidth=120", g.name)
          if ok and name ~= g.name then
            local new, why = groups.rename(g.root, name, me)
            if new then band.log("renamed " .. g.name .. " to " .. new .. ": everyone in it sees the new name") else band.msg(tostring(why)) end
          end
        end
        ImGui.SetItemTooltip(ctx, "Everyone in it sees the new name. Its folder names, here and on Google Drive, stay as they are.")
      end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, role == "owner" and "Close" or "Leave") then leave(env, g.root) end
      ImGui.SetItemTooltip(ctx, role == "owner" and "End it for everyone: every computer stops syncing it, and everyone keeps their copy. To stay and leave it to someone else, right-click their name in Who's here and make them the owner."
        or "This computer stops syncing it. You keep your copy, and someone can invite you again.")
      local quiet = require("services").days_quiet(g.id)
      if quiet and quiet >= groups.QUIET_DAYS then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, theme.YELLOW)
        ImGui.TextWrapped(ctx, string.format("Nobody in it has been online for %d days. It may have been closed, or you taken out: if so, Leave.", quiet))
        ImGui.PopStyleColor(ctx)
      end
      env.card_end()
    end
    ImGui.PopID(ctx)
  end
  ImGui.Spacing(ctx)
  if #list > 0 then
    ImGui.TextDisabled(ctx, "A new studio is for different people, or a project of its own. For another song with the same people, share it in the one you have.")
  end
  pg.start_button(env, #list == 0 and "Start a studio" or "Start a new studio")
  ImGui.SameLine(ctx)
  pg.join_button(env)
  local old = groups.old()
  if #old > 0 then
    ImGui.Spacing(ctx)
    env.heading("Closed or left", 15)
    ImGui.TextDisabled(ctx, "Nothing syncs here any more. Your copy stays until you delete it.")
    for i, o in ipairs(old) do
      ImGui.PushID(ctx, "old" .. i)
      local there = reaper.EnumerateFiles(o.root, 0) or reaper.EnumerateSubdirectories(o.root, 0)
      local can = base ~= o.root -- (the folder this computer still counts as its current one stays, until there's another)
      ImGui.BeginDisabled(ctx, not there or not can)
      if ImGui.SmallButton(ctx, "Delete my copy") and reaper.MB("Delete this computer's copy of " .. tostring(o.name) .. "?\n\n" .. tostring(o.root) ..
          "\n\nIt goes to the " .. (reaper.GetOS():find("^Win") and "Recycle Bin" or "Trash") .. ". Nobody else's copy is touched.", "StudioSync", 4) == 6 then
        local left = require("localcopy").delete_group(o.root)
        band.log(left > 0 and ("some of " .. tostring(o.name) .. " is still in use: restart REAPER and delete what's left of " .. tostring(o.root)) or ("deleted this computer's copy of " .. tostring(o.name)))
      end
      ImGui.EndDisabled(ctx)
      ImGui.SetItemTooltip(ctx, can and tostring(o.root) or "This computer is still set to it: start or join another studio first.")
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, "Keep it, hide this") then groups.forget_old(o.root) end
      ImGui.SameLine(ctx)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, tostring(o.name))
      ImGui.PopID(ctx)
    end
  end
end

-- ---- Projects -------------------------------------------------------------------------------------------------------------
local text, rows, rows_at, rows_root, new_folder = "", nil, -math.huge, nil, ""
local function folders_file(root) return root .. "/_band/folders" end
-- Folders with nothing in them yet: _band/folders/<name>.json, one file each.
local function known_folders(root, list)
  local set = {}
  for _, f in ipairs(band.files(folders_file(root), ".json")) do set[f:sub(1, -6)] = true end
  for _, r in ipairs(list) do if (r.folder or "") ~= "" then set[r.folder] = true end end
  local names = {}
  for n in pairs(set) do names[#names + 1] = n end
  table.sort(names, function(a, z) return a:lower() < z:lower() end)
  return names
end
local function make_folder(root, name)
  name = band.clean(name or "")
  if name == "" then return end
  reaper.RecursiveCreateDirectory(folders_file(root), 0)
  band.write_json(folders_file(root) .. "/" .. name .. ".json", { name = name })
  return name
end
local function open_project(env, root, song, room)
  band.use_band(root)
  env.reload_cfg()
  reaper.SetExtState(band.SECTION, "open project", song .. "|" .. (room or "main"), false)
  reaper.SetExtState(band.SECTION, "panel page", "Home", false)
  env.action("Open session")
end
-- Delete this computer's copy: lib/localcopy.lua does it a slice each frame, and its question and result show here.
local function local_copy_job(env)
  local ctx, ImGui = env.ctx, env.ImGui
  local copy = require("localcopy")
  local j = copy.job
  if not j then return end
  copy.tick()
  j = copy.job
  if j.ask then
    local q = j.ask
    copy.answer(reaper.MB(q, "StudioSync", 4) == 6)
    rows_at = -math.huge
  elseif j.finished then
    local lines = {}
    if #j.done > 0 then lines[#lines + 1] = "Deleted this computer's copy of:\n  " .. table.concat(j.done, "\n  ") end
    if #j.skipped > 0 then lines[#lines + 1] = "Left as it was:\n  " .. table.concat(j.skipped, "\n  ") end
    copy.cancel()
    rows_at = -math.huge
    if #lines > 0 then band.msg(table.concat(lines, "\n\n")) end
  else
    ImGui.TextColored(ctx, theme.YELLOW, tostring(j.words) .. "...")
    ImGui.SameLine(ctx)
    if ImGui.SmallButton(ctx, "Stop") then copy.cancel() end
  end
end
local function ask_delete(root, user, songs)
  local ok, why = require("localcopy").start(root, user, songs)
  if not ok then band.msg(tostring(why)) end
end

local function project_menu(env, root, r, names)
  local ctx, ImGui = env.ctx, env.ImGui
  local ss = require("songsync")
  local cfg = { root = root, user = env.cfg().user }
  if ImGui.BeginPopupContextItem(ctx) then
    if #r.rooms > 1 and ImGui.BeginMenu(ctx, "Open a room") then
      for _, rm in ipairs(r.rooms) do if ImGui.MenuItem(ctx, rm) then open_project(env, root, r.song, rm) end end
      ImGui.EndMenu(ctx)
    end
    if ImGui.BeginMenu(ctx, "Move to folder") then
      for _, f in ipairs(names) do
        if ImGui.MenuItem(ctx, f, nil, r.folder == f) then r.folder = chooser.set_folder(cfg, r.song, f) end
      end
      if (r.folder or "") ~= "" and ImGui.MenuItem(ctx, "(out of its folder)") then r.folder = chooser.set_folder(cfg, r.song, "") end
      ImGui.Separator(ctx)
      ImGui.SetNextItemWidth(ctx, 200)
      local enter, nf = ImGui.InputTextWithHint(ctx, "##nf", "New folder: type, then Enter", new_folder, ImGui.InputTextFlags_EnterReturnsTrue)
      new_folder = nf
      if enter and make_folder(root, nf) then
        r.folder = chooser.set_folder(cfg, r.song, band.clean(nf))
        new_folder = ""
        ImGui.CloseCurrentPopup(ctx)
      end
      ImGui.EndMenu(ctx)
    end
    ImGui.Separator(ctx)
    local here = ss.is_here(cfg, r.song)
    if here and ImGui.MenuItem(ctx, "Delete my local copy...") then ask_delete(root, cfg.user, { r.song }) end
    if not here then ImGui.MenuItem(ctx, "Only its listing is here: open it to bring it", nil, false, false) end
    ImGui.EndPopup(ctx)
  end
end

function pg.draw_projects(env)
  local ctx, ImGui = env.ctx, env.ImGui
  local base = env.cfg()
  local root = pg.root or base.root
  local cfg = { root = root, user = base.user }
  local info = band.info(root)
  local ss = require("songsync")
  -- (not under an open menu; and by name, not last worked on: two active projects swapped places every few seconds, under the mouse: Mac, 0.50.4)
  if rows_root ~= root or not rows or (reaper.time_precise() - rows_at > 5 and not ImGui.IsPopupOpen(ctx, "", ImGui.PopupFlags_AnyPopup)) then
    rows_root, rows_at, rows = root, reaper.time_precise(), chooser.songs(cfg)
    table.sort(rows, function(a, z) return a.song:lower() < z.song:lower() end)
  end
  back_button(env)
  -- the tab in front, if it isn't in a group yet, whatever's in it: an empty new tab showed no way to share at all (James)
  local front = reaper.EnumProjects(-1)
  local plain = not band.binding(front)
  if plain then
    local name = reaper.GetProjectName(front)
    name = name ~= "" and ("'" .. name:gsub("%.[Rr][Pp][Pp]$", "") .. "'") or "this project"
    if env.card("share") then
      ImGui.TextDisabled(ctx, "This tab isn't shared with anyone yet.")
      ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x2E7D4FFF)
      if ImGui.Button(ctx, "Share " .. name .. " with " .. info.name) then
        band.use_band(root)
        env.reload_cfg()
        env.action("Publish session")
      end
      ImGui.PopStyleColor(ctx)
      ImGui.SetItemTooltip(ctx, "It goes through the Prepare checklist first (lanes, FLAC, names, media in one place): much harder to tidy once the studio has it. Then it's shared, and you host it.")
      env.card_end()
    end
    ImGui.Spacing(ctx)
  end
  env.heading("Projects in " .. info.name) -- (opened from another group's project, the pills still name that one: Mac, 0.51.9)
  if ImGui.Button(ctx, "New folder") then new_folder = ""; ImGui.OpenPopup(ctx, "New folder") end
  ImGui.SetItemTooltip(ctx, "A folder for projects, seen by everyone in this studio. Projects with no folder stay at the top level.")
  if ImGui.BeginPopup(ctx, "New folder") then
    if ImGui.IsWindowAppearing(ctx) then ImGui.SetKeyboardFocusHere(ctx) end
    ImGui.SetNextItemWidth(ctx, 220)
    local enter, nf = ImGui.InputTextWithHint(ctx, "##newf", "its name, then Enter", new_folder, ImGui.InputTextFlags_EnterReturnsTrue)
    new_folder = nf
    if enter then make_folder(root, nf); new_folder = ""; ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, math.max(120, ImGui.GetContentRegionAvail(ctx) - 4))
  local _, t = ImGui.InputTextWithHint(ctx, "##findp", "search: project, host, collaborator", text)
  text = t
  local_copy_job(env)
  if #rows == 0 then
    if reaper.file_exists(root .. "/_band/band.json") then ImGui.TextDisabled(ctx, "Nothing's shared here yet.")
    else ImGui.TextDisabled(ctx, "Nothing has arrived yet: it comes once a collaborator lets you in.") end
  end
  local names = known_folders(root, rows)
  local shown = {}
  for _, r in ipairs(rows) do if chooser.match(r, text) then shown[#shown + 1] = r end end
  local by = {}
  for _, r in ipairs(shown) do
    local f = r.folder or ""
    by[f] = by[f] or {}
    table.insert(by[f], r)
  end
  local function drop_target(folder)
    if ImGui.BeginDragDropTarget(ctx) then
      local got, song = ImGui.AcceptDragDropPayload(ctx, "SS_PROJECT")
      if got then
        chooser.set_folder(cfg, song, folder)
        rows_at = -math.huge
      end
      ImGui.EndDragDropTarget(ctx)
    end
  end
  local function row(r, id)
    ImGui.PushID(ctx, r.song) -- (by name, not by place: a menu open on one project mustn't become another's)
    local avail = ImGui.GetContentRegionAvail(ctx)
    local here = ss.is_here(cfg, r.song)
    local x, y = ImGui.GetCursorScreenPos(ctx)
    local clicked = ImGui.Selectable(ctx, "##p", false, ImGui.SelectableFlags_AllowDoubleClick, avail, ImGui.GetTextLineHeightWithSpacing(ctx))
    if clicked and ImGui.IsMouseDoubleClicked(ctx, 0) then open_project(env, root, r.song, r.rooms[1]) end
    local others = {}
    for _, m in ipairs(r.members) do if m ~= r.host then others[#others + 1] = m end end
    ImGui.SetItemTooltip(ctx, "Double-click to open it. Right-click for its rooms, folders and your local copy. Drag it onto a folder.\n" ..
      "Hosted by " .. tostring(r.host) .. (#others > 0 and (", with " .. table.concat(others, ", ")) or "") .. (here and "" or "\nOnly its listing is on this computer: opening it brings the rest."))
    if ImGui.BeginDragDropSource(ctx) then
      ImGui.SetDragDropPayload(ctx, "SS_PROJECT", r.song)
      ImGui.Text(ctx, r.song)
      ImGui.EndDragDropSource(ctx)
    end
    project_menu(env, root, r, names)
    local dl = ImGui.GetWindowDrawList(ctx)
    ImGui.DrawList_AddText(dl, x + 6, y + 1, here and theme.TEXT or theme.MUTED, r.song)
    local right = (r.last ~= "" and chooser.ago(r.last, os.date("!*t")) or "") .. (here and "" or "  ·  not on this computer")
    local w = ImGui.CalcTextSize(ctx, right)
    ImGui.DrawList_AddText(dl, x + avail - w - 8, y + 1, theme.MUTED, right)
    ImGui.PopID(ctx)
  end
  for i, f in ipairs(names) do
    local list = by[f] or {}
    if text == "" or #list > 0 then
      ImGui.PushID(ctx, "f" .. i)
      if text ~= "" then ImGui.SetNextItemOpen(ctx, true) end
      local open = ImGui.TreeNodeEx(ctx, "folder", f .. "  (" .. #list .. ")", ImGui.TreeNodeFlags_SpanAvailWidth)
      drop_target(f)
      if ImGui.BeginPopupContextItem(ctx) then
        local here_songs = {}
        for _, r in ipairs(list) do if ss.is_here(cfg, r.song) then here_songs[#here_songs + 1] = r.song end end
        if ImGui.MenuItem(ctx, "Delete my local copies of what's in it...", nil, false, #here_songs > 0) then ask_delete(root, cfg.user, here_songs) end
        if ImGui.MenuItem(ctx, "Remove this folder", nil, false, #list == 0) then os.remove(folders_file(root) .. "/" .. f .. ".json") end
        ImGui.EndPopup(ctx)
      end
      if open then
        if #list == 0 then ImGui.TextDisabled(ctx, "Empty: drag a project here.") end
        for k, r in ipairs(list) do row(r, k) end
        ImGui.TreePop(ctx)
      end
      ImGui.PopID(ctx)
    end
  end
  local top = by[""] or {}
  if #names > 0 and #top > 0 then ImGui.Spacing(ctx) end
  for k, r in ipairs(top) do row(r, "top" .. k) end
  if #names > 0 then
    ImGui.TextDisabled(ctx, "Top level: drop here to take a project out of its folder")
    drop_target("")
  end
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  local all = ss.keep_all()
  local ch, v = ImGui.Checkbox(ctx, "Keep every project on this computer", all)
  if ch then reaper.SetExtState(band.SECTION, "projects keep all", v and "1" or "", true); ss.apply(cfg) end
  ImGui.SetItemTooltip(ctx, "On: every project of this studio comes here in full (the computer that stays on, so new collaborators always have a source). A project you delete here stays away.\n" ..
    "Off: every project's listing comes, and a project in full once you open it here.")
end

return pg

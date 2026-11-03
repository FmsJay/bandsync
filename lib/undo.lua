-- Undo / Redo of your own changes, for everyone (mirror sync): the top bar's arrows, the radial menu, and the
-- "BandSync - Undo" / "BandSync - Redo" actions (bind them to Ctrl+Z / Ctrl+Shift+Z). A bandmate's change is never
-- stepped over the way REAPER's own undo does (it restores a whole-project snapshot, theirs included).
local band = require("band")
local undo = {}

-- What Ctrl+Z does in a band song, by what's on top of REAPER's undo list (`top`). Your own edit: REAPER's undo, which is that
-- one step and also covers what hasn't gone out yet, or never does. A change BandSync made, a bandmate's among them: your own last
-- change instead, as REAPER's would roll theirs back (the Mac's 4 presses re-sent old parts as its own: 0.42.10). Pure.
function undo.native(top) return (top or "") ~= "" and not top:find("^BandSync") end

-- Ctrl+Z and Ctrl+Shift+Z, in the main window and the MIDI editor (it has its own Ctrl+Z, and that's where notes get moved).
-- REAPER reads shortcuts only when it starts, so undo.auto_keys sets them for the next start; Setup's button (REAPER's own box,
-- for each) is for where that doesn't apply. What's still without one:
local ids = {}
local KEYS = { { "Undo", 0, "the main window", 9 }, { "Undo", 32060, "the MIDI editor", 9 }, { "Redo", 0, "the main window", 13 }, { "Redo", 32060, "the MIDI editor", 13 } }
function undo.keys_left(dir)
  local left = {}
  for _, k in ipairs(KEYS) do
    local key = k[1] .. k[2]
    ids[key] = ids[key] or reaper.AddRemoveReaScript(true, k[2], dir .. "/BandSync - " .. k[1] .. ".lua", true)
    if ids[key] ~= 0 and reaper.CountActionShortcuts(reaper.SectionFromUniqueID(k[2]), ids[key]) == 0 then
      left[#left + 1] = { what = k[1], section = k[2], where = k[3], id = ids[key], mod = k[4], key = key }
    end
  end
  return left
end
-- The lines to add to reaper-kb.ini (its text) for `wants`, { what, section, mod }: Ctrl is mod 9, Ctrl+Shift 13, Z is key 90.
-- A key that section already has is someone's own choice, and is left alone. Pure.
function undo.kb_lines(text, wants)
  local add = {}
  for _, w in ipairs(wants) do
    local rs = text:match("SCR %d+ " .. w.section .. " (%S+) \"[^\"]*BandSync %- " .. w.what .. "%.lua\"")
    if rs and not ("\n" .. text):find("\nKEY " .. w.mod .. " 90 %S+ " .. w.section .. "%f[%D]") then
      add[#add + 1] = string.format("KEY %d 90 _%s %d", w.mod, rs, w.section)
    end
  end
  return add
end
-- Sets what's missing for the next time REAPER starts: at its start, and again as it quits (a new action registered meanwhile
-- rewrites the file from REAPER's memory). A key once seen set and now gone was removed by its owner: not set again.
-- shortcut: Windows only, as Cmd+Z's line is unverified on a Mac; Setup's button does it there until it's checked.
function undo.auto_keys(dir)
  if not reaper.GetOS():find("^Win") then return end
  local left, seen = undo.keys_left(dir), reaper.GetExtState(band.SECTION, "undo keys seen")
  local missing = {}
  for _, k in ipairs(left) do missing[k.key] = true end
  for _, k in ipairs(KEYS) do
    local key = k[1] .. k[2]
    if not missing[key] and ids[key] ~= 0 and not seen:find(key, 1, true) then seen = seen .. key .. " " end
  end
  reaper.SetExtState(band.SECTION, "undo keys seen", seen, true)
  local wants = {}
  for _, k in ipairs(left) do
    if not seen:find(k.key, 1, true) then wants[#wants + 1] = k end
  end
  if #wants == 0 then return end
  local path = reaper.GetResourcePath() .. "/reaper-kb.ini"
  local text = band.read(path)
  local lines = text and undo.kb_lines(text, wants) or {}
  if #lines == 0 then return end
  local f = io.open(path, "a")
  if not f then return end
  f:write((text:sub(-1) == "\n" and "" or "\n") .. table.concat(lines, "\n") .. "\n")
  f:close()
end
function undo.key_name() return (reaper.GetOS():find("^OSX") or reaper.GetOS():find("^macOS")) and "Cmd+Z" or "Ctrl+Z" end
function undo.bind_keys(dir)
  local left, z = undo.keys_left(dir), undo.key_name()
  local list = {}
  for _, k in ipairs(left) do list[#list + 1] = string.format("%d. %s in %s: press %s, then OK", #list + 1, k.what, k.where, k.what == "Undo" and z or z:gsub("%+Z", "+Shift+Z")) end
  if #left == 0 or reaper.MB("REAPER's own box opens " .. #left .. " time(s), one after the other. If it says the key is in use, choose to replace it:\n\n" .. table.concat(list, "\n") ..
      "\n\nOutside group projects these keys do what they always did.", "StudioSync", 1) ~= 1 then return end
  for _, k in ipairs(left) do
    if not reaper.DoActionShortcutDialog(reaper.GetMainHwnd(), reaper.SectionFromUniqueID(k.section), k.id, -1) then break end
  end
end

-- Undo (or with `redo`, redo) this person's newest own change in the bound project. `opts.ask`: asks first, always
-- (the panel); otherwise it asks only when a bandmate changed the same thing since. `opts.describe(e)`: the wording.
-- Returns what happened, for the Activity list, or nil and why not.
function undo.step(proj, cfg, b, redo, opts)
  opts = opts or {}
  local mirror, recall, sync = require("mirror"), require("recall"), require("sync")
  local all = recall.entries(cfg, b.song, b.room)
  local i
  if redo then i = mirror.last_undo(all, cfg.user) else i = mirror.last_mine(all, cfg.user) end -- (with "and/or", nothing to redo undid your last change)
  if not i then
    return nil, redo and "Nothing to redo: you haven't undone anything since your last change." or "You haven't changed anything here yet."
  end
  local e = all[i]
  local what = (redo and "redo: " or "undo: ") .. (opts.describe or recall.describe)(e)
  local others = mirror.later_by_others(all, i)
  if opts.ask or #others > 0 then
    if reaper.MB(what:sub(1, 1):upper() .. what:sub(2) .. "?\n\nIt goes to everyone." .. (#others > 0 and ("\n\n" .. table.concat(others, ", ") ..
        " changed it after that: their change to it goes back too.") or ""), "StudioSync", 4) ~= 6 then return nil end
  end
  local can, who = sync.authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  local o = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  if redo then o.redoes = e.id else o.undoes = e.id end
  -- (the whole act, as Restore's rows: it could land on a print swapped in the same second, and nothing you'd hear went back)
  local ok, res = pcall(mirror.revert, proj, cfg, b.song, b.room, mirror.plan_undo_moment(all, i), o)
  if not ok then return nil, "undo failed: " .. tostring(res) end
  return res
end

return undo

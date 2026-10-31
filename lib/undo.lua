-- Undo / Redo of your own changes, for everyone (mirror sync): the top bar's arrows, the radial menu, and the
-- "BandSync - Undo" / "BandSync - Redo" actions (bind them to Ctrl+Z / Ctrl+Shift+Z). A bandmate's change is never
-- stepped over the way REAPER's own undo does (it restores a whole-project snapshot, theirs included).
local band = require("band")
local undo = {}

-- Undo (or with `redo`, redo) this person's newest own change in the bound project. `opts.ask`: asks first, always
-- (the panel); otherwise it asks only when a bandmate changed the same thing since. `opts.describe(e)`: the wording.
-- Returns what happened, for the Activity list, or nil and why not.
function undo.step(proj, cfg, b, redo, opts)
  opts = opts or {}
  local mirror, recall, sync = require("mirror"), require("recall"), require("sync")
  local all = recall.entries(cfg, b.song, b.room)
  local i = redo and mirror.last_undo(all, cfg.user) or mirror.last_mine(all, cfg.user)
  if not i then
    return nil, redo and "Nothing to redo: you haven't undone anything since your last change." or "You haven't changed anything here yet."
  end
  local e = all[i]
  local what = (redo and "redo: " or "undo: ") .. (opts.describe or recall.describe)(e)
  local others = mirror.later_by_others(all, i)
  if opts.ask or #others > 0 then
    if reaper.MB(what:sub(1, 1):upper() .. what:sub(2) .. "?\n\nIt goes to everyone." .. (#others > 0 and ("\n\n" .. table.concat(others, ", ") ..
        " changed it after that: their change to it goes back too.") or ""), "BandSync", 4) ~= 6 then return nil end
  end
  local can, who = sync.authority(cfg, b.song, b.room, band.read_json(band.session_path(cfg, b.song)))
  local o = { can = can, mode = who and who.mode, local_mix = select(2, reaper.GetProjExtState(proj, band.SECTION, "local_mix")) == "1" }
  if redo then o.redoes = e.id else o.undoes = e.id end
  local ok, res = pcall(mirror.revert, proj, cfg, b.song, b.room, mirror.plan_undo(all, i), o)
  if not ok then return nil, "undo failed: " .. tostring(res) end
  return res
end

return undo

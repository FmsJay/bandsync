-- @description BandSync: update to the latest version
-- ReaPack installs: runs ReaPack's sync (installs updates and registers new actions).
-- Shared-folder installs: updates already arrive with the folder; this registers any new BandSync
-- scripts that came with it, which REAPER would otherwise not show.
local dir = debug.getinfo(1, "S").source:match("^@?(.*)[/\\]")
package.path = dir .. "/lib/?.lua;" .. package.path
local band = require("band")

local _, me = reaper.get_action_context()
local entry = reaper.APIExists("ReaPack_GetOwner") and reaper.ReaPack_GetOwner(me)
if entry then
  reaper.ReaPack_FreeEntry(entry)
  return reaper.Main_OnCommand(reaper.NamedCommandLookup("_REAPACK_SYNC"), 0) -- ReaPack: Synchronize packages
end

local scripts, i = {}, 0
reaper.EnumerateFiles(dir, -1)
while true do
  local name = reaper.EnumerateFiles(dir, i)
  if not name then break end
  if name:match("^BandSync %- .+%.lua$") then scripts[#scripts + 1] = name end
  i = i + 1
end
-- scripts removed or renamed in an update leave dead actions behind: unregister any BandSync action that
-- points into this folder at a file that's gone
local gone = {}
local kb = io.open(reaper.GetResourcePath() .. "/reaper-kb.ini", "r")
if kb then
  local here = band.norm(dir):lower()
  for path in kb:read("a"):gmatch('SCR %d+ %d+ %S+ "[^"]*" "([^"]*BandSync %- [^"]*%.lua)"') do
    local p = band.norm(path)
    if p:lower():sub(1, #here) == here and not reaper.file_exists(p) then gone[#gone + 1] = p end
  end
  kb:close()
end
for _, p in ipairs(gone) do reaper.AddRemoveReaScript(false, 0, p, false) end
for n, name in ipairs(scripts) do reaper.AddRemoveReaScript(true, 0, dir .. "/" .. name, n == #scripts) end
band.msg(string.format("BandSync %s runs from %s, so updates arrive with that folder.\n\n%d BandSync actions are registered, including any new ones.%s",
  band.VERSION, band.norm(dir), #scripts, #gone > 0 and ("\nRemoved " .. #gone .. " action(s) for scripts that no longer exist.") or ""))

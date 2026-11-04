-- localcopy.trash_script is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or { GetOS = function() return "OSX64" end }
package.loaded.band = package.loaded.band or {}
local copy = require("localcopy")
local s = copy.trash_script({ "/m/QA/rooms/main/events", "/m/QA/rooms/main/media" }, "QA Trash Test", "2026-11-04 08.31.05")
assert(s:find("'StudioSync - QA Trash Test - 2026-11-04 08.31.05 - 1 events'", 1, true), "the project's name is in what the Trash shows")
assert(s:find("'StudioSync - QA Trash Test - 2026-11-04 08.31.05 - 2 media'\n", 1, true), "each path has its own name")
assert(copy.trash_script({ "/m/Old Studio" }, nil, "T"):find("'StudioSync - T - 1 Old Studio'", 1, true), "a whole studio keeps its own name")
assert(copy.trash_script({ "/m/It's" }, "It's", "T"):find([['/m/It'\''s' ] && mv '/m/It'\''s' "$HOME/.Trash/"'StudioSync - It'\''s - T - 1 It'\''s']], 1, true), "a quote in a name can't break out")
print("ok")

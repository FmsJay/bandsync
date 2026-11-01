-- prints.printer is pure (lupa or Lua 5.4, from the repo root)
package.path = "lib/?.lua;" .. package.path
reaper = reaper or {}
package.loaded.band = package.loaded.band or {}
local prints = require("prints")
local has = { James = true, Mac = true } -- (who has every plug-in the item plays through)
local function can(u) return has[u] == true end
local here = { James = true, Laptop = true, Mac = true }
assert(prints.printer("Keys", "Laptop", here, {}, can) == "James", "the author lacks a plug-in: the first one here, by name, who has them")
assert(prints.printer("Keys", "Mac", here, {}, can) == "Mac", "the author has them: the author, as before")
assert(prints.printer("Keys", "Mac", here, { keys = { user = "James" } }, can) == "James", "the track's printer, when here and able, comes first")
assert(prints.printer("Keys", "Mac", { Mac = true }, { keys = { user = "James" } }, can) == "Mac", "the printer away: the author")
assert(prints.printer("Keys", "Laptop", here, { keys = { user = "Laptop" } }, can) == "James", "a printer without the plug-ins: someone who has them")
assert(prints.printer("Keys", "Laptop", { Laptop = true }, {}, can) == nil, "nobody here can: nobody prints (the old one stays)")
assert(prints.printer("Keys", "Mac", { Laptop = true }, {}, can) == "Mac", "the author away but able: theirs, when they're back")
print("ok")

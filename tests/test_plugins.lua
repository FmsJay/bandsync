-- plugins.key / common / folders_ini are pure (lupa or any Lua 5.4, from the repo root)
package.loaded.band = package.loaded.band or {}
package.path = "lib/?.lua;" .. package.path
local plugins = require("plugins")
assert(plugins.key("VST3i: Surge XT (Surge Synth Team) (2->6ch)") == "surge xt (surge synth team)", "format and channels go")
assert(plugins.key("AU: Surge XT (Surge Synth Team)") == plugins.key("CLAPi: Surge XT (Surge Synth Team)"), "same plug-in on a Mac")
assert(plugins.key("VSTi: DecentSampler (Decidedly) (34 out)") == "decentsampler (decidedly)", "outputs go")
assert(plugins.key("JS: Saike Yutani (Saike)") == "saike yutani (saike)")
local set, members = plugins.common({ { user = "James", names = { "a", "b", "c" } }, { user = "Laptop", names = { "b", "c", "d" } } })
assert(set.b and set.c and not set.a and not set.d and #members == 2, "only what everyone has")
local ini = "[Folder0]\nItem0=C:\\x\\GTune.dll\nNb=1\nType0=3\n\n[Folders]\nId0=0\nName0=Favorites\nNbFolders=1\n"
local out = plugins.folders_ini(ini, "BandSync (everyone has)", { { ident = "analysis/gfxscope", type = 2 }, { ident = "org.surge-synth-team.surge-xt", type = 7 } })
assert(out:find("[Folder0]\nItem0=C:\\x\\GTune.dll\nNb=1\nType0=3\n", 1, true), "Favorites untouched")
assert(out:find("[Folder1]\nItem0=analysis/gfxscope\nType0=2\nItem1=org.surge-synth-team.surge-xt\nType1=7\nNb=2\n", 1, true), "ours added")
assert(out:find("Id0=0\nName0=Favorites\nId1=1\nName1=BandSync (everyone has)\nNbFolders=2\n", 1, true), "listed")
local again = plugins.folders_ini(out, "BandSync (everyone has)", { { ident = "x", type = 3 } })
assert(again:find("[Folder1]\nItem0=x\nType0=3\nNb=1\n", 1, true) and again:find("NbFolders=2", 1, true), "replaced, not added twice")
assert(plugins.folders_ini("", "B", {}):find("[Folder0]\nNb=0\n\n[Folders]\nId0=0\nName0=B\nNbFolders=1\n", 1, true), "from nothing")
-- the BandSync category in reaper-fxtags.ini: added to what everyone has, taken off what they don't, the rest kept
assert(plugins.tag_key("C:\\VST3\\AG12.vst3", "VST3i") == "AG12.vst3" and plugins.tag_key("org.surge-synth-team.surge-xt", "CLAPi") == "org.surge-synth-team.surge-xt", "tag keys")
assert(plugins.tag_key("C:\\VST3\\WaveShell1.vst3<965085892", "VST3") == nil and plugins.tag_key("analysis/gfxscope", "JS") == nil, "no key for a shell or a JSFX")
local tags = "[developer]\nreaeq.dll=Cockos\n\n[category]\nreaeq.dll=EQ\nold.dll=Delay|BandSync\ngone.dll=BandSync\n"
local t2 = plugins.tags_ini(tags, { ["reaeq.dll"] = true, ["AG12.vst3"] = true })
assert(t2:find("reaeq.dll=EQ|BandSync", 1, true) and t2:find("old.dll=Delay\n", 1, true) and not t2:find("gone.dll", 1, true), "updated: " .. t2)
assert(t2:find("[category]\nAG12.vst3=BandSync\n", 1, true) and t2:find("[developer]\nreaeq.dll=Cockos", 1, true), "added, developers kept: " .. t2)
assert(plugins.tags_ini(t2, { ["reaeq.dll"] = true, ["AG12.vst3"] = true }) == t2, "unchanged the second time")
assert(plugins.tags_ini("", { ["x.dll"] = true }) == "[category]\nx.dll=BandSync\n", "from nothing")
print("ok")

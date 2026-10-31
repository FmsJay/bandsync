"""Compile every Lua file in the repo (lupa, Lua 5.4) and exit non-zero on the first that doesn't: run before a
release, so a broken file can't ship (0.33.2 did: a string split across lines in lib/page_hear.lua)."""
import glob, os, sys
import lupa

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
check = lupa.LuaRuntime().eval('function(s, n) local f, e = load(s, "@" .. n) return e or "ok" end')
bad = 0
for p in sorted(glob.glob("*.lua") + glob.glob("lib/*.lua") + glob.glob("tests/**/*.lua", recursive=True)):
    r = check(open(p, encoding="utf-8").read(), p)
    if r != "ok":
        bad += 1
        print(r)
print(f"{bad} file(s) don't compile" if bad else "all compile")
sys.exit(1 if bad else 0)

"""Use-before-declaration check for the REAPER scripts. A top-level `local function f` called, or a top-level
`local x` (3+ letters, or proj/cfg/b/key) used, on an earlier line resolves to a global that is nil at run time
(0.9.0's Live sync died on every tick that way; 0.9.4 and 0.9.6 nearly did again). Run from the repo root:
python tests/check_locals.py"""
import pathlib, re, sys

WIDE = {"proj", "cfg", "b", "key"}
bad = 0
for path in sorted(pathlib.Path(".").glob("*.lua")) + sorted(pathlib.Path("lib").glob("*.lua")):
    lines = path.read_text(encoding="utf-8").splitlines()
    code = [re.sub(r"--.*$", "", l) for l in lines]
    code = [re.sub(r'"[^"]*"|\'[^\']*\'', '""', l) for l in code]  # string contents aren't code
    for n, line in enumerate(code):
        if line.startswith((" ", "\t")):
            continue  # only top-level definitions
        m = re.match(r"local function (\w+)\s*\(", line)
        names = [m.group(1)] if m else []
        if not m:
            d = re.match(r"local ([\w\s,]+?)\s*(=|$)", line)
            names = [x.strip() for x in d.group(1).split(",")] if d else []
            names = [x for x in names if x in WIDE or len(x) >= 3]
        for name in names:
            # earlier locals/params/loop variables of the same name are other variables: skip those names
            if any(re.search(rf"(\blocal\b[^=]*\b{name}\b|\bfor\b[^=]*\b{name}\b|function\s*[\w.:]*\([^)]*\b{name}\b)", l) for l in code[:n]):
                continue
            pat = rf"(?<![\w.:]){name}\s*\(" if m else rf"(?<![\w.:]){name}\b(?!\s*=[^=])"  # `name = ...` is a table key
            for k in range(n):
                if re.search(pat, code[k]):
                    print(f"{path}:{k + 1}: {name} used before its local definition on line {n + 1}")
                    bad += 1
                    break
print("ok" if bad == 0 else f"{bad} problem(s)")
sys.exit(1 if bad else 0)

"""Use-before-declaration check for the REAPER scripts. A top-level `local function f` called on an earlier
line, or one of the script-wide locals (proj, cfg, b, key) used before its top-level declaration, resolves to
a global that is nil at run time (0.9.0's Live sync died on every tick that way; 0.9.4 nearly read `proj`
before it existed). Run from the repo root: python tests/check_locals.py"""
import pathlib, re, sys

WIDE = ("proj", "cfg", "b", "key")
bad = 0
for path in sorted(pathlib.Path(".").glob("*.lua")) + sorted(pathlib.Path("lib").glob("*.lua")):
    lines = path.read_text(encoding="utf-8").splitlines()
    code = [re.sub(r"--.*$", "", l) for l in lines]
    code = [re.sub(r'"[^"]*"|\'[^\']*\'', '""', l) for l in code]  # string contents aren't code
    for n, line in enumerate(code):
        if line.startswith((" ", "\t")):
            continue  # only top-level definitions
        m = re.match(r"local function (\w+)\s*\(", line) or re.match(r"local (\w+)\s*=\s*function", line)
        wide = re.match(r"local (\w+)\s*=", line)
        name = m.group(1) if m else (wide.group(1) if wide and wide.group(1) in WIDE else None)
        if not name or any(re.match(rf"\s*local\s+[\w,\s]*\b{name}\b", l) for l in code[:n]):
            continue  # not checked, or forward-declared earlier
        pat = rf"(?<![\w.:]){name}\s*\(" if m else rf"(?<![\w.:]){name}\b"
        for k in range(n):
            if re.search(pat, code[k]):
                print(f"{path}:{k + 1}: {name} used before its local definition on line {n + 1}")
                bad += 1
                break
print("ok" if bad == 0 else f"{bad} problem(s)")
sys.exit(1 if bad else 0)

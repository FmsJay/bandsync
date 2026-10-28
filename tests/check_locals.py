"""Use-before-declaration check for the REAPER scripts: a `local function f` (or `local f =`) that is
called on an earlier line resolves to the global f, which is nil at run time (0.9.0's Live sync died on
every tick that way). Run from the repo root: python tests/check_locals.py"""
import pathlib, re, sys

bad = 0
for path in sorted(pathlib.Path(".").glob("*.lua")) + sorted(pathlib.Path("lib").glob("*.lua")):
    lines = path.read_text(encoding="utf-8").splitlines()
    code = [re.sub(r"--.*$", "", l) for l in lines]
    for n, line in enumerate(code):
        m = re.match(r"\s*local function (\w+)\s*\(", line) or re.match(r"\s*local (\w+)\s*=\s*function", line)
        if not m or line.startswith((" ", "\t")):  # only top-level definitions
            continue
        name = m.group(1)
        if any(re.match(rf"\s*local\s+[\w,\s]*\b{name}\b", l) for l in code[:n]):
            continue  # forward-declared earlier
        for k in range(n):
            if re.search(rf"(?<![\w.:]){name}\s*\(", code[k]):
                print(f"{path}:{k + 1}: {name}() used before its local definition on line {n + 1}")
                bad += 1
                break
print("ok" if bad == 0 else f"{bad} problem(s)")
sys.exit(1 if bad else 0)

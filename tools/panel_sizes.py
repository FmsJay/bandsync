"""Which controls run off the right of the panel, on every page, at each size. Needs the panel open in a REAPER running the
MIDI Control Center dev-eval hook (write eval.lua, read result.txt). It sizes the panel and changes its page, then puts it back."""
import os, sys, time

DEV = r"J:\Portable Workstation\DAW\REAPER\Scripts\MIDI Control Center\midi_control_center\dev"
PAGES = ["Groups", "Projects", "Home", "Rooms", "Chat", "Restore", "Plugins", "Settings"]
SIZES = [(340, 700), (420, 700), (560, 640), (744, 700), (1000, 700), (1400, 260)]


def ev(code, wait=20):
    res = os.path.join(DEV, "result.txt")
    if os.path.exists(res):
        os.remove(res)
    with open(os.path.join(DEV, "eval.tmp"), "w", encoding="utf8") as f:
        f.write(code)
    os.replace(os.path.join(DEV, "eval.tmp"), os.path.join(DEV, "eval.lua"))
    for _ in range(wait * 10):
        if os.path.exists(res):
            time.sleep(0.05)
            return open(res, encoding="utf8", errors="replace").read().partition("\n")[2] # (its first line is OK or ERR)
        time.sleep(0.1)
    sys.exit("no answer from the hook")


def main():
    bad = 0
    ev('reaper.SetExtState("BandSync", "panel clipped", "?", false) return "on"')
    time.sleep(0.5)
    for w, h in SIZES:
        ev(f'reaper.SetExtState("BandSync", "panel place", "size {w} {h}", false) return "sized"')
        time.sleep(0.6)
        for page in PAGES:
            ev(f'reaper.SetExtState("BandSync", "panel page", "{page}", false) reaper.SetExtState("BandSync", "panel clipped", "?", false) return "page"')
            time.sleep(0.8)
            got = ev('return reaper.GetExtState("BandSync", "panel clipped")').strip()
            if got not in ("?", "[]", "{}", ""):
                bad += 1
                print(f"{w}x{h} {page}: {got}")
    ev('reaper.DeleteExtState("BandSync", "panel clipped", false) '
       'reaper.SetExtState("BandSync", "panel place", "size 560 640", false) '
       'reaper.SetExtState("BandSync", "panel page", "Home", false) return "done"')
    print("clean" if bad == 0 else f"{bad} page(s) with something cut off")


if __name__ == "__main__":
    main()

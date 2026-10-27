"""Write/extend the ReaPack index.xml for BandSync.

Usage (repo root):  python tools/make_index.py [--changelog "text"]
Then commit, tag v<VERSION>, and push the tag: every <source> URL points at that tag, so a
published version never changes under a bandmate. Older <version> entries are kept, so ReaPack
can pin or roll back. (reapack-index needs Ruby + pandoc; one package doesn't need that machinery.)
"""
import argparse, datetime, pathlib, re, urllib.parse
import xml.etree.ElementTree as ET

REPO = "FmsJay/bandsync"
ROOT = pathlib.Path(__file__).resolve().parent.parent
INDEX = ROOT / "index.xml"

version = re.search(r'VERSION = "([^"]+)"', (ROOT / "lib" / "band.lua").read_text(encoding="utf-8")).group(1)
ap = argparse.ArgumentParser()
ap.add_argument("--changelog", default="")
args = ap.parse_args()

def url(rel):
    return f"https://github.com/{REPO}/raw/v{version}/{urllib.parse.quote(rel)}"

if INDEX.exists():
    index = ET.parse(INDEX).getroot()
    pkg = index.find("category/reapack")
else:
    index = ET.Element("index", version="1", name="BandSync")
    cat = ET.SubElement(index, "category", name="BandSync")
    pkg = ET.SubElement(cat, "reapack", name="BandSync.lua", type="script",
                        desc="BandSync: record together remotely over a shared folder")
    meta = ET.SubElement(pkg, "metadata")
    ET.SubElement(meta, "link", rel="website").text = f"https://github.com/{REPO}"

for old in pkg.findall("version"):
    if old.get("name") == version:  # re-running for the same version replaces it
        pkg.remove(old)
ver = ET.SubElement(pkg, "version", name=version, author="James",
                    time=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
if args.changelog:
    ET.SubElement(ver, "changelog").text = args.changelog
for f in sorted(ROOT.glob("BandSync - *.lua")):
    ET.SubElement(ver, "source", main="main", file=f.name).text = url(f.name)  # registered as actions
for f in sorted((ROOT / "lib").glob("*.lua")):
    rel = f"lib/{f.name}"
    ET.SubElement(ver, "source", file=rel).text = url(rel)

ET.indent(index)
ET.ElementTree(index).write(INDEX, encoding="utf-8", xml_declaration=True)
print(f"index.xml: BandSync {version}, {len(ver)} entries")

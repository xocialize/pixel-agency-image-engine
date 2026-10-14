"""Pick licence-clean commons-sr photos for the fill bake-off and draw a numbered contact sheet to place regions by eye."""
import csv, json, random, os, sys
from PIL import Image, ImageOps, ImageDraw
C = "/Volumes/Satechi/Development/mlxengine-image/corpus/commons-sr"
rows = [r for r in csv.DictReader(open(f"{C}/ATTRIBUTION.csv")) if r["licence"] in ("CC BY 4.0", "CC0 1.0", "CC BY 3.0", "CC BY-SA 4.0") and int(r["width"]) >= 2400 and int(r["height"]) >= 1600]
fetched = {j["title"]: j for j in map(json.loads, open(f"{C}/fetched.jsonl")) if "path" in j}
random.seed(7)
want = {"exteriors": 4, "interiors": 2, "architecture": 3, "animals": 2, "humans": 3, "vegetation": 2, "textures": 1, "mountains": 1}
picked = []
for b, n in want.items():
    cand = [r for r in rows if r["bucket"] == b and r["title"] in fetched and os.path.exists(f"{C}/{fetched[r['title']]['path']}")]
    random.shuffle(cand)
    picked += [(b, r) for r in cand[:n]]
out = []
for i, (b, r) in enumerate(picked):
    out.append({"n": i, "bucket": b, "title": r["title"], "artist": r["artist"], "licence": r["licence"], "path": f"{C}/{fetched[r['title']]['path']}", "w": int(r["width"]), "h": int(r["height"])})
json.dump(out, open("photos.json", "w"), indent=1)
# sheet with a 4x4 grid per thumb to name regions as grid cells
th = 320; cols = 6; rows_ = (len(out) + cols - 1) // cols
sheet = Image.new("RGB", (cols * th, rows_ * (th + 16)), (30, 30, 30)); d = ImageDraw.Draw(sheet)
for i, p in enumerate(out):
    im = ImageOps.exif_transpose(Image.open(p["path"])).convert("RGB"); im.thumbnail((th, th))
    x, y = (i % cols) * th, (i // cols) * (th + 16)
    sheet.paste(im, (x, y + 16)); dd = ImageDraw.Draw(sheet)
    for k in range(1, 4):
        dd.line([(x + im.width * k // 4, y + 16), (x + im.width * k // 4, y + 16 + im.height)], fill=(255, 0, 255), width=1)
        dd.line([(x, y + 16 + im.height * k // 4), (x + im.width, y + 16 + im.height * k // 4)], fill=(255, 0, 255), width=1)
    dd.text((x + 4, y + 2), f"{i} {p['bucket']} {p['w']}x{p['h']}", fill=(255, 255, 255))
sheet.save("photos_sheet.jpg", quality=85); print(len(out), "photos"); [print(p["n"], p["bucket"], p["w"], p["h"], p["title"], "|", p["artist"], p["licence"]) for p in out]

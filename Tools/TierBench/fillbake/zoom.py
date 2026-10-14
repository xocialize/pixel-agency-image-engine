"""Full-resolution crops around the generated region: input | each arm | reference. zoom.py <run-dir> <suite> <ids...>"""
import json, os, sys
from PIL import Image, ImageDraw
run, suite, ids = sys.argv[1], sys.argv[2], sys.argv[3:]
cases = {c["id"]: c for c in json.load(open("cases.json"))[suite]}
rows = [r for r in json.load(open(os.path.join(run, "scores.json"))) if r["suite"] == suite]
arms = sorted({r["arm"] for r in rows}); cell = 420; tiles = []
for id_ in ids:
    c = cases[id_]; ref = Image.open(c.get("reference") or c.get("gt") or c["image"]).convert("RGB"); W, H = ref.size
    m = Image.open(c["mask"]).convert("L").resize((W, H)); bb = m.getbbox(); x0, y0, x1, y1 = bb
    g = int(max(x1 - x0, y1 - y0) * 0.6); box = (max(0, x0 - g), max(0, y0 - g), min(W, x1 + g), min(H, y1 + g))
    row = []
    src = Image.open(c["image"]).convert("RGB")
    if src.size != (W, H):  # extend: pad the cut image into the reference frame
        canvas = Image.new("RGB", (W, H), (255, 0, 255)); cv = c["canvas"]; canvas.paste(src, (cv["left"], cv["top"])); src = canvas
    else:
        src = src.copy(); src.paste((255, 0, 255), mask=m)
    row.append(("input", src.crop(box)))
    for arm in arms:
        r = next((r for r in rows if r["arm"] == arm and r["item"] == id_), None)
        im = Image.open(r["output"]).convert("RGB").resize((W, H)) if r and r.get("output") else Image.new("RGB", (W, H), (80, 0, 0))
        lab = f"{arm} {r['run_ms']/1000:.1f}s" + (f" LPIPS {r['lpips']:.2f}" if r and r.get("lpips") is not None else "") + (" FALLBACK" if r and r.get("fallback") else "")
        row.append((lab, im.crop(box)))
    if c.get("reference") or c.get("gt"): row.append(("reference", ref.crop(box)))
    tiles.append((id_, row))
cols = max(len(r) for _, r in tiles)
S = Image.new("RGB", (cols * cell, len(tiles) * (cell + 16)), (30, 30, 30)); d = ImageDraw.Draw(S)
for i, (id_, row) in enumerate(tiles):
    for j, (lab, im) in enumerate(row):
        im = im.copy(); im.thumbnail((cell, cell)); S.paste(im, (j * cell, i * (cell + 16) + 16)); d.text((j * cell + 4, i * (cell + 16) + 2), f"{id_} {lab}"[:70], fill=(255, 255, 255))
out = os.path.join(run, f"zoom-{suite}-{ids[0]}.jpg"); S.save(out, quality=88); print(out, S.size)

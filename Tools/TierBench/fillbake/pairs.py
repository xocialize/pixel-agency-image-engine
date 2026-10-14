"""Blind pairs for prompted fill from scores.json: crops around the region, arm order seeded per row, key kept aside.
pairs.py <run-dir> <suite> <rows-per-sheet>"""
import json, os, sys, random
from PIL import Image, ImageDraw
run, suite, per = sys.argv[1], sys.argv[2], int(sys.argv[3])
cases = json.load(open("cases.json"))[suite]; rows = [r for r in json.load(open(os.path.join(run, "scores.json"))) if r["suite"] == suite]
arms = sorted({r["arm"] for r in rows}); assert len(arms) == 2
random.seed(11); key = []; cell = 560
for s in range(0, len(cases), per):
    chunk = cases[s:s + per]
    S = Image.new("RGB", (2 * cell, len(chunk) * (cell + 18)), (30, 30, 30)); d = ImageDraw.Draw(S)
    for i, c in enumerate(chunk):
        order = arms[:]; random.shuffle(order); key.append({"item": c["id"], "A": order[0], "B": order[1]})
        box = c["box"]; bw, bh = box[2] - box[0], box[3] - box[1]; cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
        sz = int(max(bw, bh) * 2.2); x0 = min(max(0, cx - sz // 2), max(0, c["w"] - sz)); y0 = min(max(0, cy - sz // 2), max(0, c["h"] - sz))
        for j, arm in enumerate(order):
            r = next((r for r in rows if r["arm"] == arm and r["item"] == c["id"]), None)
            im = Image.open(r["output"]).convert("RGB") if r and r.get("output") else Image.new("RGB", (c["w"], c["h"]), (80, 0, 0))
            if im.size != (c["w"], c["h"]): im = im.resize((c["w"], c["h"]))
            im = im.crop((x0, y0, min(c["w"], x0 + sz), min(c["h"], y0 + sz))); im.thumbnail((cell, cell))
            S.paste(im, (j * cell, i * (cell + 18) + 18))
        d.text((4, i * (cell + 18) + 3), f"{s + i} {c['id']}: {c['prompt']}   [A | B]", fill=(255, 255, 255))
    S.save(os.path.join(run, f"pairs-{suite}-{s // per}.jpg"), quality=88)
json.dump(key, open(os.path.join(run, f"pairs_key-{suite}.json"), "w"), indent=1); print("sheets", (len(cases) + per - 1) // per)

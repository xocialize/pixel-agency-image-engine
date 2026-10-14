"""Score a fill bake-off run (results.jsonl from `TierBench fillbake`) and build the sheets.

Usage: score.py <run-dir> [<run-dir> ...]   (several runs are merged; later runs override the same suite/arm/item)

- fill / fill768: no reference. Records the engine's verdict (retries, rejected, model_fallback) and a marker check
  on the composite, and writes a blind pairs sheet (left/right order seeded per row; key in pairs_key.json).
- seamless: the original is the reference. LPIPS (alex), DISTS, PSNR on the region's box grown 10 %.
- extend: the full photo is the reference. Same metrics on the new strip's box (the mask's bounding box).
- remove: the gate's object-absent ground truth. PSNR in the hole, box PSNR/SSIM, LPIPS/DISTS on the box, left-in-place.
"""
import json, os, sys, random
import numpy as np
import torch
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__))
cases = json.load(open(os.path.join(HERE, "cases.json")))
by_id = {k: {c["id"]: c for c in v} for k, v in cases.items()}

import lpips, piq
_lp = lpips.LPIPS(net="alex", verbose=False).eval()
_dists = piq.DISTS(reduction="none")

def t(img):  # PIL RGB -> 1x3xHxW float 0..1
    return torch.from_numpy(np.asarray(img, dtype=np.float32) / 255.0).permute(2, 0, 1)[None]

def bbox(mask, grow=0.1):
    m = np.asarray(mask.convert("L")) > 127
    ys, xs = np.where(m); x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    gx, gy = int((x1 - x0) * grow), int((y1 - y0) * grow)
    return max(0, x0 - gx), max(0, y0 - gy), min(m.shape[1], x1 + gx), min(m.shape[0], y1 + gy)

def ref_metrics(out, ref, box):
    a, b = out.crop(box), ref.crop(box)
    if min(a.size) < 32: return {}
    with torch.no_grad():
        l = float(_lp(t(a) * 2 - 1, t(b) * 2 - 1).mean())
        d = float(_dists(t(a), t(b)).mean())
    pa, pb = np.asarray(a, np.float64), np.asarray(b, np.float64)
    mse = ((pa - pb) ** 2).mean(); psnr = 99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse)
    return {"lpips": l, "dists": d, "psnr_box": psnr}

def luma(a): a = np.asarray(a, np.float64); return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]

def ssim_gray(a, b):
    from scipy.ndimage import gaussian_filter
    x, y = luma(a), luma(b); mx, my = gaussian_filter(x, 1.5), gaussian_filter(y, 1.5)
    sxx = gaussian_filter(x * x, 1.5) - mx * mx; syy = gaussian_filter(y * y, 1.5) - my * my; sxy = gaussian_filter(x * y, 1.5) - mx * my
    c1, c2 = 6.5025, 58.5225
    return float((((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx * mx + my * my + c1) * (sxx + syy + c2))).mean())

def marker_left(out, mask, strict=40):
    """Share of the region still purple-dominant (the engine's marker test at 40; 20 catches a faint purple haze)."""
    m = np.asarray(mask.convert("L")) > 127; a = np.asarray(out).astype(int)
    if m.shape != a.shape[:2]: m = np.asarray(mask.convert("L").resize((a.shape[1], a.shape[0]))) > 127
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return float(((r - g > strict) & (b - g > strict) & m).sum() / max(1, m.sum()))

records = {}
run_dirs = sys.argv[1:]
for run in run_dirs:
    for line in open(os.path.join(run, "results.jsonl")):
        r = json.loads(line); r["_run"] = run
        records[(r["suite"], r["requested"] or r["model"], r["item"])] = r

rows = []
for (suite, arm, item), r in sorted(records.items()):
    row = {"suite": suite, "arm": arm, "item": item, "run_ms": r["runMs"], "warm": r["warm"], "error": r.get("error"),
           "warnings": ",".join(r.get("warnings") or []), "model": r["model"]}
    mp = r.get("modelParams") or {}
    row["retries"] = mp.get("retries", 0) if isinstance(mp, dict) else 0
    row["rejected"] = mp.get("rejected", "") if isinstance(mp, dict) else ""
    row["fallback"] = int("model_fallback" in (r.get("warnings") or []))
    if r.get("error") or not r.get("outputs"):
        rows.append(row); continue
    out_path = os.path.join(r["_run"], r["outputs"][0]); row["output"] = out_path
    out = Image.open(out_path).convert("RGB")
    c = by_id[suite][item] if suite in by_id else by_id["fill"][item]
    if suite in ("fill", "fill768"):
        mask = Image.open(c["mask"]); row["marker_left"] = marker_left(out, mask); row["purple_tint"] = marker_left(out, mask, strict=20)
        # how much the region changed (0-255 MAE against the input): below 18 the model painted nothing there,
        # the engine's own hand-back threshold for erase (RunPlan.eraseByName)
        m = np.asarray(mask.convert("L")) > 127; src = Image.open(c["image"]).convert("RGB")
        if out.size != src.size: out = out.resize(src.size, Image.LANCZOS)
        row["change_inside"] = float(np.abs(np.asarray(out, np.float64) - np.asarray(src, np.float64)).mean(-1)[m].mean())
        # a region still showing the marker, or left (nearly) untouched, is a failure even when the engine accepted it
        row["failed"] = int(row["fallback"] or row["marker_left"] > 0.25 or row["change_inside"] < 18)
    elif suite == "seamless":
        ref = Image.open(c["reference"]).convert("RGB"); mask = Image.open(c["mask"])
        row["purple_tint"] = marker_left(out, mask, strict=20)
        row.update(ref_metrics(out, ref, bbox(mask))); row["failed"] = int(row["fallback"] or row["purple_tint"] > 0.25)
    elif suite == "extend":
        ref = Image.open(c["reference"]).convert("RGB"); mask = Image.open(c["mask"])
        if out.size != ref.size: out = out.resize(ref.size, Image.LANCZOS)
        row["purple_tint"] = marker_left(out, mask, strict=20)
        row.update(ref_metrics(out, ref, bbox(mask, grow=0.0))); row["failed"] = int(row["fallback"] or row["purple_tint"] > 0.25)
    elif suite == "remove":
        gt = Image.open(c["gt"]).convert("RGB"); src = Image.open(c["image"]).convert("RGB")
        if out.size != gt.size: out = out.resize(gt.size, Image.LANCZOS)
        hole = np.asarray(Image.open(c["objd"]).convert("L")) > 127; obj = np.asarray(Image.open(c["obj"]).convert("L")) > 127
        yo, yg, ys = luma(out), luma(gt), luma(src)
        mse = ((yo - yg) ** 2)[hole].mean(); row["psnr_hole"] = 99.0 if mse == 0 else 10 * np.log10(255 ** 2 / mse)
        box = bbox(Image.open(c["objd"]), grow=0.045)
        row.update(ref_metrics(out, gt, box)); row["ssim_box"] = ssim_gray(out.crop(box), gt.crop(box))
        moved = np.abs(np.asarray(out, np.float64) - np.asarray(src, np.float64)).mean(-1)[obj].mean()
        needed = np.abs(np.asarray(gt, np.float64) - np.asarray(src, np.float64)).mean(-1)[obj].mean()
        row["left"] = int(needed > 0 and moved < 0.5 * needed); row["failed"] = row["left"] or row["fallback"]
    rows.append(row)

out_dir = run_dirs[-1]
json.dump(rows, open(os.path.join(out_dir, "scores.json"), "w"), indent=1)

# --- summary table per suite and arm
def mean(v): v = [x for x in v if x is not None]; return sum(v) / len(v) if v else None
lines = ["| task | arm | n | failed | retries | median warm s | cold s | change in region | purple tint | LPIPS↓ | DISTS↓ | PSNR | SSIM | hole PSNR | left |", "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
for suite in ["fill", "fill768", "seamless", "extend", "remove"]:
    for arm in sorted({r["arm"] for r in rows if r["suite"] == suite}):
        g = [r for r in rows if r["suite"] == suite and r["arm"] == arm]
        ok = [r for r in g if not r.get("error")]
        warm = sorted(r["run_ms"] for r in ok if r["warm"]); cold = [r["run_ms"] for r in g if not r["warm"]]
        f = lambda k, fmt: (fmt % mean([r.get(k) for r in ok])) if any(r.get(k) is not None for r in ok) else "—"
        lines.append(f"| {suite} | {arm} | {len(ok)}/{len(g)} | {sum(r.get('failed', 0) for r in ok)} | {sum(r.get('retries', 0) for r in ok)} | "
                     f"{(warm[len(warm) // 2] / 1000) if warm else 0:.1f} | {(cold[0] / 1000) if cold else 0:.1f} | {f('change_inside', '%.0f')} | {f('purple_tint', '%.2f')} | {f('lpips', '%.3f')} | {f('dists', '%.3f')} | "
                     f"{f('psnr_box', '%.1f')} | {f('ssim_box', '%.3f')} | {f('psnr_hole', '%.1f')} | {f('left', '%.2f')} |")
open(os.path.join(out_dir, "summary.md"), "w").write("\n".join(lines) + "\n"); print("\n".join(lines))

# --- sheets: one row per item, columns = input (marked) + each arm (+ reference)
def sheet(suite, name, with_ref=False, cell=360):
    arms = sorted({r["arm"] for r in rows if r["suite"] == suite})
    items = [c["id"] for c in cases[suite]]
    cols = 1 + len(arms) + (1 if with_ref else 0)
    S = Image.new("RGB", (cols * cell, len(items) * (cell + 16)), (30, 30, 30)); d = ImageDraw.Draw(S)
    for i, item in enumerate(items):
        c = by_id[suite][item]; y = i * (cell + 16)
        src = Image.open(c["image"]).convert("RGB")
        if "mask" in c and suite != "extend":
            m = Image.open(c["mask"]).convert("L"); src = src.copy(); src.paste((255, 0, 255), mask=m)
        tiles = [(f"{suite} {item}" + (f": {c['prompt']}" if "prompt" in c else ""), src)]
        for arm in arms:
            r = next((r for r in rows if r["suite"] == suite and r["arm"] == arm and r["item"] == item), None)
            im = Image.open(r["output"]).convert("RGB") if r and r.get("output") else Image.new("RGB", src.size, (80, 0, 0))
            tag = f"{arm} {r['run_ms'] / 1000:.1f}s" if r else arm
            if r:
                if r.get("rejected"): tag += f" rejected:{r['rejected']}"
                if r.get("fallback"): tag += " FALLBACK"
                for k in ("lpips", "psnr_hole", "change_inside"):
                    if r.get(k) is not None: tag += f" {k}={r[k]:.3g}"
            tiles.append((tag, im))
        if with_ref: tiles.append(("reference", Image.open(c.get("reference") or c["gt"]).convert("RGB")))
        for j, (label, im) in enumerate(tiles):
            im = im.copy(); im.thumbnail((cell, cell)); S.paste(im, (j * cell, y + 16)); d.text((j * cell + 4, y + 2), label[:60], fill=(255, 255, 255))
    S.save(os.path.join(out_dir, f"{name}.jpg"), quality=85)

for suite, with_ref in [("fill", False), ("fill768", False), ("seamless", True), ("extend", True), ("remove", True)]:
    if any(r["suite"] == suite for r in rows): sheet(suite, f"sheet-{suite}", with_ref)

# --- blind pairs for prompted fill: two arms, order seeded per row, key kept aside
arms = sorted({r["arm"] for r in rows if r["suite"] == "fill"})
if len(arms) == 2:
    random.seed(11); key = []; cell = 480
    items = [c["id"] for c in cases["fill"]]
    S = Image.new("RGB", (2 * cell, len(items) * (cell + 16)), (30, 30, 30)); d = ImageDraw.Draw(S)
    for i, item in enumerate(items):
        order = arms[:] ; random.shuffle(order); key.append({"item": item, "A": order[0], "B": order[1]})
        c = by_id["fill"][item]; box = c["box"]
        for j, arm in enumerate(order):
            r = next((r for r in rows if r["suite"] == "fill" and r["arm"] == arm and r["item"] == item), None)
            im = Image.open(r["output"]).convert("RGB") if r and r.get("output") else Image.new("RGB", (c["w"], c["h"]), (80, 0, 0))
            # crop around the region (2.5x its size) so the fill is judged at scale
            bw, bh = box[2] - box[0], box[3] - box[1]; cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
            s = int(max(bw, bh) * 2.5); x0 = min(max(0, cx - s // 2), max(0, c["w"] - s)); y0 = min(max(0, cy - s // 2), max(0, c["h"] - s))
            im = im.crop((x0, y0, min(c["w"], x0 + s), min(c["h"], y0 + s))); im.thumbnail((cell, cell))
            S.paste(im, (j * cell, i * (cell + 16) + 16))
        d.text((4, i * (cell + 16) + 2), f"{i} {item}: {c['prompt']}   [A | B]", fill=(255, 255, 255))
    S.save(os.path.join(out_dir, "pairs-fill.jpg"), quality=88)
    json.dump(key, open(os.path.join(out_dir, "pairs_key.json"), "w"), indent=1)
print("wrote", out_dir)

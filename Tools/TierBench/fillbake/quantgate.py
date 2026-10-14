"""The Generative Fill quant gate (AB-A-0178): an int4 tier against its reference arm, both through the engine's fill
route at the same seed (`TierBench fillbake --models <ref>,<int4>`), on the bake-off's cases (AB-R-0534).

  quantgate.py score  <cases.json> <out-dir> <name>=<run-dir>:<arm> ...     (pairs: --pair <name>:<test>:<ref>)
  quantgate.py blind  <cases.json> <out-dir> <suite> <run-dir>:<arm> <run-dir>:<arm>
  quantgate.py unblind <out-dir> <suite>                                     (reads judged-<suite>.json + the key)

score: for every pair, PSNR and LPIPS (alex) of the test arm's output against the reference arm's, on the whole image
and inside the mask (PSNR over the mask's pixels; LPIPS on the mask's bounding box), plus each arm's own failure
checks as `score.py` counts them (engine fallback, retries / rejections, marker left, purple tint, change in the
region, left-in-place and hole PSNR for remove). Writes gate.json and gate.md, and labelled per-arm sheets for the
visual failure count (prompt ignored, marker left, haze, seams).

blind: crops around the region for each item, the two arms in a random order per row (os.urandom seed), the key
written to blind-<suite>-key.json and not printed. Judge the sheets, write judged-<suite>.json as {item: "A"|"B"|"tie"},
then unblind.
"""
import json, os, sys, random
import numpy as np
import torch
from PIL import Image, ImageDraw

def load_cases(path):
    cases = json.load(open(path)); return cases, {k: {c["id"]: c for c in v} for k, v in cases.items()}

def records(run):
    out = {}
    for line in open(os.path.join(run, "results.jsonl")):
        r = json.loads(line); r["_run"] = run; out[(r["suite"], r["requested"] or r["model"], r["item"])] = r
    return out

def rgb(path, size=None):
    im = Image.open(path).convert("RGB")
    return im.resize(size, Image.LANCZOS) if size and im.size != size else im

def mask_of(c, size):
    m = Image.open(c["mask"]).convert("L")
    if m.size != size: m = m.resize(size, Image.NEAREST)
    return np.asarray(m) > 127

def bbox(m, grow=0.0):
    ys, xs = np.where(m); x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    gx, gy = int((x1 - x0) * grow), int((y1 - y0) * grow)
    x0, y0, x1, y1 = max(0, x0 - gx), max(0, y0 - gy), min(m.shape[1], x1 + gx), min(m.shape[0], y1 + gy)
    # LPIPS needs room for its receptive field: at least 64 px a side
    if x1 - x0 < 64: c = (x0 + x1) // 2; x0, x1 = max(0, c - 32), min(m.shape[1], max(0, c - 32) + 64)
    if y1 - y0 < 64: c = (y0 + y1) // 2; y0, y1 = max(0, c - 32), min(m.shape[0], max(0, c - 32) + 64)
    return int(x0), int(y0), int(x1), int(y1)

def atleast(box, side, w, h):
    """Grow a box (centred, kept inside the image) to at least `side` a side, so a thin extend strip shows its seam."""
    x0, y0, x1, y1 = box
    if x1 - x0 < side: c = (x0 + x1) // 2; x0 = max(0, min(c - side // 2, w - side)); x1 = min(w, x0 + side)
    if y1 - y0 < side: c = (y0 + y1) // 2; y0 = max(0, min(c - side // 2, h - side)); y1 = min(h, y0 + side)
    return x0, y0, x1, y1

_lp = None
def lpips_of(a, b):
    global _lp
    if _lp is None:
        import lpips; _lp = lpips.LPIPS(net="alex", verbose=False).eval()
    t = lambda im: torch.from_numpy(np.asarray(im, dtype=np.float32) / 127.5 - 1).permute(2, 0, 1)[None]
    with torch.no_grad(): return float(_lp(t(a), t(b)).mean())

def psnr(a, b, m=None):
    d = (np.asarray(a, np.float64) - np.asarray(b, np.float64)) ** 2
    mse = d[m].mean() if m is not None else d.mean()
    return 99.0 if mse == 0 else float(10 * np.log10(255 ** 2 / mse))

def luma(a): a = np.asarray(a, np.float64); return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]

def marker_left(out, m, strict=40):
    a = np.asarray(out).astype(int); r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return float(((r - g > strict) & (b - g > strict) & m).sum() / max(1, m.sum()))

def own_checks(suite, c, r):
    """The bake-off's per-arm checks (score.py), so failure counts are comparable with AB-R-0534."""
    mp = r.get("modelParams") or {}
    row = {"run_ms": r["runMs"], "warm": r["warm"], "retries": mp.get("retries", 0), "rejected": mp.get("rejected", ""),
           "fallback": int("model_fallback" in (r.get("warnings") or [])), "error": r.get("error")}
    if r.get("error") or not r.get("outputs"): row["failed"] = 1; return row
    out = rgb(os.path.join(r["_run"], r["outputs"][0]))
    if suite == "fill":
        src = rgb(c["image"]); out = out.resize(src.size, Image.LANCZOS) if out.size != src.size else out
        m = mask_of(c, src.size)
        row["marker_left"] = marker_left(out, m); row["purple_tint"] = marker_left(out, m, 20)
        row["change_inside"] = float(np.abs(np.asarray(out, np.float64) - np.asarray(src, np.float64)).mean(-1)[m].mean())
        row["failed"] = int(row["fallback"] or row["marker_left"] > 0.25 or row["change_inside"] < 18)
    elif suite in ("seamless", "extend"):
        ref = rgb(c["reference"]); out = out.resize(ref.size, Image.LANCZOS) if out.size != ref.size else out
        m = mask_of(c, ref.size); row["purple_tint"] = marker_left(out, m, 20)
        row["failed"] = int(row["fallback"] or row["purple_tint"] > 0.25)
    elif suite == "remove":
        gt, src = rgb(c["gt"]), rgb(c["image"]); out = out.resize(gt.size, Image.LANCZOS) if out.size != gt.size else out
        hole = np.asarray(Image.open(c["objd"]).convert("L")) > 127; obj = np.asarray(Image.open(c["obj"]).convert("L")) > 127
        mse = ((luma(out) - luma(gt)) ** 2)[hole].mean(); row["psnr_hole"] = 99.0 if mse == 0 else float(10 * np.log10(255 ** 2 / mse))
        moved = np.abs(np.asarray(out, np.float64) - np.asarray(src, np.float64)).mean(-1)[obj].mean()
        needed = np.abs(np.asarray(gt, np.float64) - np.asarray(src, np.float64)).mean(-1)[obj].mean()
        row["left"] = int(needed > 0 and moved < 0.5 * needed); row["failed"] = int(row["left"] or row["fallback"])
    return row

def versus(c, rt, rr):
    """Test output against reference output: whole image and inside the mask."""
    a = rgb(os.path.join(rt["_run"], rt["outputs"][0])); b = rgb(os.path.join(rr["_run"], rr["outputs"][0]), a.size)
    m = mask_of(c, a.size); box = bbox(m)
    return {"identical": bool(np.array_equal(np.asarray(a), np.asarray(b))),
            "psnr_whole": psnr(a, b), "psnr_mask": psnr(a, b, m),
            "lpips_whole": lpips_of(a, b), "lpips_mask": lpips_of(a.crop(box), b.crop(box))}

SUITES = ["fill", "seamless", "extend", "remove"]

def score(cases_path, out_dir, arms, pairs):
    cases, by_id = load_cases(cases_path); os.makedirs(out_dir, exist_ok=True)
    recs = {}
    for name, (run, arm) in arms.items():
        rr = records(run); recs[name] = {(s, i): r for (s, a, i), r in rr.items() if a == arm}
    own = {name: {f"{s}/{i}": own_checks(s, by_id[s][i], r) for (s, i), r in recs[name].items() if s in by_id}
           for name in arms}
    vs = {}
    for pname, test, ref in pairs:
        vs[pname] = {}
        for s in SUITES:
            for c in cases[s]:
                rt, rr = recs[test].get((s, c["id"])), recs[ref].get((s, c["id"]))
                if not rt or not rr or not rt.get("outputs") or not rr.get("outputs"): continue
                vs[pname][f"{s}/{c['id']}"] = versus(c, rt, rr)
                print(pname, s, c["id"], {k: round(v, 3) if isinstance(v, float) else v for k, v in vs[pname][f"{s}/{c['id']}"].items()}, flush=True)
    json.dump({"arms": {n: f"{r}:{a}" for n, (r, a) in arms.items()}, "pairs": pairs, "own": own, "versus": vs},
              open(os.path.join(out_dir, "gate.json"), "w"), indent=1)
    md = ["## Test against reference (same seed, same route)", "",
          "| pair | task | n | identical | PSNR whole (median) | PSNR mask (median) | LPIPS whole (mean) | LPIPS mask (mean) |",
          "|---|---|---|---|---|---|---|---|"]
    for pname, _, _ in pairs:
        for s in SUITES + ["all"]:
            g = [v for k, v in vs[pname].items() if s == "all" or k.startswith(s + "/")]
            if not g: continue
            med = lambda k: float(np.median([x[k] for x in g])); mean = lambda k: float(np.mean([x[k] for x in g]))
            md.append(f"| {pname} | {s} | {len(g)} | {sum(x['identical'] for x in g)} | {med('psnr_whole'):.1f} | {med('psnr_mask'):.1f} | "
                      f"{mean('lpips_whole'):.3f} | {mean('lpips_mask'):.3f} |")
    md += ["", "## Each arm's own checks (score.py's automated failures)", "",
           "| arm | task | n | auto-failed | retries | fallbacks | median warm s | change in region | purple tint | hole PSNR | left |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for name in arms:
        for s in SUITES:
            g = [v for k, v in own[name].items() if k.startswith(s + "/")]
            if not g: continue
            warm = sorted(x["run_ms"] for x in g if x["warm"])
            f = lambda k, fmt: (fmt % np.mean([x[k] for x in g if k in x])) if any(k in x for x in g) else "—"
            md.append(f"| {name} | {s} | {len(g)} | {sum(x['failed'] for x in g)} | {sum(x['retries'] for x in g)} | {sum(x['fallback'] for x in g)} | "
                      f"{(warm[len(warm) // 2] / 1000) if warm else 0:.1f} | {f('change_inside', '%.0f')} | {f('purple_tint', '%.3f')} | "
                      f"{f('psnr_hole', '%.1f')} | {f('left', '%d')} |")
    open(os.path.join(out_dir, "gate.md"), "w").write("\n".join(md) + "\n"); print("\n".join(md))
    for pname, test, ref in pairs: sheets(cases, by_id, recs, out_dir, pname, test, ref)

def sheets(cases, by_id, recs, out_dir, pname, test, ref, cell=440, per=6):
    """Labelled rows: input (region marked) | reference | test | a zoom of each on the region, for the failure count."""
    for s in SUITES:
        items = [c for c in cases[s] if (s, c["id"]) in recs[test] and (s, c["id"]) in recs[ref]]
        for k in range(0, len(items), per):
            chunk = items[k:k + per]
            S = Image.new("RGB", (5 * cell, len(chunk) * (cell + 18)), (30, 30, 30)); d = ImageDraw.Draw(S)
            for i, c in enumerate(chunk):
                src = rgb(c["image"]); y = i * (cell + 18)
                outs = [rgb(os.path.join(recs[n][(s, c["id"])]["_run"], recs[n][(s, c["id"])]["outputs"][0])) for n in (ref, test)]
                size = outs[0].size; m = mask_of(c, size)
                if s != "extend":
                    src = src.resize(size) if src.size != size else src.copy()
                    src.paste((255, 0, 255), mask=Image.fromarray((m * 255).astype(np.uint8)))
                box = atleast(bbox(m, grow=0.35), 512, *size)
                tiles = [src] + outs + [o.crop(box) for o in outs]
                labels = [f"{s} {c['id']}" + (f": {c['prompt']}" if "prompt" in c else ""), f"REF {ref}", f"TEST {test}", "REF zoom", "TEST zoom"]
                for j, (im, lab) in enumerate(zip(tiles, labels)):
                    im = im.copy(); im.thumbnail((cell, cell)); S.paste(im, (j * cell, y + 18)); d.text((j * cell + 4, y + 3), lab[:64], fill=(255, 255, 255))
            S.save(os.path.join(out_dir, f"sheet-{pname}-{s}-{k // per}.jpg"), quality=85)

def blind(cases_path, out_dir, suite, a, b, cell=520, per=5):
    cases, by_id = load_cases(cases_path); arms = [a, b]
    recs = {x: {i: r for (s, ar, i), r in records(x.split(":")[0]).items() if s == suite and ar == x.split(":")[1]} for x in arms}
    rng = random.Random(int.from_bytes(os.urandom(8), "big")); key = {}
    items = [c for c in cases[suite] if all(c["id"] in recs[x] for x in arms)]
    for k in range(0, len(items), per):
        chunk = items[k:k + per]
        S = Image.new("RGB", (2 * cell, len(chunk) * (cell + 18)), (30, 30, 30)); d = ImageDraw.Draw(S)
        for i, c in enumerate(chunk):
            order = arms[:]; rng.shuffle(order); key[c["id"]] = {"A": order[0], "B": order[1]}
            ims = [rgb(os.path.join(recs[x][c["id"]]["_run"], recs[x][c["id"]]["outputs"][0])) for x in order]
            m = mask_of(c, ims[0].size); box = atleast(bbox(m, grow=0.6 if suite != "extend" else 0.25), 512, *ims[0].size)
            for j, im in enumerate(ims):
                if im.size != ims[0].size: im = im.resize(ims[0].size)
                im = im.crop(box); im.thumbnail((cell, cell)); S.paste(im, (j * cell, i * (cell + 18) + 18))
            d.text((4, i * (cell + 18) + 3), f"{c['id']}" + (f": {c['prompt']}" if "prompt" in c else "") + "   [A | B]", fill=(255, 255, 255))
        S.save(os.path.join(out_dir, f"blind-{suite}-{k // per}.jpg"), quality=88)
    json.dump(key, open(os.path.join(out_dir, f"blind-{suite}-key.json"), "w"), indent=1)
    print(f"wrote {(len(items) + per - 1) // per} sheets, {len(items)} rows; key kept in blind-{suite}-key.json")

def unblind(out_dir, suite):
    key = json.load(open(os.path.join(out_dir, f"blind-{suite}-key.json")))
    judged = json.load(open(os.path.join(out_dir, f"judged-{suite}.json")))
    tally = {}
    for item, pick in judged.items():
        who = "tie" if pick == "tie" else key[item][pick].split(":")[1]; tally[who] = tally.get(who, 0) + 1
    print(suite, tally); return tally

if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "score":
        args = sys.argv[4:]; arms, pairs = {}, []
        for x in args:
            if x.startswith("--pair="): pairs.append(tuple(x[len("--pair="):].split(":")))
            else: n, rest = x.split("=", 1); run, arm = rest.rsplit(":", 1); arms[n] = (run, arm)
        score(sys.argv[2], sys.argv[3], arms, pairs)
    elif cmd == "blind": blind(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
    elif cmd == "unblind": unblind(sys.argv[2], sys.argv[3])

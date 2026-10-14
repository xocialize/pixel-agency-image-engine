"""Build the fill bake-off case set (AB-A-0173): prompted fill, seamless fill (reference = the original), extend
(reference = the strip cropped off), and remove (the removal gate's subset S). Writes cases.json plus a marked sheet.
Regions are given as (col, row, cols, rows) on a 4x4 grid of the working image, so they can be placed by eye."""
import json, os, sys
import numpy as np
from PIL import Image, ImageOps, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__))
IN = os.path.join(HERE, "inputs"); os.makedirs(IN, exist_ok=True)
photos = {p["n"]: p for p in json.load(open(os.path.join(HERE, "photos.json")))}
GATE = "/Volumes/Satechi/Development/mlxengine-image/WIP/removal-gate/data/prepared"
MAG = (255, 0, 255)

def working(n, w, h):
    """The photo resized to w x h (aspect-preserving resize, then centre crop)."""
    p = photos[n]; im = ImageOps.exif_transpose(Image.open(p["path"])).convert("RGB")
    k = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * k), round(im.height * k)), Image.LANCZOS)
    x, y = (im.width - w) // 2, (im.height - h) // 2
    return im.crop((x, y, x + w, y + h))

def grid_box(w, h, col, row, cols=1, rows=1, inset=0.1):
    cw, ch = w / 4, h / 4
    x0, y0 = col * cw, row * ch; x1, y1 = x0 + cols * cw, y0 + rows * ch
    dx, dy = (x1 - x0) * inset, (y1 - y0) * inset
    return [int(x0 + dx), int(y0 + dy), int(x1 - dx), int(y1 - dy)]

def save_mask(w, h, box, path):
    m = np.zeros((h, w), np.uint8); x0, y0, x1, y1 = box; m[y0:y1, x0:x1] = 255
    Image.fromarray(m).save(path)

cases = {"fill": [], "fill768": [], "seamless": [], "extend": [], "remove": []}
sheet = []

# --- prompted fill: (photo, w, h, grid region (col,row,cols,rows), prompt)
FILL = [
    ("car", 0, 1536, 1024, (3, 2, 1, 2), "a stack of orange traffic cones"),
    ("derby", 2, 1536, 1024, (0, 3, 1, 1), "a red water bottle lying on the ice"),
    ("temple", 5, 1344, 1024, (1, 3, 1, 1), "a grazing white cow"),
    ("louvre", 7, 1344, 1024, (1, 3, 1, 1), "a green park bench"),
    ("fortress", 8, 1536, 1024, (2, 3, 1, 1), "a red bicycle leaning on a lamp post"),
    ("stilts", 12, 1536, 1024, (0, 3, 1, 1), "a small wooden rowing boat"),
    ("stopsign", 13, 1024, 1024, (0, 2, 1, 2), "a brown dog sitting on the pavement"),
    ("snowforest", 14, 1536, 1024, (1, 3, 1, 1), "a snowman with a red scarf"),
    ("terrace", 15, 1536, 1024, (3, 3, 1, 1), "a steaming cup of coffee on the table"),
    ("gokyo", 17, 1536, 1024, (3, 3, 1, 1), "a yellow camping tent"),
    ("cross", 4, 1024, 1536, (0, 3, 1, 1), "a wooden bench"),
    ("statue", 6, 1184, 1024, (3, 3, 1, 1), "a terracotta pot of red tulips"),
    ("warbler", 10, 1536, 1024, (3, 1, 1, 1), "a small bird's nest with three eggs"),
    ("crystal", 16, 1536, 1024, (1, 1, 1, 2), "more of the same green crystals"),
    ("sculpture", 11, 1184, 1024, (0, 3, 1, 1), "a small bouquet of white roses on the floor"),
]
for id_, n, w, h, g, prompt in FILL:
    im = working(n, w, h); box = grid_box(w, h, *g)
    img = os.path.join(IN, f"fill-{id_}.png"); msk = os.path.join(IN, f"fill-{id_}-mask.png")
    im.save(img); save_mask(w, h, box, msk)
    cases["fill"].append({"id": id_, "image": img, "mask": msk, "prompt": prompt, "w": w, "h": h, "box": box, "photo": n})
    sheet.append((f"fill {id_}: {prompt}", im, box))
    # 768² variant: a square around the region, resized to 768
    s = min(w, h); cx, cy = (box[0] + box[2]) // 2, (box[1] + box[3]) // 2
    x0 = min(max(0, cx - s // 2), w - s); y0 = min(max(0, cy - s // 2), h - s)
    sq = im.crop((x0, y0, x0 + s, y0 + s)).resize((768, 768), Image.LANCZOS)
    k = 768 / s; b2 = [int((box[0] - x0) * k), int((box[1] - y0) * k), int((box[2] - x0) * k), int((box[3] - y0) * k)]
    img2 = os.path.join(IN, f"fill768-{id_}.png"); msk2 = os.path.join(IN, f"fill768-{id_}-mask.png")
    sq.save(img2); save_mask(768, 768, b2, msk2)
    cases["fill768"].append({"id": id_, "image": img2, "mask": msk2, "prompt": prompt, "w": 768, "h": 768, "box": b2, "photo": n})

# --- seamless fill: region over plain content; the original is the reference
SEAMLESS = [
    ("car", 0, 1536, 1024, (2, 0, 1, 1)), ("temple", 5, 1344, 1024, (0, 3, 1, 1)), ("louvre", 7, 1344, 1024, (3, 0, 1, 1)),
    ("fortress", 8, 1536, 1024, (0, 3, 1, 1)), ("stilts", 12, 1536, 1024, (3, 3, 1, 1)), ("snowforest", 14, 1536, 1024, (0, 3, 1, 1)),
    ("gokyo", 17, 1536, 1024, (0, 2, 1, 1)), ("terrace", 15, 1536, 1024, (0, 0, 1, 1)), ("warbler", 10, 1536, 1024, (0, 0, 1, 1)),
    ("crystal", 16, 1536, 1024, (0, 3, 1, 1)), ("derby", 2, 1536, 1024, (3, 3, 1, 1)),
]
for id_, n, w, h, g in SEAMLESS:
    im = working(n, w, h); box = grid_box(w, h, *g)
    img = os.path.join(IN, f"seamless-{id_}.png"); msk = os.path.join(IN, f"seamless-{id_}-mask.png")
    im.save(img); save_mask(w, h, box, msk)
    cases["seamless"].append({"id": id_, "image": img, "mask": msk, "reference": img, "w": w, "h": h, "box": box, "photo": n})
    sheet.append((f"seamless {id_}", im, box))

# --- extend: crop strips off the full working image, extend back; the full image is the reference
EXTEND = [  # id, photo, full w, h, (left, top, right, bottom) to cut off
    ("car", 0, 1536, 1024, (0, 0, 256, 0)), ("derby", 2, 1536, 1024, (256, 0, 0, 0)), ("temple", 5, 1344, 1024, (0, 192, 0, 0)),
    ("louvre", 7, 1344, 1024, (0, 0, 0, 192)), ("fortress", 8, 1536, 1024, (256, 0, 256, 0)), ("stilts", 12, 1536, 1024, (0, 0, 384, 0)),
    ("snowforest", 14, 1536, 1024, (0, 256, 0, 0)), ("gokyo", 17, 1536, 1024, (0, 0, 0, 256)), ("cross", 4, 1024, 1536, (256, 0, 0, 0)),
    ("stopsign", 13, 1024, 1024, (0, 0, 256, 0)), ("terrace", 15, 1536, 1024, (256, 192, 0, 0)), ("statue", 6, 1184, 1024, (0, 0, 0, 256)),
]
for id_, n, w, h, (l, t, r, b) in EXTEND:
    full = working(n, w, h); ref = os.path.join(IN, f"extend-{id_}-ref.png"); full.save(ref)
    cut = full.crop((l, t, w - r, h - b)); img = os.path.join(IN, f"extend-{id_}.png"); cut.save(img)
    m = np.full((h, w), 255, np.uint8); m[t:h - b, l:w - r] = 0
    msk = os.path.join(IN, f"extend-{id_}-mask.png"); Image.fromarray(m).save(msk)
    cases["extend"].append({"id": id_, "image": img, "canvas": {"left": l, "top": t, "right": r, "bottom": b}, "reference": ref,
                            "mask": msk, "w": w, "h": h, "photo": n})
    marked = full.copy(); ImageDraw.Draw(marked).rectangle((l, t, w - r - 1, h - b - 1), outline=(255, 0, 255), width=6)
    sheet.append((f"extend {id_} l{l} t{t} r{r} b{b}", marked, None))

# --- remove: the removal gate's subset S (object masks dilated 1.5%, the mask a client sends)
entries = [e for e in json.load(open(os.path.join(GATE, "manifest.json"))) if e.get("subsetS")][:20]
for e in entries:
    base = os.path.join(GATE, e["id"])
    cases["remove"].append({"id": e["id"].replace("/", "-"), "set": e["set"], "image": base + "_src.png", "mask": base + "_objd.png",
                            "gt": base + "_gt.png", "obj": base + "_obj.png", "objd": base + "_objd.png"})

json.dump(cases, open(os.path.join(HERE, "cases.json"), "w"), indent=1)
# marked sheet
th = 300; cols = 6; rows = (len(sheet) + cols - 1) // cols
S = Image.new("RGB", (cols * th, rows * (th + 16)), (30, 30, 30))
for i, (label, im, box) in enumerate(sheet):
    im = im.copy()
    if box: ImageDraw.Draw(im).rectangle(box, fill=MAG)
    im.thumbnail((th, th)); x, y = (i % cols) * th, (i // cols) * (th + 16)
    S.paste(im, (x, y + 16)); ImageDraw.Draw(S).text((x + 4, y + 2), label[:52], fill=(255, 255, 255))
S.save(os.path.join(HERE, "cases_sheet.jpg"), quality=85)
print({k: len(v) for k, v in cases.items()})

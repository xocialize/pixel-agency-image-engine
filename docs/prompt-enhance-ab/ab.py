"""Prompt enhancement A/B (AB-D-0155, E2): each profile's model, the same seed, with and without enhancement.

Usage: python3 -I ab.py BASE_URL OUT_DIR
Writes OUT_DIR/<case>-<arm>.png, OUT_DIR/results.json.
"""
import json, os, sys, time, urllib.request, urllib.error

BASE, OUT = sys.argv[1].rstrip("/"), sys.argv[2]
os.makedirs(OUT, exist_ok=True)
EXT = "x-pixelagency.prompt_enhance"
SEED = 20261019
SIZE = {"width": 1024, "height": 1024}

# (case id, model, profile policy, prompt). Recommended profiles: off vs auto. Optional ones: off vs on.
CASES = [
    ("qwen-lighthouse", "qwen-image-flash", "recommended", "a lighthouse at dusk"),
    ("qwen-jazz", "qwen-image-flash", "recommended", 'a poster for a jazz night called "Blue Hour"'),
    ("klein-bakery", "klein-4b", "recommended", 'a bakery storefront at dawn with a sign that says "OPEN"'),
    ("klein-apples", "klein-4b", "recommended", "three red apples on a wooden table, left of a blue mug"),
    ("zimage-lighthouse", "z-image-turbo", "optional", "a lighthouse at dusk"),
    ("zimage-fox", "z-image-turbo", "optional", "a red fox in fresh snow"),
    ("mage-teashop", "mage-flow-turbo", "optional", 'a tea shop sign that reads "茶馆" in gold'),
    ("mage-robot", "mage-flow-turbo", "optional", "a small robot watering plants on a balcony"),
]


def call(method, path, body=None, timeout=900):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def run(request):
    t0 = time.time()
    status, body = call("POST", "/jobs", request)
    if status != 201:
        raise SystemExit(f"POST jobs: {status} {body[:400]!r}")
    job = json.loads(body)
    while job["state"] in ("received", "fetching", "waiting", "running"):
        status, body = call("GET", f"/jobs/{job['id']}?wait=20", timeout=60)
        job = json.loads(body)
    job["_seconds"] = round(time.time() - t0, 1)
    return job


def score(png):
    import base64
    request = {"operation": "image.score",
               "inputs": {"image": {"inline": {"media_type": "image/png", "data": base64.b64encode(png).decode()}}}}
    job = run(request)
    if job.get("outcome") != "succeeded":
        return None
    status, body = call("GET", f"/jobs/{job['id']}/outputs/0")
    call("POST", f"/jobs/{job['id']}/confirm")
    return json.loads(body).get("score") if status == 200 else None


results = []
for case, model, policy, prompt in CASES:
    for arm, mode in (("off", "off"), ("on", "auto" if policy == "recommended" else "on")):
        request = {"operation": "image.generate", "model": model, "inputs": {"prompt": prompt},
                   "params": {"seed": SEED, "size": SIZE}, "extensions": {EXT: {"mode": mode}}}
        job = run(request)
        row = {"case": case, "model": model, "policy": policy, "arm": arm, "mode": mode, "prompt": prompt,
               "state": job.get("state"), "outcome": job.get("outcome"), "seconds": job["_seconds"],
               "error": job.get("error"), "warnings": job.get("warnings")}
        result = job.get("result") or {}
        row["effective"] = result.get("effective")
        row["seed"] = (result.get("provenance") or {}).get("seed")
        if job.get("outcome") == "succeeded":
            status, png = call("GET", f"/jobs/{job['id']}/outputs/0")
            path = os.path.join(OUT, f"{case}-{arm}.png")
            with open(path, "wb") as f:
                f.write(png)
            row["image"] = os.path.basename(path)
            call("POST", f"/jobs/{job['id']}/confirm")
            row["quality"] = score(png)
        pe = ((row["effective"] or {}).get("model_params") or {}).get("prompt_enhancement")
        print(f"{case:18} {arm:3} {row['outcome']} {row['seconds']:6}s pe={json.dumps(pe)[:160]} q={row.get('quality')}",
              flush=True)
        results.append(row)
        with open(os.path.join(OUT, "results.json"), "w") as f:
            json.dump(results, f, indent=1, ensure_ascii=False)

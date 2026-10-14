# Generative Fill bake-off: FLUX.2-klein-4B vs SenseNova-U1.5 8-step V2 (AB-A-0173)

**2026-10-14, Mac Studio (Mac17,14), M5 Max 128 GB, macOS 27.2. pixel-agency-image-engine 0.2.9 release
(e6fc698) on mlx-image-runtime 0.5.1; TierBench `fillbake` suite (Tools/TierBench/Sources/TierBench/FillBake.swift,
harness in Tools/TierBench/fillbake/).** Mage-Flow Edit-Turbo was dropped as a fill candidate by the operator on
2026-10-14 (ignores painted marks, AB-R-0463; square-only port). This is the quality half of the bake-off the ask
requested; the real M5 Pro 24 GB numbers still wait on that machine (AB-A-0005).

## Method

Both arms ran through the engine's own generative fill route, as a client would: `image.fill` / `image.extend`
with the model named, so the magenta marker, the paint guard (marker or dark → retry with the next seed, then LaMa
fallback), the seam harmonize and the feathered composite were identical. Seed 7 everywhere; both arms reproduce
their outputs exactly on a second run.

- **Arms.** `klein-4b` (the engine's tier: distilled 4-step, bf16, resident) and `sensenova-u1-fast`
  (8step-v2-8bit, 8 steps cfg 1). LaMa (`lama-inpaint`) as the remove floor.
- **Cases** (`Tools/TierBench/fillbake/build_cases.py`): 15 prompted fills on CC BY / CC0 commons-sr photos (objects,
  a texture, people-adjacent scenes; 1536×1024, 1344×1024, 1184×1024, 1024² and 1024×1536 canvases), the same 15 at
  768²; 11 seamless fills (no prompt, the original is the reference); 12 extends (a strip cropped off the real
  photo is the reference: left, right, top, bottom, both sides, a corner, two portrait canvases); 20 removes from
  the removal gate's subset S (object masks dilated 1.5 %, object-absent ground truth, evaluation-only data).
- **Scores** (`score.py`): LPIPS (alex) and DISTS on the region's box where a reference exists, PSNR, hole PSNR and
  left-in-place for remove, the engine's retries / rejections / fallbacks, a marker and purple-tint check, and the
  change inside the region. Prompted fill has no reference, so it was judged **blind**: crops around the region,
  arm order shuffled per row, key opened after judging (`run-fill/judgement-fill.json`). Extend and seamless were
  judged on labelled full-resolution edge crops (`judgement-extend-seamless.json`). One judge.
- **Timing** is the job's `run_ms` from the engine. Warm medians are from a second fill pass on an idle box
  (`run-timing`); cold is the first job after the arm loads.

## Results (1024-class canvases unless noted)

| Task | Arm | n | Failures | Retries / fallbacks | Warm median | Cold | LPIPS↓ | DISTS↓ |
|---|---|---|---|---|---|---|---|---|
| Prompted fill | klein-4b | 15 | **3** (nothing painted ×2, blob ×1) | 0 / 0 | 20.1 s | 24.4 s | — | — |
| Prompted fill | sensenova-u1-fast | 15 | **0** | 0 / 0 | 6.7 s | 10.2 s | — | — |
| Prompted fill 768² | klein-4b | 15 | 1 | 0 / 0 | 7.7 s | 7.5 s | — | — |
| Prompted fill 768² | sensenova-u1-fast | 15 | 0 | 0 / 0 | 2.7 s | 15.1 s | — | — |
| Seamless fill | klein-4b | 11 | 3 (hard patch ×2, invented objects ×1) | 0 / 0 | 20.3 s | — | 0.357 | 0.204 |
| Seamless fill | sensenova-u1-fast | 11 | 1 (visible rectangle) | 0 / 0 | 7.5 s | — | 0.339 | 0.169 |
| Extend | klein-4b | 12 | **6** (purple / pink haze ×5, flat patch ×1) | 1 / 0 | 22.9 s | — | 0.464 | 0.244 |
| Extend | sensenova-u1-fast | 12 | **0** | 0 / 0 | 8.6 s | — | 0.460 | 0.250 |
| Remove | lama-inpaint | 20 | 1 left | 0 / 0 | 0.9 s | 1.1 s | 0.294 | 0.171 |
| Remove | klein-4b | 20 | **11** (9 fell back to LaMa, 2 left) | 4 / 9 | 32.6 s | 20.1 s | 0.295 | 0.182 |
| Remove | sensenova-u1-fast | 20 | **0** | 0 / 0 | 4.2 s | 9.4 s | 0.265 | 0.173 |

- **Blind preference, prompted fill:** SenseNova 9, Klein 6. Klein's three failures left the region as a faint
  patch (the water bottle, the rowing boat) or a shapeless blob (the snowman); the engine accepted all three
  because the marker was gone. Klein won where it rendered a cleaner object (the cow, the small bicycle, the
  sharper nest and crystals); SenseNova's objects sit in the picture's light more often and its seams are cleaner.
- **Extend:** SenseNova preferred on 8, tied on 4, Klein on none. Klein left a purple or pink haze on five new
  strips and a flat grey patch on a sixth, all below the guard's thresholds, so they shipped. SenseNova continued
  the paving, the building, the rink and the shore; its one weakness is a faint tone step at the seam.
- **Seamless fill:** even (SenseNova 4, Klein 4, 3 ties). Klein pasted a mismatched patch twice and hallucinated
  roller skates once; SenseNova blurred one texture and left one bluish rectangle.
- **Remove through the fill route:** Klein keeps the marker (13 rejections in 20 items) and hands 9 of 20 to LaMa.
  SenseNova removes every object with no retry: median hole PSNR 17.5 dB against LaMa's 13.8 and Klein's 12.8
  (means 17.7 / 14.5 / 14.1). It reconstructs shadows and pavement well; it invented a lit doorway in one dark
  scene (corne-000044), which LaMa did not.
- **Non-square canvases** ran through the engine at their own aspect for both arms; no squash in the composites.

## Memory and cold latency per tier (the packages' own CLIs, GPU idle, `memory_arms.log`)

A 1024² (or 768²) single-reference edit, the shape of the fill route's window. MLX peak is what the tier limit
sees; the resident floor is after load. Klein's run time includes the encoder reload under eviction.

| Arm | Floor | 768² peak | 1024² peak | 768² run | 1024² run |
|---|---|---|---|---|---|
| Klein bf16, resident (the engine's tier today) | 13.7 GB | — | **24.4 GB** | — | 23.6 s |
| Klein int4, resident | 8.6 GB | — | 19.4 GB | — | 14.5 s |
| Klein int8, encoder evicted | 4.4 GB | 10.7 GB | 15.2 GB | 9.1 s | 15.4 s |
| Klein int4, encoder evicted | 2.7 GB | **8.9 GB** | 13.4 GB | 7.7 s | 18.9 s |
| SenseNova 8step-v2-4bit | 11.2 GB | 14.7 GB | 14.7 GB | 2.3 s (+2.8–4.1 s load) | 3.9 s |
| SenseNova 8step-v2-8bit | 19.0 GB | 22.9 GB | 22.5 GB (AB-R-0533) | 2.5 s | 4.0 s |

SenseNova's peak is its load transient (+3.5 GB over the floor); the denoise adds about 0.3 GB. Klein's 1024² peak
is its activation (the fp32 activation stream, IMG-011), so eviction does not bring 1024² under 12.7 GB.

## Recommendation per tier

- **16 GB (12.7 GB MLX limit):** Klein-4B int4 with the encoder evicted, **with the fill window capped at 768²**
  (8.9 GB; 1024² peaks at 13.4 GB). It is the only candidate under the limit today, at the quality above: a
  prompted fill fails about 1 in 5 and extends about half the time, with the guard catching some. Upgrade path:
  trim SenseNova int4's load transient (its 11.2 GB active set plus 0.3 GB denoise fits) and the 16 GB tier gets
  the 24 GB model; that is a sensenova-u1-swift item.
- **24 GB:** SenseNova-U1.5 8step-v2-4bit (14.7 GB peak). Fewer failures on every task, 3–4× faster, and a remove
  that beats LaMa by 3.7 dB in the hole without a naming model.
- **32 GB+:** SenseNova-U1.5 8step-v2-8bit (22.9 GB peak), which reproduces the bf16 merge (cos 0.995, AB-R-0490).

## Caveats

- The quality arms were Klein bf16 and SenseNova int8, the engine's tiers. The 16 / 24 GB quants (Klein int4,
  SenseNova int4) were only measured for memory and time. SenseNova int4 is a different-but-valid draw from int8
  (cos 0.976); Klein int4's edit quality against bf16 is unmeasured.
- One judge, 15 / 11 / 12 / 20 cases. Blind only for prompted fill.
- Remove used the first 20 of subset S with object masks, not the gate's 60, so hole PSNR is not comparable to
  AB-R-0476's table; the three arms here are comparable with each other.
- Klein's warm fill time (20 s) is above TIERS.md's 17.9 s because most canvases were 1536×1024; at 768² it is
  7.7 s. SenseNova's fill768 cold number (15.1 s) includes evicting Klein first.
- Real 24 GB numbers (M5 Pro) are still owed (AB-A-0005).

## Files

`docs/fill-bakeoff/`: `pairs-fill-{0,1,2}.jpg` (the blind pairs, key in `pairs_key-fill.json`), `sheet-fill.jpg`,
`sheet-fill768.jpg`, `sheet-seamless.jpg`, `sheet-extend.jpg`, the `zoom-*.jpg` edge crops, `judgement-*.json`,
`summary.md`, `scores.json`, `memory_arms.log`. The remove sheet and crops stay out of the repo (CORNE is
evaluation-only); they are in `bench/fillbake/run-remove/` locally. Harness: `Tools/TierBench/fillbake/`
(`build_cases.py`, `score.py`, `pairs.py`, `zoom.py`, `run_all.sh`, `memory_arms.sh`) and the `fillbake` suite.

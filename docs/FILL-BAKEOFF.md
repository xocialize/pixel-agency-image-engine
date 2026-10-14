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

Since then: AB-D-0141 (amended) put 16 GB on SenseNova 8step-v2-4bit at ≤ 768², once its load transient was gone
(AB-R-0536), with Klein-4B evicted at ≤ 768² as the documented fallback. The quant gate below passes both SenseNova
int4 tiers and moves that fallback from Klein int4 to Klein int8 (AB-R-0544).

## Quant gate (AB-A-0178, receipt AB-R-0544): the int4 tiers against their quality arms

**2026-10-14, same machine, same 58 cases, seed 7, through the engine's fill route with the model named**
(pixel-agency-image-engine 0.2.9 plus hidden `--quant-gate-arms` catalog entries, `Sources/ImageEngineCLI/QuantGateArms.swift`;
harness `Tools/TierBench/fillbake/run_quantgate.sh` and `quantgate.py`). The route renders the whole canvas at the
model's envelope, so a 768² envelope is the 768² window. The int8 reference reproduced the bake-off's SenseNova
outputs bit-identical, 58 of 58. Each reference was run again at seed 8, to show how far an equally valid draw lands.
Failures are counted as above: prompt ignored, marker left, haze, patches and seams from labelled sheets with
region zooms, and remove as LaMa fallbacks plus objects left in place. Blind: crops around the region, arm order
from `os.urandom`, key opened after judging, one judge.

| Tier (test arm) | Reference | Fill /15 | Seamless /11 | Extend /12 | Remove /20 | Blind fill (test : ref : tie) | Blind extend |
|---|---|---|---|---|---|---|---|
| 24 GB: SenseNova 8step-v2-4bit, 1024-class | 8step-v2-8bit | **0** vs 0 | 1 vs 1 | 0 vs 0 | 0 vs 0 | 4 : 3 : 8 | 0 : 1 : 11 |
| 16 GB: SenseNova 8step-v2-4bit, 768² | 8step-v2-8bit, 768² | **0** vs 0 | 1 vs 2 | 0 vs 0 | 0 vs 0 | 2 : 1 : 12 | 1 : 0 : 11 |
| 16 GB fallback: Klein-4B int4 evicted, 768² | bf16, 768² | **8** vs 6 (5 at seed 8) | 3 vs 3 | 7 vs 7 | 12 vs 14 | **1 : 4 : 10** | 2 : 3 : 7 |
| Klein-4B int8 evicted, 768² (the alternative) | bf16, 768² | 6 vs 6 | 3 vs 3 | 7 vs 7 | 14 vs 14 | 0 : 0 : 15 | 1 : 0 : 11 |

Test against reference on all 58 cases (median PSNR, mean LPIPS alex; mask = the region, LPIPS on its box), and the
reference against itself at seed 8:

| Pair | PSNR whole | PSNR mask | LPIPS whole | LPIPS mask | Reference reseeded: PSNR mask / LPIPS mask |
|---|---|---|---|---|---|
| SenseNova int4 vs int8, 1024-class | 37.7 dB | 26.7 dB | 0.016 | 0.118 | 17.3 dB / 0.257 |
| SenseNova int4 vs int8, 768² | 35.0 | 23.5 | 0.020 | 0.135 | 16.8 / 0.302 |
| Klein int4 evicted vs bf16, 768² | 36.1 | 24.4 | 0.016 | 0.117 | 19.0 / 0.248 |
| Klein int8 evicted vs bf16, 768² | 53.9 | 43.9 | 0.002 | 0.018 | — |

Prompted fill alone, inside the mask: SenseNova int4 18.2 dB / 0.191 at 1024 and 21.4 / 0.194 at 768² (reseed
14.1 / 0.410 and 14.6 / 0.477); Klein int4 19.9 / 0.176 (reseed 14.9 / 0.402). Klein's "whole" medians count the 11–13
removes where both arms fell back to LaMa and match exactly. Per-case tables: `docs/fill-quantgate/gate-*.md`.

- **24 GB, SenseNova 8step-v2-4bit: GO.** Same failures as int8 on every task (terrace's bluish rectangle in both),
  blind even, and int4 lands about half as far from int8 as a reseed does. Every prompted fill keeps int8's
  composition. One remove (corne-000022) painted a stack of papers where the object was (hole PSNR 6.6 vs 28.8 dB);
  that is not a failure by the count above, and int8's doorway in corne-000044 shows up in int4 too. Remove hole PSNR
  is 16.7 vs 17.7 dB (mean). Warm fill 6.2 vs 6.5 s.
- **16 GB, SenseNova 8step-v2-4bit at ≤ 768²: GO on quality**, against int8 at the same window: 1 failure against 2
  (int8 smudged one seamless sky), blind even, warm fill 3.3 vs 3.8 s. The memory confirmation on a real 16 GB Mac
  (AB-D-0141) still gates it. The 768² window costs both quants in remove: hole PSNR 14.2 / 13.9 dB against 17.7 at
  1024², about LaMa's 14.5 here.
- **16 GB fallback, Klein-4B int4 evicted at ≤ 768²: NO-GO.** Prompted fill fails 8 of 15 against bf16's 6 (5 at
  seed 8). The two extra failures are washed-out half-renders, a ghost snowman and a bench that is only a post.
  Blind prompted fill goes 1 : 4 against int4. The totals match (30 / 58 each) only because int4 hands two fewer
  removes to LaMa.
- **What fits instead: Klein-4B int8 evicted at ≤ 768²**, 10.7 GB MLX peak (AB-R-0534) under the 12.7 GB limit with
  2 GB to spare. It reproduces bf16: 43.9 dB inside the mask, the same failure on every case, and blind ties on 26 of
  27 pairs. Speed through the engine route, warm medians under this run's load: fill 10.2 s (int4 10.6, bf16 9.6),
  extend 10.7 s, remove 19.9 s (most removes retry, then fall back to LaMa). The package CLI on an idle GPU measured
  9.1 s at 768² against int4's 7.7 s (AB-R-0534).
- **Klein at 768² is a weak tier whatever the quant.** bf16 itself fails 30 of 58 at a 768² window, 6 of 15 prompted
  fills, against 23 of 58 and 3 of 15 at 1024² in the bake-off. SenseNova int4 at 768² fails 1 of 58. Klein stays the
  fallback only.

Caveats: one judge. For the SenseNova 1024 and Klein int8 blinds, the judge had already seen labelled sheets of the
same outputs. The Klein int4 and SenseNova 768 blinds were judged first. Load average was 30–75 throughout (other
sessions' test runners), so the times are indicative only; timing was not the point of this run. The fill route renders the whole canvas at the window. ForgeCore's provider crops a
window around the mask first (AB-R-0541), which gives a small region more pixels on large canvases, so its failure
rates may run lower than these.

## Caveats

- The quality arms were Klein bf16 and SenseNova int8, the engine's tiers. The 16 / 24 GB quants (Klein int4,
  SenseNova int4) were only measured for memory and time. SenseNova int4 is a different-but-valid draw from int8
  (cos 0.976); Klein int4's edit quality against bf16 is unmeasured. *(Since measured: the quant gate above.)*
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

Quant gate: `docs/fill-quantgate/`. Per pair it has `gate-*.md` / `.json` (`anchor` = the seed-8 rerun), the labelled
sheets `sheet-*-{fill,seamless,extend}-*.jpg`, the blind pairs `*-blind-{fill,extend}-*.jpg` with their
`*-blind-*-key.json` and `*-judged-*.json`, and `judgement-failures.json`. Remove sheets and crops stay local
(`bench/quantgate/`). Harness: `run_quantgate.sh`, `quantgate.py`, TierBench `fillbake --seed`, and the engine's
hidden `--quant-gate-arms`.

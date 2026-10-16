# Quality tiers, measured (ENG R1b)

Engines-PRD §5 sketched which model serves each quality tier "as a starting point to measure, not a decision"
(OQ-5, accepted as "measure before Desktop D1"). This is that measurement. Each request's tier, or a param such
as restore's `kind`, picks the model below when the request names none. A request can always name any offered
model.

## The mapping

| Operation | Draft | Standard (default) | Best | Basis |
|---|---|---|---|---|
| `image.generate` | Klein 4B | **Z-Image Turbo** | Z-Image Turbo | Turbo leads on quality on both prompt sets; Z-Image scored lower at 5× the time |
| `image.edit` | Klein 4B | **Klein 4B** | Klein 4B | Provisional: Qwen-Image-Edit 2511 is ~20× slower and failed one of two edits |
| `image.fill` (no prompt) | MI-GAN | **LaMa** | LaMa | LaMa fp32 (mlx-lama-swift ≥ 0.3.1) |
| `image.fill` (prompt) | Klein 4B | **Klein 4B** | Klein 4B | Paints the prompt; guarded, LaMa fallback |
| `image.erase` | MI-GAN | **LaMa** | Mage-Flow Edit Turbo, by name | Removal gate (R2): Mage +3.5 dB in the hole, 10× LaMa's time |
| `image.extend` (no prompt) | MI-GAN | **LaMa** | LaMa | LaMa continued busy photos coherently every time |
| `image.extend` (prompt) | Klein 4B | **Klein 4B** | Klein 4B | Guarded per side; unguarded, Klein failed 2 of 4 |
| `image.upscale` (photo) | NERVE | **RealPLKSR** | HEART | HEART best fidelity at ×2 and ×4; RealPLKSR best perceptual |
| `image.upscale` (drawn) | NERVE | **NERVE** | HEART | Drawn ladder (AB-R-0486): HEART beats NERVE at ×4 and ×2; NERVE ties RealPLKSR at a fifth of its cost |
| `image.upscale` (generative, by name) | | | VOSR2, Nacre | Behind ForgeCore's text-legibility guard (AB-D-0111), from 0.1.2; never a default |
| `image.restore` (denoise) | NAFNet | **SCUNet** | SCUNet | SCUNet +0.7 dB at σ 25; NAFNet ~50× faster |
| `image.restore` (deblur) | Restormer-defocus | **Restormer-defocus** | Restormer-defocus | Improves SSIM on blur; motion doesn't |
| `image.restore` (general / faces) | NAFNet / GFPGAN | **NAFNet / GFPGAN** | same | Not separately measured |
| `image.segment` | (EdgeTAM, by name) | **SAM 2.1** | SAM 2.1 | IoU 0.772 vs 0.651, same speed |
| `image.matte`, `relight`, `colorize`, `describe`, `score` | one model each | | | Timed only |

Not offered:
- **Research models** are offered only with `--allow-research`, and then named-only.

## Method

- **Machine.** Mac Studio (Mac17,14), Apple M5 Max (18 cores), 128 GB, macOS 27.2.
  - Earlier receipts on the volume were all measured on an M5 Max MacBook Pro; these are this machine's numbers.
- **Engine.** pixel-agency-image-engine, debug build.
  - GPU-bound timings match release receipts (Z-Image Turbo 13.7 s here, 13 s in its README).
  - CPU-side pre- and post-processing is slower in debug, which inflates the fastest models' times slightly.
  - One run (the hard prompts) shared the GPU with another session, so its timings are about 2× high and aren't
    used.
- **Harness.** [`Tools/TierBench`](../Tools/TierBench) drives the running engine through MESClientKit, exactly as a
  client does.
  - Times are the job's `run_ms` (median of warm runs; the first run is reported separately).
  - Quality is scored against ground truth where the corpus has it.
- **Corpora** (measurement only, never shipped; `mlxengine-image/corpus`):
  - DIV2K validation HR (upscale, restore);
  - GrabCut (segment);
  - the removal gate's prepared set (erase; `mlxengine-image/WIP/removal-gate/data/prepared`): CORNE-Val (Apache,
    evaluation only) and RemovalBench (CC-BY-4.0).
- **Raw summaries and the generate contact sheets:** [`docs/tiers/`](tiers/). Sheets built from DIV2K photos are
  kept out of the repo (research-only licence).

## Evidence

### Generate (1024², 8 everyday prompts, then 6 hard ones)

| Model | Warm time | IQA, everyday | IQA, hard | Hard-prompt recall | Notes |
|---|---|---|---|---|---|
| Klein 4B (4 steps) | 8.8 s | 0.903 | 0.867 | 0.889 | Misspells ("OPEN DAIL Y", "HELLIO"); added a kiwi to "three oranges and a lemon" |
| **Z-Image Turbo** (8 steps) | 13.7 s | 0.915 | **0.903** | **0.944** | Spelled all three texts right; miscounted apples (six for five) |
| Z-Image (28 steps) | 70.4 s | 0.895 | 0.880 | 0.778 | Junk text on the sign, garbled poster layout; stylized look |
| Klein 4B Base (28 steps) | 80.0 s | 0.914 | 0.902 | 0.944 | "OPENDALY"; dark, moody renders |
| Qwen-Image Flash | 15.9 s | 0.935 (n = 2) | — | — | Offered, not a default; quarantined until 0.2.7 (AB-T-0214) |

- **IQA:** the engine's own `image.score` (SigLIP2, 0–1).
- **Recall:** the share of each prompt's required words (texts, counts, colours, objects) found in `image.describe`'s
  caption and tags (Mage-VL).
- **The everyday prompts** gave recall 1.0 for every model, so they can't tell models apart. The hard set exists for
  that reason.
- **Verdict:** the sheets ([everyday](tiers/generate-sheet.jpg), [hard](tiers/generate-hard-sheet.jpg)) agree with
  the numbers.
  - Nothing beats Z-Image Turbo, so it is both standard and best.
  - Z-Image and Klein Base remain offered for their looks.

### Upscale (DIV2K 0801–0806, 1024² HR, PSNR/SSIM on luma, border = scale)

| Model | ×2 PSNR / SSIM | ×2 time | ×4 PSNR / SSIM | ×4 time |
|---|---|---|---|---|
| NERVE | 30.18 / 0.875 | 0.29 s | 26.97 / 0.779 | 0.22 s |
| RealPLKSR | 30.65 / 0.905 | 0.94 s | 26.46 / 0.756 | 0.31 s |
| **HEART** | **31.35 / 0.914** | 2.42 s | **27.05 / 0.782** | 0.63 s |
| Nacre (generative) | 28.75 / 0.867 | 14.1 s | 25.63 / 0.747 | 5.0 s |
| SeedVR2 | 26.88 / 0.779 | 8.7 s | 25.64 / 0.736 | 8.4 s |

RealPLKSR's and HEART's ×2 figures above are from before 0.2.2. Back then a ×2 was their ×4 output reduced by a
CoreGraphics draw that misregistered the frame by up to ±0.26 px. Since 0.2.2 it is a Lanczos reduction (the
packages' 0.2.1, AB-T-0225). On 20 Commons photo tiles that is worth +0.2 dB for RealPLKSR; on drawn content it is
+1.7 dB for RealPLKSR and +2.8 dB for HEART. NERVE's ×2 is a native checkpoint and is unaffected. Nacre's ×2 had the same draw and is a Lanczos reduction
since 0.2.4 (mlx-nacre-swift 0.1.5, AB-T-0232): +0.75 dB on drawn content.

Earlier evidence (the Commons twelve-rung ladder, AB-R-0379) agrees on ranking:
- HEART had the best PSNR on 12 of 12 rungs.
- RealPLKSR had the best DISTS on 12 of 12 rungs. DISTS is partly its own training loss, which flatters it.
- SeedVR2 was the worst learned model on JPEG photos.

That's why the tiers are NERVE (fast), RealPLKSR (balanced and perceptual) and HEART (fidelity). SeedVR2 and Nacre
stay offered by name: Nacre is a generative, provenance-clean route, not a tier.

### Upscale, drawn content (`content: drawn`; the G-4 drawn ladder, AB-R-0486)

**The set.** 75 licence-clean 768² images (`mlxengine-image/corpus/drawn-sr`, measurement only):
- line art and diagrams (19);
- text — slides, signs, infographics (16);
- UI windows (12);
- CG and anime-style art (28).

Each image was degraded by bicubic, Lanczos and two JPEG qualities at ×4 and ×2.

**Method.** References with strict loads, the AB-R-0379 harness. The MLX ports agree with them against the ground truth
to ±0.04 dB at ×4. Scores are SSIMULACRA2 (higher is better), mean over the four rungs:

| route | ×4 line / text / ui / cg | ×2 line / text / ui / cg |
|---|---|---|
| NERVE (the drawn route at draft and standard) | 25.1 / 7.8 / 4.2 / 31.2 | 59.0 / 49.0 / 44.6 / 57.8 |
| RealPLKSR | 20.9 / 3.1 / 4.2 / 31.1 | 61.7 / 50.2 / 38.4 / 65.0 |
| **HEART** (the drawn route at best) | **38.9 / 20.4 / 12.5 / 43.3** | **67.8 / 59.9 / 44.5 / 69.6** |

**Reading the results.**
- **HEART beats NERVE** on DISTS and SSIMULACRA2 together:
  - at ×4, on every class;
  - at ×2, on line, text and CG, with UI a tie.
  - It loses nowhere.
- **RealPLKSR ties NERVE at ×4** and loses on line and text, so NERVE keeps draft and standard.
- **Text is the price.** At ×4, HEART makes 110 words illegible that the input read correctly, against NERVE's 61 (of
  775). At ×2 it makes fewer, 100 against 134. Plain bicubic is the most legible of all at both scales, so for
  text-dense pages a guard (or no upscale) beats any model.

### Restore (DIV2K 0811–0816, 768²)

| Model | Denoise σ 25: PSNR / SSIM | Time | Deblur σ 2: PSNR / SSIM | Time |
|---|---|---|---|---|
| (degraded input) | 23.95 / 0.466 | | 26.77 / 0.756 | |
| **SCUNet** | **33.32 / 0.903** | 14.4 s | | |
| NAFNet | 32.64 / 0.891 | 0.29 s | 26.76 / 0.751 | 0.26 s |
| DRUNet | 27.67 / 0.644 | 0.41 s | | |
| Restormer (real denoise) | 27.05 / 0.819 | 3.0 s | | |
| **Restormer (defocus)** | | | 26.58 / **0.796** | 3.0 s |
| Restormer (motion) | | | 25.94 / 0.748 | 3.0 s |

- **Denoise.** SCUNet also leads on real camera noise (NIND, earlier receipt), so it is standard and best, with
  NAFNet as draft.
  - DRUNet needs a noise level the vocabulary doesn't carry, so it runs only when named.
  - Restormer-real is trained on real sensor noise, which synthetic Gaussian noise doesn't resemble.
- **Deblur.** Synthetic Gaussian blur is a weak test of networks trained on real defocus and motion. Their own
  benchmarks show +2.09 dB (defocus) and +1.29 dB (motion). Defocus improved SSIM here, so it comes first.

### Segment (GrabCut, 50 objects, one click at the object's deepest interior point)

| Model | IoU | Time |
|---|---|---|
| **SAM 2.1** | **0.772** | 155 ms |
| EdgeTAM | 0.651 | 160 ms |

The earlier click-select bench gave the same order (0.755 vs 0.537). EdgeTAM has no speed advantage per image in
the engine, so SAM 2.1 is the default. Segment's vocabulary has no `quality`, so EdgeTAM is reached by name.

### Edit, fill, erase and extend (two DIV2K photos at 1024²: a street market, a rugby scrum)

| Job | Klein 4B | Qwen-Image-Edit 2511 |
|---|---|---|
| Edit ("make it a snowy winter scene") | 15.4 s; snow on both photos | 314 s; snow on one, almost no change on the other |
| Fill with a prompt | 17.9 s | 317 s |
| Extend, both sides | 27.3 s; purple or dark border on 2 of 4 tries unguarded | 316 s; kept the magenta border on both |

- **LaMa erase:** 0.83 s at 1024².
- **MI-GAN extend (draft):** 2.0 s.
- The contact sheet stays out of this repo: its photos are DIV2K, licensed for academic research only. Its LaMa
  erase tiles predated the fp32 fix and showed the old pink.
- **Extend.** After the fix, LaMa continues both busy photos coherently but softly.
  - With a prompt, Klein painted both scenes seamlessly on 2 of 4 tries, left one side dark maroon once, and tinted
    one side purple once (sheet kept locally, DIV2K).
  - The paint guard now checks each side: purple-dominant over 25%, or under half as bright as the picture along its
    edge. It retries once with the next seed, then falls back to LaMa with `model_fallback`.
  - The maroon side measured 27 against an edge of 86, so it is now rejected. The slight tint (56) passes.
- **Edit is provisional.** Two photos aren't an edit benchmark. Qwen-Image-Edit stays offered by name, and should be
  re-measured with a proper edit set (instruction-following and identity preservation) before it can be a default.

### Erase (removal gate subset S, R2)

Measured 2026-10-11 on this Mac with a release build. The engine downloaded Mage-Flow Edit Turbo (int8) on first
use. Run: `tier-bench erase --gate <prepared>` (bench/r2-erase).

**Data.** The removal gate's subset S (AB-R-0463): 60 crops at 1024², the largest regions plus a seeded random fill.
Each crop has a real or rendered object-absent photo as ground truth.

**Masks.** Every arm erases each crop twice:
- with the object mask dilated 1.5% (`_objd`), the mask a client sends;
- on the 43 CORNE crops, also with the effect mask (object plus shadow and reflection), the mask a shadow-aware
  selection would send.

**How the composite works.** The engine composites through the mask (Image §1.7). So with the object mask, a
shadow outside it stays whatever the model does, and `ring` is the same for every arm.

**Metrics.**
- **Hole PSNR:** PSNR (dB) on luma inside the request's mask, against the ground truth.
- **Box:** PSNR and SSIM over the object's box grown 4.5%: the fill and its surroundings.
- **Ring:** mean absolute error (0–255) in the shadow band, which is the effect region minus the object.
- **Left:** inside the object's core, the output stayed closer to the object than half-way to the truth.
- **Fallback:** the share of jobs where Mage handed the object back twice and LaMa erased it instead.

| Mask | Arm | Hole PSNR | Box PSNR / SSIM | Ring | Left | Fallback | Warm time |
|---|---|---|---|---|---|---|---|
| object (60) | MI-GAN (draft) | 15.51 | 17.81 / 0.767 | 36.4 | 3.3% | — | 0.16 s |
| object (60) | LaMa (standard) | 16.13 | 18.31 / 0.782 | 36.4 | 5.0% | — | 0.42 s |
| object (60) | **Mage-Flow Edit Turbo, by name** | **19.66** | **20.42 / 0.791** | 36.4 | **1.7%** | 8.3% | 4.14 s |
| effect (43) | MI-GAN (draft) | 18.32 | 21.17 / 0.827 | 19.2 | 0% | — | 0.16 s |
| effect (43) | LaMa (standard) | 19.36 | 22.17 / **0.856** | 17.3 | 0% | — | 0.42 s |
| effect (43) | **Mage-Flow Edit Turbo, by name** | **20.82** | **23.52** / 0.848 | **13.8** | 2.3% | 4.7% | 4.17 s |

**Reading the results.**
- **Mage fills the hole far closer to the truth.** With object masks it is +3.5 dB over LaMa. The contact sheet
  (kept locally; CORNE is evaluation-only) shows why: it rebuilds what was behind the object, such as the flower pot
  behind a tricycle or the sofa behind a laptop, where LaMa smears.
- **With effect masks it also removes the most shadow:** ring 13.8 against 17.3.
- **Hand-backs and fallbacks.** Mage handed the object back twice on 5 of 60 crops. The engine then erased those with
  LaMa, which is where the gate's ashtray goes. That leaves 1 object of 60 in place, against LaMa's 3.
- **Cost.** About 10× LaMa's time, and the engine's footprint is 22 GB (25 GB peak) with Edit Turbo int8, Mage-VL
  and LaMa resident. LaMa's is about 0.2 GB.

**Tiers.**
- Mage-Flow Edit Turbo takes **best**; LaMa stays standard (the default) and MI-GAN draft.
- Mage as standard too is the operator's call: the quality case is there, but it makes the default erase 10× slower
  and about 20 GB heavier.
- The gate's own best configuration pasted Mage's result back through a box, which removed shadows outside the
  object mask. The Image profile forbids that (§1.7), so here shadows go only when the client's mask covers them:
  the shadow-aware mask expander (AB-T-0220 item 2) is how that gain reaches an object mask.
- Mage-Flow's content filter is off (AB-D-0122). It refused a benign photo in the gate.

### Single-model operations (1024²)

| Operation | Model | Warm time |
|---|---|---|
| matte | BiRefNet | 1.12 s |
| relight | HVI-CIDNet | 0.85 s |
| colorize | DDColor | 0.76 s |
| describe | Mage-VL | 1.91 s |
| score | SigLIP2 | 0.19 s |

## Forge Optimizer's tiers (Desktop OPT-8)

Desktop's Optimizer scaling runs on engines (D-20). Its tiers map onto MES quality like this:

| Optimizer tier | MES request | Model |
|---|---|---|
| Fast | `image.upscale`, `quality: draft` | NERVE |
| Best | `image.upscale`, `quality: standard` | RealPLKSR |
| Generative (stills, user's choice) | `image.upscale`, `model: nacre-upscale` | Nacre; VOSR2 when the engine carries it |
| Instant (the efficiency tier, AB-D-0146) | `image.upscale`, `model: anime4k-upscale` (any quality) | Anime4K VL: Metal shaders, no weights |
| Live action (video, user declares it) | Video profile (ENG R2) | FlashVSR |

- **Fast and Best** are today's Optimizer models, so this mapping keeps its output unchanged.
- **MES `best` (HEART)** is the extra fidelity step the Optimizer can offer next.
- **Generative and Live action** are routes chosen by content or provenance, never quality defaults, as in ForgeCore.
- **Instant** has no MES `quality` of its own: `quality` is one ladder for every operation, so a client names the
  model (AB-A-0183). It is offered at draft, standard and best and is never a default, being below the learned tiers on
  quality (AB-R-0559). Engine 0.2.10 (ForgeCore 0.41.1, mlx-image-runtime 0.6.0).

## What the measuring found besides tiers

- **Residency (ENG-3).** Models from earlier jobs piled up until a large load failed in Metal and killed the engine.
  The engine now keeps one heavy model at a time, evicts when a load won't fit, and releases idle models after 10
  minutes (3 at ≥ 20 GB). See `Residency.swift`.
- **Qwen-Image Flash** aborted the process intermittently (Metal "Invalid Resource" after 2–8 runs), and so did
  VOSR2 after Mage-Flow jobs. The cause was mlx's conv channel-pad helpers freeing their zero fill value before the
  GPU read it; with the 2 GiB cache cap the buffer went straight back to the OS. MLXExactConv's exact path padded one
  channel to reach one of those helpers. Fixed in mlx-exact-conv-swift 0.1.1, and Flash is offered again from 0.2.7
  (AB-T-0214). Seven convs that models call directly still reached the helpers; 0.2.8 takes their fixed packages
  (AB-R-0511):
  - the Qwen VL patch embeds behind Qwen-Image-Edit and Mage-Flow Edit (so erase at best and the creative upscale);
  - HEART's `conv_before_upsample` (upscale at best);
  - SeedVR2's VAE `conv_in`;
  - Nacre's input conv;
  - NAFNet's ending conv (restore's default).
- **LaMa's pink fills** came from the bf16 weight file. Fixed in mlx-lama-swift 0.3.1 (fp32), which ForgeCore 0.33.2
  requires (AB-R-0451).
- **Edit models don't reliably paint a marked region** on busy photos, hence the paint guard.

## Open

- **A real edit benchmark** for Klein vs Qwen-Image-Edit, before edit's best tier is final.
- **Release-build timings** for the fastest models, and memory per model in isolation.
  - The footprints in the raw summaries include whatever was resident at the time.
- **Video tiers** (ENG R2), including Optimizer's Live action route.

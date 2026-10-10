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
| `image.erase` | MI-GAN | **LaMa** | LaMa | as fill |
| `image.extend` (no prompt) | MI-GAN | **LaMa** | LaMa | LaMa continued busy photos coherently every time |
| `image.extend` (prompt) | Klein 4B | **Klein 4B** | Klein 4B | Guarded per side; unguarded, Klein failed 2 of 4 |
| `image.upscale` (photo) | NERVE | **RealPLKSR** | HEART | HEART best fidelity at ×2 and ×4; RealPLKSR best perceptual |
| `image.upscale` (drawn) | NERVE | **NERVE** | NERVE | NERVE beats RealPLKSR on graphics (Forge bench) |
| `image.restore` (denoise) | NAFNet | **SCUNet** | SCUNet | SCUNet +0.7 dB at σ 25; NAFNet ~50× faster |
| `image.restore` (deblur) | Restormer-defocus | **Restormer-defocus** | Restormer-defocus | Improves SSIM on blur; motion doesn't |
| `image.restore` (general / faces) | NAFNet / GFPGAN | **NAFNet / GFPGAN** | same | Not separately measured |
| `image.segment` | (EdgeTAM, by name) | **SAM 2.1** | SAM 2.1 | IoU 0.772 vs 0.651, same speed |
| `image.matte`, `relight`, `colorize`, `describe`, `score` | one model each | | | Timed only |

Not offered:
- **Qwen-Image Flash** is quarantined. It kills the engine process intermittently (AB-T-0214).
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
  - GrabCut (segment).
- **Raw summaries and contact sheets:** [`docs/tiers/`](tiers/).

## Evidence

### Generate (1024², 8 everyday prompts, then 6 hard ones)

| Model | Warm time | IQA, everyday | IQA, hard | Hard-prompt recall | Notes |
|---|---|---|---|---|---|
| Klein 4B (4 steps) | 8.8 s | 0.903 | 0.867 | 0.889 | Misspells ("OPEN DAIL Y", "HELLIO"); added a kiwi to "three oranges and a lemon" |
| **Z-Image Turbo** (8 steps) | 13.7 s | 0.915 | **0.903** | **0.944** | Spelled all three texts right; miscounted apples (six for five) |
| Z-Image (28 steps) | 70.4 s | 0.895 | 0.880 | 0.778 | Junk text on the sign, garbled poster layout; stylized look |
| Klein 4B Base (28 steps) | 80.0 s | 0.914 | 0.902 | 0.944 | "OPENDALY"; dark, moody renders |
| Qwen-Image Flash | 15.9 s | 0.935 (n = 2) | — | — | Quarantined (AB-T-0214) |

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

Earlier evidence (the Commons twelve-rung ladder, AB-R-0379) agrees on ranking:
- HEART had the best PSNR on 12 of 12 rungs.
- RealPLKSR had the best DISTS on 12 of 12 rungs. DISTS is partly its own training loss, which flatters it.
- SeedVR2 was the worst learned model on JPEG photos.

That's why the tiers are NERVE (fast), RealPLKSR (balanced and perceptual) and HEART (fidelity). SeedVR2 and Nacre
stay offered by name: Nacre is a generative, provenance-clean route, not a tier.

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
- [Sheet](tiers/edits-sheet.jpg). Its LaMa erase tiles predate the fp32 fix and show the old pink.
- **Extend.** After the fix, LaMa continues both busy photos coherently but softly.
  - With a prompt, Klein painted both scenes seamlessly on 2 of 4 tries, left one side dark maroon once, and tinted
    one side purple once ([sheet](tiers/extend-guard-sheet.jpg)).
  - The paint guard now checks each side: purple-dominant over 25%, or under half as bright as the picture along its
    edge. It retries once with the next seed, then falls back to LaMa with `model_fallback`.
  - The maroon side measured 27 against an edge of 86, so it is now rejected. The slight tint (56) passes.
- **Edit is provisional.** Two photos aren't an edit benchmark. Qwen-Image-Edit stays offered by name, and should be
  re-measured with a proper edit set (instruction-following and identity preservation) before it can be a default.

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
| Live action (video, user declares it) | Video profile (ENG R2) | FlashVSR |

- **Fast and Best** are today's Optimizer models, so this mapping keeps its output unchanged.
- **MES `best` (HEART)** is the extra fidelity step the Optimizer can offer next.
- **Generative and Live action** are routes chosen by content or provenance, never quality defaults, as in ForgeCore.

## What the measuring found besides tiers

- **Residency (ENG-3).** Models from earlier jobs piled up until a large load failed in Metal and killed the engine.
  The engine now keeps one heavy model at a time, evicts when a load won't fit, and releases idle models after 10
  minutes (3 at ≥ 20 GB). See `Residency.swift`.
- **Qwen-Image Flash** aborts the process intermittently (Metal "Invalid Resource" after 2–8 runs). It is quarantined
  until fixed (AB-T-0214).
- **LaMa's pink fills** came from the bf16 weight file. Fixed in mlx-lama-swift 0.3.1 (fp32), which ForgeCore 0.33.2
  requires (AB-R-0451).
- **Edit models don't reliably paint a marked region** on busy photos, hence the paint guard.

## Open

- **A real edit benchmark** for Klein vs Qwen-Image-Edit, before edit's best tier is final.
- **Release-build timings** for the fastest models, and memory per model in isolation.
  - The footprints in the raw summaries include whatever was resident at the time.
- **Video tiers** (ENG R2), including Optimizer's Live action route.

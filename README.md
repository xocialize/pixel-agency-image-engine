# Pixel Agency Image Engine

The reference engine for the [Media Engine Specification](../media-engine-spec/spec/base.md) (MES) **Image
profile**: Base 0.1 and Image 0.1, over local MLX models on Apple silicon. Pixel Agency Lite, Pixel Agency Desktop,
the `mes` CLI, or any other MES client can find it on the network and run every Image operation on it.

It's built from three parts:
- **MESEngineKit** (media-engine-spec) serves Base 0.1: routes, jobs, the spool, pairing, DNS-SD, SSE, WebSocket
  and MCP.
- **The model runtime** is ML[X] Image Server's engine half (`ImageServerModels`): the model catalog, routing and the
  runner over MLXEngine and ForgeCore, with one heavy model resident at a time under MLXServe's memory governor.
- **This package** adds the normalizer between them (Engines-PRD ENG-5): MES operations and vocabulary in, model
  runs out, and the Image profile's rules applied to whatever a model returns.

## Run it

```bash
swift run pixel-agency-image-engine
```

That serves open mode on `http://127.0.0.1:17610/mes/v0`, to this Mac only, and advertises `_mes-engine._tcp` on
the loopback interface. Models download into the shared models folder on first use.

| Option | What it does |
|---|---|
| `--paired` | TLS, pairing and bearer tokens, for clients on other machines. Binds `0.0.0.0`. |
| `--approve prompt\|auto` | Paired mode: confirm each pairing code here (default), or pre-approve every request. |
| `--allow-research` | Offer research-licensed and work-in-progress models, **named-only** (see below). |
| `--store <dir>` | The models folder. Default `~/Library/Application Support/MLXEngine/Models`, shared with ML[X] apps (ENG-13). |
| `--port`, `--host`, `--spool`, `--state`, `--ttl`, `--no-advertise` | As named. The engine id persists in `--state`. |

`MLXIMG_WEIGHTS_ROOT` points the runtime at local weight snapshots instead of downloading.

## What it offers

| Operation | Draft | Standard | Best |
|---|---|---|---|
| `image.generate` | FLUX.2 Klein 4B | **Z-Image Turbo** | Z-Image |
| `image.edit` | **Klein 4B** | **Klein 4B** | Qwen-Image-Edit 2511 |
| `image.fill` | MI-GAN | **MI-GAN** | LaMa |
| ↳ with a prompt | Klein 4B | Klein 4B | Qwen-Image-Edit 2511 |
| `image.erase` | MI-GAN | **MI-GAN** | LaMa |
| `image.extend` | MI-GAN | **Klein 4B** | Qwen-Image-Edit 2511 |
| `image.upscale` | NERVE | **RealPLKSR** | HEART, SeedVR2, NACRE |
| `image.restore` | by `kind`: NAFNet (general), SCUNet / Restormer / DRUNet (denoise), Restormer (deblur), GFPGAN / RestoreFormer++ (faces); `scratches` runs defect detection, then LaMa on just the defects |||
| `image.relight` | HVI-CIDNet |||
| `image.colorize` | DDColor |||
| `image.matte` | BiRefNet |||
| `image.segment` | EdgeTAM | **EdgeTAM** | SAM 2.1 |
| `image.describe` | Mage-VL |||
| `image.score` | SigLIP2 quality |||

Bold is the default when a request names no model. MI-GAN and LaMa are one package (`lama-inpaint`), so the
offer is LaMa's; `effective.model_params.variant` says which ran. LaMa's MLX port casts large fills pink on colour
images, so it runs only at best until that's fixed. It still bridges thin bands (extend's seam, scratch defects). Every offer carries its licence in MES terms (Base §10.2).
`commercial_use` is `true` only when every weight licence and the port's code licence are permissive.

### Research models (opt-in)

With `--allow-research`, research-licensed and work-in-progress models are offered too. That covers Qwen-Image 2.1
Turbo (8 steps) and Qwen-Image 2.1 (40 steps), Mage-Flow, SenseNova U1, Ming, Boogu and the like. The flag is the
operator accepting their terms (Base §10.2 `accepted_required`).

They are offered **`named_only`** (Base §6 rule 2): they run only when a request names them, and default choice
never picks one. Their offers say `commercial_use: false`, with the terms URL and the licence's notice, so a client
can show it. A request with `policy.license: commercial-use` is refused `policy_unmet` if it names one.

```bash
mes run image.generate -i prompt="a lighthouse at dusk" --model qwen-image-2.1
```

## The rules it applies

The normalizer (`ImageNormalizer`, `RunPlan`) holds every model to the profile, whatever the model does:
- **Sizes.**
  - A requested size, or `aspect` plus `megapixels`, snaps to the model's envelope, with the warning `size_snapped`.
  - Edits come back at the first image's size.
  - Upscales are exactly ×`scale`.
- **Masks (§1.6, §1.7).**
  - A model is shown the mask's whole non-black area as its hole. The result is then composited with the request's
    mask itself, so black pixels stay byte-identical and grey ones blend.
  - A soft matte from `image.matte` therefore feeds straight into `erase` or `fill`.
- **Generative fill and extend.** An edit model is shown where to paint in flat magenta: the masked area, or the new
  border. It is told to "replace the bright magenta area with …", naming the edges for extend; told only "around
  it", edit models often leave a side blank. Then the original's pixels are composited back, and two steps hide the
  seam without touching them:
  - **Tone.** The difference between the original and the model's re-rendering of it is measured around the seam,
    spread smoothly into the new area, and added there (`Media.harmonize`).
  - **Structure (extend).** LaMa repaints a thin band on the new side of the seam from both sides' context
    (`Media.seamBand`), so an edge the model drew a little out of step joins up.
  - **Known limit:** at full size the new area can be softer than the original (Klein's 4 steps). The best tier,
    Qwen-Image-Edit, is more faithful.
- **Colour and orientation (§1.3, §1.4).** Inputs are read upright and in sRGB, with `color_converted` when converted.
  Outputs are written sRGB and upright.
- **Alpha (§1.5).** The input's alpha is re-applied when a model drops it (`alpha_reapplied`).
- **Prompts and seeds.**
  - `negative_prompt` reaches only models that use guidance; otherwise it warns `negative_prompt_ignored`.
  - A prompt a model can't use warns `prompt_ignored`.
  - Seeds are reported and stay within 2⁵³ − 1.
- **Results.** `effective.model_params` records the model, steps and guidance actually used.

## Conformance

The engine passes the MES conformance suite. Against the live engine with real models (2026-10-09):
- **Results:** 34 passed, 0 failed, 4 skipped. **Base 0.1 conforms, Image 0.1 conforms.** The report is in
  [`docs/conformance/2026-10-09-live.md`](docs/conformance/2026-10-09-live.md).
- **Skipped:** the paired-mode tests and output expiry, which don't apply to an open-mode engine with a one-hour TTL.
  `swift test` also runs paired mode against fakes.

```bash
swift test
mes-conformance engine http://127.0.0.1:17610/mes/v0
```

`swift test` runs the suite against the normalizer over a fake catalog and runner (no MLX). The fake answers like
real packages do, with sizes a little off, alpha dropped and mattes at their own resolution, so the tests prove the
normalizer's rules rather than the models'.

## Layout

| File | What it holds |
|---|---|
| `Sources/PixelAgencyImageEngine/ImageNormalizer.swift` | The `MediaEngine`: descriptors from the live catalog, licences, validation, default refinement, errors |
| `Sources/PixelAgencyImageEngine/OperationTable.swift` | Each operation's capability, tier defaults and vocabulary |
| `Sources/PixelAgencyImageEngine/RunPlan.swift` | Each operation as model runs, and the profile's rules on the results |
| `Sources/PixelAgencyImageEngine/Media.swift` | Pixels and masks: loading, compositing, padding, marking, encoding |
| `Sources/PixelAgencyImageEngine/Runtime.swift` | Bootstraps the model runtime and the shared models folder |
| `Sources/ImageEngineCLI` | `pixel-agency-image-engine`, the headless engine |

## Not yet

- **The menu-bar app and the sandbox** (ENG-9, ENG-11). This is the headless engine.
- **Keep-warm and idle eviction** (ENG-3) are left to MLXServe's governor.
- **Channel clearance** (ENG-14).
- **Measured quality tiers** (R1b). The tier table is the PRD's sketch.

## Licence

Apache-2.0. Each model has its own licence, stated on its offer.

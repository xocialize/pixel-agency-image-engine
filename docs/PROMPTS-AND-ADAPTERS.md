# Prompt enhancement and adapters: a proposal

Status: decided 2026-10-19 (AB-D-0155): all six decisions in §4 as recommended. Work starts with E1, prompt-enhance-kit
v0.5. Sources are cited as `path:line`.

Progress:
- **E1** is prompt-enhance-kit-swift 0.5.0, which passed its gate on Qwen3.5-4B int4 (AB-R-0588), and 0.5.1 (the public
  `decision`, v2 `flux2-klein` and `z-image`; AB-A-0195, AB-R-0589).
- **E2** shipped in the engine's 0.4.0 (2026-10-19), on prompt-enhance-kit-swift 0.5.1 and mlx-qwen-llm-swift 0.6.2.
  See the README's "Prompt enhancement" and `Sources/PixelAgencyImageEngine/PromptEnhance.swift`.
  - FLUX 3 Klein's upsampler is switched per request since the engine's 0.4.1 (AB-T-0336), through the package's
    `upsample` key (mlx-image-runtime 0.14.0, AB-A-0191).
  - Still open: the console line is a tag on each card for now.
- **L1 to L3** are mlx-engine-swift 0.68.0 (contract 1.53.0; 1.55.0 adds conditioning groups), the L2 packages
  (flux2-klein-swift 0.10.1, qwen-image-edit-swift 0.11.0, mage-flow-swift 0.12.0, AB-A-0192), and mlx-image-runtime
  0.15.0's adapter catalog (AB-A-0191).
- **L4** shipped in the engine's 0.5.0 (2026-10-19): `x-pixelagency.adapters` on generate and edit. See the README's
  "Adapters" and `Sources/PixelAgencyImageEngine/Adapters.swift`. Where it settles what §2.2 left open:
  - **Error codes** follow MES 0.4's draft §6.3. A licence refusal is `policy_unmet` (Base §10.3), not
    `unsupported_parameter`. An id not on offer fails the schema's enum, so it's `out_of_limits` until MES 0.4 makes
    adapters first-class.
  - **Opt-in adapters:** gated ones, ones whose terms forbid commercial use or don't say, and `candidate`s (all 27 Qwen
    Flash adapters). Each adapter has an `adapter:<id>` card of its own in the console, since MESEngineUI has no
    nested cards.
  - **Provenance** is `effective.model_params.adapters` until MES 0.4's `provenance.adapters`.

## Summary

**Prompt enhancement.** One unified, profile-driven enhancer covers the image models we serve.
- **Dedicated (already done):** FLUX 3 Klein is the only model whose vendor *requires* its own enhancer: BFL's upsampler,
  a Qwen3.5-9B VL fine-tune (Apache-2.0). It already runs inside `flux3-klein-swift`. Keep it there; the engine only
  needs a way to switch it per request.
- **Optional dedicated:** Qwen-Image 2.1 has optional dedicated rewriters (Qwen-Image-2.1-PE, 9B, research licence).
  Their published system prompt also runs on a general LLM, so the unified enhancer covers it.
- **Unified, with per-model profiles:** everything else. But today's prompt-enhance-kit can't do it yet. It needs
  per-model profiles, structured (JSON) output, language rules, a pass-through rule, size feedback, and, for edit
  models, image input.

**Adapters (LoRA).**
- **Today:** the stack has no adapter contract. Five packages select adapters five different ways, and the image runtime
  drops all of them, so no client can reach any adapter.
- **Proposal:**
  - a typed adapter field in the engine contract;
  - one adapter registry format shared by image and video;
  - an adapter catalog in the runtime;
  - an MES extension, `x-pixelagency.adapters`, where an adapter id implies its base model, with adapter licences in
    policy checks and provenance.
- **Adapters that need reference images** (the reference-conditioned "IC" kind, e.g. pose or try-on) map their ordered
  slots onto the operation's existing image inputs.

## 1. Prompt enhancement

### 1.1 What each model asks for

| Model | Enhancer | What it produces | In our stack |
|---|---|---|---|
| **FLUX 3 Klein** | **Required** (BFL: don't use it without) | Dedicated: `flux-3-image-klein-pup`, Qwen3.5-9B VL, one system prompt per mode (t2i, i2i, t2i_bbox, i2i_bbox) | **Yes**, in its package, int8, about 10 s and 11 GB; global switch `MLXIMG_FLUX3_UPSAMPLER` |
| Qwen-Image 2.1 / Turbo | Recommended | Dedicated PE-T2I and PE-I2I (9B, research licence), returning JSON `{rewritten_prompt, wh_ratio}` | No |
| Qwen-Image Flash | Recommended | Vendor system prompt (EN and ZH) for a general LLM: under 200 words, plus a "magic" suffix | No |
| Qwen-Image-Edit 2511 | Recommended (on by default in the vendor demo) | Vendor prompt for a **vision** LLM, returning JSON `{Rewritten}` | No |
| Z-Image / Turbo | Optional | Vendor system prompt (ZH) for a general LLM; quote rendered text, no "8K / masterpiece" tags | No |
| FLUX.2 Klein 4B / Base | Recommended (prompt style matters) | No vendor enhancer; our planned klein profile (AB-T-0054 E1) | No |
| SenseNova U1.5 | Strongly recommended | Vendor prompt producing **Render JSON** (subjects, scene, lighting, composition, style, camera, visible copy, canvas), 1.1k to 1.5k tokens; a vision rewriter for edits | No |
| MOSS-Image | Recommended for layouts | **Layout JSON** (caption plus items with centred pixel boxes) and a coordinate converter script | No |
| Ming-Image | Recommended for layouts | **Layer JSON** (normalised cx, cy, w, h, and hex colours) | No |
| Mage-Flow (and Edit) | None found | No enhancer found | No |
| Boogu | Optional | Vendor rewriter on a general vision LLM | No |

Two rules apply to all of these:
- **Engine-written prompts never pass through an enhancer.** That covers the magenta-marker fill and extend
  instructions, erase-by-name, and the creative upscale (`RunPlan.swift:291,343-353,380`, `Creative.swift:77-82`). A
  rewriter would break them; Qwen's edit rewriter would substitute its own inpaint and outpaint templates.
- **Edit models need a rewriter that sees the input image:** Qwen-Image-Edit, SenseNova edit, Mage-Flow-Edit and Boogu
  edit.

### 1.2 Unified or dedicated

- **Dedicated: FLUX 3 Klein only.**
  - The model was trained on its upsampler's captions, and BFL ships box planning with it.
  - It already runs in the package. The engine needs per-request control, and the runtime blocks that today: it builds
    requests without `metaData` (`mlx-image-runtime/.../RequestMapping.swift:60-82`), so FLUX 3's `upsample` and `boxes`
    keys are unreachable.
- **Unified for everything else.** Each model gets a profile. Qwen-Image 2.1's PE models can stay optional: a backbone
  a profile may name, for "best".

### 1.3 What prompt-enhance-kit needs (v0.5)

The kit today (v0.4.0, about 300 lines):
- A template is one system string per (capability, task).
- There are three neutral seed templates and an LTX-2.3 profile, plus a seed pass-through.
- It falls back to the raw prompt on any failure.

Proposed: an `EnhanceProfile` as data, keyed by model id and task:

| Field | Why | Models |
|---|---|---|
| `system` per task (t2i, edit, r2i, layout) | the instruction | all |
| `output`: `.text`, or `.json(schema, field)` with a post-processor | structured formats; reading one field | SenseNova, MOSS, Ming, Qwen 2.1, Qwen edit |
| `language`: keep the user's, force English, or pick an EN or ZH prompt | vendors differ | Qwen Flash (EN/ZH), Qwen 2.1 (English out), Z-Image |
| `suffix` | vendor magic words | Qwen Flash |
| `passThrough`: already structured, longer than N words, or names a box table | don't rewrite a finished prompt | all |
| `vision`: input images to the backbone | edit rewriters | Qwen edit, SenseNova edit, Mage edit |
| `sizeFeedback`: map a JSON field to the request's size | `wh_ratio`, Render JSON `canvas` | Qwen 2.1, SenseNova |
| `tokenBudget` | the text encoder's limit | Z-Image 512, Klein 512, Qwen 512/1024, FLUX 3, Mage, MOSS 4096 |
| `backbone`: a minimum class (`small`, `large`, `vision`) or a package id | a 0.8B model won't write Render JSON | per profile |
| `negative`: propose one, CFG tiers only | E2, deferred until there's a way to test it (AB-T-0054) | Z-Image base, Klein base |
| `source`: the vendor prompt's origin and licence | we bundle vendor text only where its licence allows | per profile |

Fixes the kit also needs:
- **Cancellation:** it currently returns the raw prompt on `CancellationError` (`PromptEnhancer.swift:59-61,83-85`). It
  should rethrow.
- **Timeout:** add one.
- **Vendor packages:** a native transport, with an optional system prompt and size passed in `metaData` (ernie-pe
  showed the gap).
- **Profile packs:** register a whole pack at once (`register(_ library:)`).

### 1.4 Backbones

| Class | Proposed | Footprint | Serves |
|---|---|---|---|
| small text | Qwen3.5 4B (0.8B on 16 GB Macs) via `MLXQwenLLM` | about 1 to 3 GB | Z-Image, Klein, Qwen Flash, Mage, Boogu t2i |
| large and structured | Qwen3.5 9B or Gemma-3 12B (9.3 GB measured) | about 6 to 10 GB | SenseNova Render JSON, MOSS, Ming |
| vision | a Qwen3.5-9B VL loader: FLUX 3's upsampler already loads one; Mage-VL (5.4 GB, Apache-2.0) is the fallback | about 6 to 11 GB | edit rewriters |

All three need measuring on real profiles before we commit; nobody has run structured profiles on small models yet.

Vision needs one of two things:
- an image field on the engine contract's `ChatMessage`, which is a plain `String` today (`MLXToolKit/LLM.swift:12-20`;
  owned by mlx-engine);
- or the kit's `generate:` transport over a VL session.

Memory: the enhancer runs before the image model loads. So under one-heavy-model residency it loads, runs, and is
released, unless it's small enough to keep warm.

### 1.5 In the engine and through MES

- **Where it runs:** a step in `RunPlan` before `image.generate` and `image.edit` call the model
  (`RunPlan.swift:224,251`). It never touches engine-written instructions.
- **How clients control it:** an engine extension on generate and edit, `x-pixelagency.prompt_enhance`:
  `{mode: auto|on|off, seed?}`. A request without it gets `auto`:
  - required (FLUX 3): always on. `off` is honoured, with a warning that results will suffer.
  - recommended: on when the prompt is short and not already structured.
  - none or optional: off unless the request asks for `on`.
- **Honest results (G4):**
  - `effective.model_params.prompt_enhancement` reports `{applied, profile, backbone, seed, prompt}`, the rewritten
    prompt included, and a warning tells the client its prompt was rewritten.
  - The enhancement seed derives from the job's seed, so a job with a fixed seed reproduces end to end. The kit can
    already pin a seed (v0.4.0).
- **Agents over MCP:** the tool description says that an agent which already writes full captions can pass `off`.
- **Console:** each model card shows "Prompting: required, recommended, or none", with the profile and backbone. The
  backbones are models in the enabled set.
- **Preview before running:** Lite and Desktop will want to show and edit the rewritten prompt before generating, as LTX
  Studio's Enhance button does. That needs an operation, e.g. `image.enhance_prompt` (prompt plus target model, returning
  data `{prompt, size}`). This is a spec question for the media-engine-spec owners.

### 1.6 Phases

1. **E1.** Kit v0.5: `EnhanceProfile`, JSON output, language, pass-through, cancellation, profile packs. Then text
   profiles for Z-Image, Klein, Qwen Flash and Mage.
2. **E2.** Engine: the `prompt_enhance` extension, provenance, residency, and the console line. Also the runtime's
   `metaData` pass-through, so FLUX 3's `upsample` and `boxes` work per request.
3. **E3.** Structured profiles (SenseNova Render JSON, MOSS layout with its coordinate converter, Ming layers, Qwen 2.1
   with `wh_ratio`), each measured on the large backbone.
4. **E4.** Vision: edit profiles once the contract or transport carries images.
5. **E5.** The preview operation, if the spec takes it.

Retire `ernie-pe-swift` once E1 lands (AB-T-0054).

## 2. Adapters (LoRA)

### 2.1 Today

- **Contract:** none. LoRA rides free-form `metaData` (`MLXToolKit/TextToImage.swift:5-6`). Manifests can't declare
  adapter support, and there's no engine-side fetch, cache or memory accounting.
- **Five dialects:**
  - Qwen-Image Flash: `metaData["loras"]`, a list of `{repo, file, strength}`.
  - Qwen-Image-Edit Turbo and LTX: `loraId` and `loraStrength` against bundled registries.
  - LTX IC adapters: `ic.*` keys with file paths.
  - Klein and Mage-Flow: a single `loraPath` set when the model loads, so each adapter would need its own registered
    package.
  - SenseNova: adapters merged into separate model ids.
- **Inconsistent behaviour:**
  - unknown keys are skipped by some packages and throw in others;
  - there are no strength limits;
  - packages allow one adapter, or any number.
- **Fetch:**
  - direct `resolve/main` URLs, with no pinned revision and no hash check;
  - no token for Klein or Qwen;
  - per-package caches keyed by id;
  - all of it outside the engine's store, operator consent (ENG-12) and the sandboxed app's chosen models folder.
- **Runtime:** `RequestMapping.swift:60-82` drops everything, so the image engine has no adapter path at all.
- **What there is to build on:**
  - Klein's registry (uncommitted): `kind` (plain or IC), slots, licence, trigger, verification. It has 8 adapters,
    mirrored to `xocialize/*-FLUX.2-klein-4B-lora`, including try-on and pose.
  - LTX's registry v2 (`ltx-lora-registry`), with `clearedFamilies`.

### 2.2 Design

1. **Contract (mlx-engine).**
   - A typed `adapters: [AdapterRef]` on the image and video requests. Each entry: `{id, strength}`, resolved by the
     engine to a pinned source `{repo, revision, file, sha256}`.
   - `AdapterSupport` in the manifest: formats, maximum count, strength range, quantisation limits, conditioning slots.
   - Adapter weights materialised through the engine's own store: pinned revision, hash checked, token from the
     Keychain, in the models folder, with consent.
   - Adapter bytes, and the extra activation of IC adapters (LTX's roughly doubles the sequence), counted in admission.
2. **One registry format** for image and video, merging Klein's registry and LTX's v2. Each entry carries:
   - id, title;
   - base models (family and version);
   - kind (plain or IC) and ordered slots;
   - trigger and prompt template;
   - licence (SPDX, commercial use, notice, gated or not);
   - pinned source;
   - default strength and range;
   - verification.
3. **Packages** move to runtime adapters: Klein's and Mage's adapters are chosen per request, not at load. All packages
   throw on unknown keys and clamp strength. Qwen keeps its swapper. SenseNova's merged tiers stay as model offers.
4. **Runtime.** An adapter catalog next to the model catalog. `RequestMapping` passes `adapters` through, checked
   against the routed model's base family.
5. **Engine and MES.**
   - **The extension:** on each operation whose offered models accept adapters, `x-pixelagency.adapters`: an array of
     `{id: enum, strength: number (min, max)}`, up to N items. Its schema carries each adapter's metadata (base models,
     kind, slots, trigger, licence) for clients.
   - **The adapter id implies the model.** With no model named, the engine picks the adapter's base model; Base §6
     rule 2 lets the choice depend on params. A named model the adapter doesn't fit is a 422 `unsupported_parameter`.
   - **IC slots** map in order onto `references` (generate) or `images` (edit).
   - **Licences:** a `policy.license: commercial-use` request is refused when an adapter's licence disallows commercial
     use (an engine-side check). Results carry `effective.model_params.adapters [{id, strength, revision, license}]`.
     First-class `provenance.adapters` is a spec ask.
   - **Enabled set:** adapters appear under their base model's card in the console. Gated or research adapters are
     switched on with their terms accepted (`ModelEnablement` keys `adapter:<id>`), and only adapters that are on
     appear in the enum.
6. **Your own adapters (later).** The operator installs a `.safetensors` file in the console, says what licence it's
   under, and the console checks its keys against the base model. Not client uploads over MES: uploads are single-use,
   and licences and safety can't be checked.
7. **Video and audio.** The same contract, registry and extension. LTX's registry migrates, and the console's adapter
   cards are generic (MESEngineUI).

### 2.3 Phases

1. **L1.** Contract: `AdapterRef`, `AdapterSupport`, engine-managed fetch, memory (mlx-engine).
2. **L2.** The shared registry format. Klein: commit its registry and move to runtime adapters. Qwen Flash and Edit:
   adopt the typed field. Mage: runtime adapters.
3. **L3.** Runtime: the adapter catalog and `RequestMapping` pass-through.
4. **L4.** Engine: `x-pixelagency.adapters`, model choice, licence policy, provenance, console adapter cards.
5. **L5.** Spec: first-class adapters in descriptors and provenance (MES 0.4).

A faster interim is possible: the runtime translates the adapter catalog into each package's current `metaData` dialect
(Klein and Qwen Flash first) before L1. It ships adapters sooner but bakes in the dialects we mean to remove.

## 3. Who owns what

| Piece | Area |
|---|---|
| prompt-enhance-kit v0.5, profiles | `mlx-think` |
| Image input on `ChatMessage`, `AdapterRef` / `AdapterSupport`, adapter fetch and memory | `mlx-engine` |
| Klein / Qwen / Mage / SenseNova packages, adapter registry | `mlx-image` |
| LTX registry migration | `mlx-ltx` |
| Runtime `metaData` and adapter pass-through, adapter catalog | mlx-image-runtime (`mlx-image`) |
| Preview operation, `provenance.adapters`, warning codes | `mlx-apps` (media-engine-spec) |
| Extensions, policy, provenance, console | this engine |

## 4. Decisions (decided 2026-10-19: all as recommended, AB-D-0155)

1. **Default enhancement:** `auto` (rewrite short prompts for models that recommend it, with provenance and an opt-out),
   or off unless a request asks? *I recommend `auto`:* the vendors' own demos rewrite by default, and provenance keeps
   it honest.
2. **Backbones and memory:** one 4B text model plus a 9B for structured and vision profiles, or a single 9B VL model for
   everything? *I recommend 4B plus 9B VL, decided by measurement.* Most profiles are short text rewrites, and a 9B on
   every request costs seconds and 6 GB or more.
3. **Vendor prompt text:** use it verbatim where its licence allows, or write our own throughout? *I recommend verbatim
   where licensed, with the source and licence recorded in the profile.* The vendor prompts encode what the models
   were trained on.
4. **Adapter scope:** curated registry only, plus operator-installed adapters, or client uploads too? *I recommend
   curated now and operator-installed later; no client uploads.*
5. **Adapter route:** contract first (L1 to L4), or the interim `metaData` translation to ship Klein and Qwen adapters
   sooner? *I recommend contract first.* The interim would bake in the five dialects and their unpinned downloads.
6. **Preview:** ask the spec owners for an enhance-prompt operation? *I recommend yes:* Lite and Desktop need it for
   an Enhance button.

## 5. Found along the way

- **Qwen Image Demo:** edit enhancement silently sends the raw prompt, because there's no `(.imageEdit, .imageEdit)`
  template (`Demos/Qwen Image Demo/.../QwenImageDemoEngine.swift:383`; its comment at `:172` is wrong).
- **prompt-enhance-kit:** swallows cancellation (above).
- **Qwen-Image Flash:** the fallback adapter id `repo/file` builds a nested cache path whose parent directory is never
  created (`LoRAStack.swift:48` with `LoRARegistry.swift:77-88`). It's untested, but likely fails.
- **MLXEngine `docs/model-registry.md:90`:** stale. qwen-image-edit-swift `7d52293` removed the bf16 + adapters refusal.
- **Klein:** `LoRARegistry.swift` and `Resources/` are uncommitted.
- **TeleStyle and Qwen-Image-Edit Turbo:** default adapter paths hard-coded to `/Users/dustinnielson/...`.
- **`mlxengine-image/PROMPT-ENHANCER-INTEGRATION.md`:**
  - It calls `register(TemplateLibrary.klein())` and `enhanceStructured`, which don't exist.
  - Its "Gemma 15 GB" disagrees with the measured 9.3 GB (7.19 GB in LTX Studio).

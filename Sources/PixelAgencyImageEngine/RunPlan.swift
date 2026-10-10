import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
import MLXToolKit

/// One job's plan: the operation's mapping onto model runs, and the profile's rules applied to what comes back.
struct RunPlan {
    let context: RunContext
    let spec: OperationSpec
    let normalizer: ImageNormalizer
    var warnings: [Warning] = []
    var effective: [String: MESValue] = [:]
    var modelParams: [String: MESValue] = [:]
    /// The seed a generative step used, reported as the job's (Image §2).
    var seedUsed: UInt64?
    /// Models this job admitted to memory (ENG-3), released when it ends.
    var admitted: [RoutedModel] = []

    init(context: RunContext, spec: OperationSpec, normalizer: ImageNormalizer) {
        self.context = context; self.spec = spec; self.normalizer = normalizer
    }

    var runner: any ModelRunner { normalizer.runner }

    mutating func run() async throws -> MESEngineCore.RunOutput {
        let outputs: [ProducedOutput]
        switch spec.operation {
        case "image.generate": outputs = try await generate()
        case "image.edit": outputs = try await edit()
        case "image.fill", "image.erase": outputs = try await inpaint()
        case "image.extend": outputs = try await extend()
        case "image.upscale": outputs = try await upscale()
        case "image.restore": outputs = try await restore()
        case "image.relight", "image.colorize": outputs = try await sameSize()
        case "image.matte": outputs = try await matte()
        case "image.segment": outputs = try await segment()
        case "image.describe": outputs = try await describe()
        case "image.score": outputs = try await score()
        default: throw MESError(.unknownOperation, "No plan for \(spec.operation).")
        }
        if !modelParams.isEmpty { effective["model_params"] = .object(modelParams) }
        return MESEngineCore.RunOutput(outputs: outputs, effective: effective, seed: seedUsed.map { Int($0) }, warnings: warnings)
    }

    // MARK: - Shared steps

    mutating func warn(_ code: String, _ message: String, param: String? = nil) {
        warnings.append(Warning(code: code, message: message, param: param))
    }

    /// The model the engine kit chose, as the runtime's route, prepared (downloaded, loaded) before it runs. A helper
    /// step (`helper: true`, e.g. restore's defect detector) takes the runtime's default: permissive and production.
    mutating func route(_ capability: Capability, helper: Bool = false) async throws -> RoutedModel {
        let route = try await normalizer.directory.route(capability, model: helper ? nil : ModelID(context.model.id))
        await normalizer.residency.admit(route)                  // room first: one heavy model, and what fits
        admitted.append(route)
        let relay = ProgressRelay(context.reporter)
        do {
            try await runner.prepare(route) { p in relay.send(.preparing, fraction: p.fraction, message: p.phase) }
            await relay.finish()
        } catch {
            await relay.finish()
            throw error
        }
        return route
    }

    func releaseModels() async {
        for route in admitted { await normalizer.residency.release(route) }
    }

    /// Runs one model invocation, reporting its progress as output `index` of `count`.
    func invoke(_ route: RoutedModel, params: ISValueObject, mode: String? = nil, inputs: [String: [MLXToolKit.Image]] = [:],
                seed: UInt64 = 0, width: Int? = nil, height: Int? = nil, index: Int = 0, count: Int = 1) async throws -> RunOutputValue {
        let spec = JobSpec(capability: route.capability, model: route.id, mode: mode, params: params, count: 1)
        let work = RunWork(route: route, spec: spec, seed: seed, width: width, height: height, inputs: inputs, outputIndex: index)
        let relay = ProgressRelay(context.reporter)
        do {
            let output = try await runner.run(work) { p in
                // The runtime reports `downloading`/`loading` when the governor had to reload mid-job.
                let stage: Stage = ["downloading", "loading", "waiting_for_memory"].contains(p.phase) ? .preparing : .running
                relay.send(stage, step: p.step, steps: p.totalSteps,
                           fraction: p.fraction.map { (Double(index) + $0) / Double(count) }, message: p.phase)
            }
            await relay.finish()
            return output
        } catch {
            await relay.finish()
            throw error
        }
    }

    /// Loads an image input (upright, sRGB), warning when its colours were converted.
    mutating func load(_ name: String) throws -> Pixels {
        guard let url = context.input(name)?.fileURL else { throw NormalizerError.input("Input '\(name)' is missing.") }
        let loaded = try Media.load(url)
        if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "'\(name)' was converted to sRGB.", param: name) }
        return loaded.pixels
    }

    mutating func loadMask(_ name: String, for image: Pixels) throws -> Mask {
        guard let url = context.input(name)?.fileURL else { throw NormalizerError.input("Input '\(name)' is missing.") }
        let (mask, resampled) = try Media.loadMask(url, width: image.width, height: image.height)
        if resampled { warn(ImageProfile.WarningCode.maskResampled, "The mask was resized to the image.", param: name) }
        return mask
    }

    /// The requested output format (PNG unless `output.media_type` asks for JPEG).
    var outputType: String { context.param("output")?["media_type"]?.stringValue ?? "image/png" }

    func write(_ pixels: Pixels, name: String, kind: MESCore.Kind = .image, index: Int = 0) throws -> ProducedOutput {
        let type = kind == .mask ? "image/png" : outputType
        let url = context.outputDirectory.appendingPathComponent("\(name)-\(index).\(type == "image/jpeg" ? "jpg" : "png")")
        try Media.encode(pixels.cgImage, mediaType: type).write(to: url)
        return .file(url, name: name, kind: kind, mediaType: type, width: pixels.width, height: pixels.height)
    }

    func write(_ mask: Mask, name: String, index: Int = 0) throws -> ProducedOutput {
        let url = context.outputDirectory.appendingPathComponent("\(name)-\(index).png")
        try Media.encode(mask.cgImage, mediaType: "image/png").write(to: url)
        return .file(url, name: name, kind: .mask, mediaType: "image/png", width: mask.width, height: mask.height)
    }

    func image(_ value: RunOutputValue) throws -> Pixels {
        guard case .image(let image) = value else { throw NormalizerError.engine("The model returned no image.") }
        return try Media.pixels(image)
    }

    /// The seed: the request's, or a random one that survives JSON (≤ 2^53 − 1).
    func seed(count: Int) -> UInt64 {
        if let s = context.param("seed")?.intValue, s >= 0 { return UInt64(s) }
        return UInt64.random(in: 0...(9_007_199_254_740_991 - UInt64(count)))
    }

    /// Re-applies the input's alpha when the model dropped it (Image §1.5).
    mutating func keepAlpha(_ output: Pixels, input: Pixels) -> Pixels {
        guard input.hasTransparency, !output.hasTransparency else { return output }
        warn(ImageProfile.WarningCode.alphaReapplied, "The model can't carry alpha; the input's was re-applied.")
        return Media.reapplyAlpha(output, from: input)
    }

    // MARK: - Generate and edit

    /// `size`, or `aspect` + `megapixels`, or the model's default; then snapped to its envelope (`size_snapped`).
    mutating func size(for route: RoutedModel, required: Bool) -> (Int, Int)? {
        var w = route.defaults.width, h = route.defaults.height
        var asked = false
        if let size = context.param("size"), let sw = size["width"]?.intValue, let sh = size["height"]?.intValue {
            (w, h, asked) = (sw, sh, true)
        } else if let aspect = context.param("aspect")?.stringValue {
            let parts = aspect.split(separator: ":").compactMap { Double($0) }
            let mp = context.param("megapixels")?.numberValue ?? 1
            if parts.count == 2, parts[0] > 0, parts[1] > 0 {
                let area = mp * 1_000_000
                w = Int((area * parts[0] / parts[1]).squareRoot())
                h = Int(Double(w) * parts[1] / parts[0])
                asked = true
            }
        } else if let mp = context.param("megapixels")?.numberValue {
            let side = Int((mp * 1_000_000).squareRoot())
            (w, h, asked) = (side, side, true)
        }
        guard asked || required else { return nil }
        let fitted = route.envelope.fit(width: w, height: h) ?? route.envelope.clamp(width: w, height: h)
        if asked, fitted.width != w || fitted.height != h {
            warn(ImageProfile.WarningCode.sizeSnapped, "\(w)×\(h) became \(fitted.width)×\(fitted.height) for \(route.displayName).", param: "size")
        }
        effective["size"] = ["width": .number(Double(fitted.width)), "height": .number(Double(fitted.height))]
        return (fitted.width, fitted.height)
    }

    /// A negative prompt reaches only models that use classifier-free guidance.
    mutating func negativePrompt(for route: RoutedModel) -> String? {
        guard let negative = context.param("negative_prompt")?.stringValue, !negative.isEmpty else { return nil }
        guard (route.defaults.guidance ?? 0) > 1 else {
            warn(ImageProfile.WarningCode.negativePromptIgnored, "\(route.displayName) doesn't use a negative prompt.", param: "negative_prompt")
            return nil
        }
        return negative
    }

    mutating func generate() async throws -> [ProducedOutput] {
        let route = try await route(.textToImage)
        let (w, h) = size(for: route, required: true)!
        let count = context.param("count")?.intValue ?? 1
        let base = seed(count: count)
        var params: ISValueObject = ["prompt": .string(context.input("prompt")?.text ?? "")]
        if let negative = negativePrompt(for: route) { params["negativePrompt"] = .string(negative) }
        record(route)
        var outputs: [ProducedOutput] = []
        for i in 0..<count {
            let result = try image(try await invoke(route, params: params, seed: base + UInt64(i), width: w, height: h, index: i, count: count))
            outputs.append(try write(result, name: "images", index: i))
        }
        effective["count"] = .number(Double(count))
        seedUsed = base
        return outputs
    }

    mutating func edit() async throws -> [ProducedOutput] {
        let route = try await route(.imageEdit)
        var images: [MLXToolKit.Image] = []
        var first: Pixels?
        for (i, input) in (context.inputs["images"] ?? []).enumerated() {
            guard let url = input.fileURL else { continue }
            let loaded = try Media.load(url)
            if loaded.colorConverted { warn(ImageProfile.WarningCode.colorConverted, "Image \(i + 1) was converted to sRGB.", param: "images") }
            if first == nil { first = loaded.pixels }
            images.append(Media.modelImage(loaded.pixels))
        }
        guard let first else { throw NormalizerError.input("image.edit needs at least one image.") }
        let size = size(for: route, required: false)
        let base = seed(count: 1)
        var params: ISValueObject = ["prompt": .string(context.input("instruction")?.text ?? "")]
        if let strength = context.param("strength")?.numberValue { params["strength"] = .number(strength) }
        record(route)
        var result = try image(try await invoke(route, params: params, inputs: ["images": images], seed: base,
                                                 width: size?.0, height: size?.1))
        if size == nil, result.width != first.width || result.height != first.height {
            result = result.resized(first.width, first.height)                     // the first image sets the size
        }
        seedUsed = base
        return [try write(result, name: "image")]
    }

    // MARK: - Masks: fill, erase, extend

    /// The inpainting package's variant for a large hole: MI-GAN at draft (LaMa's fast sibling), LaMa at standard and
    /// best. LaMa's pink cast on colour fills was the published bf16 weights, not the port; mlx-lama-swift 0.3.1 loads
    /// fp32 weights and matches PyTorch within one 8-bit level in every hole pixel (AB-R-0451). What remains is
    /// Big-LaMa's own limit: very large box holes (~65% of the frame and up) fade to a grey, blurry centre in PyTorch
    /// too; mug-sized holes (~25–40% of a 768² frame) fill cleanly.
    mutating func inpaintMode() -> String? {
        let lama = context.quality != .draft
        modelParams["variant"] = .string(lama ? "lama" : "mi-gan")
        return lama ? nil : "fast"
    }

    /// Whether the chosen model is an edit model, which runs fill and extend generatively.
    func generative() async -> Bool {
        await normalizer.directory.model(ModelID(context.model.id))?.capabilities.contains(.imageEdit) ?? false
    }

    mutating func inpaint() async throws -> [ProducedOutput] {
        let original = try load("image")
        let mask = try loadMask("mask", for: original)
        let prompt = context.input("prompt")?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if spec.operation == "image.fill", await generative() {
            let instruction = prompt.isEmpty
                ? "Fill the bright magenta area so it blends seamlessly into the rest of the picture, as if nothing had been there. Keep everything else unchanged."
                : "Replace the bright magenta area with \(prompt). Match the picture's lighting, perspective and style, and keep everything else unchanged."
            if let result = try await paint(original, region: mask, instruction: instruction, prompt: prompt) {
                return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
            }
            let result = try await fallBack(original, hole: mask.hole)
            return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
        }
        if !prompt.isEmpty {
            warn("prompt_ignored", "\(context.model.title) fills from the surrounding picture; the prompt isn't used.", param: "prompt")
        }
        let route = try await route(.imageInpaint)
        record(route)
        let mode = inpaintMode()
        let result = try image(try await invoke(route, params: [:], mode: mode,
                                                inputs: ["image": [Media.modelImage(original)], "mask": [Media.modelImage(mask.hole)]]))
        return [try write(Media.composite(result: result, over: original, mask: mask), name: "image")]
    }

    /// The edit model left its region unpainted (the marker colour is still there, twice): LaMa fills it instead,
    /// so the marker never reaches an output.
    mutating func fallBack(_ canvas: Pixels, hole: Mask) async throws -> Pixels {
        warn("model_fallback", "\(context.model.title) didn't paint the area usably twice; LaMa filled it instead.")
        let lama = try await route(.imageInpaint, helper: true)
        modelParams["fallback"] = .string(lama.id.rawValue)
        return try image(try await invoke(lama, params: [:], inputs: ["image": [Media.modelImage(canvas)], "mask": [Media.modelImage(hole)]]))
    }

    mutating func extend() async throws -> [ProducedOutput] {
        let original = try load("image")
        let prompt = context.input("prompt")?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let (l, t, r, b) = try padding(for: original)
        let (canvas, mask) = Media.pad(original, left: l, top: t, right: r, bottom: b)
        effective["canvas"] = ["left": .number(Double(l)), "top": .number(Double(t)), "right": .number(Double(r)), "bottom": .number(Double(b))]
        let result: Pixels
        if await generative() {
            // Naming the edges matters: told only "around it", edit models often leave a side blank.
            let edges = [("left", l), ("right", r), ("top", t), ("bottom", b)].filter { $0.1 > 0 }.map(\.0)
            let named = edges.count > 1 ? edges.dropLast().joined(separator: ", ") + " and " + edges.last! : edges.first ?? "outer"
            let instruction = "Replace the bright magenta \(edges.count > 1 ? "areas" : "area") at the \(named) "
                + "\(edges.count > 1 ? "edges" : "edge") with a seamless continuation of the scene"
                + (prompt.isEmpty ? "" : " showing \(prompt)") + ". Keep everything else unchanged."
            let sides = Media.sides(width: canvas.width, height: canvas.height, left: l, top: t, right: r, bottom: b)
            guard let paintedRegion = try await paint(canvas, region: mask, instruction: instruction, prompt: prompt,
                                                      parts: sides, checkDark: true) else {
                let filled = try await fallBack(canvas, hole: mask)
                return [try write(Media.composite(result: filled, over: canvas, mask: mask), name: "image")]
            }
            let painted = Media.composite(result: paintedRegion, over: canvas, mask: mask)
            // The edit model continued its own re-rendering of the picture, so its border can meet the original out of
            // step (a trunk a little to one side). LaMa bridges a thin band on the new side of the seam from both
            // sides' context; the original's pixels stay as they are.
            let band = Media.seamBand(of: mask, width: max(8, max(canvas.width, canvas.height) / 48))
            let lama = try await route(.imageInpaint, helper: true)
            modelParams["seam"] = .string(lama.id.rawValue)
            let bridged = try image(try await invoke(lama, params: [:], inputs: ["image": [Media.modelImage(painted)],
                                                                                 "mask": [Media.modelImage(band)]]))
            result = Media.composite(result: bridged, over: painted, mask: band)
        } else {
            if !prompt.isEmpty {
                warn("prompt_ignored", "\(context.model.title) extends from the picture itself; the prompt isn't used.", param: "prompt")
            }
            let route = try await route(.imageInpaint)
            record(route)
            result = try image(try await invoke(route, params: [:], mode: inpaintMode(), inputs: ["image": [Media.modelImage(canvas)],
                                                                                                "mask": [Media.modelImage(mask)]]))
        }
        return [try write(Media.composite(result: result, over: canvas, mask: mask), name: "image")]
    }

    /// An edit model paints `region` (shown to it in magenta) as `instruction` says. The result is at the canvas's
    /// size; the caller composites it with the mask, so only the region changes. Edit models sometimes keep the marker
    /// (as is, or as a shaded purple surface) or leave the region dark (`Media.paintingProblem`), so such a result is
    /// retried once with the next seed, and nil after that: the caller falls back.
    mutating func paint(_ canvas: Pixels, region: Mask, instruction: String, prompt: String, parts: [Mask]? = nil,
                        checkDark: Bool = false) async throws -> Pixels? {
        let route = try await route(.imageEdit)
        record(route)
        let fitted = route.envelope.fit(width: canvas.width, height: canvas.height)
            ?? route.envelope.clamp(width: canvas.width, height: canvas.height)
        let base = seed(count: 2)
        let marked = Media.mark(canvas, region: region)
        // A prompt that asks for the marker's colour can't be checked for it.
        let checkable = !["magenta", "pink", "fuchsia", "purple"].contains { prompt.lowercased().contains($0) }
        for attempt in 0..<2 {
            let result = try image(try await invoke(route, params: ["prompt": .string(instruction)], inputs: ["images": [Media.modelImage(marked)]],
                                                    seed: base + UInt64(attempt), width: fitted.width, height: fitted.height))
                .resized(canvas.width, canvas.height)
            let problem = checkable ? Media.paintingProblem(result, canvas: canvas, parts: parts ?? [region], checkDark: checkDark) : nil
            guard let problem else {
                seedUsed = base + UInt64(attempt)
                if attempt > 0 { modelParams["retries"] = .number(Double(attempt)) }
                return Media.harmonize(result, toward: canvas, region: region)
            }
            modelParams["rejected"] = .string(problem)
        }
        return nil
    }

    /// `canvas` as {left, top, right, bottom}, or {size, anchor}, in pixels.
    func padding(for image: Pixels) throws -> (Int, Int, Int, Int) {
        guard let canvas = context.param("canvas") else { return (0, 0, 0, 0) }
        if let l = canvas["left"]?.intValue, let t = canvas["top"]?.intValue, let r = canvas["right"]?.intValue, let b = canvas["bottom"]?.intValue {
            return (l, t, r, b)
        }
        guard let w = canvas["size"]?["width"]?.intValue, let h = canvas["size"]?["height"]?.intValue,
              w >= image.width, h >= image.height else {
            throw MESError(.outOfLimits, "canvas.size must be at least the image's size.", param: "canvas")
        }
        let (dx, dy) = (w - image.width, h - image.height)
        let anchor = canvas["anchor"]?.stringValue ?? "center"
        let left = anchor.contains("left") ? 0 : anchor.contains("right") ? dx : dx / 2
        let top = anchor.hasPrefix("top") ? 0 : anchor.hasPrefix("bottom") ? dy : dy / 2
        return (left, top, dx - left, dy - top)
    }

    // MARK: - Processing

    mutating func upscale() async throws -> [ProducedOutput] {
        let input = try load("image")
        let scale = context.param("scale")?.intValue ?? 2
        let route = try await route(.imageUpscale)
        record(route)
        var result = try image(try await invoke(route, params: ["scale": .number(Double(scale))], inputs: ["image": [Media.modelImage(input)]]))
        let (w, h) = (input.width * scale, input.height * scale)
        if result.width != w || result.height != h { result = result.resized(w, h) }   // exactly ×scale (Image §3)
        effective["scale"] = .number(Double(scale))
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    mutating func restore() async throws -> [ProducedOutput] {
        let input = try load("image")
        let kind = context.param("kind")?.stringValue ?? "general"
        effective["kind"] = .string(kind)
        if kind == "scratches" {
            // Old-photo scratches (IMG-4): find the defects, then inpaint just those.
            let detector = try await route(.defectDetect, helper: true)
            guard case .matte(let matte, _) = try await invoke(detector, params: ["kind": "binary"], inputs: ["image": [Media.modelImage(input)]]) else {
                throw NormalizerError.engine("The defect detector returned no mask.")
            }
            let mask = try Media.mask(matte, width: input.width, height: input.height)
            let painter = try await route(.imageInpaint, helper: true)
            modelParams["detector"] = .string(detector.id.rawValue)
            record(painter)
            let result = try image(try await invoke(painter, params: [:], inputs: ["image": [Media.modelImage(input)], "mask": [Media.modelImage(mask)]]))
            return [try write(keepAlpha(Media.composite(result: result, over: input, mask: mask), input: input), name: "image")]
        }
        let route = try await route(.imageRestore)
        record(route)
        var result = try image(try await invoke(route, params: [:], inputs: ["image": [Media.modelImage(input)]]))
        if result.width != input.width || result.height != input.height { result = result.resized(input.width, input.height) }
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    /// relight and colorize: same size and composition (Image §3).
    mutating func sameSize() async throws -> [ProducedOutput] {
        let input = try load("image")
        if let prompt = context.input("prompt")?.text, !prompt.isEmpty {
            warn("prompt_ignored", "\(context.model.title) corrects exposure; the prompt isn't used.", param: "prompt")
        }
        let route = try await route(spec.capability)
        record(route)
        var params: ISValueObject = [:]
        if let strength = context.param("strength")?.numberValue { params["strength"] = .number(strength) }
        var result = try image(try await invoke(route, params: params, inputs: ["image": [Media.modelImage(input)]]))
        if result.width != input.width || result.height != input.height { result = result.resized(input.width, input.height) }
        return [try write(keepAlpha(result, input: input), name: "image")]
    }

    mutating func matte() async throws -> [ProducedOutput] {
        let input = try load("image")
        let route = try await route(.matting)
        record(route)
        guard case .matte(let matte, _) = try await invoke(route, params: ["kind": "softAlpha"], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no matte.")
        }
        let mask = try Media.mask(matte, width: input.width, height: input.height)
        let wanted = Set(context.param("outputs")?.arrayValue?.compactMap(\.stringValue) ?? ["mask", "extract"])
        var outputs: [ProducedOutput] = []
        if wanted.contains("mask") { outputs.append(try write(mask, name: "mask")) }
        if wanted.contains("extract") {
            let url = context.outputDirectory.appendingPathComponent("extract-0.png")
            let cut = Media.extract(input, alpha: mask)
            try Media.encode(cut.cgImage, mediaType: "image/png").write(to: url)          // alpha needs PNG
            outputs.append(.file(url, name: "extract", kind: .image, mediaType: "image/png", width: cut.width, height: cut.height))
        }
        return outputs
    }

    mutating func segment() async throws -> [ProducedOutput] {
        let input = try load("image")
        guard let points = context.input("points")?.data?.arrayValue, !points.isEmpty else {
            throw NormalizerError.input("image.segment needs points: [{x, y, label}] with x and y in 0…1.")
        }
        let pixels: [ISValue] = points.map { p in
            [.number((p["x"]?.numberValue ?? 0) * Double(input.width)), .number((p["y"]?.numberValue ?? 0) * Double(input.height))]
        }
        let labels: [ISValue] = points.map { .number($0["label"]?.stringValue == "exclude" ? 0 : 1) }
        let route = try await route(.promptSegment)
        record(route)
        guard case .matte(let matte, let score) = try await invoke(route, params: ["points": .array(pixels), "pointLabels": .array(labels)],
                                                                   inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no mask.")
        }
        if let score { modelParams["score"] = .number(Double(score)) }
        return [try write(try Media.mask(matte, width: input.width, height: input.height), name: "masks")]
    }

    mutating func describe() async throws -> [ProducedOutput] {
        let input = try load("image")
        let language = context.param("language")?.stringValue ?? "en"
        let route = try await route(.imageAnalysis)
        record(route)
        let question = Describe.prompt + (language == "en" ? "" : " Write the caption and alt text in the language with code \(language).")
        guard case .text(let reply) = try await invoke(route, params: ["prompt": .string(question)], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no text.")
        }
        var value = Describe.parse(reply)
        value["language"] = .string(language)
        return [.data(.object(value), name: "description")]
    }

    mutating func score() async throws -> [ProducedOutput] {
        let input = try load("image")
        let route = try await route(.imageQualityScore)
        record(route)
        guard case .score(let raw, _) = try await invoke(route, params: [:], inputs: ["image": [Media.modelImage(input)]]) else {
            throw NormalizerError.engine("The model returned no score.")
        }
        let r = Double(raw.description) ?? Double(raw)          // the Float's own digits, not its binary widening
        let value: MESValue = ["score": .number(min(1, max(0, r))), "scale": .string("\(route.id.rawValue): 0 (worst) to 1 (best)"),
                               "raw": .number(r)]
        return [.data(value, name: "score")]
    }

    /// The model-specific detail of a run (Base §10.1: `effective.model_params`).
    mutating func record(_ route: RoutedModel) {
        modelParams["model"] = .string(route.id.rawValue)
        if let steps = route.defaults.steps { modelParams["steps"] = .number(Double(steps)) }
        if let guidance = route.defaults.guidance { modelParams["guidance"] = .number(guidance) }
    }
}

typealias ISValueObject = [String: ISValue]

/// Hands the runtime's synchronous progress callbacks to the job's async reporter, in order.
final class ProgressRelay: Sendable {
    typealias Update = (stage: Stage, step: Int?, steps: Int?, fraction: Double?, message: String?)
    private let continuation: AsyncStream<Update>.Continuation
    private let task: Task<Void, Never>

    init(_ reporter: RunReporter) {
        let (stream, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.continuation = continuation
        task = Task {
            for await u in stream { await reporter.progress(u.stage, step: u.step, steps: u.steps, fraction: u.fraction, message: u.message) }
        }
    }

    func send(_ stage: Stage, step: Int? = nil, steps: Int? = nil, fraction: Double? = nil, message: String? = nil) {
        continuation.yield((stage, step, steps, fraction, message))
    }

    func finish() async {
        continuation.finish()
        await task.value
    }
}
typealias RunOutputValue = ImageServerModels.RunOutput

/// Asking a vision-language model for a library description, and reading its answer.
enum Describe {
    static let prompt = """
        Describe this image. Reply with JSON only, no other text:
        {"caption": "one sentence: the subject, the setting and the style", \
        "alt_text": "a short description for a screen reader, under 125 characters", \
        "tags": ["5 to 12 lowercase keywords: subjects, objects, setting, style, mood, main colours"]}
        """

    /// The reply → the profile's `description` (caption, alt text, lowercase tags). A reply that isn't JSON still
    /// yields a caption, so a chatty model isn't a failed job.
    static func parse(_ reply: String) -> [String: MESValue] {
        struct Reply: Decodable { var caption: String?; var alt_text: String?; var tags: [String]? }
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed: Reply?
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close {
            parsed = try? JSONDecoder().decode(Reply.self, from: Data(text[open...close].utf8))
        }
        let caption = parsed?.caption ?? String(text.prefix { $0 != "\n" }.prefix(400))
        let tags = (parsed?.tags ?? []).map { $0.lowercased() }.filter { !$0.isEmpty }
        return ["caption": .string(caption), "alt_text": .string(String((parsed?.alt_text ?? caption).prefix(250))),
                "tags": .array(tags.map { .string($0) })]
    }
}

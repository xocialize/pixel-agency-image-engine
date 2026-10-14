import AppKit
import ArgumentParser
import Foundation
import MESCore

@main
struct TierBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tier-bench",
        abstract: "Measure the Image Engine's quality tiers end to end (ENG R1b).",
        discussion: "Runs against a running engine. Suites: tiers, upscale, restore, segment, generate, edits, singles, erase, or all.")

    @Argument(help: "Suites to run.") var suites: [String] = ["all"]
    @Option(help: "The engine's base URL.") var engine = "http://127.0.0.1:17610/mes/v0"
    @Option(help: "The corpus root (sr-bench, interactive-seg). Default: $TIERBENCH_CORPUS, else ./corpus.")
    var corpus = ProcessInfo.processInfo.environment["TIERBENCH_CORPUS"] ?? "corpus"
    @Option(help: "Where results go.") var out: String
    @Option(help: "Images per measured set.") var count = 6
    @Option(help: "Objects for segment.") var objects = 50
    @Option(help: "Only these models (comma-separated): generate by model id; erase by arm (mi-gan, lama, or an edit model's id).")
    var models: String?
    @Option(help: "erase: the removal gate's prepared set (manifest.json and its crops). Default: $TIERBENCH_GATE, else <corpus>/removal-gate/prepared.")
    var gate: String?
    @Option(help: "erase: how many of the gate's subset S (60) to run.") var eraseItems = 60
    @Option(help: "judge: a previous run whose generate outputs to judge.") var from: String?
    @Flag(help: "generate: the hard prompt set (text in the image, counts, attribute binding).") var hard = false
    @Option(help: "fillbake: the case file (bench/fillbake/cases.json).") var cases: String?
    @Option(help: "fillbake: which tasks (comma-separated: fill, fill768, seamless, extend, remove).") var tasks = "fill,fill768,seamless,extend,remove"
    @Option(help: "fillbake: the seed every job asks for (the bake-off's is 7).") var seed = 7

    func run() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let bench = try await Bench(engine: URL(string: engine)!, out: URL(fileURLWithPath: out, isDirectory: true))
        let root = URL(fileURLWithPath: corpus, isDirectory: true)
        let all = suites.contains("all")
        var footprints: [String: Double] = [:]
        let only = models.map { Set($0.split(separator: ",").map(String.init)) }
        let suite = Suites(bench: bench, corpus: root, count: count, only: only, hard: hard)
        if all || suites.contains("tiers") { await suite.tiers() }
        if all || suites.contains("singles") { try await suite.singles(&footprints) }
        if all || suites.contains("upscale") { try await suite.upscale(scale: 4, &footprints); try await suite.upscale(scale: 2, &footprints) }
        if all || suites.contains("restore") { try await suite.restore(&footprints) }
        if all || suites.contains("segment") { try await suite.segment(objects: objects, &footprints) }
        if all || suites.contains("generate") { try await suite.generate(&footprints) }
        if all || suites.contains("edits") { try await suite.edits(&footprints) }
        let gateDir = URL(fileURLWithPath: gate ?? ProcessInfo.processInfo.environment["TIERBENCH_GATE"]
            ?? root.appendingPathComponent("removal-gate/prepared").path, isDirectory: true)
        if suites.contains("erase") || (all && FileManager.default.fileExists(atPath: gateDir.appendingPathComponent("manifest.json").path)) {
            try await suite.erase(gate: gateDir, items: eraseItems, &footprints)
        }
        if suites.contains("judge"), let from { try await suite.judge(from: URL(fileURLWithPath: from, isDirectory: true)) }
        if suites.contains("fillbake"), let cases {
            let arms = models.map { $0.split(separator: ",").map(String.init) } ?? ["klein-4b", "sensenova-u1-fast"]
            try await suite.fillBake(cases: URL(fileURLWithPath: cases), arms: arms, tasks: Set(tasks.split(separator: ",").map(String.init)),
                                     seed: seed, &footprints)
        }
        let md = "# Tier bench — \(bench.info.name)\n\nRun \(ISO8601DateFormatter().string(from: Date())), engine \(engine).\n"
            + Summary.markdown(bench.records, footprints: footprints)
        try md.write(to: bench.out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(bench.records)
        try data.write(to: bench.out.appendingPathComponent("records.json"))
        print(md)
    }
}

struct Suites {
    let bench: Bench
    let corpus: URL
    let count: Int
    let only: Set<String>?
    let hard: Bool
    var prompts: [(String, [[String]])] { hard ? Self.hardPrompts : Self.prompts }
    var generateSuite: String { hard ? "generate-hard" : "generate" }

    var inputs: URL { bench.out.appendingPathComponent("inputs") }

    func div2k(_ offset: Int, _ n: Int) throws -> [URL] {
        let dir = corpus.appendingPathComponent("sr-bench/DIV2K_valid_HR")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return Array(files.dropFirst(offset).prefix(n))
    }

    func prepare(_ raster: Raster, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let url = inputs.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try raster.write(url) }
        return url
    }

    /// Which model each tier picks, per operation (one run each, on small inputs).
    func tiers() async {
        guard let photo = try? prepare(try Raster(contentsOf: div2k(0, 1)[0]).centreSquare(1024).resized(512, 512), "tier-photo.png"),
              let mask = try? prepare(Self.centreMask(512, 512, fraction: 0.3), "tier-mask.png") else { return }
        for op in bench.operations {
            // Operations whose vocabulary has no `quality` run once, at the engine's default.
            let takesQuality = op.params["properties"]?["quality"] != nil
            let tiers: [QualityTier?] = takesQuality ? QualityTier.allCases.filter(op.qualityTiers.contains) : [nil]
            for tier in tiers {
                var inputs: [String: Bench.Input] = [:]
                for spec in op.inputs where spec.required {
                    switch spec.kind {
                    case .text: inputs[spec.name] = .text(spec.name == "instruction" ? "make it winter" : "a small wooden boat on a lake")
                    case .image: inputs[spec.name] = .file(photo)
                    case .mask: inputs[spec.name] = .file(mask)
                    case .data: inputs[spec.name] = .data([["x": 0.5, "y": 0.5, "label": "include"]])
                    default: break
                    }
                }
                var params: [String: JSONValue] = [:]
                if op.operation == "image.generate" { params["size"] = ["width": 512, "height": 512] }
                if op.operation == "image.extend" { params["canvas"] = ["left": 128, "top": 0, "right": 128, "bottom": 0] }
                await bench.run(suite: "tiers", operation: op.operation, item: "photo", inputs: inputs, params: params,
                                quality: tier, folder: "tiers")
            }
        }
    }

    /// Single-model operations: time at 1024².
    func singles(_ footprints: inout [String: Double]) async throws {
        let photo = try prepare(try Raster(contentsOf: div2k(20, 1)[0]).centreSquare(1024), "single-photo.png")
        let grey = try prepare(Self.greyscale(try Raster(contentsOf: photo)), "single-grey.png")
        for (op, image) in [("image.relight", photo), ("image.colorize", grey), ("image.matte", photo), ("image.describe", photo), ("image.score", photo)] {
            for (i, warm) in [false, true, true].enumerated() {
                await bench.run(suite: "singles", operation: op, item: "photo-\(i)", inputs: ["image": .file(image)], warm: warm, folder: "singles")
            }
            if let model = bench.offers(op).first?.id { footprints[model] = bench.footprintGB() }
        }
    }

    /// Full-reference SR: DIV2K centre crops, bicubic-ish downscale, PSNR/SSIM (luma, border = scale) against HR.
    func upscale(scale: Int, _ footprints: inout [String: Double]) async throws {
        let side = 1024, lrSide = side / scale
        var pairs: [(lr: URL, hr: Raster, name: String)] = []
        for file in try div2k(0, count) {
            let hr = try Raster(contentsOf: file).centreSquare(side)
            let name = file.deletingPathExtension().lastPathComponent
            pairs.append((try prepare(hr.resized(lrSide, lrSide), "\(name)-lr\(scale).png"), hr, name))
        }
        for offer in bench.offers("image.upscale") {
            let suite = "upscale-x\(scale)"
            await bench.run(suite: suite, operation: "image.upscale", item: "warm-up", inputs: ["image": .file(pairs[0].lr)],
                            params: ["scale": .number(Double(scale))], model: offer.id, warm: false, folder: "\(suite)/warmup")
            for pair in pairs {
                await bench.run(suite: suite, operation: "image.upscale", item: pair.name, inputs: ["image": .file(pair.lr)],
                                params: ["scale": .number(Double(scale))], model: offer.id, folder: "\(suite)/\(offer.id)") { files in
                    let sr = try Raster(contentsOf: files[0])
                    return ["psnr": Score.psnr(sr, pair.hr, border: scale), "ssim": Score.ssim(sr, pair.hr, border: scale)]
                }
            }
            footprints[offer.id] = bench.footprintGB()
        }
    }

    /// Restoration against clean ground truth: Gaussian noise σ 25 (denoise) and Gaussian blur σ 2 (deblur).
    func restore(_ footprints: inout [String: Double]) async throws {
        var sets: [(kind: String, items: [(input: URL, clean: Raster, name: String)])] = [("denoise", []), ("deblur", [])]
        for (i, file) in try div2k(10, count).enumerated() {
            let clean = try Raster(contentsOf: file).centreSquare(768)
            let name = file.deletingPathExtension().lastPathComponent
            sets[0].items.append((try prepare(clean.noisy(sigma: 25, seed: UInt64(1000 + i)), "\(name)-noise25.png"), clean, name))
            sets[1].items.append((try prepare(clean.blurred(sigma: 2), "\(name)-blur2.png"), clean, name))
        }
        let candidates = ["denoise": ["scunet-denoise", "restormer-denoise", "drunet-denoise", "nafnet-restore"],
                          "deblur": ["restormer-motion", "restormer-defocus", "nafnet-restore"]]
        let offered = Set(bench.offers("image.restore").map(\.id))
        for set in sets {
            let suite = "restore-\(set.kind)"
            func score(_ clean: Raster) -> ([URL]) throws -> [String: Double] {
                { files in let r = try Raster(contentsOf: files[0]); return ["psnr": Score.psnr(r, clean), "ssim": Score.ssim(r, clean)] }
            }
            let input0 = set.items[0]
            await bench.run(suite: suite, operation: "image.restore", item: "input", inputs: ["image": .file(input0.input)],
                            params: ["kind": "general"], model: "nafnet-restore", warm: false, folder: "\(suite)/input", score: { _ in
                let degraded = try Raster(contentsOf: input0.input)
                return ["psnr-degraded": Score.psnr(degraded, input0.clean)]
            })
            for model in candidates[set.kind]! where offered.contains(model) {
                await bench.run(suite: suite, operation: "image.restore", item: "warm-up", inputs: ["image": .file(input0.input)],
                                params: ["kind": .string(set.kind)], model: model, warm: false, folder: "\(suite)/warmup")
                for item in set.items {
                    await bench.run(suite: suite, operation: "image.restore", item: item.name, inputs: ["image": .file(item.input)],
                                    params: ["kind": .string(set.kind)], model: model, folder: "\(suite)/\(model)", score: score(item.clean))
                }
                footprints[model] = bench.footprintGB()
            }
            for item in set.items {
                let degraded = try Raster(contentsOf: item.input)
                bench.note(suite: suite, item: item.name, metrics: ["psnr": Score.psnr(degraded, item.clean), "ssim": Score.ssim(degraded, item.clean)])
            }
        }
    }

    /// One click at the object's deepest interior point, IoU against GrabCut ground truth (ignore band excluded).
    func segment(objects: Int, _ footprints: inout [String: Double]) async throws {
        let dir = corpus.appendingPathComponent("interactive-seg/GrabCut")
        let images = try FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("data_GT"), includingPropertiesForKeys: nil)
            .filter { ["jpg", "png", "bmp"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [(image: URL, gt: BinaryMask, ignore: [Bool], click: JSONValue, name: String)] = []
        for image in images.prefix(objects) {
            let name = image.deletingPathExtension().lastPathComponent
            let gtURL = dir.appendingPathComponent("boundary_GT/\(name).bmp")
            guard FileManager.default.fileExists(atPath: gtURL.path) else { continue }
            let (gt, ignore) = try BinaryMask.groundTruth(gtURL)
            let p = gt.deepestPoint
            let click: JSONValue = [["x": .number((Double(p.x) + 0.5) / Double(gt.width)), "y": .number((Double(p.y) + 0.5) / Double(gt.height)), "label": "include"]]
            // The engine takes PNG, JPEG, HEIC, WebP and TIFF; some GrabCut images are BMP.
            let input = image.pathExtension.lowercased() == "bmp" ? try prepare(try Raster(contentsOf: image), "grabcut-\(name).png") : image
            items.append((input, gt, ignore, click, name))
        }
        for offer in bench.offers("image.segment") {
            await bench.run(suite: "segment-1click", operation: "image.segment", item: "warm-up",
                            inputs: ["image": .file(items[0].image), "points": .data(items[0].click)], model: offer.id, warm: false, folder: "segment/warmup")
            for item in items {
                await bench.run(suite: "segment-1click", operation: "image.segment", item: item.name,
                                inputs: ["image": .file(item.image), "points": .data(item.click)], model: offer.id, folder: "segment/\(offer.id)") { files in
                    let mask = try BinaryMask.output(files[0], width: item.gt.width, height: item.gt.height)
                    return ["iou": Score.iou(mask, item.gt, ignore: item.ignore)]
                }
            }
            footprints[offer.id] = bench.footprintGB()
        }
    }

    static let prompts: [(String, [[String]])] = [
        ("a red vintage bicycle leaning against a sunlit brick wall, photograph", [["bicycle", "bike"], ["brick"]]),
        ("a bowl of ramen with a soft-boiled egg on a wooden table, overhead shot", [["ramen", "noodle"], ["egg"]]),
        ("a lighthouse on a rocky coast at dusk", [["lighthouse"], ["rock", "cliff", "coast"]]),
        ("a golden retriever puppy playing in autumn leaves", [["dog", "puppy", "retriever"], ["leaves", "leaf", "autumn"]]),
        ("a glass teapot with blooming tea on a windowsill", [["teapot", "tea"], ["window"]]),
        ("a snowy mountain cabin with smoke rising from the chimney at night", [["cabin", "house", "hut"], ["snow"], ["night"]]),
        ("a woman reading a book in a cafe, natural light, portrait", [["woman", "girl", "person"], ["book", "reading"]]),
        ("three oranges and a lemon on a blue ceramic plate, studio product photo", [["orange"], ["lemon"], ["plate"]]),
    ]

    /// Harder prompts, where distilled few-step models tend to slip: text in the image, counts, attribute binding.
    /// Recall checks the describer's caption and tags for the words that must be there.
    static let hardPrompts: [(String, [[String]])] = [
        ("a wooden shop sign that says OPEN DAILY, photograph", [["open daily"]]),
        ("a white coffee mug printed with the word HELLO in black letters", [["hello"]]),
        ("a concert poster with the title SUMMER JAZZ NIGHT", [["summer jazz"]]),
        ("three cats sitting on a red sofa", [["three", "3"], ["cat"], ["red"]]),
        ("a blue cube on top of a yellow sphere, studio render", [["blue"], ["cube"], ["yellow"], ["sphere", "ball"]]),
        ("five green apples in a row on a wooden table", [["five", "5"], ["green"], ["apple"]]),
    ]

    /// Text to image at 1024², each default-routable model; judged afterwards by the engine's own score
    /// (SigLIP2 IQA) and by prompt-keyword recall in its description (Mage-VL).
    func generate(_ footprints: inout [String: Double]) async throws {
        let models = bench.offers("image.generate").filter { $0.namedOnly != true }.map(\.id).filter { only?.contains($0) ?? true }
        var outputs: [(index: Int, file: URL, keywords: [[String]], model: String, item: String)] = []
        for model in models {
            await bench.run(suite: generateSuite, operation: "image.generate", item: "warm-up", inputs: ["prompt": .text(prompts[0].0)],
                            params: ["seed": 7, "size": ["width": 1024, "height": 1024]], model: model, warm: false, folder: "generate/warmup")
            for (i, (prompt, keywords)) in prompts.enumerated() {
                let record = await bench.run(suite: generateSuite, operation: "image.generate", item: "p\(i)", inputs: ["prompt": .text(prompt)],
                                             params: ["seed": .number(Double(100 + i)), "size": ["width": 1024, "height": 1024]],
                                             model: model, folder: "generate/\(model)")
                if let path = record.outputs.first {
                    outputs.append((bench.records.count - 1, bench.out.appendingPathComponent(path), keywords, model, "p\(i)"))
                }
            }
            footprints[model] = bench.footprintGB()
        }
        try await judge(outputs)
        try Sheet.make(outputs.map { ("\($0.model) \($0.item)", $0.file) }, columns: prompts.count,
                       to: bench.out.appendingPathComponent("generate-sheet-\(models.joined(separator: "+").prefix(60)).png"))
    }

    /// Judges a previous run's generate outputs (copied in as generate records here).
    func judge(from run: URL) async throws {
        let lines = try String(contentsOf: run.appendingPathComponent("results.jsonl"), encoding: .utf8).split(separator: "\n")
        var outputs: [(index: Int, file: URL, keywords: [[String]], model: String, item: String)] = []
        for line in lines {
            guard let record = try? JSONDecoder().decode(Record.self, from: Data(line.utf8)), record.suite == "generate",
                  record.error == nil, let path = record.outputs.first, record.item.hasPrefix("p"), let i = Int(record.item.dropFirst()) else { continue }
            bench.appendRecord(record)
            outputs.append((bench.records.count - 1, run.appendingPathComponent(path), Self.prompts[i].1, record.model, record.item))
        }
        try await judge(outputs)
        try Sheet.make(outputs.map { ("\($0.model) \($0.item)", $0.file) }, columns: Self.prompts.count,
                       to: bench.out.appendingPathComponent("generate-sheet-judged.png"))
    }

    /// Scores each output with the engine's own judges: SigLIP2 IQA, and prompt-keyword recall in Mage-VL's description.
    func judge(_ outputs: [(index: Int, file: URL, keywords: [[String]], model: String, item: String)]) async throws {
        for output in outputs {
            let scored = await bench.run(suite: "judge", operation: "image.score", item: "\(output.model)/\(output.item)",
                                         inputs: ["image": .file(output.file)], folder: "judge")
            let described = await bench.run(suite: "judge", operation: "image.describe", item: "\(output.model)/\(output.item)",
                                            inputs: ["image": .file(output.file)], folder: "judge")
            var metrics: [String: Double] = [:]
            if let s = scored.metrics["score"] { metrics["iqa"] = s }
            if let path = described.outputs.first, let data = FileManager.default.contents(atPath: bench.out.appendingPathComponent(path).path),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                let text = ((value["caption"]?.stringValue ?? "") + " " + (value["tags"]?.arrayValue?.compactMap(\.stringValue).joined(separator: " ") ?? "")).lowercased()
                let hits = output.keywords.filter { group in group.contains { text.contains($0) } }.count
                metrics["recall"] = Double(hits) / Double(output.keywords.count)
            }
            bench.update(output.index, metrics: metrics)
        }
    }

    /// Edit, generative fill, erase and extend per tier on real photos: time, the engine's IQA, and a contact sheet.
    func edits(_ footprints: inout [String: Double]) async throws {
        var sheet: [(String, URL)] = []
        let photos = try div2k(30, 2).map { try prepare(try Raster(contentsOf: $0).centreSquare(1024), "edit-\($0.lastPathComponent)") }
        let mask = try prepare(Self.centreMask(1024, 1024, fraction: 0.3), "edit-mask.png")
        let jobs: [(op: String, inputs: (URL) -> [String: Bench.Input], params: [String: JSONValue], tiers: [QualityTier], label: String)] = [
            ("image.edit", { ["images": .file($0), "instruction": .text("make it a snowy winter scene")] }, [:], [.draft, .best], "edit winter"),
            ("image.fill", { ["image": .file($0), "mask": .file(mask), "prompt": .text("a small wooden bench")] }, [:], [.standard, .best], "fill bench"),
            ("image.erase", { ["image": .file($0), "mask": .file(mask)] }, [:], [.standard, .best], "erase centre"),
            ("image.extend", { ["image": .file($0)] }, ["canvas": ["left": 256, "top": 0, "right": 256, "bottom": 0]], [.draft, .standard, .best], "extend sides"),
        ]
        for job in jobs {
            for tier in job.tiers {
                for (i, photo) in photos.enumerated() {
                    let r = await bench.run(suite: "edits", operation: job.op, item: "photo\(i)", inputs: job.inputs(photo), params: job.params,
                                            quality: tier, warm: i > 0, folder: "edits/\(job.op)-\(tier.rawValue)")
                    if let path = r.outputs.first { sheet.append(("\(job.label) [\(tier.rawValue)] \(r.model)", bench.out.appendingPathComponent(path))) }
                }
                if let last = bench.records.last { footprints[last.model] = bench.footprintGB() }
            }
        }
        try Sheet.make(sheet, columns: 3, to: bench.out.appendingPathComponent("edits-sheet.png"))
    }

    static func centreMask(_ w: Int, _ h: Int, fraction: Double) -> Raster {
        let (mw, mh) = (Int(Double(w) * fraction), Int(Double(h) * fraction))
        var r = Raster(width: w, height: h, rgba: Array(repeating: [0, 0, 0, 255], count: w * h).flatMap { $0 })
        for y in (h - mh) / 2..<((h + mh) / 2) { for x in (w - mw) / 2..<((w + mw) / 2) { for c in 0..<3 { r.rgba[(y * w + x) * 4 + c] = 255 } } }
        return r
    }

    static func greyscale(_ r: Raster) -> Raster {
        var out = r
        let y = r.luma
        for i in 0..<(r.width * r.height) { for c in 0..<3 { out.rgba[i * 4 + c] = UInt8(min(255, y[i].rounded())) } }
        return out
    }
}

extension Bench {
    func update(_ index: Int, metrics: [String: Double]) { updateRecord(index) { $0.metrics.merge(metrics) { $1 } } }
    /// A reference row (e.g. the degraded input's own score), recorded as model "input".
    func note(suite: String, item: String, metrics: [String: Double]) {
        appendRecord(Record(suite: suite, operation: "reference", item: item, requested: nil, quality: nil, model: "(degraded input)",
                            runMs: 0, warm: true, metrics: metrics))
    }
}

/// A labelled grid of thumbnails.
enum Sheet {
    static func make(_ entries: [(String, URL)], columns: Int, cell: Int = 256, to url: URL) throws {
        guard !entries.isEmpty else { return }
        let label = 18, rows = (entries.count + columns - 1) / columns
        let (w, h) = (columns * cell, rows * (cell + label))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.15, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (i, entry) in entries.enumerated() {
            let x = (i % columns) * cell, y = h - (i / columns + 1) * (cell + label)
            if let image = NSImage(contentsOf: entry.1) {
                let s = image.size, k = min(Double(cell) / s.width, Double(cell) / s.height)
                image.draw(in: NSRect(x: Double(x) + (Double(cell) - s.width * k) / 2, y: Double(y + label) + (Double(cell) - s.height * k) / 2,
                                      width: s.width * k, height: s.height * k))
            }
            (entry.0 as NSString).draw(at: NSPoint(x: x + 4, y: y + 2), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}

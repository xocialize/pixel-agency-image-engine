import Foundation
import MESCore

/// Erase against ground truth: the removal gate's prepared set (AB-R-0463/0464). Each sample is a 1024² crop with a
/// real or rendered object-absent photo (`_gt`), the object's core mask (`_obj`), the core dilated 1.5% (`_objd`, the
/// mask a client sends) and, on CORNE, the effect mask: object plus shadow and reflection (`_eff`). Subset S is the
/// gate's 60: the largest regions plus a seeded random fill.
///
/// Every arm erases every sample through the engine, as a client would, with `_objd` as the mask; CORNE samples run
/// again with `_eff`, the mask a shadow-aware selection would send. The engine composites through the mask (Image
/// §1.7), so with `_objd` a shadow outside it stays whatever the model does: `ring` measures exactly that.
extension Suites {
    struct GateItem {
        let id: String
        let set: String
        let src, gt, obj, objd: URL
        let eff: URL?
        var name: String { id.replacingOccurrences(of: "/", with: "-") }
    }

    func gateItems(_ gate: URL, limit: Int) throws -> [GateItem] {
        struct Entry: Decodable { let id: String; let set: String; let subsetS: Bool }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: gate.appendingPathComponent("manifest.json")))
        return entries.filter(\.subsetS).prefix(limit).map { e in
            func file(_ suffix: String) -> URL { gate.appendingPathComponent("\(e.id)_\(suffix).png") }
            let eff = file("eff")
            return GateItem(id: e.id, set: e.set, src: file("src"), gt: file("gt"), obj: file("obj"), objd: file("objd"),
                            eff: FileManager.default.fileExists(atPath: eff.path) ? eff : nil)
        }
    }

    /// The arms: MI-GAN (LaMa's package at draft), LaMa, and each offered edit model that erases by name.
    func eraseArms() -> [(label: String, model: String, quality: QualityTier?)] {
        let offered = Set(bench.offers("image.erase").map(\.id))
        var arms: [(String, String, QualityTier?)] = []
        if offered.contains("lama-inpaint") { arms += [("mi-gan", "lama-inpaint", .draft), ("lama", "lama-inpaint", .standard)] }
        for id in offered.sorted() where id != "lama-inpaint" { arms.append((id, id, nil)) }
        return arms.filter { only?.contains($0.0) ?? true }
    }

    func erase(gate: URL, items limit: Int, _ footprints: inout [String: Double]) async throws {
        let items = try gateItems(gate, limit: limit)
        guard !items.isEmpty else { throw BenchError("no subset-S items in \(gate.path)") }
        let arms = eraseArms()
        var sheet: [(String, URL)] = []
        let shown = Array(items.prefix(8))
        for item in shown { sheet.append(("\(item.name) input", item.src)) }
        for arm in arms {
            await bench.run(suite: "erase-objd", operation: "image.erase", item: "warm-up",
                            inputs: ["image": .file(items[0].src), "mask": .file(items[0].objd)],
                            model: arm.model, quality: arm.quality, warm: false, folder: "erase/warmup")
            for (maskSet, maskFor) in [("objd", { (i: GateItem) -> URL? in i.objd }), ("eff", { (i: GateItem) -> URL? in i.eff })] {
                for item in items {
                    guard let mask = maskFor(item) else { continue }
                    let record = await bench.run(suite: "erase-\(maskSet)", operation: "image.erase", item: item.name,
                                                 inputs: ["image": .file(item.src), "mask": .file(mask)],
                                                 model: arm.model, quality: arm.quality, folder: "erase-\(maskSet)/\(arm.label)") { files in
                        try EraseScore.score(output: files[0], item: item, mask: mask)
                    }
                    bench.update(bench.records.count - 1, metrics: ["fallback": record.warnings.contains("model_fallback") ? 1 : 0])
                    if maskSet == "objd", shown.contains(where: { $0.id == item.id }), let path = record.outputs.first {
                        sheet.append(("\(item.name) \(arm.label)", bench.out.appendingPathComponent(path)))
                    }
                }
            }
            footprints[arm.model] = bench.footprintGB()
        }
        for item in shown { sheet.append(("\(item.name) ground truth", item.gt)) }
        // One row per arm (plus input and ground truth), one column per sample.
        try Sheet.make(sheet, columns: shown.count, to: bench.out.appendingPathComponent("erase-sheet.png"))
    }
}

/// Erase scores against the object-absent ground truth (0–255 scale where not a ratio).
enum EraseScore {
    static func score(output: URL, item: Suites.GateItem, mask: URL) throws -> [String: Double] {
        let gt = try Raster(contentsOf: item.gt)
        let (w, h) = (gt.width, gt.height)
        let out = try Raster(contentsOf: output).resized(w, h), src = try Raster(contentsOf: item.src).resized(w, h)
        let hole = try BinaryMask.output(mask, width: w, height: h)
        let obj = try BinaryMask.output(item.obj, width: w, height: h)
        let objd = try BinaryMask.output(item.objd, width: w, height: h)
        var m: [String: Double] = ["psnr_hole": psnr(out, gt, where: hole.on)]
        // The region's box (the object's dilated box grown 4.5%, the gate's prompt box): the fill and its surroundings.
        if let box = box(objd, grow: Int(0.045 * Double(w))) {
            let a = out.cropped(x: box.x, y: box.y, width: box.w, height: box.h), b = gt.cropped(x: box.x, y: box.y, width: box.w, height: box.h)
            m["psnr_box"] = Score.psnr(a, b)
            m["ssim_box"] = Score.ssim(a, b)
        }
        if let effURL = item.eff {
            let eff = try BinaryMask.output(effURL, width: w, height: h)
            m["psnr_eff"] = psnr(out, gt, where: eff.on)
            // The shadow and reflection band: effect region minus the dilated object.
            m["ring"] = mae(out, gt, where: zip(eff.on, objd.on).map { $0 && !$1 })
        }
        // Left in place: inside the object's core the output stayed closer to the object than half-way to the truth.
        let moved = mae(out, src, where: obj.on), needed = mae(gt, src, where: obj.on)
        m["left"] = needed > 0 && moved < 0.5 * needed ? 1 : 0
        return m
    }

    static func psnr(_ a: Raster, _ b: Raster, where on: [Bool]) -> Double {
        let (ya, yb) = (a.luma, b.luma)
        var se = 0.0, n = 0
        for i in on.indices where on[i] { let d = ya[i] - yb[i]; se += d * d; n += 1 }
        return n == 0 || se == 0 ? 99 : 10 * log10(255 * 255 / (se / Double(n)))
    }

    static func mae(_ a: Raster, _ b: Raster, where on: [Bool]) -> Double {
        var total = 0, n = 0
        for i in on.indices where on[i] {
            for c in 0..<3 { total += abs(Int(a.rgba[i * 4 + c]) - Int(b.rgba[i * 4 + c])) }
            n += 1
        }
        return n == 0 ? 0 : Double(total) / Double(n * 3)
    }

    static func box(_ mask: BinaryMask, grow: Int) -> (x: Int, y: Int, w: Int, h: Int)? {
        var (x0, y0, x1, y1) = (mask.width, mask.height, -1, -1)
        for y in 0..<mask.height { for x in 0..<mask.width where mask.on[y * mask.width + x] {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 >= 0 else { return nil }
        let (bx0, by0) = (max(0, x0 - grow), max(0, y0 - grow))
        let (bx1, by1) = (min(mask.width - 1, x1 + grow), min(mask.height - 1, y1 + grow))
        // SSIM's 11×11 window needs room.
        guard bx1 - bx0 >= 16, by1 - by0 >= 16 else { return nil }
        return (bx0, by0, bx1 - bx0 + 1, by1 - by0 + 1)
    }
}

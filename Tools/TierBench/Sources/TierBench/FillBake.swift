import Foundation
import MESCore

/// The Generative Fill bake-off (AB-A-0173): each arm runs the same prompted fills, seamless fills, extends and removes
/// through the engine's own route (`image.fill` / `image.extend` with the model named), so the marker, guard,
/// harmonize and feather are identical. Cases come from `bench/fillbake/cases.json` (`build_cases.py`); scoring
/// (LPIPS, DISTS, PSNR, marker checks, sheets) happens afterwards in `score.py` from `results.jsonl`.
extension Suites {
    struct FillCases: Decodable {
        struct Fill: Decodable { let id: String; let image: String; let mask: String; let prompt: String }
        struct Seamless: Decodable { let id: String; let image: String; let mask: String }
        struct Extend: Decodable {
            struct Canvas: Decodable { let left, top, right, bottom: Int }
            let id: String; let image: String; let canvas: Canvas
        }
        struct Remove: Decodable { let id: String; let image: String; let mask: String }
        let fill: [Fill]
        let fill768: [Fill]
        let seamless: [Seamless]
        let extend: [Extend]
        let remove: [Remove]
    }

    func fillBake(cases file: URL, arms: [String], tasks: Set<String>, _ footprints: inout [String: Double]) async throws {
        let cases = try JSONDecoder().decode(FillCases.self, from: Data(contentsOf: file))
        let seed: JSONValue = 7
        for arm in arms {
            // Cold: the first job loads the arm (or reloads it after another arm evicted it).
            var cold = true
            func run(_ suite: String, _ op: String, _ item: String, _ inputs: [String: Bench.Input], _ params: [String: JSONValue]) async {
                await bench.run(suite: suite, operation: op, item: item, inputs: inputs, params: params, model: arm,
                                warm: !cold, folder: "fillbake/\(suite)/\(arm)")
                cold = false
            }
            if tasks.contains("fill") {
                for c in cases.fill {
                    await run("fill", "image.fill", c.id, ["image": .file(URL(fileURLWithPath: c.image)), "mask": .file(URL(fileURLWithPath: c.mask)),
                                                          "prompt": .text(c.prompt)], ["seed": seed])
                }
            }
            if tasks.contains("fill768") {
                for c in cases.fill768 {
                    await run("fill768", "image.fill", c.id, ["image": .file(URL(fileURLWithPath: c.image)), "mask": .file(URL(fileURLWithPath: c.mask)),
                                                             "prompt": .text(c.prompt)], ["seed": seed])
                }
            }
            if tasks.contains("seamless") {
                for c in cases.seamless {
                    await run("seamless", "image.fill", c.id, ["image": .file(URL(fileURLWithPath: c.image)), "mask": .file(URL(fileURLWithPath: c.mask))],
                              ["seed": seed])
                }
            }
            if tasks.contains("extend") {
                for c in cases.extend {
                    let canvas: JSONValue = ["left": .number(Double(c.canvas.left)), "top": .number(Double(c.canvas.top)),
                                             "right": .number(Double(c.canvas.right)), "bottom": .number(Double(c.canvas.bottom))]
                    await run("extend", "image.extend", c.id, ["image": .file(URL(fileURLWithPath: c.image))], ["canvas": canvas, "seed": seed])
                }
            }
            if tasks.contains("remove") {
                for c in cases.remove {
                    await run("remove", "image.fill", c.id, ["image": .file(URL(fileURLWithPath: c.image)), "mask": .file(URL(fileURLWithPath: c.mask))],
                              ["seed": seed])
                }
            }
            footprints[arm] = bench.footprintGB()
        }
    }
}

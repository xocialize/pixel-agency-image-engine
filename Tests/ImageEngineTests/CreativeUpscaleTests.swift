import CoreGraphics
import Foundation
import ImageServerModels
@testable import MESConformance
import MESCore
import MESEngineCore
@testable import PixelAgencyImageEngine
import Testing

// G-5 (AB-D-0126, AB-A-0162): the creative upscale, `image.upscale` with the extension `x-pixelagency.creative`.
// Realistic (creativity 0) is VOSR2; Creative is the precision base, Mage-Flow-Edit-Turbo over tiles from a partial
// start, a colour lock, then faces and certain text lines from the base.

@Suite("Creative upscale (G-5)", .serialized)
struct CreativeUpscaleTests {
    static func creative(_ values: [String: MESValue]) -> [String: MESValue] { [Creative.name: .object(values)] }

    @Test("image.upscale declares the extension when its editor and VOSR2 are here; the extension's schema")
    func descriptor() async throws {
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner()).descriptors()
        let up = try #require(ops.first { $0.operation == "image.upscale" })
        let ext = try #require(up.extensions?.first { $0.name == Creative.name })
        #expect(ext.schema["properties"]?["creativity"]?["maximum"] == 1 && ext.schema["additionalProperties"] == false)
        #expect(ops.filter { $0.operation != "image.upscale" }.allSatisfy { $0.extensions?.contains { $0.name == Creative.name } != true })
        let missing = FakeModels(FakeModels.catalog.filter { $0.id.rawValue != Creative.editor })
        let without = await ImageNormalizer(directory: missing, runner: FakeRunner()).descriptors()
        #expect(without.first { $0.operation == "image.upscale" }?.extensions == nil, "no editor, no creative upscale")
    }

    @Test("Creative: the precision base, Mage over one tile from σ 0.9 (the default), the instruction with the style, colour locked to the base")
    func oneTile() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.upscale", inputs: ["image": image(Fixtures.png(width: 64, height: 48))],
                params: ["scale": 2], extensions: Self.creative(["prompt": "film grain"])))
            let calls = runner.calls.withLock { $0.suffix(2) }
            #expect(calls.map(\.route.id.rawValue) == ["realplksr-upscale", Creative.editor])
            let edit = try #require(calls.last)
            #expect(edit.spec.params["initSigma"]?.doubleValue == 0.9)
            #expect(edit.spec.params["prompt"]?.stringValue == Creative.instruction("film grain")
                    && Creative.instruction("film grain").hasSuffix(" Style: film grain."))
            #expect(edit.width == 128 && edit.height == 128, "one tile, square, the target's size")
            let params = try #require(job.result?.effective["model_params"])
            #expect(params["editor"] == .string(Creative.editor) && params["base"] == "realplksr-upscale" && params["tiles"] == 1)
            let (output, data) = try await probe.output(job)
            #expect(output.width == 128 && output.height == 96, "exactly ×scale")
            // The fake base is flat grey and the fake editor flat green: the colour lock keeps the base's colour.
            let decoded = try DecodedImage(data)
            let p = decoded.pixel(64, 48)
            #expect(abs(Int(p[0]) - 128) <= 2 && abs(Int(p[1]) - 128) <= 2 && abs(Int(p[2]) - 128) <= 2, "\(p)")
        }
    }

    @Test("Creative over several tiles: each tile its own seed at the target size; creativity 1 is σ 0.95")
    func tiles() async throws {
        try await withEngine { probe, runner in
            let before = runner.calls.withLock { $0.count }
            let job = try await probe.succeed(JobRequest(
                operation: "image.upscale", inputs: ["image": image(Fixtures.png(width: 300, height: 200))],
                params: ["scale": 4], extensions: Self.creative(["creativity": 1, "protect_faces": false, "protect_text": false])))
            let edits = runner.calls.withLock { Array($0[before...]) }.filter { $0.route.id.rawValue == Creative.editor }
            #expect(edits.count == 2, "1200 wide in two tiles, 800 tall in one")
            #expect(edits.allSatisfy { $0.spec.params["initSigma"]?.doubleValue == 0.95 && $0.width == 800 && $0.height == 800 })
            #expect(Set(edits.map(\.seed)).count == 2)
            let (output, _) = try await probe.output(job)
            #expect(output.width == 1200 && output.height == 800)
        }
    }

    @Test("An editor with the tiles mode gets every tile in one call (one conditioner load), tile k at the job's seed + k, as a call per tile has them")
    func oneCallForAllTiles() async throws {
        let request = JobRequest(operation: "image.upscale", inputs: ["image": image(Fixtures.png(width: 300, height: 200))],
                                 params: ["scale": 4], extensions: Self.creative(["protect_faces": false, "protect_text": false]))
        for tiled in [false, true] {
            try await withEngine(tiled: tiled ? [Creative.editor] : []) { probe, runner in
                let job = try await probe.succeed(request)
                let seed = try #require(job.result?.provenance.seed.map(UInt64.init))
                let edits = runner.calls.withLock { $0 }.filter { $0.route.id.rawValue == Creative.editor }
                if tiled {
                    #expect(edits.count == 1, "one call for both tiles")
                    let call = try #require(edits.first)
                    #expect(call.spec.mode == Creative.tilesMode && call.inputs["images"]?.count == 2)
                    #expect(call.seed == seed && call.width == 800 && call.height == 800 && call.spec.params["initSigma"]?.doubleValue == 0.9)
                } else {
                    #expect(edits.map(\.seed) == [seed, seed + 1] && edits.allSatisfy { $0.spec.mode == nil })
                }
                let params = try #require(job.result?.effective["model_params"])
                #expect(params["tiles"] == 2 && params["editor_calls"] == .number(tiled ? 1 : 2))
                // Each band lands where its tile came from: the fake paints band k from seed + k, so after the colour
                // lock the tiles' own areas differ exactly as their seeds do — the same in both paths.
                let (output, data) = try await probe.output(job)
                #expect(output.width == 1200 && output.height == 800)
                let decoded = try DecodedImage(data)
                #expect(decoded.pixel(100, 400) == decoded.pixel(150, 400) && decoded.pixel(1100, 400) == decoded.pixel(1050, 400))
            }
        }
    }

    @Test("Gated by memory: where the models' peak is over this Mac's budget the extension isn't offered and the summary says why; a tight Mac warns")
    func memoryGate() async throws {
        let gb: UInt64 = 1_000_000_000
        func fit(_ peak: UInt64, _ budget: UInt64) -> MemoryFit {
            MemoryFit(fits: true, additionalBytes: 0, availableBytes: 0, message: "", projectedPeakBytes: peak, budgetBytes: budget)
        }
        // 16 GB Mac: Mage-Flow's conditioner and DiT take turns (~9.7 GB) under a ~12.7 GB budget; VOSR2 ~7 GB.
        #expect(Creative.unavailableReason(editor: fit(97 * gb / 10, 127 * gb / 10), realistic: fit(7 * gb, 127 * gb / 10)) == nil)
        #expect(Creative.unavailableReason(editor: nil, realistic: nil) == nil, "unknown is offered")
        let small = try #require(Creative.unavailableReason(editor: fit(97 * gb / 10, 59 * gb / 10), realistic: fit(7 * gb, 59 * gb / 10)))
        #expect(small.contains("Mage-Flow-Edit-Turbo") && small.contains("9.7 GB") && small.contains("5.9 GB"), "\(small)")

        let options = ImageNormalizer.Options(creativeUnavailable: small)
        let ops = await ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), options: options).descriptors()
        let up = try #require(ops.first { $0.operation == "image.upscale" })
        #expect(up.extensions == nil && up.summary?.contains(small) == true)

        let tight = MemoryFit(fits: false, additionalBytes: 9 * gb, availableBytes: 3 * gb, message: "3.0 GB available")
        try await withEngine(runner: FakeRunner(fit: tight)) { probe, _ in
            let job = try await probe.succeed(JobRequest(operation: "image.upscale", inputs: ["image": image()], params: ["scale": 2],
                                                         extensions: Self.creative([:])))
            #expect(job.warnings.contains { $0.code == "memory_tight" })
        }
    }

    @Test("Realistic (creativity 0) is VOSR2; a prompt there is ignored and says so")
    func realistic() async throws {
        try await withEngine { probe, runner in
            let job = try await probe.succeed(JobRequest(
                operation: "image.upscale", inputs: ["image": image()], params: ["scale": 2],
                extensions: Self.creative(["creativity": 0, "prompt": "film grain"])))
            #expect(runner.calls.withLock { $0.last?.route.id.rawValue } == Creative.realistic)
            #expect(job.warnings.contains { $0.code == "prompt_ignored" })
            #expect(job.result?.effective["model_params"]?["model"] == .string(Creative.realistic))
        }
    }

    @Test("Refused at submit: the creative upscale at 16 bits, and values outside the extension's schema")
    func refusals() async throws {
        try await withEngine(sixteenBit: ["realplksr-upscale"]) { probe, _ in
            func submit(_ params: [String: MESValue], _ values: [String: MESValue]) async throws -> (Int, String?) {
                let reply = try await probe.wire.json("POST", "jobs", JobRequest(
                    operation: "image.upscale", inputs: ["image": image()], params: params, extensions: Self.creative(values)))
                return (reply.status, reply.errorCode)
            }
            let deep = try await submit(["scale": 2, "output": ["bit_depth": 16]], ["creativity": 0.5])
            #expect(deep.0 == 422 && deep.1 == "unsupported_parameter")
            #expect(try await submit(["scale": 2], ["creativity": 2]).0 == 422)
            #expect(try await submit(["scale": 2], ["mood": "dreamy"]).0 == 422)
        }
    }

    @Test("The pieces: tile layout covers each axis with ~128 px overlaps; ramps sum to one; masks; the colour lock; altered words")
    func pieces() throws {
        let (starts, tile) = Creative.layout(2400, maxTile: 1024, overlap: 128)
        #expect(starts.first == 0 && starts.last! + tile == 2400 && tile <= 1024 && tile % 16 == 0)
        let overlap = tile - (starts[1] - starts[0])
        #expect(overlap >= 128 && overlap < 200, "\(overlap)")
        for p in 0..<overlap {
            let sum = Creative.ramp(tile - overlap + p, length: tile, low: false, high: true, overlap: overlap)
                + Creative.ramp(p, length: tile, low: true, high: false, overlap: overlap)
            #expect(abs(sum - 1) < 1e-5)
        }
        #expect(Creative.layout(900, maxTile: 1024, overlap: 128) == ([0], 900))

        let faces = Creative.faceMask([CGRect(x: 40, y: 40, width: 20, height: 20)], width: 100, height: 100)
        #expect(faces[50 * 100 + 50] == 1 && faces[5 * 100 + 5] == 0)
        let lines = Creative.lineMask([.init(text: "OPEN", box: CGRect(x: 20, y: 40, width: 60, height: 10), certain: true),
                                       .init(text: "maybe", box: CGRect(x: 20, y: 80, width: 60, height: 10), certain: false)],
                                      width: 100, height: 100)
        #expect(lines[45 * 100 + 50] == 1 && lines[85 * 100 + 50] == 0, "only certain lines are kept")

        var c = Pixels(width: 32, height: 32), b = Pixels(width: 32, height: 32)
        for i in 0..<(32 * 32) { c.rgba[i * 4 + 1] = 200; c.rgba[i * 4 + 3] = 255; b.rgba[i * 4] = 90; b.rgba[i * 4 + 3] = 255 }
        let locked = Creative.colourLock(c, base: b, sigma: 3)
        #expect(Array(locked.rgba[528..<531]) == [90, 0, 0], "flat in, the base's colour out")

        #expect(Creative.normalized("Jazz  Night 28") == Creative.normalized("JAZZ NIGHT 28"))
        #expect(Creative.normalized("JAZZ NIGHT 28") != Creative.normalized("JAZZ NIGHT 30"))
        #expect(Creative.Request(prompt: "", creativity: 0.5).initSigma == 0.9)
    }
}

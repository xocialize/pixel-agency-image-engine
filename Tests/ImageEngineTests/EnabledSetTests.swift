import Foundation
import ImageServerAPI
import ImageServerModels
import MESCore
import MESEngineCore
@testable import PixelAgencyImageEngine
import Testing

// The engine app's Models section (ENG-4, ENG-9): the operator's enabled set decides what's offered, and the engine's
// own default choice moves to the next model that's on.

@Suite("The enabled set: what the engine app's Models section turns on and off")
struct EnabledSetTests {
    @Test("A model switched off isn't offered and the default moves on; an opt-in model switched on is offered named-only")
    func enabledSet() async throws {
        let enablement = ModelEnablement(file: nil)
        let engine = ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), options: .init(enablement: enablement))
        var generate = try #require(await engine.descriptors().first { $0.operation == "image.generate" })
        #expect(generate.models.first?.id == "z-image-turbo" && generate.models.first?.isDefault == true)
        #expect(!generate.models.contains { $0.id == "qwen-image-2.1" }, "opt-in models start off")

        try enablement.set("z-image-turbo", enabled: false, optIn: false)
        try enablement.set("qwen-image-2.1", enabled: true, optIn: true)
        generate = try #require(await engine.descriptors().first { $0.operation == "image.generate" })
        #expect(!generate.models.contains { $0.id == "z-image-turbo" })
        let next = try #require(generate.models.first { $0.isDefault == true }, "another model is the default")
        #expect(next.namedOnly != true && next.id != "qwen-image-2.1")
        let qwen = try #require(generate.models.first { $0.id == "qwen-image-2.1" })
        #expect(qwen.namedOnly == true && qwen.isDefault == nil && qwen.license.acceptedRequired == true)
        #expect(!generate.models.contains { $0.id == "flux-3-klein" }, "only the opt-in models switched on")

        // The model cards' view: every usable model, on or off.
        let catalog = try #require(await engine.catalogDescriptors().first { $0.operation == "image.generate" })
        #expect(Set(["z-image-turbo", "qwen-image-2.1", "flux-3-klein"]).isSubset(of: Set(catalog.models.map(\.id))))
    }

    @Test("Switching off an operation's only model drops the operation")
    func lastModel() async throws {
        let enablement = ModelEnablement(file: nil)
        let engine = ImageNormalizer(directory: FakeModels(), runner: FakeRunner(), options: .init(enablement: enablement))
        #expect(await engine.descriptors().contains { $0.operation == "image.matte" })
        try enablement.set("birefnet-matte", enabled: false, optIn: false)
        #expect(await engine.descriptors().contains { $0.operation == "image.matte" } == false)
    }

    @Test("Without an enabled set the headless engine is unchanged: research models only with --allow-research")
    func headless() async throws {
        let engine = ImageNormalizer(directory: FakeModels(), runner: FakeRunner())
        let generate = try #require(await engine.descriptors().first { $0.operation == "image.generate" })
        #expect(generate.models.contains { $0.id == "z-image-turbo" } && !generate.models.contains { $0.id == "qwen-image-2.1" })
    }

    @Test("Download now loads a model; the operator releases it from memory")
    func prefetchAndUnload() async throws {
        let runner = FakeRunner()
        let engine = ImageNormalizer(directory: FakeModels(), runner: runner)
        try await engine.prefetch("lama-inpaint") { _ in }
        #expect(await runner.residentPackages().contains("fake.lama-inpaint"))
        #expect(await engine.unload("lama-inpaint"))
        #expect(await !runner.residentPackages().contains("fake.lama-inpaint"))
        #expect(await engine.unload("lama-inpaint") == false, "nothing to release")
        await #expect(throws: MESError.self) { try await engine.prefetch("no-such-model") { _ in } }
    }
}

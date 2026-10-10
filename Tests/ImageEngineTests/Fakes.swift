import CoreGraphics
import Foundation
import ImageIO
import ImageServerAPI
import ImageServerModels
import MLXToolKit
import Synchronization
import UniformTypeIdentifiers

/// A catalog without MLX: the models the engine would register, with their licences and envelopes.
actor FakeModels: ImageModelDirectory, ModelRouter {
    var infos: [ModelInfo]

    init(_ infos: [ModelInfo] = FakeModels.catalog) { self.infos = infos }

    func models() -> [ModelInfo] { infos }
    func model(_ id: ModelID) -> ModelInfo? { infos.first { $0.id == id } }
    func capabilities() -> [Capability] { Array(Set(infos.flatMap(\.capabilities))).sorted { $0.rawValue < $1.rawValue } }

    func route(_ capability: Capability, model: ModelID?) throws -> RoutedModel {
        let info: ModelInfo?
        if let model {
            info = infos.first { $0.id == model && $0.capabilities.contains(capability) }
        } else {
            info = infos.first { $0.capabilities.contains(capability) && $0.isDefaultRoutable }
        }
        guard let info else {
            throw APIError.unprocessable("unknown_model", "No model \(model?.rawValue ?? "(default)") for \(capability.rawValue).", param: "model")
        }
        return RoutedModel(id: info.id, packageID: "fake.\(info.id.rawValue)", capability: capability, displayName: info.displayName,
                           license: info.license, envelope: info.envelope, defaults: info.defaults, sourceRepo: info.sourceRepo,
                           revision: info.revision, footprintBytes: info.footprintBytes)
    }

    func modelID(forPackage packageID: String) -> ModelID? {
        packageID.hasPrefix("fake.") ? ModelID(String(packageID.dropFirst(5))) : nil
    }

    func registeredModels() -> [RegisteredModel] {
        infos.map { RegisteredModel(id: $0.id, packageID: "fake.\($0.id.rawValue)", capabilities: $0.capabilities, footprintBytes: $0.footprintBytes) }
    }

    static let apache = LicenseStamp(licenseClass: .permissive, weightLicenses: ["Apache-2.0"], portCodeLicense: "MIT")
    static let research = LicenseStamp(licenseClass: .restricted, weightLicenses: ["LicenseRef-Qwen-Research"], portCodeLicense: "MIT",
                                       advisories: ["Research use only."])

    static func model(_ id: String, _ capabilities: [Capability], license: LicenseStamp = apache, maturity: Maturity = .prod,
                      guidance: Double? = nil, maxPixels: Int = 2_100_000, maxInputs: Int = 1, gb: Double = 2) -> ModelInfo {
        ModelInfo(id: ModelID(id), displayName: id.capitalized, summary: "", capabilities: capabilities, defaultFor: [],
                  maturity: maturity, license: license, sourceRepo: "example/\(id)", revision: "main",
                  envelope: SizeEnvelope(maxPixels: maxPixels, multipleOf: 16, maxInputs: maxInputs),
                  defaults: GenerationDefaults(steps: 4, guidance: guidance, width: 1024, height: 1024),
                  footprintBytes: UInt64(gb * 1_073_741_824), state: ModelState(downloaded: true, resident: false))
    }

    static let catalog: [ModelInfo] = [
        model("z-image-turbo", [.textToImage], guidance: 1, gb: 12),
        model("klein-4b", [.textToImage, .imageEdit], guidance: 4, maxInputs: 4, gb: 8),
        model("z-image", [.textToImage], guidance: 4, gb: 12),
        model("qwen-image-2.1", [.textToImage], license: research, guidance: 1, gb: 30),
        model("boogu", [.imageEdit], maturity: .wip, guidance: 4, gb: 20),
        model("lama-inpaint", [.imageInpaint]),
        model("realplksr-upscale", [.imageUpscale]),
        model("nerve-upscale", [.imageUpscale]),
        model("heart-upscale", [.imageUpscale]),
        model("seedvr2-upscale", [.imageUpscale]),
        model("nafnet-restore", [.imageRestore]),
        model("scunet-denoise", [.imageRestore]),
        model("defect-detect", [.defectDetect]),
        model("cidnet-relight", [.imageRelight]),
        model("ddcolor-colorize", [.imageColorize]),
        model("birefnet-matte", [.matting]),
        model("edgetam-segment", [.promptSegment]),
        model("sam21-segment", [.promptSegment]),
        model("mage-vl", [.imageAnalysis]),
        model("siglip2-quality", [.imageQualityScore]),
    ]
}

/// A runner that answers like the real packages do (sizes a little off, alpha dropped, mattes at their own
/// resolution), so the normalizer's rules are what make the outputs right.
final class FakeRunner: ModelRunner {
    let calls = Mutex<[RunWork]>([])
    let resident = Mutex<Set<String>>([])
    let delay: Duration
    /// An edit model that returns its input, keeping the marker (as Qwen-Image-Edit did on some R1b extends).
    let editKeepsMarker: Bool

    init(delay: Duration = .milliseconds(30), editKeepsMarker: Bool = false) { self.delay = delay; self.editKeepsMarker = editKeepsMarker }

    func residentPackages() async -> Set<String> { resident.withLock { $0 } }

    func prepare(_ route: RoutedModel, progress: @escaping @Sendable (JobProgress) -> Void) async throws {
        progress(JobProgress(phase: "loading", fraction: 0.5))
        resident.withLock { _ = $0.insert(route.packageID) }   // like the runtime: loaded models stay until evicted
    }

    func run(_ work: RunWork, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> ImageServerModels.RunOutput {
        calls.withLock { $0.append(work) }
        for step in 1...2 {
            try await Task.sleep(for: delay)
            progress(JobProgress(phase: "denoise", fraction: Double(step) / 2, step: step, totalSteps: 2))
        }
        let first = work.inputs["image"]?.first ?? work.inputs["images"]?.first
        let size = first.flatMap { Self.size(of: $0) }
        switch work.route.capability {
        case .textToImage:
            let w = work.width ?? 1024, h = work.height ?? 1024
            let shade = CGFloat(work.seed % 251) / 255
            return .image(Self.solid(w, h, red: shade, green: 0.5, blue: 1 - shade))
        case .imageEdit where editKeepsMarker:
            return .image(first!)
        case .imageEdit:
            let (w, h) = size ?? (64, 64)
            return .image(Self.solid(max(16, w / 2), max(16, h / 2), red: 0.2, green: 0.8, blue: 0.2))   // models pick their own size
        case .imageInpaint:
            let (w, h) = size ?? (64, 64)
            return .image(Self.solid(w, h, red: 1, green: 0, blue: 1))
        case .imageUpscale:
            let (w, h) = size ?? (64, 64)
            let scale = work.spec.params["scale"]?.intValue ?? 4
            return .image(Self.solid(w * scale - 2, h * scale - 2, red: 0.5, green: 0.5, blue: 0.5))   // off by a little
        case .imageRestore, .imageRelight, .imageColorize:
            let (w, h) = size ?? (64, 64)
            return .image(Self.solid(w, h, red: 0.3, green: 0.3, blue: 0.3))
        case .matting, .promptSegment, .defectDetect:
            let (w, h) = size ?? (64, 64)
            return .matte(Self.greyMatte(max(8, w / 2), max(8, h / 2)), score: 0.9)
        case .imageAnalysis:
            return .text(#"Sure! {"caption": "A test card.", "alt_text": "A test card.", "tags": ["Test", "Card"]}"#)
        case .imageQualityScore:
            return .score(1.4, subscores: [:])
        default:
            throw APIError.unprocessable("unsupported_capability", "The fake doesn't serve \(work.route.capability.rawValue).")
        }
    }

    func evict(packageID: String) async { resident.withLock { _ = $0.remove(packageID) } }
    func machineFit(_ route: RoutedModel) async -> MemoryFit? { nil }

    static func size(of image: MLXToolKit.Image) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (cg.width, cg.height)
    }

    static func solid(_ w: Int, _ h: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> MLXToolKit.Image {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return MLXToolKit.Image(format: .png, data: png(ctx.makeImage()!), width: w, height: h)
    }

    static func greyMatte(_ w: Int, _ h: Int) -> Matte {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        return Matte(format: .png, data: png(ctx.makeImage()!), width: w, height: h, kind: .softAlpha)
    }

    static func png(_ image: CGImage) -> Data {
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

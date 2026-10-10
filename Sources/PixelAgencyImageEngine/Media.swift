import CoreGraphics
import Foundation
import ImageIO
import MLXToolKit
import UniformTypeIdentifiers

/// Pixels the normalizer works in: sRGB, 8 bits per channel, premultiplied RGBA, top row first. Every rule the Image
/// profile states about pixels (masks, compositing, sizes, alpha) is applied on these, whatever the model returns.
struct Pixels: Sendable {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, rgba: [UInt8]? = nil) {
        self.width = width; self.height = height
        self.rgba = rgba ?? [UInt8](repeating: 0, count: width * height * 4)
    }

    /// Draws `image` into a new buffer of `width` × `height` (its own size by default), converting to sRGB.
    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let (w, h) = (width ?? image.width, height ?? image.height)
        self.init(width: w, height: h)
        rgba.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    var cgImage: CGImage {
        var copy = rgba
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    /// Whether any pixel is less than fully opaque.
    var hasTransparency: Bool { stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 255 } }

    func resized(_ w: Int, _ h: Int) -> Pixels { w == width && h == height ? self : Pixels(cgImage, width: w, height: h) }
}

/// An 8-bit grey mask, top row first. White (255) = change.
struct Mask: Sendable {
    let width: Int
    let height: Int
    var values: [UInt8]

    init(width: Int, height: Int, values: [UInt8]? = nil) {
        self.width = width; self.height = height
        self.values = values ?? [UInt8](repeating: 0, count: width * height)
    }

    /// A mask from any image (its luminance), resampled to `width` × `height`.
    init(_ image: CGImage, width: Int, height: Int) {
        self.init(width: width, height: height)
        values.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Every pixel the mask lets change, at full strength: what a model is asked to repaint. The composite still
    /// blends by the mask itself, so black pixels stay untouched (Image §1.7) and grey ones blend (§1.6); but a
    /// model shown only the mask's solid core paints the soft fringe back in from what it can still see.
    var hole: Mask { Mask(width: width, height: height, values: values.map { $0 > 0 ? 255 : 0 }) }

    var cgImage: CGImage {
        var copy = values
        return copy.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.makeImage()!
        }
    }
}

enum Media {
    struct Loaded {
        var pixels: Pixels
        /// The file carried a profile other than sRGB and was converted (Image §1.3: warn `color_converted`).
        var colorConverted: Bool
    }

    /// Loads an input upright (EXIF orientation applied, Image §1.4) and in sRGB (§1.3).
    static func load(_ url: URL) throws -> Loaded {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            throw NormalizerError.input("\(url.lastPathComponent) isn't a readable image.")
        }
        let upright = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h), kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        guard let image = upright else { throw NormalizerError.input("\(url.lastPathComponent) can't be decoded.") }
        let name = image.colorSpace?.name as String?
        let converted = image.colorSpace?.model == .rgb && name != (CGColorSpace.sRGB as String)
            && !(props[kCGImagePropertyProfileName] as? String ?? "sRGB").localizedCaseInsensitiveContains("sRGB")
        return Loaded(pixels: Pixels(image), colorConverted: converted)
    }

    /// Loads a mask as 8-bit grey at `width` × `height`; says whether it had to be resampled (warn `mask_resampled`).
    static func loadMask(_ url: URL, width: Int, height: Int) throws -> (Mask, resampled: Bool) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NormalizerError.input("The mask isn't a readable image.")
        }
        return (Mask(image, width: width, height: height), image.width != width || image.height != height)
    }

    /// A model's image output as pixels.
    static func pixels(_ image: MLXToolKit.Image) throws -> Pixels {
        switch image.format {
        case .png, .jpeg:
            guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw NormalizerError.engine("The model returned an unreadable image.")
            }
            return Pixels(cg)
        case .rawBGRA8:
            guard let w = image.width, let h = image.height else { throw NormalizerError.engine("A raw image without a size.") }
            let row = image.bytesPerRow ?? w * 4
            var copy = image.data
            let cg = copy.withUnsafeMutableBytes { buffer in
                CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: row, space: Pixels.sRGB,
                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!.makeImage()!
            }
            return Pixels(cg)
        }
    }

    /// A model's matte output as a mask at `width` × `height`.
    static func mask(_ matte: Matte, width: Int, height: Int) throws -> Mask {
        guard let source = CGImageSourceCreateWithData(matte.data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NormalizerError.engine("The model returned an unreadable matte.")
        }
        return Mask(cg, width: width, height: height)
    }

    /// Pixels as the PNG a model package takes.
    static func modelImage(_ pixels: Pixels) -> MLXToolKit.Image {
        MLXToolKit.Image(format: .png, data: encode(pixels.cgImage, mediaType: "image/png"), width: pixels.width, height: pixels.height)
    }

    static func modelImage(_ mask: Mask) -> MLXToolKit.Image {
        MLXToolKit.Image(format: .png, data: encode(mask.cgImage, mediaType: "image/png"), width: mask.width, height: mask.height)
    }

    /// Encodes as PNG or JPEG, tagged sRGB (Image §1.3), upright with no orientation flag (§1.4).
    static func encode(_ image: CGImage, mediaType: String) -> Data {
        let type: UTType = mediaType == "image/jpeg" ? .jpeg : .png
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.92 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// The model's result over the original where the mask is white, blended where grey, and the original's exact
    /// pixels where black (Image §1.7: untouched pixels stay untouched).
    static func composite(result: Pixels, over original: Pixels, mask: Mask) -> Pixels {
        let r = result.resized(original.width, original.height)
        var out = original
        for i in 0..<(original.width * original.height) {
            let m = Int(mask.values[i])
            guard m > 0 else { continue }
            for c in 0..<4 {
                let o = Int(original.rgba[i * 4 + c]), n = Int(r.rgba[i * 4 + c])
                out.rgba[i * 4 + c] = UInt8((n * m + o * (255 - m) + 127) / 255)
            }
        }
        return out
    }

    /// Puts the input's alpha back on a model output that lost it (Image §1.5: warn `alpha_reapplied`).
    static func reapplyAlpha(_ output: Pixels, from input: Pixels) -> Pixels {
        let alpha = input.resized(output.width, output.height)
        var out = output
        for i in 0..<(output.width * output.height) {
            let a = Int(alpha.rgba[i * 4 + 3])
            guard a < 255 else { continue }
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt8((Int(output.rgba[i * 4 + c]) * a + 127) / 255) }
            out.rgba[i * 4 + 3] = UInt8(a)
        }
        return out
    }

    /// The image on a larger canvas for `image.extend` (IMG-5): the original at (`left`, `top`), the new area filled
    /// with the nearest edge pixels as a starting point, and a mask that is white exactly over the new area.
    static func pad(_ image: Pixels, left: Int, top: Int, right: Int, bottom: Int) -> (Pixels, Mask) {
        let w = image.width + left + right, h = image.height + top + bottom
        var canvas = Pixels(width: w, height: h)
        var mask = Mask(width: w, height: h)
        for y in 0..<h {
            let sy = min(max(y - top, 0), image.height - 1)
            for x in 0..<w {
                let sx = min(max(x - left, 0), image.width - 1)
                let inside = x >= left && x < left + image.width && y >= top && y < top + image.height
                let s = (sy * image.width + sx) * 4, d = (y * w + x) * 4
                for c in 0..<4 { canvas.rgba[d + c] = image.rgba[s + c] }
                if !inside { mask.values[y * w + x] = 255 }
            }
        }
        return (canvas, mask)
    }

    /// `image` with the mask's non-black area painted flat magenta: how an edit model is shown where to paint. Its
    /// instruction then says "replace the bright magenta area with …", the phrasing edit models follow reliably.
    static let marker: [UInt8] = [255, 0, 255, 255]
    static func mark(_ image: Pixels, region: Mask) -> Pixels {
        var out = image
        for i in 0..<(image.width * image.height) where region.values[i] > 0 {
            for c in 0..<4 { out.rgba[i * 4 + c] = marker[c] }
        }
        return out
    }

    /// Makes a generative result meet the original without a seam, leaving the original untouched.
    ///
    /// An edit model re-renders the whole picture, so its painted region continues *its* version of the rest, not the
    /// original, which differs a little in tone. Compositing the original back then leaves a visible seam. This
    /// measures `original − result` outside the region, spreads it smoothly into the region (normalized
    /// convolution on a coarse grid: an average of the nearby differences that fades with distance), and adds it to
    /// the result. Where the model already matches the original (LaMa composites itself), it changes nothing.
    static func harmonize(_ result: Pixels, toward original: Pixels, region: Mask) -> Pixels {
        let (w, h) = (original.width, original.height)
        let cell = max(1, max(w, h) / 256)
        let (gw, gh) = ((w + cell - 1) / cell, (h + cell - 1) / cell)
        var diff = [Float](repeating: 0, count: gw * gh * 3), weight = [Float](repeating: 0, count: gw * gh)
        for y in 0..<h {
            for x in 0..<w where region.values[y * w + x] == 0 {
                let g = (y / cell) * gw + x / cell, i = (y * w + x) * 4
                weight[g] += 1
                for c in 0..<3 { diff[g * 3 + c] += Float(original.rgba[i + c]) - Float(result.rgba[i + c]) }
            }
        }
        let sigma = max(2, Float(max(gw, gh)) / 40)                     // ~2.5% of the long side
        blur(&weight, gw, gh, channels: 1, sigma: sigma)
        blur(&diff, gw, gh, channels: 3, sigma: sigma)
        let floor = Float(cell * cell) / 2                              // half a cell's support: fades beyond the seam
        var out = result
        for y in 0..<h {
            for x in 0..<w where region.values[y * w + x] > 0 {
                // Bilinear in the grid, at the pixel's centre.
                let gx = min(Float(gw - 1), max(0, (Float(x) + 0.5) / Float(cell) - 0.5))
                let gy = min(Float(gh - 1), max(0, (Float(y) + 0.5) / Float(cell) - 0.5))
                let (x0, y0) = (Int(gx), Int(gy)), (x1, y1) = (min(gw - 1, Int(gx) + 1), min(gh - 1, Int(gy) + 1))
                let (fx, fy) = (gx - Float(x0), gy - Float(y0))
                func at(_ a: [Float], _ gx: Int, _ gy: Int, _ c: Int, _ n: Int) -> Float { a[(gy * gw + gx) * n + c] }
                func lerp(_ a: [Float], _ c: Int, _ n: Int) -> Float {
                    let top = at(a, x0, y0, c, n) * (1 - fx) + at(a, x1, y0, c, n) * fx
                    let bottom = at(a, x0, y1, c, n) * (1 - fx) + at(a, x1, y1, c, n) * fx
                    return top * (1 - fy) + bottom * fy
                }
                let support = max(lerp(weight, 0, 1), floor)
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let v = Float(result.rgba[i + c]) + lerp(diff, c, 3) / support
                    out.rgba[i + c] = UInt8(min(Float(result.rgba[i + 3]), max(0, v.rounded())))   // premultiplied
                }
            }
        }
        return out
    }

    /// A separable Gaussian blur in place, over `channels` interleaved planes.
    static func blur(_ a: inout [Float], _ w: Int, _ h: Int, channels n: Int, sigma: Float) {
        let r = Int((sigma * 3).rounded(.up))
        let raw = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = raw.reduce(0, +)
        let kernel = raw.map { $0 / total }
        var tmp = a
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<n {
                    var s: Float = 0
                    for k in -r...r { let xx = min(w - 1, max(0, x + k)); s += a[(y * w + xx) * n + c] * kernel[k + r] }
                    tmp[(y * w + x) * n + c] = s
                }
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                for c in 0..<n {
                    var s: Float = 0
                    for k in -r...r { let yy = min(h - 1, max(0, y + k)); s += tmp[(yy * w + x) * n + c] * kernel[k + r] }
                    a[(y * w + x) * n + c] = s
                }
            }
        }
    }

    /// The part of `region` within `width` pixels of the rest of the picture: the strip on the new side of a seam.
    static func seamBand(of region: Mask, width band: Int) -> Mask {
        let (w, h) = (region.width, region.height)
        // Dilate the kept area (region == 0) by `band`, separably, with running counts; keep what lands in the region.
        var rows = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            var prefix = [Int](repeating: 0, count: w + 1)
            for x in 0..<w { prefix[x + 1] = prefix[x] + (region.values[y * w + x] == 0 ? 1 : 0) }
            for x in 0..<w where prefix[min(w, x + band + 1)] - prefix[max(0, x - band)] > 0 { rows[y * w + x] = 1 }
        }
        var out = Mask(width: w, height: h)
        for x in 0..<w {
            var prefix = [Int](repeating: 0, count: h + 1)
            for y in 0..<h { prefix[y + 1] = prefix[y] + Int(rows[y * w + x]) }
            for y in 0..<h where region.values[y * w + x] > 0 && prefix[min(h, y + band + 1)] - prefix[max(0, y - band)] > 0 {
                out.values[y * w + x] = 255
            }
        }
        return out
    }

    /// The image with the matte as its alpha (the `extract` output of `image.matte`).
    static func extract(_ image: Pixels, alpha: Mask) -> Pixels {
        var out = image
        for i in 0..<(image.width * image.height) {
            let a = Int(alpha.values[i])
            for c in 0..<3 { out.rgba[i * 4 + c] = UInt8((Int(image.rgba[i * 4 + c]) * a + 127) / 255) }
            out.rgba[i * 4 + 3] = UInt8((Int(image.rgba[i * 4 + 3]) * a + 127) / 255)
        }
        return out
    }
}

/// Failures the normalizer reports (mapped to MES errors by the engine).
enum NormalizerError: Error, CustomStringConvertible {
    case input(String)
    case engine(String)
    var description: String {
        switch self {
        case .input(let m), .engine(let m): m
        }
    }
}

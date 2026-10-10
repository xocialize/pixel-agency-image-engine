import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An 8-bit RGBA raster (sRGB, top row first), for scoring outputs against ground truth.
struct Raster {
    let width: Int
    let height: Int
    var rgba: [UInt8]

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }

    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) {
        let (w, h) = (width ?? image.width, height ?? image.height)
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.init(width: w, height: h, rgba: buffer)
    }

    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BenchError("can't read \(url.lastPathComponent)") }
        self.init(image)
    }

    var cgImage: CGImage {
        var copy = rgba
        return copy.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }
    }

    func resized(_ w: Int, _ h: Int) -> Raster { Raster(cgImage, width: w, height: h) }

    func cropped(x: Int, y: Int, width w: Int, height h: Int) -> Raster {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for row in 0..<h {
            let src = ((y + row) * width + x) * 4, dst = row * w * 4
            out.replaceSubrange(dst..<(dst + w * 4), with: rgba[src..<(src + w * 4)])
        }
        return Raster(width: w, height: h, rgba: out)
    }

    /// The largest centred square, at most `side`.
    func centreSquare(_ side: Int) -> Raster {
        let s = min(side, width, height)
        return cropped(x: (width - s) / 2, y: (height - s) / 2, width: s, height: s)
    }

    func write(_ url: URL) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw BenchError("can't write \(url.lastPathComponent)") }
    }

    /// Luma (BT.601), the channel SR and restoration papers score.
    var luma: [Double] {
        (0..<(width * height)).map { i in
            0.299 * Double(rgba[i * 4]) + 0.587 * Double(rgba[i * 4 + 1]) + 0.114 * Double(rgba[i * 4 + 2])
        }
    }

    /// Additive Gaussian noise of `sigma` (0–255 scale), seeded, per channel.
    func noisy(sigma: Double, seed: UInt64) -> Raster {
        var rng = SplitMix(seed)
        var out = self
        for i in 0..<(width * height) {
            for c in 0..<3 {
                let v = Double(rgba[i * 4 + c]) + sigma * rng.gaussian()
                out.rgba[i * 4 + c] = UInt8(min(255, max(0, v.rounded())))
            }
        }
        return out
    }

    /// A separable Gaussian blur of `sigma` pixels.
    func blurred(sigma: Double) -> Raster {
        let r = Int((sigma * 3).rounded(.up))
        let k = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +)
        let kernel = k.map { $0 / sum }
        func pass(_ src: [UInt8], horizontal: Bool) -> [UInt8] {
            var dst = src
            for y in 0..<height {
                for x in 0..<width {
                    for c in 0..<3 {
                        var acc = 0.0
                        for t in -r...r {
                            let xx = horizontal ? min(width - 1, max(0, x + t)) : x
                            let yy = horizontal ? y : min(height - 1, max(0, y + t))
                            acc += Double(src[(yy * width + xx) * 4 + c]) * kernel[t + r]
                        }
                        dst[(y * width + x) * 4 + c] = UInt8(min(255, max(0, acc.rounded())))
                    }
                }
            }
            return dst
        }
        return Raster(width: width, height: height, rgba: pass(pass(rgba, horizontal: true), horizontal: false))
    }
}

/// A grey mask, 0/1 by threshold.
struct BinaryMask {
    let width: Int
    let height: Int
    var on: [Bool]

    /// GrabCut/Berkeley rules (isegm): channel 0, > 128 = object, 128 = ignore.
    static func groundTruth(_ url: URL) throws -> (BinaryMask, ignore: [Bool]) {
        let r = try Raster(contentsOf: url)
        let values = (0..<(r.width * r.height)).map { r.rgba[$0 * 4] }
        return (BinaryMask(width: r.width, height: r.height, on: values.map { $0 > 128 }), values.map { $0 == 128 })
    }

    static func output(_ url: URL, width: Int, height: Int) throws -> BinaryMask {
        let r = try Raster(contentsOf: url).resized(width, height)
        return BinaryMask(width: width, height: height, on: (0..<(width * height)).map { r.rgba[$0 * 4] >= 128 })
    }

    /// The interior point farthest from the boundary (the standard first click).
    var deepestPoint: (x: Int, y: Int) {
        // Two-pass chamfer distance to the nearest background pixel.
        let big = Int.max / 4
        var d = on.map { $0 ? big : 0 }
        for y in 0..<height { for x in 0..<width where d[y * width + x] > 0 {
            var v = d[y * width + x]
            if x > 0 { v = min(v, d[y * width + x - 1] + 1) }
            if y > 0 { v = min(v, d[(y - 1) * width + x] + 1) }
            d[y * width + x] = v
        } }
        for y in stride(from: height - 1, through: 0, by: -1) { for x in stride(from: width - 1, through: 0, by: -1) where d[y * width + x] > 0 {
            var v = d[y * width + x]
            if x < width - 1 { v = min(v, d[y * width + x + 1] + 1) }
            if y < height - 1 { v = min(v, d[(y + 1) * width + x] + 1) }
            d[y * width + x] = v
        } }
        let best = d.indices.max { d[$0] < d[$1] } ?? 0
        return (best % width, best / width)
    }
}

enum Score {
    /// PSNR on luma, `border` pixels cropped (the SR convention: border = scale).
    static func psnr(_ a: Raster, _ b: Raster, border: Int = 0) -> Double {
        let (ya, yb) = (a.luma, b.luma)
        var se = 0.0, n = 0
        for y in border..<(a.height - border) { for x in border..<(a.width - border) {
            let d = ya[y * a.width + x] - yb[y * a.width + x]; se += d * d; n += 1
        } }
        return se == 0 ? 99 : 10 * log10(255 * 255 / (se / Double(n)))
    }

    /// SSIM on luma: 11×11 Gaussian window, σ 1.5 (Wang et al.), `border` cropped.
    static func ssim(_ a: Raster, _ b: Raster, border: Int = 0) -> Double {
        let (w, h) = (a.width, a.height)
        let (x, y) = (a.luma, b.luma)
        let k = (-5...5).map { exp(-Double($0 * $0) / (2 * 1.5 * 1.5)) }
        let s = k.reduce(0, +)
        let g = k.map { $0 / s }
        func blur(_ v: [Double]) -> [Double] {
            var t = v, o = v
            for yy in 0..<h { for xx in 0..<w { var acc = 0.0
                for i in -5...5 { acc += v[yy * w + min(w - 1, max(0, xx + i))] * g[i + 5] }; t[yy * w + xx] = acc } }
            for yy in 0..<h { for xx in 0..<w { var acc = 0.0
                for i in -5...5 { acc += t[min(h - 1, max(0, yy + i)) * w + xx] * g[i + 5] }; o[yy * w + xx] = acc } }
            return o
        }
        let mx = blur(x), my = blur(y)
        let sxx = blur(zip(x, x).map { $0 * $1 }), syy = blur(zip(y, y).map { $0 * $1 }), sxy = blur(zip(x, y).map { $0 * $1 })
        let c1: Double = 6.5025, c2: Double = 58.5225          // (0.01·255)², (0.03·255)²
        var total = 0.0, n = 0
        for yy in border..<(h - border) { for xx in border..<(w - border) {
            let i = yy * w + xx
            let vx = sxx[i] - mx[i] * mx[i], vy = syy[i] - my[i] * my[i], cv = sxy[i] - mx[i] * my[i]
            total += ((2 * mx[i] * my[i] + c1) * (2 * cv + c2)) / ((mx[i] * mx[i] + my[i] * my[i] + c1) * (vx + vy + c2))
            n += 1
        } }
        return total / Double(n)
    }

    /// IoU, skipping `ignore` pixels.
    static func iou(_ a: BinaryMask, _ b: BinaryMask, ignore: [Bool]) -> Double {
        var inter = 0, union = 0
        for i in a.on.indices where !ignore[i] {
            if a.on[i] && b.on[i] { inter += 1 }
            if a.on[i] || b.on[i] { union += 1 }
        }
        return union == 0 ? 1 : Double(inter) / Double(union)
    }
}

/// A small seeded generator (SplitMix64) with Box–Muller Gaussians.
struct SplitMix {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// SwitchTV branding from the one source logo (switchtv-icon-source.png: the split-apple mark above the wordmark, on white).
// Usage: make_branding.swift <source.png> <out dir>
//   writes <out>/icon-art.png   the mark alone, centred on the logo's own white, 16:10 (the input of dm/ios/tools/tv_icon.swift for the App Icon)
//          <out>/shelf-art.png  the whole logo, centred on the logo's own white with margins, 8:3 (the Top Shelf images)
//          <out>/colors.txt     the sampled red / black / paper colour, as hex (paper = DM_ICON_BACKDROP for tv_icon.swift) (Theme.swift keeps these)
// The mark's rectangle is measured on the 1254x1254 source. A new logo at another size: change `markRect`.
import AppKit

func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("make_branding: \(m)\n".utf8)); exit(1) }
let args = CommandLine.arguments
guard args.count == 3 else { fail("usage: make_branding.swift <source.png> <out dir>") }
guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(args[1])") }
let out = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let scale = Double(image.width) / 1254.0
let markRect = CGRect(x: 230 * scale, y: 50 * scale, width: 790 * scale, height: 900 * scale)   // top-left origin: the apple and leaf, no wordmark
guard let mark = image.cropping(to: markRect) else { fail("cannot crop the mark") }

func paper() -> CGColor {   // the source's own background (not pure white), from its top-left corner
    let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self), o = (image.height - 1 - 12) * c.bytesPerRow + 12 * 4
    return CGColor(srgbRed: Double(p[o]) / 255, green: Double(p[o + 1]) / 255, blue: Double(p[o + 2]) / 255, alpha: 1)
}
let background = paper()
func canvas(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.setFillColor(background); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c
}
func place(_ art: CGImage, in c: CGContext, _ w: Int, _ h: Int, height fraction: Double) {
    let ph = Double(h) * fraction, pw = ph * Double(art.width) / Double(art.height)
    c.draw(art, in: CGRect(x: (Double(w) - pw) / 2, y: (Double(h) - ph) / 2, width: pw, height: ph))
}
func write(_ c: CGContext, _ name: String) {
    let d = CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, c.makeImage()!, nil); if !CGImageDestinationFinalize(d) { fail("cannot write \(name)") }
}
let icon = canvas(1600, 960); place(mark, in: icon, 1600, 960, height: 0.78); write(icon, "icon-art.png")
let shelf = canvas(2400, 900); place(image, in: shelf, 2400, 900, height: 0.88); write(shelf, "shelf-art.png")

// Sample the red from the flat fill of the right half (between the buttons and the leaf), the black from the left half.
let probe = canvas(image.width, image.height); probe.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let px = probe.data!.assumingMemoryBound(to: UInt8.self), row = probe.bytesPerRow
func hex(_ x: Double, _ y: Double) -> String {   // x, y in source points, top-left origin; the median of a 21x21 patch
    var r: [Int] = [], g: [Int] = [], b: [Int] = []
    for dy in -10...10 { for dx in -10...10 {
        let ix = Int(x * scale) + dx, iy = image.height - 1 - (Int(y * scale) + dy), o = iy * row + ix * 4
        r.append(Int(px[o])); g.append(Int(px[o + 1])); b.append(Int(px[o + 2]))
    } }
    func med(_ a: [Int]) -> Int { a.sorted()[a.count / 2] }
    return String(format: "%02X%02X%02X", med(r), med(g), med(b))
}
let p = background.components!
let paperHex = String(format: "%02X%02X%02X", Int((p[0] * 255).rounded()), Int((p[1] * 255).rounded()), Int((p[2] * 255).rounded()))
try! "paper \(paperHex)\nred \(hex(740, 400))\nblack \(hex(400, 780))\n".write(to: out.appendingPathComponent("colors.txt"), atomically: true, encoding: .utf8)

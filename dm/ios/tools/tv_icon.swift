// Apple TV app icon from one image of any shape: a layered image stack (the parallax on the home screen) and the Top Shelf banners, written into an asset catalog.
// Usage: tv_icon.swift <image> <Assets.xcassets>            write AppIcon.brandassets (build_ipa.sh with DM_TVOS=1)
//        tv_icon.swift <image> --preview <out.png>          write what the home screen shows, for a front end
// Wide art fills the icon edge to edge. Art closer to a square (a game's cover, its 256x256 icon) sits whole on a blurred, darkened copy of itself. tvOS needs opaque back layers and at least two layers.
import AppKit
import CoreImage

let wideEnough = 1.4   // width / height from which art fills the icon (the icon is 5:3, about 1.67)

func fail(_ message: String) -> Never { FileHandle.standardError.write(Data("tv_icon: \(message)\n".utf8)); exit(1) }

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else { fail("cannot read the image \(path)") }
    return image
}

// Crop at the target aspect ratio; icon and independent Top Shelf crops share this geometry.
// Positions select from the available overflow: -1 left/top, 0 center, +1 right/bottom.
func cropArtwork(_ image: CGImage, environment: [String: String], prefix: String = "DM_ICON", ratio: Double = 5.0 / 3.0) -> CGImage {
    func number(_ key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let raw = environment[key] else { return fallback }
        guard let n = Double(raw), n.isFinite, range.contains(n) else { fail("invalid \(key)") }
        return n
    }
    let scale = number("\(prefix)_CROP_SCALE", fallback: 0, range: 0...3)
    if scale == 0 { return image }
    guard scale >= 1 else { fail("crop scale must be at least 1") }
    let x = number("\(prefix)_CROP_X", fallback: 0, range: -1...1)
    let y = number("\(prefix)_CROP_Y", fallback: 0, range: -1...1)
    let width = Double(image.width), height = Double(image.height)
    let cropWidth = min(width, height * ratio) / scale
    let cropHeight = cropWidth / ratio
    let rect = CGRect(x: (width - cropWidth) * (x + 1) / 2,
                      y: (height - cropHeight) * (y + 1) / 2,
                      width: cropWidth, height: cropHeight)
    guard let cropped = image.cropping(to: rect) else { fail("cannot crop this image") }
    return cropped
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("cannot make a \(w)x\(h) bitmap") }
    c.interpolationQuality = .high
    return c
}

func fillRect(_ art: CGImage, _ w: Int, _ h: Int) -> CGRect {   // covers the canvas, cropped
    let s = max(Double(w) / Double(art.width), Double(h) / Double(art.height))
    let dw = Double(art.width) * s, dh = Double(art.height) * s
    return CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh)
}

func fitRect(_ art: CGImage, _ w: Int, _ h: Int, inset: Double) -> CGRect {   // whole, centered
    let s = min(Double(w) * inset / Double(art.width), Double(h) * inset / Double(art.height))
    let dw = Double(art.width) * s, dh = Double(art.height) * s
    return CGRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh)
}

func blurred(_ art: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let c = bitmap(w, h)
    c.draw(art, in: fillRect(art, w, h))
    let input = CIImage(cgImage: c.makeImage()!).clampedToExtent()
    let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: Double(h) * 0.06])!
    let extent = CGRect(x: 0, y: 0, width: w, height: h)
    return CIContext().createCGImage(blur.outputImage!.cropped(to: extent), from: extent)!
}

// DM_ICON_BACKDROP=RRGGBB: a flat backdrop instead of the blurred copy of the art, for a logo that already sits on its own paper colour (tvport/switchtv/Branding).
// The back layer is that colour, the front layer the art filling the icon; the Top Shelf's sides are that colour too.
let backdrop: CGColor? = {
    guard let hex = ProcessInfo.processInfo.environment["DM_ICON_BACKDROP"], hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
    return CGColor(srgbRed: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
}()

func wide(_ art: CGImage) -> Bool { Double(art.width) / Double(art.height) >= wideEnough }

func backLayer(_ art: CGImage, _ w: Int, _ h: Int) -> CGImage {   // opaque: tvOS refuses an icon whose back layer has transparency
    let c = bitmap(w, h)
    c.setFillColor(backdrop ?? CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if backdrop != nil { return c.makeImage()! }
    if wide(art) { c.draw(art, in: fillRect(art, w, h)) } else {
        c.draw(blurred(art, w, h), in: CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return c.makeImage()!
}

func frontLayer(_ art: CGImage, _ w: Int, _ h: Int) -> CGImage {   // transparent around the art
    let c = bitmap(w, h)
    if backdrop != nil { c.draw(art, in: fillRect(art, w, h)) } else if wide(art) {   // The middle of the art lifted off the back, so the parallax has something to move; its edges fade into the same picture below
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
        let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), colors: colors, locations: [0, 0.55, 1])!
        c.saveGState()
        let mask = bitmap(w, h)
        mask.drawRadialGradient(fade, startCenter: CGPoint(x: w / 2, y: h / 2), startRadius: 0, endCenter: CGPoint(x: w / 2, y: h / 2), endRadius: Double(max(w, h)) * 0.55, options: [])
        c.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: mask.makeImage()!)
        c.draw(art, in: fillRect(art, w, h))
        c.restoreGState()
    } else {
        let r = fitRect(art, w, h, inset: 0.86)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -Double(h) * 0.012), blur: Double(h) * 0.05, color: CGColor(gray: 0, alpha: 0.6))
        c.draw(art, in: r)
        c.restoreGState()
    }
    return c.makeImage()!
}

// The wide asset includes 200 points of horizontal bleed on each side of the
// 1920x720 composition. Keep that composition identical in the standard asset,
// the wide asset's center and the preview; never fit artwork to the bleed width.
// tvOS extends the static banner below this region for its full-screen backdrop.
func shelfContent(_ art: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let c = bitmap(w, h)
    let area = CGRect(x: 0, y: 0, width: w, height: h)
    c.setFillColor(backdrop ?? CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
    c.fill(area)
    if backdrop == nil { c.draw(blurred(art, w, h), in: area) }
    // Automatic preserves the whole source. An explicit crop already has the
    // 8:3 visible aspect ratio, so fitting it fills the composition exactly.
    c.draw(art, in: fitRect(art, w, h, inset: 1))
    return c.makeImage()!
}

func shelf(_ art: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let visibleWidth = min(w, h * 8 / 3)
    let content = shelfContent(art, visibleWidth, h)
    if visibleWidth == w { return content }
    let c = bitmap(w, h)
    let area = CGRect(x: 0, y: 0, width: w, height: h)
    c.setFillColor(backdrop ?? CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1))
    c.fill(area)
    if backdrop == nil { c.draw(blurred(art, w, h), in: area) }
    c.draw(content, in: CGRect(x: (w - visibleWidth) / 2, y: 0, width: visibleWidth, height: h))
    return c.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(d, image, nil)
    if !CGImageDestinationFinalize(d) { fail("cannot write \(url.path)") }
}

func writeJSON(_ value: Any, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

let info: [String: Any] = ["author": "xcode", "version": 1]

func imageStack(_ art: CGImage, _ name: String, _ w: Int, _ h: Int, _ scales: [Int], in brand: URL) -> String {
    let stack = brand.appendingPathComponent(name + ".imagestack")
    let layers = ["Front", "Back"]
    writeJSON(["info": info, "layers": layers.map { ["filename": $0 + ".imagestacklayer"] }], stack.appendingPathComponent("Contents.json"))
    for layer in layers {
        let dir = stack.appendingPathComponent(layer + ".imagestacklayer")
        writeJSON(["info": info], dir.appendingPathComponent("Contents.json"))
        let set = dir.appendingPathComponent("Content.imageset")
        var images: [[String: Any]] = []
        for s in scales {
            let file = "icon@\(s)x.png"
            writeJSON(["info": info], set.appendingPathComponent("Contents.json"))
            writePNG(layer == "Back" ? backLayer(art, w * s, h * s) : frontLayer(art, w * s, h * s), set.appendingPathComponent(file))
            images.append(["idiom": "tv", "filename": file, "scale": "\(s)x"])
        }
        writeJSON(["info": info, "images": images], set.appendingPathComponent("Contents.json"))
    }
    return name + ".imagestack"
}

func shelfSet(_ art: CGImage, _ name: String, _ w: Int, _ h: Int, in brand: URL) -> String {
    let set = brand.appendingPathComponent(name + ".imageset")
    var images: [[String: Any]] = []
    for s in [1, 2] {
        let file = "shelf@\(s)x.png"
        writeJSON(["info": info], set.appendingPathComponent("Contents.json"))
        writePNG(shelf(art, w * s, h * s), set.appendingPathComponent(file))
        images.append(["idiom": "tv", "filename": file, "scale": "\(s)x"])
    }
    writeJSON(["info": info, "images": images], set.appendingPathComponent("Contents.json"))
    return name + ".imageset"
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: tv_icon.swift <image> <Assets.xcassets> | <image> --preview <out.png>") }
let art = cropArtwork(loadImage(args[1]), environment: ProcessInfo.processInfo.environment)

if args[2] == "--preview" {
    guard args.count == 4 else { fail("--preview needs an output path") }
    let c = bitmap(800, 480), all = CGRect(x: 0, y: 0, width: 800, height: 480)
    c.draw(backLayer(art, 800, 480), in: all)
    c.draw(frontLayer(art, 800, 480), in: all)
    writePNG(c.makeImage()!, URL(fileURLWithPath: args[3]))
    exit(0)
}

let environment = ProcessInfo.processInfo.environment
let customShelf = environment["DM_TOP_SHELF_ART"].flatMap { $0.isEmpty ? nil : loadImage($0) }
let shelfArt = cropArtwork(customShelf ?? art, environment: environment, prefix: "DM_SHELF", ratio: 8.0 / 3.0)
if args[2] == "--shelf-preview" {
    guard args.count == 4 else { fail("--shelf-preview needs an output path") }
    writePNG(shelf(shelfArt, 960, 360), URL(fileURLWithPath: args[3]))
    exit(0)
}
let catalog = URL(fileURLWithPath: args[2]), brand = catalog.appendingPathComponent("AppIcon.brandassets")
try? FileManager.default.removeItem(at: brand)
writeJSON(["info": info], catalog.appendingPathComponent("Contents.json"))
writeJSON(["info": info, "assets": [
    ["idiom": "tv", "size": "400x240", "role": "primary-app-icon", "filename": imageStack(art, "App Icon", 400, 240, [1, 2], in: brand)],
    ["idiom": "tv", "size": "1280x768", "role": "primary-app-icon", "filename": imageStack(art, "App Icon - App Store", 1280, 768, [1], in: brand)],
    ["idiom": "tv", "size": "1920x720", "role": "top-shelf-image", "filename": shelfSet(shelfArt, "Top Shelf Image", 1920, 720, in: brand)],
    ["idiom": "tv", "size": "2320x720", "role": "top-shelf-image-wide", "filename": shelfSet(shelfArt, "Top Shelf Image Wide", 2320, 720, in: brand)],
]], brand.appendingPathComponent("Contents.json"))

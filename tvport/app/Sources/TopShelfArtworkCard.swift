import SwiftUI
import UniformTypeIdentifiers

extension Game {
    var topShelfArguments: [String] {
        var arguments: [String] = []
        if let topShelfArtwork { arguments += ["--shelf-art", topShelfArtwork] }
        if let crop = topShelfCrop {
            arguments += ["--shelf-scale", String(crop.scale), "--shelf-x", String(crop.x), "--shelf-y", String(crop.y)]
        }
        return arguments
    }
}

struct TopShelfArtworkCard: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top Shelf Cover").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let preview = library.topShelfPreview {
                    ArtworkPositioningPreview(preview: preview, topShelf: true)
                        .id(library.selection)
                }
                if library.topShelfPreview == nil || targeted {
                    Text("Drop PNG or JPEG\n1920 × 720 (8:3)")
                        .font(.caption).multilineTextAlignment(.center)
                        .foregroundStyle(.white).padding(8)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .aspectRatio(8.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 2) } }
            .accessibilityLabel("Top Shelf visible-area preview. Drop a PNG or JPEG. Recommended size 1920 by 720 pixels.")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL else { return false }
                if ["nsp", "xci", "nsz", "xcz", "nup"].contains(url.pathExtension.lowercased()) || url.hasDirectoryPath {
                    if let game = library.current { library.attachAddons(urls, to: game.id) }
                    return true
                }
                guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()), NSImage(contentsOf: url) != nil else { return false }
                library.setTopShelfArtwork(url)
                return true
            } isTargeted: { targeted = $0 }
            Text("PNG or JPEG · 1920 × 720 (8:3)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Choose Cover…") { choosing = true }
                if library.current?.topShelfArtwork != nil {
                    Button("Use App Icon Image") { library.setTopShelfArtwork(nil) }
                }
            }
            ArtworkFramingControls(topShelf: true)
            Text("Uses the App Icon image unless you choose a separate cover. Preview shows the central area; extra side background is added for tvOS. Applies on next Build & Install.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.png, .jpeg]) { result in
            if case .success(let url) = result { library.setTopShelfArtwork(url) }
        }
    }
}

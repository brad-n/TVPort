import SwiftUI

/// Shared by the empty library and sidebar; importing follows the folder picker's path.
struct GameFolderDropTarget: ViewModifier {
    let addFolder: (URL) -> Void
    @State private var isTargeted = false
    @State private var showingDropError = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.08))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        }
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                let folders = GameDropImport.folders(from: urls)
                showingDropError = folders.isEmpty
                for folder in folders { addFolder(folder) }
                return !folders.isEmpty
            } isTargeted: { isTargeted = $0 }
            .alert("Couldn’t add this item", isPresented: $showingDropError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Drop a game folder or an .nsp, .xci, .nsz, .xcz or .nup file. Make sure the drive is connected and the item is accessible.")
            }
    }
}

import SwiftUI
import UniformTypeIdentifiers

struct TVPortCommands: Commands {
    @ObservedObject var library: Library
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Manage Saves") { openWindow(id: "manage-saves") }
        }
    }
}

struct DefaultBuildFolderSettings: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false

    var body: some View {
        Form {
            Section("SwitchTV") {
                Toggle("Keep SwitchTV up to date", isOn: $library.keepSwitchTVCurrent)
                Text("SwitchTV is the launcher app that lists your games on the Apple TV. When this is on, TVPort refreshes it after every Build & Install and after you remove a game, so new games appear in it. Nothing is sent when the list is unchanged. Apple TV does not let one app put others in a home-screen folder: new apps appear at the end of the home screen, so make a “Games” folder there once by hand (hold the clickpad on an app, choose New Folder) to keep the top row clean.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Default build folder") {
                Text(library.defaultBuildFolder.isEmpty ? "Beside each game’s original files" : library.defaultBuildFolder)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Folder…") { choosing = true }
                    if !library.defaultBuildFolder.isEmpty {
                        Button("Use Original Game Folders") { library.defaultBuildFolder = "" }
                    }
                }
                Text("TVPort keeps each game’s builds in a separate subfolder. Original game files stay where they are. You can override this location in each game’s settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If a build needs a new location, TVPort copies it on the next build and keeps the original. Use a drive with enough free space for both copies.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 440)
        .disabled(library.isBusy)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { library.defaultBuildFolder = url.path }
        }
    }
}

struct GameBuildFolderSettings: View {
    @EnvironmentObject var library: Library
    @Environment(\.openSettings) private var openSettings

    private var nextToOriginal: Bool {
        library.defaultBuildFolder.isEmpty || library.current?.buildNextToOriginal == true
    }

    private var folder: String {
        nextToOriginal ? (library.current?.folder ?? "") : library.defaultBuildFolder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Default folder from Settings", isOn: Binding(
                get: { !nextToOriginal },
                set: { _ in
                    setNextToOriginal(false)
                    if library.defaultBuildFolder.isEmpty { openSettings() }
                }
            ))
            .toggleStyle(.checkbox)
            Toggle("Next to original files", isOn: Binding(
                get: { nextToOriginal },
                set: { _ in setNextToOriginal(true) }
            ))
            .toggleStyle(.checkbox)
            Text(folder).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if library.defaultBuildFolder.isEmpty {
                Text("Choose Default folder from Settings to set a shared build location.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let path = library.info?.build_path {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) }
            }
            Text("Stores the generated game files, shaders and Apple TV app. Existing builds are copied to a new location on the next build; the originals are kept.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(library.isBusy)
    }

    private func setNextToOriginal(_ enabled: Bool) {
        library.update {
            $0.buildNextToOriginal = enabled
            $0.buildFolder = nil
        }
        Task { await library.refresh() }
    }
}

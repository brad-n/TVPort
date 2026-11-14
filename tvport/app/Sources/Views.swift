import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct TVPortApp: App {
    @StateObject private var library = Library()
    @NSApplicationDelegateAdaptor(URLBuildDelegate.self) private var urlDelegate

    var body: some Scene {
        WindowGroup("TVPort") {
            ContentView().environmentObject(library).frame(width: 1000).frame(minHeight: 620)
                .background(InitialWindowSize())
                .onAppear { URLBuildRouter.shared.attach(library) }
        }
        // URL events go to URLBuildDelegate; an empty match set stops this scene opening a window for each one.
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .defaultSize(width: 1000, height: 670)
        .windowToolbarStyle(.unified)
        .commands { TVPortCommands(library: library) }
        Settings {
            DefaultBuildFolderSettings().environmentObject(library)
        }
        Window("", id: "manage-saves") {
            SaveManagerView().environmentObject(library)
                .frame(width: 1000)
                .background(InitialWindowSize())
                .toolbar {
                    // Native toolbar chrome gives both windows the same corner treatment.
                    ToolbarItem(placement: .principal) {
                        Spacer().frame(width: 1).accessibilityHidden(true)
                    }
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1000, height: 670)
        .windowResizability(.contentSize)
    }
}

// SwiftUI's defaultSize yields to saved window frames. Apply the requested
// starting size once after attachment, while allowing later height changes.
private struct InitialWindowSize: NSViewRepresentable {
    final class Marker: NSView {
        private weak var sizedWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== sizedWindow else { return }
            sizedWindow = window
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                let top = window.frame.maxY
                window.setContentSize(NSSize(width: 1000, height: 670))
                window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
            }
        }
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow
    @State private var choosingFolder = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            VStack(spacing: 0) {
                List(library.games, selection: $library.selection) { game in
                    VStack(alignment: .leading, spacing: 6) {
                        GameArtworkThumbnail(titleID: game.titleID, name: game.name,
                                             artworkPath: game.artwork ?? (game.id == library.selection ? library.artworkPath : nil))
                            .overlay(alignment: .topLeading) {
                                if let badge = library.buildBadge(for: game.id) {
                                    Text(badge).font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(.regularMaterial, in: Capsule()).padding(6)
                                }
                            }
                        Text(game.name).lineLimit(1)
                        if game.built == true {
                            Text("Built").font(.callout).foregroundStyle(.secondary)
                        }
                        if let time = library.backedUp(game) { Text("Saves backed up \(time)").font(.caption).foregroundStyle(.secondary) }
                    }
                    .modifier(GameSelectionStyle(selected: library.selection == game.id))
                    .tag(game.id)
                    .contextMenu {
                        if library.buildQueue.position(game.id) != nil {
                            Button("Remove from Queue") { library.removeQueuedBuild(game.id) }
                        }
                        Button("Remove from List") { library.remove(game) }
                            .disabled(library.buildQueue.active?.gameID == game.id)
                    }
                    .modifier(GameAddonDropTarget(gameID: game.id))
                }
                if library.queuedBuildCount > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(library.buildQueueSummary)
                            .font(.callout.weight(.medium))
                        Text(library.automaticallyBackingUp ? "Waiting for automatic backup to finish." : "Keep TVPort open. Queued games build one at a time.")
                            .font(.caption).foregroundStyle(.secondary)
                        if library.buildQueue.paused {
                            Button("Resume Queue") { library.resumeBuildQueue() }
                                .disabled(library.buildQueue.active != nil)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }
            .frame(width: 240)
            .modifier(GameFolderDropTarget(addFolder: library.add(folder:)))
            .navigationSplitViewColumnWidth(240)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                Button { choosingFolder = true } label: { Label("Add Game", systemImage: "plus") }
                    .help("Choose a game folder, or drop a game file or folder into the sidebar")
                Button { openWindow(id: "manage-saves") } label: {
                    Label("Manage Saves", systemImage: "externaldrive.badge.timemachine")
                        .offset(x: -3)
                }
                    .help("Import, export and restore saves for games installed on an Apple TV")
                SetupStatusButton()
            }
        } detail: {
            Group {
            if library.current == nil {
                VStack(spacing: 0) {
                    SetupBanner().padding(20)
                    AutomaticBackupStatus().padding(.horizontal, 20)
                    ContentUnavailableView {
                        Label("No games yet", systemImage: "appletv")
                    } description: {
                        Text("Drop a game folder or an .nsp, .xci, .nsz, .xcz or .nup file here. A dropped file adds its containing folder, including updates and DLC.")
                    } actions: {
                        Button("Drop game folder here") { choosingFolder = true }
                            .buttonStyle(.borderedProminent)
                            .help("Drop a game file or folder here, or click to choose a folder")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(GameFolderDropTarget(addFolder: library.add(folder:)))
            } else if let game = library.current {
                GameView().modifier(GameAddonDropTarget(gameID: game.id))
            }
            }
            .frame(minWidth: 740)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let folder) = result { library.add(folder: folder) }
        }
        .sheet(isPresented: $library.showingSetup) { SetupView().environmentObject(library) }
        .alert("Couldn’t add updates or DLC", isPresented: Binding(get: { library.addonError != nil }, set: { if !$0 { library.addonError = nil } })) {
            Button("OK", role: .cancel) { library.addonError = nil }
        } message: { Text(library.addonError ?? "") }
        .task { await library.checkSetup() }
        .task { await library.backUpEveryFewMinutes() }
        .task(id: library.selection) { await library.refresh() }
        .onChange(of: library.defaultBuildFolder) { _, _ in Task { await library.refresh() } }
    }

}

struct SetupStatusButton: View {
    @EnvironmentObject var library: Library

    var body: some View {
        Button { library.showingSetup = true } label: {
            Image(systemName: setupHasIssue ? "exclamationmark.triangle" : setupReady ? "checkmark.seal" : "seal")
                .symbolRenderingMode(.palette)
                .foregroundStyle(setupHasIssue ? Color.red : setupReady ? Color.green : Color.secondary)
                .font(.system(size: 16))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(setupHelp)
        .help(setupHelp)
    }

    private var setupHasIssue: Bool {
        !library.setupMissing.isEmpty || library.setupFailure != nil
            || (library.setup?.ready == false && !library.settingUp)
    }

    private var setupReady: Bool {
        library.setup?.ready == true && !setupHasIssue && !library.settingUp
    }

    private var setupHelp: String {
        if !library.setupMissing.isEmpty {
            return "Setup — missing: \(library.setupMissing.map(\.name).joined(separator: ", ")). Click to see what needs fixing."
        }
        if setupHasIssue { return "Setup needs attention. Click to see what needs fixing." }
        if setupReady { return "Setup — all requirements are ready." }
        return library.settingUp ? "Setup is in progress." : "Checking setup requirements…"
    }
}

struct GameView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Header()
                    SetupBanner()
                    AutomaticBackupStatus()
                    if let notice = library.notice { NoticeBar(text: notice) }
                    if let info = library.info, !info.prepared, info.sources.isEmpty {
                        NoticeBar(text: "This folder has no .nsp, .xci, .nsz, .xcz or .nup files. TVPort builds only from games you dumped from your own Switch.")
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 24) {
                            ArtworkCard()
                            TopShelfArtworkCard()
                        }.frame(width: 300)
                        // The grouped form adds its own 20-point horizontal inset.
                        // Let the surrounding content provide the shared margins.
                        SettingsForm().padding(.horizontal, -20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 6)
            }
            if library.showsRunForSelection {
                Divider()
                ProgressPanel()
            }
        }
        .navigationTitle("")
        .toolbar { gameToolbar }
        .sheet(isPresented: $library.showingDiagnosis) {
            LastRunStatsView().environmentObject(library)
        }
    }

    @ToolbarContentBuilder
    private var gameToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { actions }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { actions }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            ToolbarActionButton(title: "Last Run Stats", enabled: canUseInstalledGame && !library.readingDiagnosis,
                                help: "Read memory and frame times from the Apple TV") { library.diagnose() }
            ToolbarActionButton(title: "Open on TV", enabled: canUseInstalledGame) { library.launch() }
            ToolbarActionButton(title: "Install SwitchTV", enabled: library.device != nil && !library.isBusy,
                                help: "Install or update the SwitchTV launcher on the selected Apple TV") { library.installSwitchTV() }
            if library.buildQueue.active?.gameID == library.selection && library.buildQueue.active != nil {
                ToolbarActionButton(title: "Stop", enabled: !library.buildQueue.paused) { library.cancel() }
            } else if let gameID = library.selection, library.buildQueue.position(gameID) != nil {
                ToolbarActionButton(title: "Remove from Queue") { library.removeQueuedBuild(gameID) }
            } else {
                ToolbarActionButton(title: library.automaticallyBackingUp || library.buildQueue.active != nil || !library.buildQueue.pending.isEmpty ? "Add to Queue" : "Build & Install",
                                    enabled: canBuild, primary: true,
                                    help: "Uses the device and build options selected when added. Remove and re-add to change a queued build.") {
                    library.build(install: true)
                }
            }
        }
        // Add to the toolbar's 8-point inset to match the content's 20-point margin.
        .padding(.trailing, 12)
    }

    private var canUseInstalledGame: Bool {
        library.bundleID != nil && library.device != nil && !library.isBusy
    }

    private var canBuild: Bool {
        guard let info = library.info, info.folder == library.current?.folder, library.device != nil, library.setupMissing.isEmpty, !library.settingUp, !library.transferringSaves, library.checkingAddonGame == nil else { return false }
        return info.prepared || (!info.sources.isEmpty && (library.keys != nil || info.keyless == true))
    }
}

struct Header: View {
    @EnvironmentObject var library: Library

    var body: some View {
        if let info = library.info {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let status = library.buildStatus(for: library.selection ?? info.folder, built: info.built == true)
                let expiry = status == "Built" ? SigningExpiry(info.signing?.expires) : nil
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.title2.weight(.semibold))
                    Text([info.version.isEmpty ? nil : "Version \(info.version)",
                          info.title_id.isEmpty ? nil : "ID: \(info.title_id)", status,
                          expiry?.label(at: context.date)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .help("Expiry comes from this build’s signing profile and is shown in your Mac’s local time.")
                    if let expiry, expiry.date.timeIntervalSince(context.date) < 3 * 86_400,
                       info.signing?.free_team == true {
                        Label(expiry.date <= context.date
                              ? "This build’s signature has expired. Build & Install renews it."
                              : "Build & Install renews the signature before it expires.",
                              systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange)
                    }
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// Shown while something a build needs is missing, or while the first start sets up the engine.
struct SetupBanner: View {
    @EnvironmentObject var library: Library

    var body: some View {
        if library.settingUp {
            HStack {
                ProgressView().controlSize(.small)
                Text("Setting up: \(library.setupStage)").lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else if !library.setupMissing.isEmpty || library.setupFailure != nil {
            HStack {
                Label(library.setupFailure != nil ? "TVPort could not finish setting up." : "Before the first build, this Mac needs: \(library.setupMissing.map(\.name).joined(separator: ", ")).",
                      systemImage: "exclamationmark.triangle")
                Spacer()
                Button("Show Setup") { library.showingSetup = true }
            }
            .padding(10).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup").font(.title2.weight(.semibold))
            Text("TVPort carries its engine and sets up its own Python. A build also needs these from Apple and others, which only you can install. Your games and prod.keys stay in the folders you choose.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let checks = library.setup?.checks {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(check.ok ? .green : .orange)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(check.name).font(.headline)
                                Text(check.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            if !check.ok {
                                if !check.fix.isEmpty { Text(check.fix).fixedSize(horizontal: false, vertical: true) }
                                if !check.command.isEmpty {
                                    HStack {
                                        Text(check.command).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                                        Button("Copy") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(check.command, forType: .string)
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if library.settingUp {
                HStack { ProgressView().controlSize(.small); Text(library.setupStage) }
            }
            if let failure = library.setupFailure {
                Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(8)
            }
            HStack {
                Button("Check Again") { Task { await library.checkSetup() } }.disabled(library.settingUp)
                if library.setup?.can_set_up == true && library.setup?.checks.first(where: { $0.name == "Python" })?.ok == false {
                    Button("Set Up") { library.runSetup() }.disabled(library.isBusy)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 600)
    }
}

struct NoticeBar: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ArtworkCard: View {
    @EnvironmentObject var library: Library
    @State private var choosing = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App Icon").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                if let preview = library.preview {
                    ArtworkPositioningPreview(preview: preview)
                        .id(library.selection)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.title)
                        Text("Drop an image here")
                    }.foregroundStyle(.secondary)
                }
                if targeted { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3) }
            }
            .aspectRatio(5.0 / 3.0, contentMode: .fit)
            .accessibilityLabel("App icon preview. Drop an image to replace it.")
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, url.isFileURL else { return false }
                if ["nsp", "xci", "nsz", "xcz", "nup"].contains(url.pathExtension.lowercased()) || url.hasDirectoryPath {
                    guard library.canEditAddons else { return false }
                    if let game = library.current { library.attachAddons(urls, to: game.id) }
                    return true
                }
                guard NSImage(contentsOf: url) != nil else { return false }
                library.setArtwork(url)
                return true
            } isTargeted: { targeted = $0 }
            HStack {
                Button("Choose Artwork…") { choosing = true }
                if library.current?.artwork != nil { Button("Use Automatic Artwork") { library.setArtwork(nil) } }
            }
            if library.current?.artwork == nil, !library.artworkStatus.isEmpty {
                Text(library.artworkStatus).font(.caption).foregroundStyle(.secondary)
            }
            ArtworkFramingControls()
            Text("Automatic framing keeps square art on a blurred background. Crop to fill lets you zoom and choose the visible area. Top Shelf uses this artwork unless you choose a separate cover. Takes effect at the next Build & Install.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { library.setArtwork(url) }
        }
    }
}

struct SettingsForm: View {
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow
    @State private var choosingKeys = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Build folder") {
                GameBuildFolderSettings()
            }
            Section("Updates & DLC") {
                GameAddonsCard()
            }
            Section("Apple TV") {
                Picker("Device", selection: $library.device) {
                    if library.devices.isEmpty { Text("None found").tag(AppleTV.ID?.none) }
                    ForEach(library.devices) { Text($0.title).tag(Optional($0.id)) }
                }
                TextField("Signing team", text: $library.team, prompt: Text("10-character team ID"))
                Button("Look Again") { Task { await library.refreshDevices() } }
                Button("Install SwitchTV on Apple TV") { library.installSwitchTV() }
                    .disabled(library.device == nil || library.isBusy)
                    .help("Puts the SwitchTV launcher, with every game you have built, on the selected Apple TV")
                if let status = library.switchTVStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Performance") {
                Picker("Render mode", selection: binding(\.mode, default: .handheld)) { ForEach(RenderMode.allCases) { Text($0.label).tag($0) } }
                Text(library.current?.mode.note ?? "").font(.caption).foregroundStyle(.secondary)
                Picker("Texture detail", selection: binding(\.texture, default: .medium)) { ForEach(TextureDetail.allCases) { Text($0.label).tag($0) } }
                Text("The A15 has to store these textures uncompressed, so lower detail saves memory and shortens loading.").font(.caption).foregroundStyle(.secondary)
                if library.info?.render_scale == true {
                    Picker("3D resolution", selection: renderScaleBinding) {
                        ForEach([1.0, 0.9, 0.8, 0.75, 0.7, 0.6, 0.5], id: \.self) { Text($0 == 1 ? "Full" : "\(Int(($0 * 100).rounded()))%").tag($0) }
                    }
                    Text("Draws the game's 3D scene at a lower resolution, so the GPU keeps up; menus and text stay sharp. Below Full the size is fixed, in place of the game's own dynamic resolution. Takes effect at the next Build & Install.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Picker("Upscaler", selection: upscalerBinding) {
                    Text("Game's own (default)").tag("game")
                    Text("MetalFX").tag("metalfx")
                    Text("Off — simple scaling, most speed").tag("off")
                }
                Text("How the game's image is scaled up to the screen. Off uses plain scaling and leaves the most speed for the game; the picture is a little softer. Takes effect at the next Build & Install.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Frame rate", selection: fpsBinding(profileFPS ?? 0)) {
                    if profileFPS == nil { Text("Game default").tag(0) }
                    Text("30 fps").tag(30)
                    Text("Up to 60 fps").tag(60)
                }
                .disabled(profileFPS == nil)
                Text(frameRateNote)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if library.info?.frame_step == true {
                    Toggle("Hold 30 fps when the Apple TV is hot", isOn: coolBinding)
                    Text("When tvOS reports the TV as hot, it lowers the chip's speed, the GPU to about a third, whatever the game does, and this makes the game hold 30 fps so the TV cools down sooner. Off, the game keeps trying for 60, which it can then rarely reach, and the TV stays hot and slow for longer. Takes effect at the next Build & Install.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Frame-rate counter", isOn: binding(\.showFPS, default: false))
                Text("Shows how many frames reach the screen each second (FPS) while you play, so you can monitor performance. This only displays the frame rate; it does not change the FPS limit. Takes effect at the next Build & Install.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Controller") {
                Toggle("Swap A/B", isOn: swapABBinding)
                Toggle("Swap X/Y", isOn: swapXYBinding)
                Text("Swap each pair independently for this game. Your choices become the default for new games. Takes effect at the next Build & Install.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Saves") {
                Button("Manage Saves…") { openWindow(id: "manage-saves") }
                Text("While TVPort is open, it backs up all supported installed games’ saves from the Apple TV every 30 minutes, only reading the TV. Enable iCloud backups in Manage Saves to keep new backups in iCloud Drive, in TVPort Saves.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Players", text: playersBinding, prompt: Text("Names, separated by commas"))
                Text("With two or more names, the Apple TV asks who's playing, and each person gets their own saves. The first name picked keeps the saves already on the TV. Takes effect at the next Build & Install.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let game = library.current, let time = library.backedUp(game) {
                    LabeledContent("Last backup", value: "\(time), \(place(game))")
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Allow a damaged game manual", isOn: flagBinding(\.allowDamagedManual))
                        note("A damaged offline manual no longer stops the build. Damaged game data still does.")
                        TextField("Extra extractor arguments", text: textBinding(\.extractorArguments), prompt: Text("--option value, quotes keep spaces"))
                        note("Added to every extraction step of the game's files, not to the title and key checks. --allow-damaged also turns off reuse of earlier results, so the next build takes longer.")
                        Picker("Game memory paging", selection: pagingBinding) {
                            Text("Automatic").tag("")
                            Text("On").tag("on")
                            Text("Off").tag("off")
                        }
                        note("Keeps the game's own memory in files on the Apple TV's storage so it doesn't count against tvOS's ~2.1 GB app limit. Automatic is right for almost every game.")
                        Picker("Compressed textures (ASTC)", selection: compressedTexturesBinding) {
                            Text("Automatic").tag("")
                            Text("On").tag("on")
                            Text("Off").tag("off")
                        }
                        Picker("Block size", selection: compressedBlockBinding) {
                            Text("Matched to the original").tag(0)
                            Text("4×4").tag(4)
                            Text("6×6").tag(6)
                        }
                        .pickerStyle(.segmented).disabled(library.games.first { $0.id == library.selection }?.compressedTextures == "off")
                        note("The Apple TV's GPU has no BC texture formats, so the game's BC1/2/3/7 textures would be stored as RGBA8, 4 to 8 times their size. On, and Automatic, which is on for the Apple TV, prepares them as ASTC on this Mac while building and sends them with the game files (it can add several GB), and the game stores them that way; if they can't be prepared the build stops and says why. Matched keeps each texture about its original size: BC1 textures (the most compact Switch format) are slightly softer at 6×6. 4×4 is sharpest but BC1 textures double in size; 6×6 for everything is smallest. Off keeps them as RGBA8.")
                        Picker("Store textures once", selection: textureOnceBinding) {
                            Text("Automatic").tag("")
                            Text("On").tag("on")
                            Text("Off").tag("off")
                        }
                        .disabled(library.games.first { $0.id == library.selection }?.compressedTextures == "off")
                        note("Without it, each BC texture is on the Apple TV twice: the game's original and its ASTC copy. On, and Automatic, which is on whenever Compressed textures is, keeps one: the game files are rewritten on this Mac with the original textures cut out (the original game files are not changed), which can save several GB on the Apple TV. If that can't be done the build carries on and stores them twice.")
                        Picker("Compress game data", selection: compressGameDataBinding) {
                            Text("Automatic").tag("")
                            Text("On").tag("on")
                            Text("Off").tag("off")
                        }
                        note("On, and Automatic, which is on, compresses the game files on this Mac while building (lossless: the game reads exactly the same data) and sends them in that form, which can save several GB on the Apple TV. It takes a few minutes more to build. If that can't be done the build carries on and sends the files as they are.")
                        if library.info?.res_scale == true {
                            Picker("Resolution scale", selection: resScaleBinding) {
                                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text("\(Int($0 * 100)) %").tag($0) }
                            }
                            note("Renders the game's 3D larger or smaller than the game chose, for any game. Above 100 % it takes more GPU time and much more memory (200 % takes about four times the memory of each scaled target), and the Apple TV stops an app past about 2 GB. 100 % is off.")
                        }
                        Toggle("Metal 4 pipelines", isOn: flagBinding(\.metal4Pipelines))
                        note("Turns on DM_PSO_MTL4 and keeps the pulling shader libraries in the build. Experimental.")
                        TextField("Pipeline archive GPU", text: textBinding(\.pipelineGPU), prompt: Text("Empty for none, or g18p"))
                        note("GPU architectures, separated by commas, to make a pipeline archive for on this Mac. Empty builds no archive, as before.")
                        Text("Extra environment switches").font(.callout)
                        TextEditor(text: textBinding(\.extraEnvironment))
                            .font(.system(.caption, design: .monospaced)).frame(minHeight: 64)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                        note("One KEY=VALUE per line, with capital letters, digits and underscores in the key. Blank lines and lines starting with # are skipped. These replace a generated switch with the same name.")
                        note("Advanced options are saved for this game and take effect at the next Build & Install.")
                    }
                    .padding(.top, 6)
                }
            }
            Section("Game keys") {
                LabeledContent("prod.keys") {
                    HStack {
                        Text(library.keys.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent + "/prod.keys" } ?? "Not found").foregroundStyle(.secondary)
                        Button("Choose…") { choosingKeys = true }
                    }
                }
                Text("Select the keys from your own Switch for games, updates and DLC. TVPort reads this file where it is and never includes it in the built app.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped).scrollDisabled(true)
        .fileImporter(isPresented: $choosingKeys, allowedContentTypes: [.data, .item]) { result in
            if case .success(let url) = result { library.update { $0.keys = url.path } }
        }
    }

    private func place(_ game: Game) -> String {
        (library.backups[game.folder]?.last_backup_place ?? library.info?.last_backup_place) == "icloud" ? "iCloud Drive" : "this Mac"
    }

    private var pagingBinding: Binding<String> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?.gameMemoryPaging ?? "" }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0.gameMemoryPaging = value.isEmpty ? nil : value }
        })
    }

    private var compressedTexturesBinding: Binding<String> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?.compressedTextures ?? "" }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0.compressedTextures = value.isEmpty ? nil : value }
        })
    }

    private var textureOnceBinding: Binding<String> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?.textureOnce ?? "" }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0.textureOnce = value.isEmpty ? nil : value }
        })
    }

    private var compressGameDataBinding: Binding<String> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?.compressGameData ?? "" }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0.compressGameData = value.isEmpty ? nil : value }
        })
    }

    private var compressedBlockBinding: Binding<Int> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?.compressedTextureBlock ?? 0 }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0.compressedTextureBlock = value == 6 || value == 4 ? value : nil }
        })
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func textBinding(_ path: WritableKeyPath<Game, String?>) -> Binding<String> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?[keyPath: path] ?? "" }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0[keyPath: path] = value.isEmpty ? nil : value }
        })
    }

    private func flagBinding(_ path: WritableKeyPath<Game, Bool?>) -> Binding<Bool> {
        let gameID = library.selection
        return Binding(get: { library.games.first { $0.id == gameID }?[keyPath: path] ?? false }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0[keyPath: path] = value ? true : nil }
        })
    }

    private var playersBinding: Binding<String> {
        Binding(get: { library.current?.players ?? "" }, set: { value in library.update { $0.players = value } })
    }

    private var profileFPS: Int? {
        guard let fps = library.info?.fps_target, [30, 60].contains(fps) else { return nil }
        return fps
    }

    private var frameRateNote: String {
        guard let info = library.info else { return "Frame-rate selection is unavailable until the game has been checked." }
        if info.title_id.isEmpty { return "Frame-rate selection becomes available once a supported game profile is detected. Until then, the game uses its own frame rate." }
        guard profileFPS != nil else { return "This game's profile does not support choosing a frame rate. The game uses its own frame rate." }
        return "At 30 the TV does half the work, so it heats up more slowly and loads faster, and a game the TV cannot run at 60 is steadier. Up to 60 holds 60 where the TV keeps up and 30 where it does not. Takes effect at the next Build & Install."
    }

    private func fpsBinding(_ profile: Int) -> Binding<Int> {
        Binding(get: { profile == 0 ? 0 : library.current?.fpsTarget ?? profile }, set: { value in
            guard profile != 0 else { return }
            library.update { $0.fpsTarget = value == profile ? nil : value }
        })
    }

    private var swapABBinding: Binding<Bool> {
        Binding(get: { library.current?.swapsAB ?? false }, set: { library.setButtonSwap(ab: $0) })
    }

    private var swapXYBinding: Binding<Bool> {
        Binding(get: { library.current?.swapsXY ?? false }, set: { library.setButtonSwap(xy: $0) })
    }

    private var coolBinding: Binding<Bool> {
        Binding(get: { library.current?.coolWhenHot ?? true }, set: { value in library.update { $0.coolWhenHot = value ? nil : false } })
    }

    private var upscalerBinding: Binding<String> {
        Binding(get: { library.current?.upscaler ?? "game" }, set: { value in library.update { $0.upscaler = value == "game" ? nil : value } })
    }

    private var resScaleBinding: Binding<Double> {
        Binding(get: { library.current?.resScale ?? 1 }, set: { value in library.update { $0.resScale = value == 1 ? nil : value } })
    }
    private var renderScaleBinding: Binding<Double> {
        Binding(get: { library.current?.renderScale ?? 1 }, set: { value in library.update { $0.renderScale = value < 1 ? value : nil } })
    }

    private func binding<T>(_ path: WritableKeyPath<Game, T>, default fallback: T) -> Binding<T> {
        // SwiftUI can read a control's binding while removing its game view.
        // Keep it tied to that game and tolerate the game no longer existing.
        let gameID = library.selection
        return Binding(get: {
            library.games.first { $0.id == gameID }?[keyPath: path] ?? fallback
        }, set: { value in
            guard library.selection == gameID else { return }
            library.update { $0[keyPath: path] = value }
        })
    }
}

struct LastRunStatsView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Last Run Stats").font(.title2.weight(.semibold))
            Text(library.info?.name ?? "Game").foregroundStyle(.secondary)
            if library.readingDiagnosis {
                ProgressView("Reading the last run from the Apple TV…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if let error = library.diagnosisError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .textSelection(.enabled)
            } else if let diagnosis = library.diagnosis {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if diagnosis.run.last_frame > 0 || diagnosis.run.peak_mb > 0 || diagnosis.run.worst_ms > 0 {
                            DiagnosisCard(diagnosis: diagnosis)
                        } else {
                            Text("The game left a log, but no performance readings yet. Play beyond the loading screens, then refresh.")
                            ForEach(diagnosis.verdicts, id: \.self) { Text($0) }
                        }
                    }.textSelection(.enabled)
                }.frame(maxHeight: 240)
                DisclosureGroup("Show Run Log", isExpanded: $showLog) {
                    SelectableLogView(text: diagnosis.log, accessibilityLabel: "Last run log").frame(height: 220)
                }
            }
            HStack {
                if !library.readingDiagnosis {
                    Button("Refresh") { library.diagnose() }
                    if let diagnosis = library.diagnosis, library.diagnosisError == nil {
                        LogExportButton(text: diagnosis.log,
                                        filename: "\(library.info?.name ?? "Game") - Last Run.txt")
                    }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 650)
    }
}

struct DiagnosisCard: View {
    let diagnosis: Diagnosis

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last Run").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 4) {
                GridRow { stat("Peak memory", "\(Int(diagnosis.run.peak_mb)) MB"); stat("Long frames", "\(diagnosis.run.hitches)"); stat("Worst frame", "\(Int(diagnosis.run.worst_ms)) ms") }
                GridRow { stat("Closest to limit", diagnosis.run.min_headroom_mb.map { "\(Int($0)) MB left" } ?? "Not reported"); stat("Texture loading", "\(Int(diagnosis.run.texture_ms)) ms"); stat("Shaders", "\(Int(diagnosis.run.pipeline_ms)) ms") }
            }
            ForEach(diagnosis.verdicts, id: \.self) { Label($0, systemImage: "arrow.right.circle") }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
        }
    }
}

struct ProgressPanel: View {
    @EnvironmentObject var library: Library
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                switch library.selectedRun {
                case .idle:
                    if !library.selectedStage.isEmpty { Text(library.selectedStage).foregroundStyle(.secondary) }
                case .running:
                    ProgressView().controlSize(.small)
                    Text(library.selectedStage).lineLimit(1)
                case .succeeded: Label(library.selectedStage, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Label("Failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
                if !library.selectedLog.isEmpty {
                    if library.selectedRun != .idle || !library.selectedStage.isEmpty {
                        Text("|").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                    Button(showLog ? "Hide Log" : "Show Log") { showLog.toggle() }.buttonStyle(.link)
                }
                Spacer()
                if !library.selectedLog.isEmpty {
                    LogExportButton(text: library.selectedLog.joined(separator: "\n"),
                                    filename: "\(library.current?.name ?? "Game") - Build Log.txt")
                }
            }
            if library.selectedRun == .running, let progress = library.selectedProgress { ProgressView(value: progress) }
            if case .failed(let message) = library.selectedRun {
                Text(message).font(.callout).textSelection(.enabled).lineLimit(8).foregroundStyle(.red)
            }
            if showLog && !library.selectedLog.isEmpty {
                SelectableLogView(text: library.selectedLog.joined(separator: "\n"))
                    .frame(height: 170)
            }
        }
        .padding(12)
        .onChange(of: library.selection) { _, _ in showLog = false }
        .onChange(of: library.selectedLog.isEmpty) { _, isEmpty in
            if isEmpty { showLog = false }
        }
    }
}

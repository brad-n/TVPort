import Foundation
import SwiftUI

enum RenderMode: String, Codable, CaseIterable, Identifiable {
    case handheld, docked
    var id: String { rawValue }
    var label: String { self == .handheld ? "Handheld (720p)" : "Docked (900p)" }
    var note: String {
        self == .handheld ? "Lighter on the GPU and on memory. Some games lose motion controls in this mode."
                          : "Sharper, but the A15 can't always hold it, and it leaves less memory."
    }
}

enum TextureDetail: Int, Codable, CaseIterable, Identifiable {
    case full = 0, high = 1024, medium = 512, low = 256
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .full: return "Full"
        case .high: return "High (1024)"
        case .medium: return "Medium (512)"
        case .low: return "Low (256)"
        }
    }
}

struct Game: Codable, Identifiable, Hashable {
    var folder: String
    var name: String
    var titleID = ""
    var artwork: String?
    var artworkCrop: ArtworkCrop? = ArtworkCrop()
    var topShelfArtwork: String?
    var topShelfCrop: ArtworkCrop? = ArtworkCrop()
    var buildFolder: String?
    var buildNextToOriginal: Bool?
    var lastBuildPath: String?
    var built: Bool?
    var keys: String?
    var mode: RenderMode = .handheld
    var texture: TextureDetail = .medium
    var renderScale: Double?   // the 3D views at this fraction of the game's size, for games with a render-scale stub; nil = full size. Optional: library.json saved before it decodes as is
    var coolWhenHot: Bool?     // frame-step games hold 30 fps while the TV is thermally serious; nil = on (the engine's default)
    var fpsTarget: Int?        // 30 or 60 in place of the profile's fps_target; nil = the profile's
    var swapABXY: Bool?       // Legacy combined choice, retained when reading older libraries.
    var swapAB: Bool?
    var swapXY: Bool?
    var swapsAB: Bool { swapAB ?? swapABXY ?? false }
    var swapsXY: Bool { swapXY ?? swapABXY ?? false }
    var showFPS = false
    var players: String?
    // Advanced: all optional so library.json saved before them decodes as is; nil / empty / false = today's behaviour
    var allowDamagedManual: Bool?
    var extractorArguments: String?   // shell-style words for nx_extract's extraction calls
    var metal4Pipelines: Bool?
    var gameMemoryPaging: String?     // "on" / "off"; nil = Automatic (the engine's default for the target). A tri-state, not a tvOS flag, so other targets can share it
    var compressedTextures: String?   // "on" / "off"; nil = Automatic (on for Apple TV builds). A tri-state and a block size, not tvOS flags, so other targets can share them
    var compressedTextureBlock: Int?  // ASTC block of the compressed textures: 4 (4x4, the default) or 6 (6x6, about 2.3 times smaller, softer)
    var pipelineGPU: String?          // GPU architectures for the pipeline archive (build script --gpu); empty = none
    var extraEnvironment: String?     // KEY=VALUE lines for the app's env file
    var addons: [GameAddon]?
    var id: String { folder }

    /// The build's options for the Advanced section; each is left out at its default.
    var advancedArguments: [String] {
        var arguments: [String] = []
        if allowDamagedManual == true { arguments.append("--allow-damaged-manual") }
        for word in Game.shellWords(extractorArguments ?? "") { arguments.append("--nx-extract-arg=\(word)") }
        if metal4Pipelines == true { arguments.append("--pso-mtl4") }
        if let paging = gameMemoryPaging, paging == "on" || paging == "off" { arguments += ["--guest-file", paging] }
        if let choice = compressedTextures, choice == "on" || choice == "off" { arguments += ["--astc", choice] }
        if compressedTextureBlock == 6 { arguments += ["--astc-block", "6"] }
        let gpu = (pipelineGPU ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !gpu.isEmpty { arguments += ["--gpu", gpu] }
        for line in (extraEnvironment ?? "").split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !text.hasPrefix("#") { arguments += ["--extra-env", text] }
        }
        return arguments
    }

    /// Splits like a shell would for the common cases: whitespace separates words, and single or double quotes keep spaces in one.
    static func shellWords(_ text: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, started = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character; started = true
            } else if character.isWhitespace {
                if started || !current.isEmpty { words.append(current) }
                current = ""; started = false
            } else {
                current.append(character)
            }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
}

struct BuildResult {
    let run: Run
    let stage: String
    let log: [String]
}

enum Run: Equatable {
    case idle, running, succeeded, failed(String)
}

@MainActor
final class Library: ObservableObject {
    @Published var games: [Game] = []
    @Published var selection: Game.ID? {
        didSet { if oldValue != selection { restoreSelectedArtwork() } }
    }
    @Published var info: GameInfo?
    @Published var automaticArtwork: String?
    @Published var artworkStatus = ""
    @Published var preview: NSImage?
    @Published var topShelfPreview: NSImage?
    @Published var devices: [AppleTV] = []
    @Published var device: AppleTV.ID?
    @Published var team = ""
    @Published var run = Run.idle
    @Published private(set) var runGameID: Game.ID?
    @Published private(set) var buildQueue = BuildQueue()
    @Published private var completedBuilds: [Game.ID: BuildResult] = [:]
    @Published var stage = ""
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var diagnosis: Diagnosis?
    @Published var showingDiagnosis = false
    @Published var readingDiagnosis = false
    @Published var diagnosisError: String?
    @Published var notice: String?
    @Published var checkingAddonGame: String?
    @Published var addonError: String?
    @Published var setup: SetupReport?
    @Published var settingUp = false
    @Published var setupStage = ""
    @Published var setupFailure: String?
    @Published var showingSetup = false
    @Published var transferringSaves = false
    @Published private(set) var automaticallyBackingUp = false
    @Published private(set) var automaticBackupNotice: String?
    @Published var backups: [String: BackupStatus] = [:]
    @Published var icloudBackups = UserDefaults.standard.bool(forKey: "BackUpToICloud") {
        didSet { UserDefaults.standard.set(icloudBackups, forKey: "BackUpToICloud") }
    }
    @Published var icloudAvailable = true
    @Published var defaultBuildFolder = UserDefaults.standard.string(forKey: "DefaultBuildFolder") ?? "" {
        didSet { UserDefaults.standard.set(defaultBuildFolder, forKey: "DefaultBuildFolder") }
    }
    private var building: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewRequest = UUID()
    private struct PreviewKey: Equatable {
        let art: String
        let artStamp: String
        let crop: ArtworkCrop?
        let shelfArt: String?
        let shelfStamp: String
        let shelfCrop: ArtworkCrop?
    }
    private struct CachedPreview {
        let key: PreviewKey
        let icon: NSImage
        let shelf: NSImage
        let automaticArtwork: String?
    }
    private var artworkPreviews: [Game.ID: CachedPreview] = [:]
    private var recentArtwork: [Game.ID] = []
    private static let backupInterval: Double = 30 * 60

    private static let store = Backend.data.appendingPathComponent("library.json")
    private static let previews = FileManager.default.temporaryDirectory.appendingPathComponent("TVPortPreviews", isDirectory: true)

    private struct ControllerDefaults: Codable {
        var swapAB: Bool
        var swapXY: Bool
    }
    private var controllerDefaults: ControllerDefaults?
    private static let controllerDefaultsFile = Backend.data.appendingPathComponent("controller-defaults.json")

    init() {
        if let data = try? Data(contentsOf: Self.controllerDefaultsFile) {
            controllerDefaults = try? JSONDecoder().decode(ControllerDefaults.self, from: data)
        }
        if let data = try? Data(contentsOf: Self.store), let saved = try? JSONDecoder().decode([Game].self, from: data) { games = saved }
        selection = games.first?.id
        try? FileManager.default.createDirectory(at: Self.previews, withIntermediateDirectories: true)
    }

    var artworkPath: String? { current?.artwork ?? automaticArtwork ?? info?.icon }

    var current: Game? { games.first { $0.id == selection } }
    // Keep build results and their log attached to the game that started the build.
    // Busy state remains global, including when another game is selected.
    var selectedRun: Run { selectedBuildResult?.run ?? .idle }
    var selectedStage: String { selectedBuildResult?.stage ?? "" }
    var selectedLog: [String] { selectedBuildResult?.log ?? [] }
    var selectedProgress: Double? { runGameID == selection ? progress : nil }
    private var selectedBuildResult: BuildResult? {
        if runGameID == nil || runGameID == selection { return BuildResult(run: run, stage: stage, log: log) }
        return selection.flatMap { completedBuilds[$0] }
    }
    var showsRunForSelection: Bool { selectedRun != .idle || !selectedStage.isEmpty || !selectedLog.isEmpty }
    var queuedBuildCount: Int { buildQueue.pending.count + (buildQueue.active == nil ? 0 : 1) }
    var buildQueueSummary: String {
        if buildQueue.paused { return "\(queuedBuildCount) in queue · paused" }
        if buildQueue.active != nil {
            return "\(queuedBuildCount) in queue · 1 building, \(buildQueue.pending.count) waiting"
        }
        return "\(queuedBuildCount) in queue · waiting"
    }
    func buildBadge(for gameID: Game.ID) -> String? {
        if buildQueue.active?.gameID == gameID { return buildQueue.paused ? "Stopping…" : "Building" }
        guard let waitingPosition = buildQueue.position(gameID) else { return nil }
        let position = waitingPosition + (buildQueue.active == nil ? 0 : 1)
        return buildQueue.paused ? "Paused · \(position) in queue" : "Queued · \(position)"
    }
    func buildStatus(for gameID: Game.ID, built: Bool) -> String {
        buildBadge(for: gameID) ?? (built ? "Built" : "Ready to build")
    }
    var isBusy: Bool { buildQueue.active != nil || !buildQueue.pending.isEmpty || run == .running || settingUp || transferringSaves || automaticallyBackingUp || checkingAddonGame != nil }
    // Package inspection reads local files; automatic save backups only read the TV.
    var canEditAddons: Bool { buildQueue.active == nil && buildQueue.pending.isEmpty && run != .running && !settingUp && !transferringSaves && checkingAddonGame == nil }
    /// Unknown until the first check, which then does not hold anything back.
    var setupMissing: [Check] { setup?.checks.filter { !$0.ok } ?? [] }
    var bundleID: String? { info?.bundle_id }
    /// One prod.keys serves every game: this game's pick, then any other game's, then where the backend found one.
    var keys: String? { current?.keys ?? games.compactMap(\.keys).first ?? info?.keys }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(games) { try? data.write(to: Self.store) }
    }

    func update(_ change: (inout Game) -> Void) {
        guard let index = games.firstIndex(where: { $0.id == selection }) else { return }
        change(&games[index])
        save()
    }

    func setButtonSwap(ab: Bool? = nil, xy: Bool? = nil) {
        guard current != nil else { return }
        update { game in
            if let ab { game.swapAB = ab }
            if let xy { game.swapXY = xy }
        }
        guard let game = current else { return }
        controllerDefaults = ControllerDefaults(swapAB: game.swapsAB, swapXY: game.swapsXY)
        if let data = try? JSONEncoder().encode(controllerDefaults) {
            try? data.write(to: Self.controllerDefaultsFile, options: .atomic)
        }
    }

    func add(folder: URL) {
        if !games.contains(where: { $0.folder == folder.path }) {
            var game = Game(folder: folder.path, name: folder.lastPathComponent)
            game.swapAB = controllerDefaults?.swapAB ?? current?.swapsAB ?? false
            game.swapXY = controllerDefaults?.swapXY ?? current?.swapsXY ?? false
            games.append(game)
            save()
        }
        selection = folder.path
    }

    func remove(_ game: Game) {
        guard buildQueue.active?.gameID != game.id else { return }
        buildQueue.remove(game.id)
        completedBuilds.removeValue(forKey: game.id)
        artworkPreviews.removeValue(forKey: game.id)
        recentArtwork.removeAll { $0 == game.id }
        games.removeAll { $0.id == game.id }
        save()
        if selection == game.id { selection = games.first?.id }
    }

    func attachAddons(_ urls: [URL], to gameID: Game.ID) {
        guard canEditAddons, let game = games.first(where: { $0.id == gameID }), !urls.isEmpty else { return }
        var arguments = ["check-addons", game.folder]
        for url in urls where url.isFileURL { arguments += ["--source", url.path] }
        guard arguments.count > 2 else { addonError = "Drop local update or DLC files, or a folder containing them."; return }
        if let key = game.keys ?? keys { arguments += ["--keys", key] }
        checkingAddonGame = gameID
        Task {
            defer { checkingAddonGame = nil; startNextBuild() }
            do {
                let result = try await Backend.ask(GameAddonCheck.self, arguments)
                guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
                var items = games[index].addons ?? []
                let incomingIDs = Set(result.addons.map(\.title_id))
                let replacedPaths = Set(items.filter { incomingIDs.contains($0.title_id) }.map(\.path))
                items.removeAll { replacedPaths.contains($0.path) }
                for addon in result.addons {
                    items.removeAll { $0.title_id == addon.title_id }
                    items.append(addon)
                }
                games[index].addons = items
                games[index].titleID = result.title_id
                save()
                if selection == gameID { notice = "Updates and DLC added. Use Build & Install to apply them." }
            } catch { addonError = error.localizedDescription }
        }
    }

    func removeAddon(_ addon: GameAddon, from gameID: Game.ID) {
        guard canEditAddons, let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        // A merged package can contain multiple DLC entries. Remove its file as a unit.
        games[index].addons?.removeAll { $0.path == addon.path }
        save()
        if selection == gameID { notice = "Attachment removed. Use Build & Install to apply the change." }
    }

    /// Reads the selected game's folder and refreshes the Apple TV list.
    func refresh() async {
        guard !Task.isCancelled else { return }
        let gameID = selection
        previewTask?.cancel(); previewRequest = UUID()
        // A same-game refresh must keep its existing artwork while metadata is read.
        // In particular, cancelling a build must not clear images from a cancelled task.
        diagnosis = nil; notice = nil
        await refreshDevices()
        guard !Task.isCancelled, selection == gameID, let game = current else { return }
        do {
            let found = try await Backend.ask(GameInfo.self, ["inspect", game.folder])
            guard !Task.isCancelled, selection == game.id else { return }
            info = found
            if team.isEmpty, let known = found.team { team = known }
            update {
                $0.name = found.name
                if !found.title_id.isEmpty { $0.titleID = found.title_id }
                if let path = found.build_path { $0.lastBuildPath = path }
                $0.built = found.built ?? false
            }
            let titleID = found.artwork_title_id ?? found.title_id
            automaticArtwork = ArtworkStore.cachedBanner(titleID)?.path ?? automaticArtwork
            await renderPreview()
            await findArtwork(titleID: titleID, gameID: game.id)
        } catch {
            guard !Task.isCancelled, selection == gameID else { return }
            notice = error.localizedDescription
        }
    }

    func findArtwork(titleID: String, gameID: Game.ID) async {
        guard !titleID.isEmpty else {
            artworkStatus = "Automatic artwork needs a title ID in the game filename or an existing build."
            return
        }
        guard current?.artwork == nil else { return }
        artworkStatus = automaticArtwork == nil ? "Looking up eShop artwork…" : ""
        _ = await ArtworkStore.shared.fetchMissing([titleID])
        guard selection == gameID else { return }
        automaticArtwork = ArtworkStore.cachedBanner(titleID)?.path
        artworkStatus = automaticArtwork == nil ? "No eShop artwork available. Using the game's icon when available, or choose an image." : ""
        await renderPreview()
    }

    func refreshDevices() async {
        struct Answer: Decodable { let devices: [AppleTV] }
        guard let answer = try? await Backend.ask(Answer.self, ["devices"]) else { return }
        devices = answer.devices
        if device == nil || !devices.contains(where: { $0.id == device }) { device = devices.first?.id }
    }

    func setArtwork(_ url: URL?) {
        update { $0.artwork = url?.path; $0.artworkCrop = ArtworkCrop() }
        schedulePreview()
        if url == nil, let game = current {
            let titleID = info?.artwork_title_id ?? info?.title_id ?? game.titleID
            Task { await findArtwork(titleID: titleID, gameID: game.id) }
        }
    }

    func setArtworkCrop(_ crop: ArtworkCrop?) {
        update { $0.artworkCrop = crop }
        schedulePreview()
    }

    func setTopShelfArtwork(_ url: URL?) {
        update { $0.topShelfArtwork = url?.path; $0.topShelfCrop = ArtworkCrop() }
        schedulePreview()
    }

    func setTopShelfCrop(_ crop: ArtworkCrop?) {
        update { $0.topShelfCrop = crop }
        schedulePreview()
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewRequest = UUID() // Invalidate a renderer already running before the next one starts.
        previewTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            await renderPreview()
        }
    }

    private func previewKey(_ game: Game, art: String) -> PreviewKey {
        func stamp(_ path: String?) -> String {
            guard let path, let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
            return "\(attributes[.modificationDate] ?? "")|\(attributes[.size] ?? "")"
        }
        return PreviewKey(art: art, artStamp: stamp(art), crop: game.artworkCrop,
                          shelfArt: game.topShelfArtwork, shelfStamp: stamp(game.topShelfArtwork), shelfCrop: game.topShelfCrop)
    }

    private func restoreSelectedArtwork() {
        previewTask?.cancel(); previewRequest = UUID()
        info = nil; diagnosis = nil; notice = nil; artworkStatus = ""
        guard let game = current, let cached = artworkPreviews[game.id],
              cached.key == previewKey(game, art: game.artwork ?? cached.key.art) else {
            preview = nil; topShelfPreview = nil; automaticArtwork = nil
            return
        }
        preview = cached.icon; topShelfPreview = cached.shelf
        automaticArtwork = cached.automaticArtwork
        touchArtwork(game.id)
    }

    private func touchArtwork(_ gameID: Game.ID) {
        recentArtwork.removeAll { $0 == gameID }
        recentArtwork.append(gameID)
        // Bound decoded-image memory while keeping recently visited games instant.
        while recentArtwork.count > 20 { artworkPreviews.removeValue(forKey: recentArtwork.removeFirst()) }
    }

    /// Preview and installed artwork use the same renderer and crop arguments.
    func renderPreview() async {
        let request = UUID()
        previewRequest = request
        guard let game = current, let art = artworkPath ?? current?.topShelfArtwork else { preview = nil; topShelfPreview = nil; return }
        let key = previewKey(game, art: art)
        if let cached = artworkPreviews[game.id], cached.key == key {
            preview = cached.icon; topShelfPreview = cached.shelf
            touchArtwork(game.id)
            return
        }
        let out = Self.previews.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: out) }
        struct Answer: Decodable { let preview: String }
        do {
            _ = try await Backend.ask(Answer.self, ["preview", "--art", art, "--out", out.path] + (game.artworkCrop?.arguments ?? []))
            guard previewRequest == request, current?.id == game.id, !Task.isCancelled else { return }
            preview = NSImage(contentsOf: out)
            let shelfOut = Self.previews.appendingPathComponent(UUID().uuidString + ".png")
            defer { try? FileManager.default.removeItem(at: shelfOut) }
            _ = try await Backend.ask(Answer.self, ["preview", "--top-shelf", "--art", art, "--out", shelfOut.path]
                + (game.artworkCrop?.arguments ?? []) + game.topShelfArguments)
            guard previewRequest == request, current?.id == game.id, !Task.isCancelled else { return }
            topShelfPreview = NSImage(contentsOf: shelfOut)
            if let preview, let topShelfPreview {
                artworkPreviews[game.id] = CachedPreview(key: key, icon: preview, shelf: topShelfPreview,
                                                        automaticArtwork: automaticArtwork ?? info?.icon)
                touchArtwork(game.id)
            }
        } catch {
            guard previewRequest == request, current?.id == game.id, !Task.isCancelled else { return }
            preview = nil; topShelfPreview = nil
            notice = "That artwork could not be read: \(error.localizedDescription)"
        }
    }

    func build(install: Bool) {
        guard let game = current, let info, info.folder == game.folder,
              !settingUp, !transferringSaves, checkingAddonGame == nil,
              setupMissing.isEmpty, !install || device != nil,
              buildQueue.active?.gameID != game.id, buildQueue.position(game.id) == nil else { return }
        var arguments = [game.folder, "--mode", game.mode.rawValue, "--texture-cap", String(game.texture.rawValue)]
        if game.swapsAB { arguments.append("--swap-ab") }
        if game.swapsXY { arguments.append("--swap-xy") }
        if game.showFPS { arguments.append("--fps") }
        if let scale = game.renderScale, scale < 1, info.render_scale == true { arguments += ["--render-scale", String(scale)] }
        if game.coolWhenHot == false, info.frame_step == true { arguments.append("--no-thermal-cap") }
        if let fps = game.fpsTarget, (info.fps_target ?? 0) != 0, fps != info.fps_target { arguments += ["--fps-target", String(fps)] }
        if !team.isEmpty { arguments += ["--team", team] }
        if let keys { arguments += ["--keys", keys] }
        if let players = game.players, !players.isEmpty { arguments += ["--players", players] }
        arguments += game.advancedArguments
        if let art = artworkPath { arguments += ["--art", art] }
        arguments += game.artworkCrop?.arguments ?? []
        arguments += game.topShelfArguments
        if icloudBackups { arguments.append("--icloud") }
        if install, let device { arguments += ["--device", device] }
        buildQueue.enqueue(QueuedBuild(gameID: game.id, name: game.name, arguments: arguments, install: install))
        // A new standalone build after an earlier failure is an explicit retry.
        if buildQueue.active == nil && buildQueue.pending.count == 1 { buildQueue.resume() }
        startNextBuild()
    }

    func removeQueuedBuild(_ gameID: Game.ID) { buildQueue.remove(gameID) }

    func resumeBuildQueue() {
        guard buildQueue.active == nil, !settingUp, !transferringSaves, checkingAddonGame == nil else { return }
        buildQueue.resume()
        startNextBuild()
    }

    private func startNextBuild() {
        guard !automaticallyBackingUp, !settingUp, !transferringSaves, checkingAddonGame == nil else { return }
        guard let request = buildQueue.next() else { return }
        runGameID = request.gameID
        completedBuilds.removeValue(forKey: request.gameID)
        run = .running; stage = "Starting"; progress = nil; log = []; notice = nil
        building = Task {
            var finished = false
            for await event in Backend.stream(["build"] + request.arguments) {
                switch event {
                case .stage(let name): stage = name; progress = nil; append(name)
                case .log(let line): append(line)
                case .progress(let value): progress = value
                case .failed(let message): run = .failed(message); finished = true
                case .done: run = .succeeded; stage = request.install ? "Installed on the Apple TV" : "Built"; progress = nil; finished = true
                }
            }
            if Task.isCancelled { run = .idle; stage = "Stopped"; progress = nil }
            else if !finished { run = .failed("The build stopped without saying why. See the log.") }
            let succeeded = run == .succeeded
            completedBuilds[request.gameID] = BuildResult(run: run, stage: stage, log: log)
            // Refresh the completed game's metadata even if the user selected another game.
            if succeeded,
               let found = try? await Backend.ask(GameInfo.self, ["inspect", request.gameID]),
               let index = games.firstIndex(where: { $0.id == request.gameID }) {
                games[index].built = found.built
                games[index].lastBuildPath = found.build_path
                save()
            }
            building = nil
            buildQueue.finish(succeeded: succeeded && !Task.isCancelled)
            startNextBuild()
            if !Task.isCancelled && selection == request.gameID { await refresh() }
        }
    }

    func cancel() {
        guard buildQueue.active != nil else { return }
        buildQueue.pause()
        stage = "Stopping…"
        building?.cancel()
    }

    /// What a build needs from this Mac. The first start of each release also unpacks the engine and makes its Python, without being asked.
    func checkSetup() async {
        guard Backend.developerFolder != nil else {
            setup = SetupReport(checks: [Check(name: "Xcode", ok: false, detail: "Not installed", fix: "Install Xcode from the App Store, open it once, then press Check Again.", command: "")],
                                ready: false, needs_setup: false, can_set_up: false)
            showingSetup = true
            return
        }
        do {
            let report = try await Backend.ask(SetupReport.self, ["doctor"])
            setup = report
            if report.needs_setup && report.can_set_up && !settingUp && setupFailure == nil { runSetup() }
        } catch { setupFailure = error.localizedDescription }
    }

    func runSetup() {
        guard !settingUp, run != .running else { return }
        settingUp = true; setupStage = "Starting"; setupFailure = nil
        Task {
            var failed: String?
            for await event in Backend.stream(["setup"]) {
                switch event {
                case .stage(let name): setupStage = name; append(name)
                case .log(let line): append(line)
                case .failed(let message): failed = message
                case .progress, .done: break
                }
            }
            settingUp = false; setupStage = ""; setupFailure = failed
            await checkSetup()
        }
    }

    func backUpSaves() {
        guard let game = current, let device, let bundleID else { return }
        notice = "Copying saves from the Apple TV…"
        Task {
            do {
                let backup = try await Backend.ask(SaveBackup.self, ["backup", game.folder, "--device", device, "--bundle", bundleID] + (icloudBackups ? ["--icloud"] : []))
                switch backup.state {
                case "unavailable": notice = "The Apple TV did not answer. Wake it with the remote, then try again."
                case "busy": notice = "The game was saving during each copy. Try again in a moment."
                default: notice = backup.files == 0 ? "The Apple TV has no saves for this game yet." : backup.changed ? "\(backup.files) save files backed up." : "The backup is already up to date."
                }
                await refresh()
            } catch { notice = error.localizedDescription }
        }
    }

    /// While the app is open: a round when it opens, then every few minutes, and soon after the TV can be reached again.
    func backUpEveryFewMinutes() async {
        while !Task.isCancelled {
            let wait = await backUpRound()
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// One round of automatic backups of every built game. It only reads the TV (backend.py autobackup), and is quiet when the TV is asleep or away, or the game is not installed.
    private func backUpRound() async -> Double {
        if devices.isEmpty { await refreshDevices() }
        let folders = games.map(\.folder)
        guard let device else { return Self.backupInterval }
        guard !isBusy else { return Self.backupInterval }   // builds and imports manage their own backups
        automaticallyBackingUp = true
        automaticBackupNotice = nil
        defer {
            automaticallyBackingUp = false
            startNextBuild()
        }
        let arguments = ["autobackup", "--device", device] + folders.flatMap { ["--folder", $0] } + (icloudBackups ? ["--icloud"] : [])
        guard let round = try? await Backend.ask(BackupRound.self, arguments) else {
            automaticBackupNotice = "Automatic backup could not finish. TVPort will try again automatically."
            return Self.backupInterval
        }
        if round.state == "unreachable" {
            automaticBackupNotice = "Apple TV unavailable. Automatic backup will try again; saved copies are still available."
        } else if round.state == "partial" {
            automaticBackupNotice = "Some saves could not be backed up. TVPort will try again automatically."
        }
        icloudAvailable = round.icloud
        for (folder, var status) in round.games {
            status.checked = status.checked ?? backups[folder]?.checked   // a round that could not ask keeps the last time the copy matched the TV
            backups[folder] = status
        }
        return Self.backupInterval
    }

    /// When the Mac's copy of a game's saves last matched the TV, or when its newest backup was made.
    func backedUp(_ game: Game) -> String? {
        let status = backups[game.folder]
        let time = status?.checked ?? status?.last_backup_time ?? (game.id == selection ? info?.last_backup_time : nil)
        guard let time else { return nil }
        let date = Date(timeIntervalSince1970: time)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened) : date.formatted(date: .abbreviated, time: .shortened)
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 4000 { log.removeFirst(log.count - 4000) }
    }

    func launch() {
        guard let device, let bundleID else { return }
        notice = nil
        Task {
            struct Answer: Decodable { let launched: String }
            do { _ = try await Backend.ask(Answer.self, ["launch", "--device", device, "--bundle", bundleID]) } catch { notice = error.localizedDescription }
        }
    }

    func diagnose() {
        guard !readingDiagnosis, let device, let bundleID else { return }
        showingDiagnosis = true
        readingDiagnosis = true
        diagnosis = nil
        diagnosisError = nil
        let gameID = selection
        Task {
            defer { readingDiagnosis = false }
            do {
                let result = try await Backend.ask(Diagnosis.self, ["diagnose", "--device", device, "--bundle", bundleID])
                guard selection == gameID else { showingDiagnosis = false; return }
                diagnosis = result
            } catch {
                guard selection == gameID else { showingDiagnosis = false; return }
                diagnosisError = error.localizedDescription
            }
        }
    }
}

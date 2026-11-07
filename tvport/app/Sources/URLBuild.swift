import SwiftUI
import AppKit

/// Receives tvport:// URLs through the app delegate (so no extra window is opened), holding any that
/// arrive before the library is attached, e.g. when a URL launches the app.
@MainActor
final class URLBuildRouter {
    static let shared = URLBuildRouter()
    private weak var library: Library?
    private var waiting: [URL] = []

    func attach(_ library: Library) {
        self.library = library
        let urls = waiting; waiting = []
        for url in urls { Task { await library.handle(url: url) } }
    }

    func receive(_ urls: [URL]) {
        guard let library else { waiting += urls; return }
        for url in urls { Task { await library.handle(url: url) } }
    }
}

final class URLBuildDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in URLBuildRouter.shared.receive(urls) }
    }
}

extension Library {
    /// tvport://build?title=<16 hex>[&install=1|0]: the same request as clicking Build & Install,
    /// through `build(install:)`. Every refusal is one log line, with no selection change and no dialog.
    func handle(url: URL) async {
        let command: TVPortURLCommand
        switch TVPortURLCommand.parse(url) {
        case .failure(let reason): append("URL build refused: \(reason.message)"); return
        case .success(let parsed): command = parsed
        }
        guard case .build(let titleID, let install) = command else { return }
        func refuse(_ why: String) { append("URL build refused (\(titleID)): \(why)") }

        guard let game = games.first(where: { $0.titleID.uppercased() == titleID }) else { return refuse("unknown title") }
        func busy() -> Bool { buildQueue.active?.gameID == game.id || buildQueue.position(game.id) != nil }
        if busy() { return refuse("already building or queued") }
        if install {
            if devices.isEmpty { await refreshDevices() }
            if device == nil { return refuse("no Apple TV selected") }
        }
        // Read-only look at the game (not the selection), so a keys problem refuses before anything changes.
        guard let found = try? await Backend.ask(GameInfo.self, ["inspect", game.folder]) else { return refuse("could not read the game") }
        let hasKeys = (game.keys ?? games.compactMap(\.keys).first ?? found.keys) != nil
        guard found.prepared || (!found.sources.isEmpty && hasKeys) else { return refuse("keys missing") }
        if busy() { return refuse("already building or queued") }

        // build(install:) works on the selected game, as the button does.
        if selection != game.id { selection = game.id }
        await refresh()
        build(install: install)
        if !busy() { refuse("could not start (busy or setup incomplete)") }
    }
}

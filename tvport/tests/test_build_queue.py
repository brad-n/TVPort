"""Exercise the real library with an in-memory backend; no games or devices touched."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SOURCES = REPO / 'tvport/app/Sources'


@unittest.skipUnless(sys.platform == 'darwin', 'macOS SwiftUI required')
class BuildQueueTests(unittest.TestCase):
    def test_queue_selection_cancel_and_cover_defaults(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # Reuse production wire types and argument generation with a fake transport.
            definitions = (SOURCES / 'Backend.swift').read_text().split('enum Backend {')[0]
            definitions += '\n' + (SOURCES / 'GameAddons.swift').read_text().split('struct GameAddonDropTarget')[0]
            definitions += '\n' + (SOURCES / 'TopShelfArtworkCard.swift').read_text().split('struct TopShelfArtworkCard')[0]
            stub = root / 'Transport.swift'
            stub.write_text(definitions + r'''
@MainActor enum Backend {
    static let data = URL(fileURLWithPath: CommandLine.arguments[1])
    static let developerFolder: String? = "/fake"
    static var starts: [[String]] = []
    static var continuations: [AsyncStream<BuildEvent>.Continuation] = []
    static var reads = 0
    static var allowPreviews = false
    static var previewReads = 0
    static var backupContinuation: CheckedContinuation<String, Error>?
    static func stream(_ arguments: [String]) -> AsyncStream<BuildEvent> {
        starts.append(arguments)
        return AsyncStream { continuations.append($0) }
    }
    static func ask<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        reads += 1
        if arguments.first == "check-addons" {
            await Task.yield()
            return try JSONDecoder().decode(type, from: Data(#"{"title_id":"0100000000000000","addons":[{"path":"/external/update.nsp","kind":"Update","title_id":"0100000000000800","version":1}]}"#.utf8))
        }
        if arguments.first == "autobackup" {
            let json: String = try await withCheckedThrowingContinuation { backupContinuation = $0 }
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        }
        if allowPreviews && arguments.first == "preview" {
            previewReads += 1
            let output = arguments[arguments.firstIndex(of: "--out")! + 1]
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
            for x in 0..<4 { for y in 0..<4 { bitmap.setColor(.red, atX: x, y: y) } }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
            return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: ["preview":output]))
        }
        throw BackendError(message: "No device in this test")
    }
}
@MainActor final class ArtworkStore {
    static let shared = ArtworkStore()
    static func cachedBanner(_ id: String) -> URL? { nil }
    func fetchMissing(_ ids: [String]) async {}
}
''')
            checks = root / 'Checks.swift'
            checks.write_text(r'''
import Foundation
import AppKit

@main struct Checks {
    @MainActor static func settle(_ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Async operation did not finish")
    }
    @MainActor static func select(_ game: Game, _ library: Library) {
        library.selection = game.id
        let object: [String: Any] = ["folder":game.folder, "title_id":"", "name":game.name,
            "version":"1.0", "sources":[], "prepared":true]
        library.info = try! JSONDecoder().decode(GameInfo.self, from: JSONSerialization.data(withJSONObject: object))
    }
    @MainActor static func main() async {
        let library = Library()
        library.keepSwitchTVCurrent = false   // SwitchTV refreshes after an install (SwitchTVSync, test_switchtv_sync.py); this test counts only game builds
        var a = Game(folder: "/sample/A", name: "A"); a.swapAB = true
        var b = Game(folder: "/sample/B", name: "B"); b.swapXY = true
        let c = Game(folder: "/sample/C", name: "C")
        library.games = [a, b, c]
        assert(a.topShelfCrop == ArtworkCrop())
        assert(a.artworkCrop == ArtworkCrop())
        let old = try! JSONDecoder().decode(Game.self, from: Data(#"{"folder":"/old","name":"Old","titleID":"","mode":"handheld","texture":512,"showFPS":false}"#.utf8))
        assert(old.topShelfCrop == nil) // Preserve existing Automatic choices.
        assert(old.artworkCrop == nil)
        assert(!old.swapsAB && !old.swapsXY)
        var legacy = old; legacy.folder = "/legacy"; legacy.swapABXY = true
        let migrated = try! JSONDecoder().decode(Game.self, from: JSONEncoder().encode(legacy))
        assert(migrated.swapsAB && migrated.swapsXY)
        library.games = [migrated, old]
        select(migrated, library)
        library.setButtonSwap(ab: false)
        assert(library.current!.swapsAB == false && library.current!.swapsXY)
        library.add(folder: URL(fileURLWithPath: "/sample/new"))
        assert(!library.current!.swapsAB && library.current!.swapsXY)
        library.setButtonSwap(ab: true)
        library.selection = old.id // Switching games must not change the saved default.
        let reloaded = Library()
        reloaded.add(folder: URL(fileURLWithPath: "/sample/reopened"))
        assert(reloaded.current!.swapsAB && reloaded.current!.swapsXY)
        reloaded.setButtonSwap(xy: false)
        reloaded.add(folder: URL(fileURLWithPath: "/sample/AB-only"))
        assert(reloaded.current!.swapsAB && !reloaded.current!.swapsXY)
        assert(!old.swapsAB && !old.swapsXY)
        print("PASS: legacy pair migration, explicit off, independent defaults and persistence")
        library.games = [a, b, c]
        select(a, library)
        library.device = "TV-A"; library.team = "TEAM-A"
        library.build(install: true)
        await settle { Backend.starts.count == 1 }
        assert(Backend.starts[0].contains("--swap-ab") && !Backend.starts[0].contains("--swap-xy"))
        library.build(install: true) // Duplicate active request ignored.
        select(b, library)
        assert(!library.showsRunForSelection)
        library.device = "TV-B"; library.team = "TEAM-B"
        library.build(install: true); library.build(install: true)
        assert(library.buildQueue.pending.count == 1)
        assert(library.buildBadge(for: b.id) == "Queued · 2")
        select(c, library)
        library.build(install: true)
        assert(library.buildQueue.position(c.id) == 2)
        assert(library.queuedBuildCount == 3)
        assert(library.buildQueueSummary == "3 in queue · 1 building, 2 waiting")
        assert(library.buildStatus(for: a.id, built: false) == "Building")
        assert(library.buildStatus(for: b.id, built: true) == "Queued · 2")
        assert(library.buildStatus(for: c.id, built: false) == "Queued · 3")
        library.removeQueuedBuild(c.id)
        assert(library.buildQueue.position(c.id) == nil)
        library.build(install: true)
        library.device = "CHANGED"; library.team = "CHANGED"
        Backend.continuations[0].yield(.log("A log"))
        Backend.continuations[0].yield(.done(bundle: "A", signing: nil))
        // A done event alone must not start another process before stream termination.
        await settle { library.run == .succeeded }
        assert(Backend.starts.count == 1)
        Backend.continuations[0].finish()
        await settle { Backend.starts.count == 2 }
        let args = Backend.starts[1]
        assert(args[1] == b.id)
        assert(args.contains("--swap-xy") && !args.contains("--swap-ab"))
        assert(args[args.firstIndex(of: "--device")! + 1] == "TV-B")
        assert(args[args.firstIndex(of: "--team")! + 1] == "TEAM-B")
        select(a, library)
        assert(library.queuedBuildCount == 2)
        assert(library.buildQueueSummary == "2 in queue · 1 building, 1 waiting")
        assert(library.buildStatus(for: b.id, built: false) == "Building")
        assert(library.selectedStage == "Installed on the Apple TV")
        assert(library.selectedLog.contains("A log"))
        select(c, library)
        assert(!library.showsRunForSelection)
        Backend.continuations[1].yield(.failed("Test failure"))
        Backend.continuations[1].finish()
        await settle { library.buildQueue.active == nil }
        assert(library.buildQueue.paused && Backend.starts.count == 2)
        assert(library.buildQueue.position(c.id) == 1)
        select(b, library)
        assert(library.selectedRun == .failed("Test failure"))
        library.resumeBuildQueue()
        await settle { Backend.starts.count == 3 }
        select(c, library)
        let artwork = NSImage(size: NSSize(width: 10, height: 10))
        library.preview = artwork; library.topShelfPreview = artwork
        library.automaticArtwork = "/sample/art.png"
        library.cancel()
        assert(library.isBusy) // Still reserved until cancellation finishes.
        await settle { library.buildQueue.active == nil }
        assert(library.selectedStage == "Stopped")
        assert(library.preview === artwork && library.topShelfPreview === artwork)
        assert(library.automaticArtwork == "/sample/art.png")
        let reads = Backend.reads
        let cancelled = Task { await library.refresh() }
        cancelled.cancel()
        await cancelled.value
        assert(Backend.reads == reads)
        assert(library.preview === artwork)
        await library.refresh() // Same-game read failure also keeps the artwork.
        assert(library.preview === artwork && library.topShelfPreview === artwork)
        library.setTopShelfCrop(nil)
        library.setTopShelfArtwork(URL(fileURLWithPath: "/sample/new.png"))
        assert(library.current?.topShelfCrop == ArtworkCrop())
        let cachedLibrary = Library()
        let artFile = Backend.data.appendingPathComponent("art.png")
        try! Data("first image".utf8).write(to: artFile)
        let artGame = Game(folder: "/sample/art-game", name: "Artwork", artwork: artFile.path)
        cachedLibrary.games = [artGame, b]
        select(artGame, cachedLibrary)
        Backend.allowPreviews = true
        await cachedLibrary.renderPreview()
        assert(Backend.previewReads == 2)
        let firstPreview = cachedLibrary.preview!
        let firstShelf = cachedLibrary.topShelfPreview!
        select(b, cachedLibrary)
        assert(cachedLibrary.preview == nil)
        select(artGame, cachedLibrary)
        assert(cachedLibrary.preview === firstPreview && cachedLibrary.topShelfPreview === firstShelf)
        await cachedLibrary.renderPreview()
        assert(Backend.previewReads == 2) // Switching back does not render either image again.
        cachedLibrary.update { $0.artworkCrop = ArtworkCrop(scale: 2, x: 0, y: 0) }
        await cachedLibrary.renderPreview()
        assert(Backend.previewReads == 4)
        cachedLibrary.update { $0.topShelfCrop = nil }
        await cachedLibrary.renderPreview()
        assert(Backend.previewReads == 6)
        try! Data("replacement source image".utf8).write(to: artFile)
        await cachedLibrary.renderPreview()
        assert(Backend.previewReads == 8)
        for outcome in ["done", "unreachable", "error"] {
            let waiting = Library()
            waiting.games = [a, b]
            waiting.devices = [AppleTV(id: "TV", name: "Test TV", model: nil, os: nil, connected: true, developer_mode: true)]
            waiting.device = "TV"
            select(a, waiting)
            let before = Backend.starts.count
            let backupTask = Task { await waiting.backUpEveryFewMinutes() }
            await settle { waiting.automaticallyBackingUp && Backend.backupContinuation != nil }
            assert(waiting.isBusy) // Transfers remain protected while browsing is allowed by the views.
            assert(waiting.canEditAddons)
            waiting.attachAddons([URL(fileURLWithPath: "/external/update.nsp")], to: a.id)
            assert(waiting.checkingAddonGame == a.id && !waiting.canEditAddons)
            await settle { waiting.checkingAddonGame == nil }
            assert(waiting.automaticallyBackingUp)
            assert(waiting.games[0].addons?.first?.path == "/external/update.nsp")
            waiting.removeAddon(waiting.games[0].addons!.first!, from: a.id)
            assert(waiting.games[0].addons?.isEmpty == true)
            waiting.transferringSaves = true
            assert(!waiting.canEditAddons)
            waiting.transferringSaves = false
            waiting.build(install: true)
            assert(!waiting.canEditAddons)
            select(b, waiting)
            waiting.build(install: true)
            waiting.removeQueuedBuild(b.id)
            assert(waiting.buildQueue.pending.count == 1)
            assert(waiting.buildQueue.active == nil && Backend.starts.count == before)
            let continuation = Backend.backupContinuation!
            Backend.backupContinuation = nil
            if outcome == "error" {
                continuation.resume(throwing: BackendError(message: "Connection lost"))
            } else {
                continuation.resume(returning: "{\"state\":\"\(outcome)\",\"games\":{},\"icloud\":true}")
            }
            await settle { Backend.starts.count == before + 1 }
            backupTask.cancel()
            await backupTask.value
            assert(!waiting.automaticallyBackingUp)
            assert(waiting.automaticBackupNotice == nil || outcome != "done")
            if outcome != "done" { assert(waiting.automaticBackupNotice != nil) }
            assert(Backend.starts.last?[1] == a.id)
            waiting.cancel()
            await settle { waiting.buildQueue.active == nil }
            assert(Backend.starts.count == before + 1)
        }
        print("PASS: queue waits for automatic backup; success/offline/error unblock exactly once; pending removal and notices")
        print("PASS: instant artwork cache, no repeated rendering, crop and source invalidation")
        print("PASS: serial builds, request snapshots, duplicates, queue removal, failure pause, resume, game-scoped results, cancellation keeps artwork, cover defaults")
    }
}
''')
            executable = root / 'checks'
            subprocess.run(['swiftc', '-parse-as-library',
                            str(SOURCES / 'Model.swift'), str(SOURCES / 'BuildQueue.swift'), str(SOURCES / 'SwitchTVSync.swift'),
                            str(SOURCES / 'ArtworkCrop.swift'), str(stub), str(checks),
                            '-o', str(executable)], check=True)
            subprocess.run([str(executable), str(root / 'data')], check=True)

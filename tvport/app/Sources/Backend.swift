import Foundation

// tvport/backend.py, as the app sees it: one JSON answer, or a stream of events for a build.

struct AppleTV: Codable, Identifiable, Hashable {
    let id: String
    let name: String?
    let model: String?
    let os: String?
    let connected: Bool
    let developer_mode: Bool
    var title: String { [name, model].compactMap { $0 }.joined(separator: " · ") }
}

struct Signing: Codable, Hashable {
    let team: String?
    let expires: String?
    let days_left: Int?
    let free_team: Bool?
}

struct GameInfo: Codable {
    let folder: String
    let build_folder: String?
    let build_path: String?
    let title_id: String
    let artwork_title_id: String?
    let name: String
    let version: String
    let sources: [String]
    let keyless: Bool?        // only NUP containers (Switch 2): no prod.keys needed
    let prepared: Bool
    let built: Bool?
    let render_scale: Bool?   // the rewritten game has a render-scale stub (backend.py render_scale_supported)
    let frame_step: Bool?     // and a frame step, which holds 30 fps while the TV is hot (frame_step_supported)
    let fps_target: Int?      // the profile's frame-rate target (0: the game's own limit, no choice to offer)
    let icon: String?
    let team: String?
    let bundle_id: String?
    let signing: Signing?
    let keys: String?
    let last_backup: String?
    let last_backup_time: Double?
    let last_backup_place: String?
}

struct SaveBackup: Codable {
    let files: Int
    let folder: String?
    let changed: Bool
    let state: String?
}

/// One game in a round of automatic backups (backend.py autobackup).
struct BackupStatus: Codable {
    let state: String
    var checked: Double?
    let last_backup: String?
    let last_backup_time: Double?
    let last_backup_place: String?
}

struct BackupRound: Codable {
    let state: String
    let games: [String: BackupStatus]
    let icloud: Bool
}

struct RunLog: Codable {
    let last_frame: Int
    let peak_mb: Double
    let gpu_mb: Double
    let min_headroom_mb: Double?
    let hitches: Int
    let worst_ms: Double
    let texture_ms: Double
    let pipeline_ms: Double
    let gpu_slow_frames: Int
}

struct Diagnosis: Codable {
    let run: RunLog
    let verdicts: [String]
    let log: String
}

enum BuildEvent {
    case stage(String)
    case log(String)
    case progress(Double)
    case failed(String)
    case done(bundle: String, signing: Signing?)
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Check: Codable, Hashable, Identifiable {
    let name: String
    let ok: Bool
    let detail: String
    let fix: String
    let command: String
    var id: String { name }
}

struct SetupReport: Codable {
    let checks: [Check]
    let ready: Bool
    let needs_setup: Bool
    let can_set_up: Bool
}

enum Backend {
    /// A packed app carries backend.py and the engine (scripts/package_tvport.py). An app built in the checkout runs them from there: TVPortRoot, set at build time (project.yml).
    static var script: URL {
        if let carried = Bundle.main.url(forResource: "backend", withExtension: "py") { return carried }
        let root = Bundle.main.object(forInfoDictionaryKey: "TVPortRoot") as? String ?? ""
        return URL(fileURLWithPath: root).appendingPathComponent("tvport/backend.py").standardizedFileURL
    }

    /// TVPort's own folder, which backend.py uses too. TVPORT_DATA moves both, for a test run.
    static let data = ProcessInfo.processInfo.environment["TVPORT_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TVPort", isDirectory: true)

    static let noXcode = "TVPort needs Xcode. Install it from the App Store and open it once."

    /// /usr/bin/python3 and xcrun are only stubs until Xcode or its command line tools are installed, and starting one opens Apple's installer.
    static var developerFolder: String? {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        p.arguments = ["-p"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private static func process(_ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path] + arguments
        p.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        let dotnet = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dotnet").path
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/local/share/dotnet:\(dotnet):/usr/bin:/bin:/usr/sbin:/sbin"   // an app opened from Finder has no shell PATH: the engine needs xcodegen, dotnet and glslang
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TVPORT_DATA"] = data.path
        environment["TVPORT_DEFAULT_BUILD_FOLDER"] = UserDefaults.standard.string(forKey: "DefaultBuildFolder") ?? ""
        p.environment = environment
        return p
    }

    /// A command that answers with one JSON object.
    static func ask<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        try await Task.detached(priority: .userInitiated) {
            guard developerFolder != nil else { throw BackendError(message: noXcode) }
            let p = process(arguments)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let failure = try? JSONDecoder().decode([String: String].self, from: data), let message = failure["error"] {
                throw BackendError(message: message)
            }
            do { return try JSONDecoder().decode(T.self, from: data) } catch {
                throw BackendError(message: "The backend gave an unreadable answer: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
            }
        }.value
    }

    /// `build` or `setup`: events as they happen. Cancelling the task stops the command.
    static func stream(_ arguments: [String]) -> AsyncStream<BuildEvent> {
        AsyncStream { continuation in
            let p = process(arguments)
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            let reader = LineReader { line in
                if let event = parse(line) { continuation.yield(event) }
            }
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; reader.finish(); continuation.finish() } else { reader.add(data) }
            }
            continuation.onTermination = { _ in if p.isRunning { p.terminate() } }
            guard developerFolder != nil else {
                continuation.yield(.failed(noXcode))
                continuation.finish()
                return
            }
            do { try BuildActivity.run(p) } catch {
                continuation.yield(.failed("Could not start the backend: \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }

    private struct Wire: Decodable {
        let event: String
        var name: String?
        var line: String?
        var value: Double?
        var message: String?
        var bundle_id: String?
        var signing: Signing?
    }

    static func parse(_ line: String) -> BuildEvent? {
        guard let data = line.data(using: .utf8), let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return line.isEmpty ? nil : .log(line)   // anything not from the backend itself (a Python traceback) still reaches the log
        }
        switch wire.event {
        case "stage": return .stage(wire.name ?? "")
        case "log": return .log(wire.line ?? "")
        case "progress": return .progress(wire.value ?? 0)
        case "error": return .failed(wire.message ?? "The build failed")
        case "done": return .done(bundle: wire.bundle_id ?? "", signing: wire.signing)
        default: return nil
        }
    }
}

/// Splits a pipe's chunks into lines; a chunk can end mid-line.
final class LineReader: @unchecked Sendable {
    private var pending = Data()
    private let lock = NSLock()
    private let onLine: (String) -> Void

    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }

    func add(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        while let end = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<end]
            pending = Data(pending[pending.index(after: end)...])
            onLine(String(decoding: line, as: UTF8.self))
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)); pending = Data() }
    }
}

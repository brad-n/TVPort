import Foundation

/// When TVPort refreshes SwitchTV (the launcher app that lists the games) on the Apple TV, and what it says about it. The work itself is `backend.py switchtv sync`,
/// which skips the build and install when the catalogue fingerprint is unchanged.
enum SwitchTVSync {
    enum Trigger: Equatable {
        case gameBuilt(installed: Bool, succeeded: Bool)   // a Build & Install finished (a build without an install does not change what is on the TV)
        case gameRemoved
    }

    static let keepKey = "KeepSwitchTVUpToDate"

    /// On unless the person turned it off.
    static func keepUpToDate(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: keepKey) == nil ? true : defaults.bool(forKey: keepKey)
    }

    /// A game that did not build or install changes nothing for SwitchTV; without an Apple TV chosen there is nothing to update.
    static func shouldSync(_ trigger: Trigger, keepUpToDate: Bool, device: String?) -> Bool {
        guard keepUpToDate, device != nil else { return false }
        switch trigger {
        case .gameBuilt(let installed, let succeeded): return installed && succeeded
        case .gameRemoved: return true
        }
    }

    /// Never while a build is running: both use the Apple TV and the project folder. A paused queue (a failed build) does not hold it back.
    static func canRunNow(buildActive: Bool, buildsWaiting: Bool, queuePaused: Bool, otherWork: Bool) -> Bool {
        !buildActive && !otherWork && (!buildsWaiting || queuePaused)
    }

    /// A failure here is a warning in the log, never a failed game build.
    static func warning(_ message: String) -> String { "Warning: SwitchTV was not updated on the Apple TV. \(message)" }
}

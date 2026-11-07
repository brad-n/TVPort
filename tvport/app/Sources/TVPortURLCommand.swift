import Foundation

/// What a tvport:// URL may ask for. Pure and UI-free so it can be checked on its own
/// (see Tests/url_command_check.swift). Only `tvport://build` exists; nothing else is reachable.
enum TVPortURLCommand: Equatable {
    /// `titleID` is normalised to upper case; `install` is true for Build & Install, false for Build.
    case build(titleID: String, install: Bool)

    enum Reason: Equatable, Error {
        case unsupported
        case malformedTitle
        case malformedInstall

        var message: String {
            switch self {
            case .unsupported: return "unsupported"
            case .malformedTitle: return "title must be exactly 16 hex digits"
            case .malformedInstall: return "install must be 0 or 1"
            }
        }
    }

    static func parse(_ url: URL) -> Result<TVPortURLCommand, Reason> {
        guard url.scheme?.lowercased() == "tvport",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "build",
              parts.path.isEmpty || parts.path == "/",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil
        else { return .failure(.unsupported) }

        let items = parts.queryItems ?? []
        let titles = items.filter { $0.name == "title" }
        let installs = items.filter { $0.name == "install" }
        guard titles.count == 1, let title = titles[0].value,
              title.count == 16, title.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { return .failure(.malformedTitle) }

        var install = true
        if !installs.isEmpty {
            guard installs.count == 1, let value = installs[0].value, value == "0" || value == "1"
            else { return .failure(.malformedInstall) }
            install = value == "1"
        }
        return .success(.build(titleID: title.uppercased(), install: install))
    }
}

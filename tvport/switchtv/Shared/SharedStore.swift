// What SwitchTV, its Top Shelf extension and the game apps share: a few small items in a shared keychain access group (<team>.dev.tvport.switchtv, named by SwitchTVGroup in each Info.plist; every app
// that uses it lists it under keychain-access-groups). One generic-password item per record, service "dev.tvport.switchtv", so two apps never rewrite each other's records:
//   account <TITLE ID IN CAPITALS>   the Unix time (seconds, as text) the game was last played; SwitchTV writes it when it opens a game, and a game app writes its own when it comes to the front
//                                    (dm/ios/SourcesTV/TVLastPlayed.m: keep the two in step).
//   account launchable               JSON array of the title IDs whose app answers its URL scheme, written by SwitchTV (an extension cannot ask canOpenURL).
// Why the keychain and not an App Group: an App Group needs an App ID registered in the developer account, which Xcode can only do with an Apple ID signed in; the keychain group works under the
// team's wildcard profile (L9492K5865.*) that automatic signing already has. tvOS keeps the keychain (it purges app files). Without the entitlement every call fails quietly and the store is empty.
import Foundation
import Security

/// Where the records are kept: the keychain for real, a folder in the command-line checks.
protocol SharedBacking {
    func all() -> [String: Data]
    func put(_ account: String, _ data: Data)
}

struct KeychainBacking: SharedBacking {
    static let service = "dev.tvport.switchtv"
    let group: String

    func all() -> [String: Data] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccessGroup as String: group,
                                    kSecMatchLimit as String: kSecMatchLimitAll, kSecReturnAttributes as String: true, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [:] }
        var found: [String: Data] = [:]
        for item in items { if let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data { found[account] = data } }
        return found
    }

    func put(_ account: String, _ data: Data) {
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
        if SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            SecItemAdd(key.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]) { $1 } as CFDictionary, nil)
        }
    }
}

struct FolderBacking: SharedBacking {
    let root: URL
    func all() -> [String: Data] {
        var found: [String: Data] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] { found[name] = try? Data(contentsOf: root.appendingPathComponent(name)) }
        return found
    }
    func put(_ account: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: root.appendingPathComponent(account), options: .atomic)
    }
}

struct SharedStore {
    static let infoKey = "SwitchTVGroup"
    static let launchableAccount = "launchable"
    let backing: SharedBacking

    init(backing: SharedBacking) { self.backing = backing }

    /// The store of this app's Info.plist group; nil when the plist names none.
    init?(group: String? = Bundle.main.object(forInfoDictionaryKey: SharedStore.infoKey) as? String) {
        guard let group, !group.isEmpty else { return nil }
        backing = KeychainBacking(group: group)
    }

    private static func isTitleID(_ text: String) -> Bool { text.count == 16 && text.allSatisfy(\.isHexDigit) }

    /// Title ID -> time last played.
    func lastPlayed() -> [String: Double] {
        var result: [String: Double] = [:]
        for (account, data) in backing.all() where Self.isTitleID(account) {
            if let text = String(data: data, encoding: .utf8), let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) { result[account.uppercased()] = seconds }
        }
        return result
    }

    /// Never moves a record back in time: a later play (by the game itself) stays.
    func record(_ titleID: String, at date: Date = Date()) {
        let id = titleID.uppercased()
        guard Self.isTitleID(id), (lastPlayed()[id] ?? 0) < date.timeIntervalSince1970 else { return }
        backing.put(id, Data(String(format: "%.0f", date.timeIntervalSince1970).utf8))
    }

    func launchable() -> Set<String> {
        guard let data = backing.all()[Self.launchableAccount], let ids = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(ids.map { $0.uppercased() })
    }

    func setLaunchable(_ ids: Set<String>) {
        if let data = try? JSONEncoder().encode(ids.sorted()) { backing.put(Self.launchableAccount, data) }
    }
}

import Foundation

enum GameDropImport {
    /// The backend builds a folder, including its updates and DLC. A dropped
    /// game file selects that folder in place, including on external volumes.
    static func folders(from urls: [URL]) -> [URL] {
        let gameExtensions: Set<String> = ["nsp", "xci", "nsz", "xcz", "nup"]
        var seen = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey]),
                  values.isPackage != true else { return nil }
            let folder: URL
            if values.isDirectory == true {
                folder = url.standardizedFileURL
            } else if values.isRegularFile == true && gameExtensions.contains(url.pathExtension.lowercased()) {
                folder = url.deletingLastPathComponent().standardizedFileURL
            } else {
                return nil
            }
            return seen.insert(folder.path).inserted ? folder : nil
        }
    }
}

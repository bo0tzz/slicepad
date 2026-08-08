import Foundation

/// Keeps the last profile so it survives a restart.
///
/// A copy rather than a security-scoped bookmark: a bookmark goes stale when the
/// original moves, is edited by its app, or lives in a cloud provider that has
/// evicted it — and the failure then arrives at launch, with nothing the app can
/// do about it. A profile is a few hundred kilobytes, and the whole point of the
/// carrier is that it is a snapshot rather than a live document.
enum ProfileStore {
    private static var directory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
    }

    private static var fileURL: URL? {
        directory?.appendingPathComponent("profile.3mf")
    }

    /// The name the file had when it was chosen, so the app can show what the user
    /// picked rather than the name it was filed under.
    static var name: String? {
        get { UserDefaults.standard.string(forKey: "profileName") }
        set { UserDefaults.standard.set(newValue, forKey: "profileName") }
    }

    static var saved: URL? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }

    static func save(_ source: URL) throws {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.copyItem(at: source, to: fileURL)
        name = source.deletingPathExtension().lastPathComponent
    }
}

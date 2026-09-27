import Foundation

/// A copy of Claude made by Parallex: its own app in `/Applications`, its own data folder,
/// signed into its own account.
///
/// Parallex keeps each copy's record in `Application Support/Parallex/instances/<slug>/
/// instance.json`, and the copy's Claude data inside that folder. Nothing about the data
/// folder's location is guessed: it is read from the switch Parallex launches the copy with,
/// which is the same switch the running process carries, so a copy is attributed exactly as
/// `Guards` attributes it.
public struct ParallexInstance: Sendable, Hashable {
    public let slug: String
    public let name: String
    public let dataRoot: URL
    /// The copy's own app, when it is still where Parallex put it.
    public let appURL: URL?
    public let bundleIdentifier: String?
    /// The letters Parallex draws on the copy's icon, and their color.
    public let badgeText: String?
    public let badgeColorHex: String?
    /// A custom icon picked in Parallex, if any.
    public let customIconURL: URL?
    public let recordURL: URL
}

public enum ParallexInstances {

    public static var instancesDirectory: URL {
        HostPaths.current.applicationSupport
            .appendingPathComponent("Parallex", isDirectory: true)
            .appendingPathComponent("instances", isDirectory: true)
    }

    /// Every Parallex copy of Claude Desktop on this machine.
    ///
    /// Copies of other apps are skipped, and so are copies in Parallex's other isolation
    /// modes: only a copy launched with its own `--user-data-dir` has Claude data of its own.
    public static func claudeCopies() -> [ParallexInstance] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: instancesDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { instance(at: $0) }
    }

    static func instance(at folder: URL) -> ParallexInstance? {
        let recordURL = folder.appendingPathComponent("instance.json")
        guard let data = try? Data(contentsOf: recordURL),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        guard (record["targetBundleID"] as? String) == Discovery.electronBundleIdentifier,
              (record["mode"] as? String) == "data-dir"
        else { return nil }

        let slug = (record["slug"] as? String) ?? folder.lastPathComponent
        let name = (record["name"] as? String) ?? slug
        let arguments = (record["arguments"] as? [String]) ?? []
        let environment = (record["environment"] as? [String: String]) ?? [:]
        let settings = (record["settings"] as? [String: Any]) ?? [:]

        let dataRoot = Guards.userDataDirectory(inArguments: arguments)
            ?? environment["CLAUDE_USER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? folder.appendingPathComponent("data", isDirectory: true)

        let bundleIdentifier = record["bundleIdentifier"] as? String
        let appURL = locateApp(recordPath: record["wrapperPath"] as? String, name: name,
                               bundleIdentifier: bundleIdentifier)

        var customIcon: URL?
        if let file = settings["customIconFile"] as? String, !file.isEmpty {
            let url = folder.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) { customIcon = url }
        }

        return ParallexInstance(
            slug: slug, name: name,
            dataRoot: Discovery.canonical(dataRoot),
            appURL: appURL, bundleIdentifier: bundleIdentifier,
            badgeText: (settings["badgeText"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            badgeColorHex: settings["badgeColorHex"] as? String,
            customIconURL: customIcon,
            recordURL: recordURL)
    }

    /// The copy's app: where Parallex recorded it, or where a person would have moved it,
    /// accepted only when it is still the same app.
    static func locateApp(recordPath: String?, name: String, bundleIdentifier: String?) -> URL? {
        var candidates: [URL] = []
        if let recordPath, !recordPath.isEmpty { candidates.append(URL(fileURLWithPath: recordPath)) }
        for directory in HostPaths.current.applicationDirectories {
            candidates.append(directory.appendingPathComponent("\(name).app"))
        }
        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            guard let bundleIdentifier else { return candidate }
            if Self.bundleIdentifier(of: candidate) == bundleIdentifier { return candidate }
        }
        return nil
    }

    static func bundleIdentifier(of app: URL) -> String? {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }
}

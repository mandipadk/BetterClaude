import Foundation

/// Reads and validates a `.coworkbundle`.
///
/// Everything here treats the bundle as hostile input even though we wrote the format:
/// a bundle arrives over AirDrop, email or a shared drive, and by then nothing about it is
/// ours. Nothing is ever extracted, so there is no unpacking step to subvert; the remaining
/// attack surface is a manifest entry that points somewhere it should not, and that is what
/// ``verify(at:)`` closes.
public enum BundleReader {

    public static func openManifest(at url: URL) throws -> Manifest {
        let manifestURL = url.appendingPathComponent(BundleLayout.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BundleError.missingManifest(url)
        }
        let manifest = try Manifest.makeDecoder().decode(
            Manifest.self, from: try Data(contentsOf: manifestURL))
        guard manifest.bundleVersion <= Manifest.currentVersion else {
            throw BundleError.unsupportedVersion(found: manifest.bundleVersion,
                                                 supported: Manifest.currentVersion)
        }
        return manifest
    }

    public static func slotURL(_ slot: String, in bundle: URL) -> URL {
        bundle
            .appendingPathComponent(BundleLayout.sessionsDirName, isDirectory: true)
            .appendingPathComponent(slot, isDirectory: true)
    }

    /// Checks the bundle against its manifest and returns every problem found.
    ///
    /// Returning a list rather than throwing on the first failure is deliberate: the user
    /// deserves to see all of what is wrong with a bundle at once, and a caller that wants
    /// strictness only has to test for emptiness. An empty array means every file in every
    /// slot is present, unmodified, and reachable without following a link.
    public static func verify(at url: URL) throws -> [String] {
        let manifest = try openManifest(at: url)
        var problems: [String] = []
        let fm = FileManager.default

        // No link of any kind may exist anywhere in the bundle: a symlink can point outside
        // it, and a hardlink means the "copy" is still the original file.
        let whole = try BundleFS.walk(url)
        for link in whole.symlinks { problems.append("symlink in bundle: \(link)") }
        for odd in whole.irregular { problems.append("not a regular file: \(odd)") }
        for bad in whole.unreadable { problems.append("unreadable: \(bad)") }

        let allowedRoot: Set<String> = [BundleLayout.manifestFileName, BundleLayout.scanReportFileName]
        for rel in whole.files where !rel.contains("/") && !allowedRoot.contains(rel) {
            problems.append("unexpected file at bundle root: \(rel)")
        }

        var slotNames: Set<String> = []
        for entry in manifest.sessions {
            guard BundleLayout.isValidSlotName(entry.slot) else {
                problems.append("invalid slot name: \(entry.slot)")
                continue
            }
            slotNames.insert(entry.slot)
            let slotDir = slotURL(entry.slot, in: url)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: slotDir.path, isDirectory: &isDir), isDir.boolValue else {
                problems.append("missing slot directory: \(entry.slot)")
                continue
            }

            var declared: Set<String> = []
            for file in entry.files {
                guard BundleFS.isSafeRelativePath(file.path) else {
                    problems.append("\(entry.slot): unsafe path in manifest: \(file.path)")
                    continue
                }
                declared.insert(file.path)
                let fileURL = slotDir.appendingPathComponent(file.path)
                guard fm.fileExists(atPath: fileURL.path) else {
                    problems.append("\(entry.slot): declared file is missing: \(file.path)")
                    continue
                }
                guard BundleFS.isContained(fileURL, in: slotDir) else {
                    problems.append("\(entry.slot): path escapes the slot: \(file.path)")
                    continue
                }
                if BundleFS.hardLinkCount(of: fileURL) > 1 {
                    problems.append("\(entry.slot): hardlinked file: \(file.path)")
                }
                let size = (try? BundleFS.byteCount(of: fileURL)) ?? -1
                if size != file.bytes {
                    problems.append("\(entry.slot): size mismatch: \(file.path)")
                }
                guard let digest = try? BundleFS.sha256Hex(of: fileURL) else {
                    problems.append("\(entry.slot): unreadable: \(file.path)")
                    continue
                }
                if digest != file.sha256 {
                    problems.append("\(entry.slot): sha256 mismatch: \(file.path)")
                }
            }

            let onDisk = try BundleFS.walk(slotDir).files
            for rel in onDisk where !declared.contains(rel) {
                problems.append("\(entry.slot): file on disk is absent from the manifest: \(rel)")
            }
        }

        let sessionsDir = url.appendingPathComponent(BundleLayout.sessionsDirName, isDirectory: true)
        if let contents = try? fm.contentsOfDirectory(atPath: sessionsDir.path) {
            for name in contents.sorted() where !slotNames.contains(name) {
                problems.append("undeclared slot directory: \(name)")
            }
        } else if !manifest.sessions.isEmpty {
            problems.append("missing \(BundleLayout.sessionsDirName)/ directory")
        }

        return problems
    }

    /// The scan report recorded when the bundle was written, if it is still present.
    /// It is evidence about the export, not a substitute for re-scanning on import.
    public static func openScanReport(at url: URL) throws -> ScanReport? {
        let reportURL = url.appendingPathComponent(BundleLayout.scanReportFileName)
        guard FileManager.default.fileExists(atPath: reportURL.path) else { return nil }
        return try Manifest.makeDecoder().decode(ScanReport.self, from: try Data(contentsOf: reportURL))
    }
}

import AppKit
import CoworkKit
import Observation
import SwiftUI

/// Keeps Better Claude up to date: checks GitHub Releases once a day (and on request), and
/// installs a signed update in place.
@MainActor
@Observable
final class UpdateModel {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String?)
        case downloading(Double)
        case readyToRestart
        case failed(String)
    }

    var state: State = .idle
    var isPresented = false
    /// A newer release found by an automatic check, shown quietly in the sidebar.
    private(set) var waiting: String?
    private var update: AvailableUpdate?
    @ObservationIgnored private var timer: Timer?

    enum Keys {
        static let automatic = "checkForUpdatesAutomatically"
        static let lastChecked = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? AppVersion.current
    }

    /// Whether this copy can replace itself: a real bundle in a folder it can write to.
    var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        return bundle.pathExtension == "app" && !bundle.path.contains("/.build/")
            && FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Check a moment after launch if the last check is a day old, then hourly while open.
    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            checkIfDue()
        }
    }

    private func checkIfDue() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.automatic) as? Bool ?? true else { return }
        if let last = defaults.object(forKey: Keys.lastChecked) as? Date, Date().timeIntervalSince(last) < 86_400 {
            return
        }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if userInitiated {
            state = .checking
            isPresented = true
        }
        do {
            let found = try await Updater.check(currentVersion: currentVersion)
            UserDefaults.standard.set(Date(), forKey: Keys.lastChecked)
            if let found {
                update = found
                let skipped = UserDefaults.standard.string(forKey: Keys.skipped)
                if userInitiated || found.version != skipped {
                    state = .available(version: found.version, notes: found.notes)
                    waiting = found.version
                }
            } else if userInitiated {
                update = nil
                waiting = nil
                state = .upToDate
            }
        } catch {
            if userInitiated { state = .failed("\(error)") }
        }
    }

    func showWaiting() {
        guard let update else { return }
        state = .available(version: update.version, notes: update.notes)
        isPresented = true
    }

    func skip() {
        if let update { UserDefaults.standard.set(update.version, forKey: Keys.skipped) }
        waiting = nil
        isPresented = false
    }

    func install() async {
        guard let update else { return }
        guard canInstallInPlace else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        state = .downloading(0)
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("BetterClaudeUpdate-\(UUID().uuidString)", isDirectory: true)
            let newApp = try await Updater.download(update, into: staging,
                                                    expectingBundleIdentifier: Bundle.main.bundleIdentifier) { fraction in
                Task { @MainActor in self.state = .downloading(fraction) }
            }
            _ = try Updater.install(newApp: newApp, replacing: Bundle.main.bundleURL)
            state = .readyToRestart
            // The swap script waits for this process to exit before touching the bundle.
            try? await Task.sleep(for: .milliseconds(400))
            AppDelegate.quit()
        } catch {
            state = .failed("\(error)")
        }
    }
}

/// The update conversation, one centered message per state, like Parallex's.
///
/// It says what the app is about to do to itself before it does it.
struct UpdateSheet: View {
    @State var model: UpdateModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            VStack(spacing: 6) {
                Text(headline).font(Theme.Font.title)
                Text("You have version \(model.currentVersion)")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(maxWidth: 420)
            Spacer(minLength: 0)
            buttons
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(width: 540, height: 460)
        .background(WindowGlassBackground(material: .sidebar))
        .tint(Theme.accent)
    }

    private var symbol: String {
        switch model.state {
        case .checking, .idle: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        case .available: return "arrow.down.circle.fill"
        case .downloading, .readyToRestart: return "arrow.down.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch model.state {
        case .failed: return Theme.attention
        case .checking, .idle: return .secondary
        default: return Theme.accent
        }
    }

    private var headline: String {
        switch model.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Better Claude is up to date"
        case .available(let version, _): return "Version \(version) is ready"
        case .downloading: return "Downloading…"
        case .readyToRestart: return "Restarting…"
        case .failed: return "Couldn't check for updates"
        case .idle: return "Updates"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .checking, .idle:
            ProgressView().controlSize(.small)
        case .upToDate:
            Text("No newer release has been published.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
        case .available(_, let notes):
            VStack(spacing: Theme.Space.m) {
                if let notes, !notes.isEmpty {
                    ScrollView {
                        Text(notes)
                            .font(Theme.Font.body)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                Text("The download is checked against Better Claude's signature before anything is replaced. Your conversations and settings aren't touched.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction).progressViewStyle(.linear).frame(width: 260)
                Text("Better Claude restarts when this finishes.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        case .readyToRestart:
            Text("Replacing the app and opening it again.")
                .font(Theme.Font.body).foregroundStyle(.secondary)
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(Theme.Font.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing was changed. You can download a release from GitHub instead.")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: Theme.Space.m) {
            switch model.state {
            case .available:
                Button("Skip This Version") { model.skip() }.quietAction()
                Button("Not Now") { onClose() }.quietAction().keyboardShortcut(.cancelAction)
                Button("Install and Restart") { Task { await model.install() } }
                    .prominentAction().keyboardShortcut(.defaultAction)
            case .downloading, .readyToRestart, .checking:
                EmptyView()
            default:
                Button("Done") { onClose() }.prominentAction().keyboardShortcut(.defaultAction)
            }
        }
    }
}

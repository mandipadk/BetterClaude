import CoworkKit
import SwiftUI

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
    private var update: AvailableUpdate?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func check(userInitiated: Bool) async {
        state = .checking
        isPresented = userInitiated
        do {
            if let found = try await Updater.check(currentVersion: currentVersion) {
                update = found
                state = .available(version: found.version, notes: found.notes)
                isPresented = true
            } else {
                update = nil
                state = .upToDate
            }
        } catch {
            state = .failed("\(error)")
            if userInitiated { isPresented = true }
        }
    }

    func install() async {
        guard let update else { return }
        state = .downloading(0)
        do {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("BetterClaudeUpdate-\(UUID().uuidString)", isDirectory: true)
            let newApp = try await Updater.download(update, into: staging) { fraction in
                Task { @MainActor in self.state = .downloading(fraction) }
            }
            _ = try Updater.install(newApp: newApp, replacing: Bundle.main.bundleURL)
            state = .readyToRestart
            // The swap script waits for this process to exit before touching the bundle.
            try? await Task.sleep(for: .milliseconds(400))
            NSApplication.shared.terminate(nil)
        } catch {
            state = .failed("\(error)")
        }
    }
}

/// The update conversation, one centered message per state, like Parallex's.
///
/// It says what the app is about to do to itself, including the part that is uncomfortable:
/// the download is checksum-verified but not signature-verified, so the release account is
/// the trust boundary. Hiding that behind a progress bar would be the easier design and the
/// dishonest one.
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
                Text("The download is checked against a SHA-256 published with the release, which catches a damaged or altered file. It isn't signature-checked, so only install updates if you trust where they come from.")
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

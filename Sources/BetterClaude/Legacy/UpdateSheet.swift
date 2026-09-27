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

/// The update conversation.
///
/// It says what the app is about to do to itself, including the part that is uncomfortable:
/// the download is checksum-verified but not signature-verified, so the release account is
/// the trust boundary. Hiding that behind a progress bar would be the easier design and the
/// dishonest one.
struct UpdateSheet: View {
    @State var model: UpdateModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            body(for: model.state)
            Hairline()
            footer
        }
        .frame(width: 520)
        .background(Design.Palette.raised)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.primary)
            Text("You have \(model.currentVersion)")
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    private var headline: String {
        switch model.state {
        case .checking: return "Checking for updates"
        case .upToDate: return "Up to date"
        case .available(let version, _): return "Version \(version) is available"
        case .downloading: return "Downloading"
        case .readyToRestart: return "Restarting"
        case .failed: return "Could not check for updates"
        case .idle: return "Updates"
        }
    }

    @ViewBuilder
    private func body(for state: UpdateModel.State) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            switch state {
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Text("No newer release has been published.")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondary)
            case .available(_, let notes):
                if let notes, !notes.isEmpty {
                    Text(notes)
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    SectionLabel(text: "Before you install")
                    Text("The download is checked against a SHA-256 published with the release, "
                         + "which catches a corrupted or altered file in transit. It is not "
                         + "signature-verified, so anyone able to publish a release could publish "
                         + "a matching checksum. Install updates only if you trust the source.")
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Design.Palette.accent)
                Text("The app will restart when this finishes.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
            case .readyToRestart:
                Text("Replacing the application and reopening it.")
                    .font(Design.Typography.body)
                    .foregroundStyle(Design.Palette.secondary)
            case .failed(let message):
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                    StatusMark(kind: .warning)
                    Text(message)
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Text("Nothing was changed. You can download a release manually from GitHub.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
            case .idle:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    private var footer: some View {
        HStack(spacing: Design.Space.s) {
            Spacer()
            switch model.state {
            case .available:
                Button("Not now") { onClose() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Install and restart") { Task { await model.install() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            case .downloading, .readyToRestart, .checking:
                Button("Close") { onClose() }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(true)
            default:
                Button("Done") { onClose() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }
}

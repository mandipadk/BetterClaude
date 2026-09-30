import AppKit
import CoworkKit
import SwiftUI

/// Keys and tokens that ended up in a conversation, so you know what to rotate.
@MainActor
@Observable
final class SecretsModel {
    private(set) var findings: [SecretSweep.Finding] = []
    private(set) var handled: Set<String> = []
    private(set) var sweeping = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    private(set) var swept: Int?

    var open: [SecretSweep.Finding] { findings.filter { !handled.contains($0.fingerprint) } }
    var rotated: [SecretSweep.Finding] { findings.filter { handled.contains($0.fingerprint) } }

    func sweep(_ snapshot: CatalogSnapshot) {
        guard !sweeping else { return }
        sweeping = true
        handled = HandledSecrets.load()
        let files = SecretSweep.files(in: snapshot)
        progress = (0, files.count)
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                SecretSweep.sweep(files) { done, total in
                    Task { @MainActor in self.progress = (max(self.progress.done, done), total) }
                }
            }.value
            findings = found
            swept = files.count
            sweeping = false
        }
    }

    func setRotated(_ finding: SecretSweep.Finding, _ rotated: Bool) {
        if rotated { handled.insert(finding.fingerprint) } else { handled.remove(finding.fingerprint) }
        try? HandledSecrets.save(handled)
    }
}

struct SecretsPage: View {
    @Environment(AppServices.self) private var services
    @State private var showsRotated = false

    var body: some View {
        let model = services.secrets
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Secrets").font(Theme.Font.display)
                    Text("API keys and tokens that ended up in a conversation, pasted in, printed by a command, or written by Claude. Conversations are plain text on your disk, so these are keys to rotate.")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, Theme.Space.xl)

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.sweeping {
                            Text("Reading \(model.progress.done) of \(model.progress.total) conversations…")
                                .font(Theme.Font.title)
                                .monospacedDigit()
                        } else if model.swept != nil {
                            Text(model.open.isEmpty ? "Nothing to rotate" : "\(model.open.count) key\(model.open.count == 1 ? "" : "s") to rotate")
                                .font(Theme.Font.hero)
                                .contentTransition(.numericText())
                            Text("Found in \(Set(model.open.flatMap(\.conversations)).count) of \(model.swept ?? 0) conversations.")
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sweep Again") { model.sweep(services.snapshot) }
                        .buttonStyle(.secondary)
                        .disabled(model.sweeping)
                }
                .padding(.bottom, Theme.Space.l)

                ForEach(model.open) { finding in
                    FindingRow(finding: finding, rotated: false)
                }

                if !model.rotated.isEmpty {
                    DisclosureGroup(isExpanded: $showsRotated) {
                        ForEach(model.rotated) { finding in FindingRow(finding: finding, rotated: true) }
                    } label: {
                        Text("\(model.rotated.count) you've rotated").font(Theme.Font.headline)
                    }
                    .padding(.top, Theme.Space.l)
                }

                Text("Better Claude never shows or keeps a whole key: only its first few and last four characters, and a fingerprint to recognise it again. It hides these keys from what Claude reads through its history tools, from Markdown exports, and from handoffs. It doesn't change Claude's own files; rotating the key is what makes it safe.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Theme.Space.xl)
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if model.swept == nil { model.sweep(services.snapshot) } }
    }
}

private struct FindingRow: View {
    @Environment(AppServices.self) private var services
    let finding: SecretSweep.Finding
    let rotated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(finding.kind.name).font(Theme.Font.headline)
                Text(finding.masked)
                    .font(Theme.Font.code)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: 5))
                    .textSelection(.disabled)
                Spacer()
                if let url = finding.kind.rotateURL, !rotated {
                    Button("Rotate…") { NSWorkspace.shared.open(url) }.buttonStyle(.secondary)
                }
                Button(rotated ? "Not Rotated Yet" : "I've Rotated It") {
                    services.secrets.setRotated(finding, !rotated)
                }
                .buttonStyle(.secondary)
            }
            ForEach(Array(finding.sightings.prefix(4).enumerated()), id: \.offset) { _, sighting in
                if let conversation = services.snapshot.conversations.first(where: { $0.id == sighting.conversationID }) {
                    Button {
                        services.filter = .all
                        services.destination = .conversations
                        services.selectedConversationID = conversation.id
                    } label: {
                        (Text("\(sighting.source.description) in ").foregroundStyle(.secondary)
                         + Text(conversation.title).foregroundStyle(Theme.accent))
                            .font(Theme.Font.callout)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            if finding.sightings.count > 4 {
                Text("And \(finding.sightings.count - 4) more.").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

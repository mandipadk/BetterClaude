import AppKit
import CoworkKit
import SwiftUI

/// Continue a conversation somewhere else: pick where, review what will happen, do it, and
/// be able to take it back. Steps move like Parallex's create flow.
struct ContinueSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: ContinueModel
    let onClose: () -> Void

    @State private var forward = true

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case .choose: ChooseStep(model: model).transition(stepTransition)
                case .review: ReviewStep(model: model).transition(stepTransition)
                case .working: WorkingStep(model: model).transition(stepTransition)
                case .done: DoneStep(model: model).transition(stepTransition)
                case .failed: FailedStep(model: model).transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth, value: model.step)

            actionBar
        }
        .frame(width: 660, height: 580)
        .tint(Theme.accent)
        .onDisappear { model.cleanUp() }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: Theme.Space.m) {
            if let failure = model.failure, model.step == .choose || model.step == .review {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(3)
            }
            Spacer(minLength: Theme.Space.m)
            switch model.step {
            case .choose:
                Button("Cancel", action: onClose).quietAction().keyboardShortcut(.cancelAction)
                Button {
                    forward = true
                    model.review(in: services.snapshot)
                } label: {
                    if model.isPlanning { ProgressView().controlSize(.small).tint(.white) } else { Text("Review") }
                }
                .prominentAction()
                .frame(minWidth: 110)
                .disabled(model.destination == nil || model.isPlanning)
                .keyboardShortcut(.defaultAction)
            case .review:
                Button("Back") { forward = false; model.step = .choose }.quietAction()
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { forward = true; model.apply() }
                    .prominentAction()
                    .frame(minWidth: 110)
                    .disabled(!(model.plan?.isExecutable ?? false)
                              || (!(model.plan?.conflicts.isEmpty ?? true) && !model.quitIfOpen))
                    .keyboardShortcut(.defaultAction)
            case .working:
                EmptyView()
            case .done:
                if !model.undone {
                    Button("Undo") { model.undo() }.quietAction()
                }
                Button(model.undone ? "Close" : openTitle) {
                    if !model.undone { openDestination() }
                    onClose()
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
            case .failed:
                if model.partialReceiptID != nil, !model.undone {
                    Button("Undo What It Wrote") { model.undo() }.quietAction()
                }
                Button("Close", action: onClose).prominentAction().keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var openTitle: String {
        switch model.destination {
        case .account(let installID, _): return "Open \(services.install(installID)?.name ?? "Claude")"
        case .project: return "Open in Terminal"
        case nil: return "Done"
        }
    }

    private func openDestination() {
        switch model.destination {
        case .account(let installID, _):
            if let install = services.install(installID) { services.open(install) }
        case .project(let path):
            if let slot = model.plan?.computed.first {
                services.resumeInTerminal(cwd: path, sessionId: slot.cliSessionId)
            }
        case nil:
            break
        }
    }
}

// MARK: - Choose

private struct ChooseStep: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: ContinueModel
    @State private var showOptions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue “\(model.conversation.title)”")
                        .font(Theme.Font.title)
                        .lineLimit(2)
                    Text("Pick where to carry it. The original stays where it is.")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                }

                let accounts = accountDestinations
                if !accounts.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("In Claude").font(Theme.Font.section)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 138), spacing: 10)], spacing: 10) {
                            ForEach(accounts, id: \.destination) { item in
                                InstallTile(install: item.install, detail: item.detail,
                                            isSelected: model.destination == item.destination,
                                            isOpen: services.isRunning(item.install)) {
                                    model.destination = item.destination
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text("In a Claude Code project").font(Theme.Font.section)
                    VStack(spacing: 2) {
                        ForEach(projectChoices, id: \.self) { path in
                            ProjectRow(path: path, isSelected: model.destination == .project(path: path),
                                       home: services.snapshot.paths) {
                                model.destination = .project(path: path)
                            }
                        }
                    }
                    Button("Choose a Folder…") { chooseFolder() }
                        .buttonStyle(.secondary)
                }

                DisclosureGroup(isExpanded: $showOptions) {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        if model.isCowork {
                            ExplainedToggle(title: "Include files you uploaded",
                                            detail: "Documents and images you attached. They can be large.",
                                            isOn: $model.includeUploads)
                            ExplainedToggle(title: "Include files Claude made",
                                            detail: "Everything in the conversation's outputs folder.",
                                            isOn: $model.includeOutputs)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your name and email").font(Theme.Font.body)
                            Picker("Your name and email", selection: $model.profile) {
                                Text("Keep them, it's my own Claude").tag(RedactionProfile.sameUser)
                                Text("Remove them, it's someone else's account").tag(RedactionProfile.crossUser)
                                Text("Remove everything optional, for sharing").tag(RedactionProfile.share)
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }
                    }
                    .padding(.top, Theme.Space.s)
                } label: {
                    Text("More options")
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(Theme.Motion.snappy) { showOptions.toggle() } }
                }
            }
            .padding(24)
        }
    }

    struct AccountChoice {
        let destination: ContinueDestination
        let install: Install
        let detail: String
    }

    /// Every Desktop account a conversation can land in, except the one it came from.
    private var accountDestinations: [AccountChoice] {
        let sourceAccount = model.conversation.coworkSession?.account.id
        return services.installs.flatMap { install -> [AccountChoice] in
            let accounts = (services.snapshot.accounts[install.id] ?? [])
                .filter { $0.canReceiveTransfer && $0.id != sourceAccount }
            let signedIn = accounts.filter(\.isSignedIn)
            let shown = signedIn.isEmpty ? accounts : signedIn
            return shown.map { account in
                let detail = shown.count > 1
                    ? (account.emailAddress.map { "\($0), \(account.orgLabel)" } ?? account.orgLabel)
                    : (account.emailAddress ?? account.orgLabel)
                return AccountChoice(destination: .account(installID: install.id, account),
                                     install: install, detail: detail)
            }
        }
    }

    private var projectChoices: [String] {
        var paths = services.projects.prefix(5).map(\.path)
        if case .project(let chosen) = model.destination, !paths.contains(chosen) { paths.insert(chosen, at: 0) }
        return paths
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Claude Code should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.destination = .project(path: url.path)
    }
}

/// A destination install as a tile, like picking an app in Parallex.
private struct InstallTile: View {
    let install: Install
    let detail: String
    let isSelected: Bool
    let isOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                InstallIcon(install: install, size: 44)
                Text(install.name).font(Theme.Font.bodyMedium).lineLimit(1)
                Text(isOpen ? "Open now" : detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Theme.accent.opacity(0.14) : Theme.subtleFill,
                        in: .rect(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.white, Theme.accent)
                        .padding(7)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.snappy, value: isSelected)
        .accessibilityLabel("\(install.name), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProjectRow: View {
    let path: String
    let isSelected: Bool
    let home: HostPaths
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(isSelected ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(Theme.Font.body)
                    Text(home.abbreviating(URL(fileURLWithPath: path).deletingLastPathComponent().path))
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent).fontWeight(.semibold)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(isSelected ? Theme.accent.opacity(0.12) : .clear,
                        in: .rect(cornerRadius: Theme.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(HoverRowStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Review

private struct ReviewStep: View {
    @Environment(AppServices.self) private var services
    @Bindable var model: ContinueModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Passage(from: model.source, conversationTitle: model.conversation.title,
                        to: destinationInstall, projectName: destinationProject)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.s)

                VStack(alignment: .leading, spacing: 6) {
                    Text(heading).font(Theme.Font.title)
                    Text(summary)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let plan = model.plan {
                    let blocking = plan.preconditions.filter { !$0.passed }
                    let notices = plan.preconditions.filter { $0.passed && $0.isNotice }
                    if !blocking.isEmpty || !notices.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            ForEach(blocking, id: \.id) { check in
                                CheckRow(symbol: "xmark.octagon.fill", tint: Theme.failure,
                                         title: check.title, detail: check.detail)
                            }
                            ForEach(notices, id: \.id) { check in
                                CheckRow(symbol: "info.circle.fill", tint: .secondary,
                                         title: check.title, detail: check.detail)
                            }
                        }
                    }

                    if !plan.conflicts.isEmpty {
                        ExplainedToggle(
                            title: "Quit \(destinationName) for me",
                            detail: "\(destinationName) is open. It has to be closed while the conversation is written, or it could overwrite it. Reopen it straight after.",
                            isOn: $model.quitIfOpen)
                    }
                }

                Label("You can undo this from History at any time.", systemImage: "arrow.uturn.backward")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationInstall: Install? {
        if case .account(let id, _) = model.destination { return services.install(id) }
        return services.installs.first { $0.kind == .claudeCode }
    }

    private var destinationProject: String? {
        if case .project(let path) = model.destination { return URL(fileURLWithPath: path).lastPathComponent }
        return nil
    }

    private var destinationName: String {
        switch model.destination {
        case .account(let id, _): return services.install(id)?.name ?? "Claude"
        case .project(let path): return URL(fileURLWithPath: path).lastPathComponent
        case nil: return ""
        }
    }

    private var heading: String {
        switch model.destination {
        case .account: return "Ready to continue in \(destinationName)"
        case .project: return "Ready to continue in Claude Code"
        case nil: return ""
        }
    }

    private var summary: String {
        let title = "“\(model.conversation.title)”"
        switch model.destination {
        case .account(_, let account):
            let who = account.emailAddress.map { ", signed in as \($0)" } ?? ""
            return "Copies \(title) into \(destinationName)\(who). It will be at the top of its conversation list."
        case .project(let path):
            return "Copies \(title) into Claude Code for \(services.snapshot.paths.abbreviating(path)), where `claude --resume` picks it up."
        case nil:
            return ""
        }
    }
}

private struct CheckRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Font.body)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Working, done, failed

private struct WorkingStep: View {
    let model: ContinueModel
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            ForkMark(size: 64)
                .scaleEffect(pulse ? 1.06 : 0.96)
                .opacity(pulse ? 1 : 0.7)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .onAppear { pulse = true }
            Text(model.progress ?? "Copying the conversation…")
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DoneStep: View {
    @Environment(AppServices.self) private var services
    let model: ContinueModel

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: model.undone ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(model.undone ? Color.secondary : Theme.accent)
                .symbolEffect(.bounce, value: model.undone)
                .contentTransition(.symbolEffect(.replace))
            Text(model.undone ? "Undone" : title).font(Theme.Font.title)
            Text(model.undone ? "Everything it wrote has been removed." : detail)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
    }

    private var title: String {
        switch model.destination {
        case .account(let id, _): return "It's in \(services.install(id)?.name ?? "Claude")"
        case .project: return "It's in Claude Code"
        case nil: return "Done"
        }
    }

    private var detail: String {
        switch model.destination {
        case .account: return "Open it and the conversation is at the top of the list, ready to pick up where it left off."
        case .project(let path): return "Open it in Terminal, or run claude --resume in \(URL(fileURLWithPath: path).lastPathComponent)."
        case nil: return ""
        }
    }
}

private struct FailedStep: View {
    let model: ContinueModel

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: model.undone ? "arrow.uturn.backward.circle.fill" : "exclamationmark.octagon.fill")
                .font(.system(size: 52))
                .foregroundStyle(model.undone ? Color.secondary : Theme.failure)
            Text(model.undone ? "Undone" : "It didn't finish").font(Theme.Font.title)
            Text(model.undone ? "Everything it wrote has been removed." : (model.failure ?? ""))
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
    }
}

/// Where the conversation is and where it is going, as a picture: the source's icon, the
/// conversation travelling between, the destination's icon.
private struct Passage: View {
    let from: Install?
    let conversationTitle: String
    let to: Install?
    let projectName: String?
    @State private var arrived = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            end(from, caption: from?.name ?? "Claude")
            VStack(spacing: 6) {
                Text(conversationTitle)
                    .font(Theme.Font.callout.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule()
                    .frame(maxWidth: 220)
                    .offset(x: arrived || reduceMotion ? 0 : -24)
                    .opacity(arrived || reduceMotion ? 1 : 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            end(to, caption: projectName.map { "\($0) in Claude Code" } ?? to?.name ?? "Claude")
        }
        .onAppear { withAnimation(Theme.Motion.smooth.delay(0.1)) { arrived = true } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(conversationTitle), from \(from?.name ?? "Claude") to \(projectName ?? to?.name ?? "Claude")")
    }

    private func end(_ install: Install?, caption: String) -> some View {
        VStack(spacing: 6) {
            if let install { InstallIcon(install: install, size: 56) } else { GlyphTile(systemImage: "folder.fill", size: 56) }
            Text(caption)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 130)
    }
}

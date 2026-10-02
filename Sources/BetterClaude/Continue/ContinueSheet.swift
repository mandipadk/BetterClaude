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
    @State private var showOptions = false
    @State private var chooseHeight: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case .choose: ChooseStep(model: model, showOptions: $showOptions, contentHeight: $chooseHeight).transition(stepTransition)
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
        .frame(width: 620, height: model.step == .choose ? min(chooseHeight + 62, 600) : 460)
        .animation(reduceMotion ? nil : Theme.Motion.snappy, value: chooseHeight)
        .background(Theme.Surface.window)
        .onDisappear { model.cleanUp() }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    // MARK: Actions

    private var actionBar: some View {
        HStack(spacing: 8) {
            if model.step == .choose, !model.isClaudeCode {
                Button(showOptions ? "Fewer Options" : "More Options") {
                    withAnimation(Theme.Motion.snappy) { showOptions.toggle() }
                }
                .buttonStyle(.quiet)
            }
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
                    .disabled(!model.canApply)
                    .keyboardShortcut(.defaultAction)
            case .working:
                EmptyView()
            case .done:
                if !model.undone {
                    Button("Undo") { model.undo() }.quietAction().disabled(model.isUndoing)
                }
                Button(model.undone ? "Close" : openTitle) {
                    if !model.undone { openDestination() }
                    onClose()
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
            case .failed:
                if model.partialReceiptID != nil, !model.undone {
                    Button("Undo What It Wrote") { model.undo() }.quietAction().disabled(model.isUndoing)
                }
                Button("Close", action: onClose).prominentAction().keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var openTitle: String {
        switch model.destination {
        case .account(let installID, _), .codeTab(let installID):
            return "Open \(services.install(installID)?.name ?? "Claude")"
        case .project: return "Open in Terminal"
        case nil: return "Done"
        }
    }

    private func openDestination() {
        switch model.destination {
        case .account(let installID, _), .codeTab(let installID):
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
    @Binding var showOptions: Bool
    @Binding var contentHeight: CGFloat
    @State private var pickingProject = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.project == nil ? "Continue “\(model.subject)”" : "Copy “\(model.subject)” to another Claude")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Surface.primary)
                    .lineLimit(2)
                Text(model.isClaudeCode
                     ? "Pick the Claude whose Code tab it belongs in. It's the same conversation, so it carries on where it left off. Nothing leaves this Mac."
                     : model.project == nil
                     ? "Pick where to carry on. Nothing leaves this Mac."
                     : "The project, its folder, what Claude remembers about it, and \(model.countPhrase). The original stays where it is. Nothing leaves this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Surface.secondary)
                    .padding(.top, 3)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3),
                          alignment: .leading, spacing: 10) {
                    if model.isClaudeCode {
                        ForEach(codeTabDestinations) { install in
                            DestinationTile(install: install,
                                            detail: services.isRunning(install) ? "Code tab, open now" : "Code tab",
                                            isSelected: model.destination == .codeTab(installID: install.id)) {
                                model.destination = .codeTab(installID: install.id)
                            }
                        }
                    }
                    ForEach(model.isClaudeCode ? [] : accountDestinations, id: \.destination) { item in
                        DestinationTile(install: item.install,
                                        detail: services.isRunning(item.install) ? roomLine(item.room, open: true) : roomLine(item.room, open: false, fallback: item.detail),
                                        isSelected: model.destination == item.destination) {
                            pickingProject = false
                            model.destination = item.destination
                        }
                    }
                    if model.project == nil, !model.isClaudeCode, let code = services.installs.first(where: { $0.kind == .claudeCode }) {
                        DestinationTile(install: code, detail: projectLine,
                                        isSelected: pickingProject || isProject) {
                            pickingProject = true
                            if !isProject, let first = projectChoices.first { model.destination = .project(path: first) }
                        }
                    }
                }
                .padding(.top, 16)

                if pickingProject || isProject {
                    SectionLabel(title: "In which project", top: 20)
                    Card(inset: 44) {
                        ForEach(projectChoices, id: \.self) { path in
                            Button { model.destination = .project(path: path) } label: {
                                Row(title: URL(fileURLWithPath: path).lastPathComponent,
                                    detail: services.snapshot.paths.abbreviating(URL(fileURLWithPath: path).deletingLastPathComponent().path)) {
                                    RowSymbol(name: "folder")
                                } trailing: {
                                    if model.destination == .project(path: path) {
                                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                                    }
                                }
                                .background(model.destination == .project(path: path) ? Theme.Surface.selection : .clear)
                            }
                            .buttonStyle(.plain)
                        }
                        Button { chooseFolder() } label: {
                            Row(title: "Choose a Folder…") { RowSymbol(name: "folder.badge.plus") } trailing: { EmptyView() }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showOptions {
                    SectionLabel(title: "Options", top: 20)
                    Card {
                        if model.isCowork {
                            Toggle(isOn: $model.includeUploads) {
                                Text("Include files you uploaded")
                                Text("Documents and images you attached. They can be large.")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            Toggle(isOn: $model.includeOutputs) {
                                Text("Include files Claude made")
                                Text("Everything in the conversation's outputs folder.")
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        // A project's folders only travel with your own name and email kept.
                        if model.project == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your name and email").font(.system(size: 13, weight: .medium))
                            Picker("Your name and email", selection: $model.profile) {
                                Text("Keep them, it's my own Claude").tag(RedactionProfile.sameUser)
                                Text("Remove them, it's someone else's account").tag(RedactionProfile.crossUser)
                                Text("Remove everything optional, for sharing").tag(RedactionProfile.share)
                            }
                            .labelsHidden()
                            .pickerStyle(.radioGroup)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            if model.destination == nil {
                if model.isClaudeCode {
                    if let first = codeTabDestinations.first { model.destination = .codeTab(installID: first.id) }
                } else if let first = accountDestinations.first {
                    model.destination = first.destination
                }
            }
        }
    }

    /// Claudes with a Code tab, other than the one the conversation is already listed in.
    private var codeTabDestinations: [Install] {
        let current: String? = { if case .codeTab = model.conversation.origin { return model.conversation.installID } else { return nil } }()
        return services.installs.filter { $0.isDesktop && $0.codeTabRoot != nil && $0.id != current }
    }

    private var isProject: Bool {
        if case .project = model.destination { return true }
        return false
    }

    private var projectLine: String {
        if case .project(let path) = model.destination { return URL(fileURLWithPath: path).lastPathComponent }
        return "Pick a project"
    }

    private func roomLine(_ room: Double?, open: Bool, fallback: String = "") -> String {
        // Room is what's left of the tighter of the five-hour and weekly limits.
        let left = room.map { "\(Int($0.rounded()))% left before a limit" }
        if open { return left.map { $0 + ", open now" } ?? "Open now" }
        return left ?? fallback
    }

    struct AccountChoice {
        let destination: ContinueDestination
        let install: Install
        let detail: String
        /// How much of the account's tighter limit is left, when Claude has said.
        let room: Double?
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
                                     install: install, detail: detail,
                                     room: services.usage.headroom(for: account.accountId))
            }
        }
        // The account with the most room left first, so a conversation goes where it can go on.
        .enumerated().sorted { a, b in
            switch (a.element.room, b.element.room) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
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

/// A place to continue in, as a tile: its icon, its name, and how much room it has.
private struct DestinationTile: View {
    let install: Install
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                InstallIcon(install: install, size: 40)
                    .frame(width: 36, height: 36)
                Text(install.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Surface.primary)
                    .lineLimit(1).padding(.top, 8)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Surface.group, in: .rect(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accentBright : Theme.Surface.line, lineWidth: isSelected ? 2 : 0.5)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(install.name), \(detail)")
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
                Passage(from: model.source, conversationTitle: model.subject,
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

                if let codeTab = model.codeTabPlan, !codeTab.problems.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        ForEach(codeTab.problems, id: \.self) { problem in
                            CheckRow(symbol: "xmark.octagon.fill", tint: Theme.failure, title: problem, detail: nil)
                        }
                    }
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
        if case .codeTab(let id) = model.destination { return services.install(id) }
        return services.installs.first { $0.kind == .claudeCode }
    }

    private var destinationProject: String? {
        if case .project(let path) = model.destination { return URL(fileURLWithPath: path).lastPathComponent }
        return nil
    }

    private var destinationName: String {
        switch model.destination {
        case .account(let id, _), .codeTab(let id): return services.install(id)?.name ?? "Claude"
        case .project(let path): return URL(fileURLWithPath: path).lastPathComponent
        case nil: return ""
        }
    }

    private var heading: String {
        switch model.destination {
        case .account: return model.project == nil ? "Ready to continue in \(destinationName)" : "Ready to copy it to \(destinationName)"
        case .project: return "Ready to continue in Claude Code"
        case .codeTab: return "Ready to add it to \(destinationName)'s Code tab"
        case nil: return ""
        }
    }

    private var summary: String {
        let title = "“\(model.subject)”"
        switch model.destination {
        case .account(_, let account):
            let who = account.emailAddress.map { ", signed in as \($0)" } ?? ""
            if model.project != nil {
                return "Copies the project \(title) and \(model.countPhrase) into \(destinationName)\(who). The project is made there once, with the same folder, and each conversation is filed in it."
            }
            return "Copies \(title) into \(destinationName)\(who). It will be at the top of its conversation list."
        case .project(let path):
            return "Copies \(title) into Claude Code for \(services.snapshot.paths.abbreviating(path)), where `claude --resume` picks it up."
        case .codeTab:
            if model.codeTabPlan?.copyTo != nil {
                return "Copies \(title) into the Claude Code folder \(destinationName) uses and lists it in its Code tab, ready to carry on."
            }
            return "Lists \(title) in \(destinationName)'s Code tab. It's the same conversation, not a copy: carrying on there continues where it left off, and it stays in Claude Code's own list too."
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
            BMark(size: 64)
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
            Text(model.undone ? (model.undoNote ?? "Everything it wrote has been removed.") : detail)
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let failure = model.undoFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(24)
    }

    private var title: String {
        switch model.destination {
        case .account(let id, _): return "It's in \(services.install(id)?.name ?? "Claude")"
        case .project: return "It's in Claude Code"
        case .codeTab(let id): return "It's in \(services.install(id)?.name ?? "Claude")'s Code tab"
        case nil: return "Done"
        }
    }

    private var detail: String {
        switch model.destination {
        case .account:
            return model.project == nil
                ? "Open it and the conversation is at the top of the list, ready to pick up where it left off."
                : "Open it and the project is in Projects, with \(model.countPhrase) in it. The original is still in \(model.source?.name ?? "the first Claude") until you delete it there."
        case .project(let path): return "Open it in Terminal, or run claude --resume in \(URL(fileURLWithPath: path).lastPathComponent)."
        case .codeTab(let id):
            let name = services.install(id)?.name ?? "Claude"
            return services.install(id).map(services.isRunning) == true ? "\(name) is open: quit and reopen it to see the conversation in its Code tab."
                : "Open \(name) and it's in the Code tab, ready to carry on."
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
            Text(model.undone ? (model.undoNote ?? "Everything it wrote has been removed.") : (model.failure ?? ""))
                .font(Theme.Font.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let failure = model.undoFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
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
                    .background(Theme.groupFill, in: .capsule)
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

import CoworkKit
import SwiftUI

struct TransferSheet: View {
    @State var model: TransferModel
    let app: AppModel
    let onClose: () -> Void
    @State private var destinationQuery = ""
    @State private var showsAllChecks = false
    @State private var showsPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            content
            Hairline()
            footer
        }
        .frame(minWidth: 660, idealWidth: 660, maxWidth: 660,
               minHeight: 420, idealHeight: 640, maxHeight: 680)
        .background(Design.Palette.raised)
        .onAppear(perform: preselectDestination)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(Design.Typography.heading)
                .foregroundStyle(Design.Palette.primary)
            Text(subhead)
                .font(Design.Typography.caption)
                .foregroundStyle(Design.Palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    private var headline: String {
        switch model.stage {
        case .finished: return "Transferred"
        case .failed: return "Nothing was written"
        case .ready, .running: return "Review"
        default: return model.sessions.count == 1 ? "Transfer conversation"
                                                  : "Transfer \(model.sessions.count) conversations"
        }
    }

    private var subhead: String {
        switch model.stage {
        case .ready, .running: return model.destination?.label ?? ""
        case .finished, .failed: return ""
        default:
            return model.sessions.prefix(3).map(\.title).joined(separator: " · ")
                + (model.sessions.count > 3 ? " and \(model.sessions.count - 3) more" : "")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.stage {
        case .configuring, .planning:
            configure
        case .ready, .running:
            review
        case .finished(let id, let summary):
            outcome(mark: .ok, title: "The conversation is in place.", body: summary, receipt: id)
        case .failed(let message):
            outcome(mark: .blocked, title: "Stopped before writing anything.", body: message, receipt: nil)
        }
    }

    // MARK: - Configure

    private var configure: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Destination")
                    .padding(.bottom, Design.Space.m)

                if !installs.isEmpty {
                    SubHead(text: "Claude")
                        .padding(.bottom, Design.Space.xs)
                    ForEach(installs) { option in
                        DestinationRow(option: option, isSelected: model.destination == option.destination) {
                            model.destination = option.destination
                        }
                    }
                } else {
                    Text(projects.isEmpty
                         ? "No other destination is available."
                         : "No other Claude account is signed in on this Mac.")
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.secondary)
                        .padding(.bottom, Design.Space.s)
                }

                if !allProjects.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        // The count belongs on the label because the list below is bounded:
                        // without it, three visible rows silently claim to be the whole set.
                        SubHead(text: "Claude Code · \(allProjects.count)")
                        Spacer()
                        MiniSearch(text: $destinationQuery)
                            .frame(width: 150)
                    }
                    .padding(.top, Design.Space.l)
                    .padding(.bottom, Design.Space.xs)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { option in
                                DestinationRow(option: option,
                                               isSelected: model.destination == option.destination) {
                                    model.destination = option.destination
                                }
                            }
                        }
                    }
                    // Deliberately not a whole number of rows: the half-cut row plus the fade
                    // is what tells the reader the list continues.
                    .frame(height: 150)
                    .fadingBottomEdge(68)
                }

                SectionLabel(text: "Include")
                    .padding(.top, Design.Space.l)
                    .padding(.bottom, Design.Space.s)
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    Checkbox(title: "Files you uploaded", isOn: $model.includeUploads)
                    Checkbox(title: "Files the conversation produced", isOn: $model.includeOutputs)
                }
                Text("The conversation always travels. Attachments are off by default because they are large and personal.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                    .padding(.top, Design.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)

                SectionLabel(text: "Identity")
                    .padding(.top, Design.Space.l)
                    .padding(.bottom, Design.Space.s)
                VStack(alignment: .leading, spacing: Design.Space.s) {
                    RadioOption(title: "Keep — my own installs",
                                value: RedactionProfile.sameUser, selection: $model.profile)
                    RadioOption(title: "Remove — another account",
                                value: RedactionProfile.crossUser, selection: $model.profile)
                    RadioOption(title: "Remove everything optional",
                                value: RedactionProfile.share, selection: $model.profile)
                }
                Text("Credentials, audit logs and permission grants are never included, in any mode.")
                    .font(Design.Typography.caption)
                    .foregroundStyle(Design.Palette.muted)
                    .padding(.top, Design.Space.xs)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Design.Typography.body)
            .padding(.horizontal, Design.Space.xl)
            .padding(.vertical, Design.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fadingBottomEdge(56)
    }

    // MARK: - Review

    @ViewBuilder
    private var review: some View {
        if let plan = model.plan {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let manifest = model.manifest {
                        SectionLabel(text: "Moving")
                            .padding(.bottom, Design.Space.s)
                        ForEach(manifest.sessions, id: \.slot) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: Design.Space.m) {
                                Text(entry.chat.title)
                                    .font(Design.Typography.body)
                                    .foregroundStyle(Design.Palette.primary)
                                    .lineLimit(1)
                                Spacer(minLength: Design.Space.m)
                                Text("\(entry.chat.userTurns + entry.chat.assistantTurns) turns")
                                    .font(Design.Typography.numeric)
                                    .foregroundStyle(Design.Palette.muted)
                            }
                            .padding(.vertical, 5)
                        }
                    }

                    // Warnings first. Everything below this point is reassurance; this is the
                    // only part that might change what the reader decides to do.
                    if !model.progressLines.isEmpty {
                        SectionLabel(text: "Before you continue")
                            .padding(.top, Design.Space.l)
                            .padding(.bottom, Design.Space.s)
                        ForEach(model.progressLines, id: \.self) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                                StatusMark(kind: .warning)
                                Text(line)
                                    .font(Design.Typography.body)
                                    .foregroundStyle(Design.Palette.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                        }
                    }

                    checks(plan)

                    if !plan.conflicts.isEmpty {
                        Checkbox(title: "Quit Claude before writing", isOn: $model.quitRunningVariant)
                            .padding(.top, Design.Space.m)
                    }

                    creates(plan)
                }
                .padding(.horizontal, Design.Space.xl)
                .padding(.vertical, Design.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack { ProgressView().controlSize(.small) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Passing checks collapse to one line. Nine rows of reassurance ahead of the one line
    /// that reports a problem inverts the importance of the screen.
    @ViewBuilder
    private func checks(_ plan: ImportPlan) -> some View {
        let failures = plan.preconditions.filter { !$0.passed }
        let passes = plan.preconditions.count - failures.count

        SectionLabel(text: "Checks")
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.s)

        ForEach(failures, id: \.id) { check in
            checkRow(check)
        }

        if passes > 0 {
            DisclosureToggle(
                expandedTitle: "Hide the \(passes) that passed",
                collapsedTitle: "\(passes) check\(passes == 1 ? "" : "s") passed",
                isExpanded: $showsAllChecks,
                leadingMark: nil)
                .padding(.vertical, 3)
            if showsAllChecks {
                ForEach(plan.preconditions.filter(\.passed), id: \.id) { check in
                    checkRow(check)
                }
            }
        }
    }

    private func checkRow(_ check: PreconditionResult) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            StatusMark(kind: check.passed ? .ok : .blocked)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(Design.Typography.body)
                    .foregroundStyle(check.passed ? Design.Palette.secondary : Design.Palette.primary)
                if let detail = check.detail, !check.passed {
                    Text(detail)
                        .font(Design.Typography.caption)
                        .foregroundStyle(Design.Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    /// A plain-language summary by default. Two 80-character UUID paths answer "what will
    /// this write to my disk" with something nobody can read or verify.
    @ViewBuilder
    private func creates(_ plan: ImportPlan) -> some View {
        SectionLabel(text: "Creates")
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.s)

        Text("\(plan.willCreate.count) new item\(plan.willCreate.count == 1 ? "" : "s") in \(plan.endpoint.describedDestination).")
            .font(Design.Typography.body)
            .foregroundStyle(Design.Palette.primary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Nothing that already exists is changed.")
            .font(Design.Typography.caption)
            .foregroundStyle(Design.Palette.muted)
            .padding(.top, 2)

        DisclosureToggle(expandedTitle: "Exact paths", collapsedTitle: "Show exact paths",
                         isExpanded: $showsPaths, leadingMark: nil)
            .padding(.top, Design.Space.s)

        if showsPaths {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan.willCreate, id: \.self) { url in
                    Text(url.path.abbreviatingHome)
                        .font(Design.Typography.mono)
                        .foregroundStyle(Design.Palette.muted)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, Design.Space.xs)
        }
    }

    private func outcome(mark: StatusMark.Kind, title: String, body: String, receipt: String?) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.m) {
            HStack(spacing: Design.Space.s) {
                StatusMark(kind: mark)
                Text(title)
                    .font(Design.Typography.heading)
                    .foregroundStyle(Design.Palette.primary)
            }
            Text(body)
                .font(Design.Typography.body)
                .foregroundStyle(Design.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let receipt {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    SectionLabel(text: "To undo")
                    Text("cowork undo \(receipt)")
                        .font(Design.Typography.mono)
                        .foregroundStyle(Design.Palette.muted)
                        .textSelection(.enabled)
                }
                .padding(.top, Design.Space.s)
            }
            Spacer()
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Design.Space.s) {
            Spacer()
            switch model.stage {
            case .configuring:
                Button("Cancel") { model.cleanUpBundle(); onClose() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Review") { Task { await model.buildPlan() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!model.canPlan)
                    .keyboardShortcut(.defaultAction)
            case .planning, .running:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Back") { model.stage = .configuring }
                    .buttonStyle(QuietButtonStyle())
                Button("Transfer") { Task { await model.apply() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canTransfer)
                    .keyboardShortcut(.defaultAction)
            case .finished, .failed:
                Button("Done") { onClose() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Design.Space.xl)
        .padding(.vertical, Design.Space.l)
    }

    /// The running-app check is the only failure the user can clear from inside this sheet.
    private var canTransfer: Bool {
        guard let plan = model.plan else { return false }
        if plan.isExecutable { return true }
        let failures = plan.preconditions.filter { !$0.passed }
        return model.quitRunningVariant && failures.allSatisfy { $0.id == "PC2" }
    }

    // MARK: - Destinations

    /// Opens with a destination already chosen when there is an unambiguous one, so the
    /// primary action is live on arrival instead of dead until the user notices it.
    private func preselectDestination() {
        guard model.destination == nil else { return }
        if let onlyInstall = installs.first, installs.count == 1 {
            model.destination = onlyInstall.destination
        } else if installs.isEmpty, let onlyProject = projects.first, projects.count == 1 {
            model.destination = onlyProject.destination
        } else {
            model.destination = installs.first?.destination
        }
    }

    /// Only accounts that already hold conversations are offered.
    ///
    /// An account with none has never been signed into on this machine, and Claude Desktop
    /// only ever reads the account it is signed into — so a conversation imported there
    /// would sit on disk permanently invisible, with nothing to explain why. The command
    /// line keeps an escape hatch for the rare case where it is wanted.
    private var installs: [DestinationOption] {
        let sourceIDs = Set(model.sessions.compactMap { $0.cowork?.account.id })
        return app.stores.flatMap { store in
            (app.accounts[store] ?? [])
                .filter { !sourceIDs.contains($0.id) && $0.sessionCount > 0 }
                .map { account in
                    DestinationOption(
                        destination: .coworkAccount(account),
                        title: account.emailAddress ?? account.displayIdentity,
                        detail: "\(store.variantDirName) · \(account.sessionCount) conversation\(account.sessionCount == 1 ? "" : "s")",
                        warning: app.isRunning(store)
                            ? "\(store.variantDirName) is running — it must be quit first"
                            : nil)
                }
        }
    }

    private var allProjects: [DestinationOption] { projectOptions(matching: nil) }
    private var projects: [DestinationOption] { projectOptions(matching: destinationQuery) }

    private func projectOptions(matching query: String?) -> [DestinationOption] {
        app.claudeCodeProjects.compactMap { dir -> DestinationOption? in
            guard let path = app.projectPath(dir) else { return nil }
            let name = URL(fileURLWithPath: path).lastPathComponent
            if let query, !query.isEmpty,
               !name.localizedCaseInsensitiveContains(query),
               !path.localizedCaseInsensitiveContains(query) { return nil }
            return DestinationOption(destination: .claudeCodeProject(URL(fileURLWithPath: path)),
                                     title: name, detail: path.abbreviatingHome, warning: nil)
        }
    }
}

struct DestinationOption: Identifiable {
    let destination: Destination
    let title: String
    let detail: String
    let warning: String?

    var id: String { destination.id }
}

private struct DestinationRow: View {
    let option: DestinationOption
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isSelected ? Design.Palette.accent : Design.Palette.controlStroke)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.title)
                        .font(Design.Typography.body)
                        .foregroundStyle(Design.Palette.primary)
                        .lineLimit(1)
                    Text(option.warning ?? option.detail)
                        .font(Design.Typography.caption)
                        .foregroundStyle(option.warning == nil ? Design.Palette.muted : Design.Palette.accent)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Design.Space.corner, style: .continuous)
                    .fill(isHovering ? Design.Palette.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct MiniSearch: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Design.Palette.faint)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(Design.Typography.caption)
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Design.Palette.hover)
        )
    }
}

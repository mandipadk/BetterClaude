import CoworkKit
import SwiftUI

struct TransferSheet: View {
    @State var model: TransferModel
    let app: AppModel
    let onClose: () -> Void
    @State private var destinationQuery = ""
    @State private var showsAllChecks = false
    @State private var showsPaths = false

    /// How many Claude Code projects the destination list shows before deferring to search.
    /// Chosen so the configure step stays one screen tall at the app's 560pt minimum height,
    /// which is what keeps the Identity section above the fold.
    private static let visibleProjects = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            content
            Hairline()
            footer
        }
        // Width is fixed; height follows the content. An idealHeight held every stage at
        // 640pt whatever it contained, so a two-line "Transferred" receipt rendered with a
        // 401pt empty band — 63% of the sheet — and a failure with 450pt. The maxHeight is
        // a ceiling for the configure step's list, not a target for the short stages.
        .frame(width: 660)
        .frame(maxHeight: 680)
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

    /// Destination scrolls; Include and Identity do not.
    ///
    /// Two earlier attempts treated this as a sizing problem — first a nested 150pt scroll
    /// view, then a list bounded to four rows — and both left the Identity section below the
    /// fold at the app's minimum window, where it rendered zero pixels. The bounded list was
    /// actually 31pt taller than the nested scroll it replaced, so the "fix" regressed it.
    ///
    /// No constant works, because the deficit is 171pt and each project row is 43pt: the only
    /// number that fits is zero. The structure was the problem. Identity now lives outside the
    /// scroll view entirely, so the choice between keeping and removing identifiers is on
    /// screen at every window size — which matters because the default keeps them, and someone
    /// sending a conversation to another person's account has to be able to see the
    /// alternative exists.
    private var configure: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                    // A bounded list, not a nested scroll view. This used to be its own
                    // ScrollView pinned to 150pt inside the outer one — two scrollers with
                    // two bottom fades, and the cost was not cosmetic: at the app's minimum
                    // window the entire Identity section sat below the fold, so someone
                    // sending a conversation to another person's account could not see that
                    // "Remove — another account" existed. The default keeps identifiers.
                    //
                    // Showing a few and letting the search field narrow keeps the sheet one
                    // screen tall, which is what makes the sections below it reachable.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(projects.prefix(Self.visibleProjects)) { option in
                            DestinationRow(option: option,
                                           isSelected: model.destination == option.destination) {
                                model.destination = option.destination
                            }
                        }
                    }
                    if projects.count > Self.visibleProjects {
                        Text("\(projects.count - Self.visibleProjects) more — search to narrow the list.")
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Palette.muted)
                            .padding(.top, Design.Space.xs)
                    } else if projects.isEmpty && !destinationQuery.isEmpty {
                        Text("No project matches “\(destinationQuery)”.")
                            .font(Design.Typography.caption)
                            .foregroundStyle(Design.Palette.muted)
                            .padding(.top, Design.Space.xs)
                    }
                }

            }
            .font(Design.Typography.body)
            .padding(.horizontal, Design.Space.xl)
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fadingBottomEdge(56)

            Hairline()

            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Include")
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
            .fadingBottomEdge(56)
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
                // Held to the button height so the footer does not collapse 58 -> 48pt at
                // the instant the user clicks Review or Transfer, with the cursor still over
                // where the button was.
                ProgressView().controlSize(.small)
                    .frame(height: 26)
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

    /// Accounts Claude Desktop will actually read from: signed-in, or already holding
    /// conversations.
    ///
    /// This used to require `sessionCount > 0`, on the reasoning that an account with none
    /// had never been signed into, so an import would sit there permanently invisible. The
    /// premise was wrong. An empty account disqualifies itself as a *source*; it says nothing
    /// about it as a *destination*, and a freshly signed-in install — the one you are most
    /// likely to be transferring *to* — has no sessions by definition. `isSignedIn` reads the
    /// install's own record of which account it is signed into, which is the thing the old
    /// check was trying to infer.
    private var installs: [DestinationOption] {
        let sourceIDs = Set(model.sessions.compactMap { $0.cowork?.account.id })
        return app.stores.flatMap { store in
            (app.accounts[store] ?? [])
                .filter { !sourceIDs.contains($0.id) && $0.canReceiveTransfer }
                .map { account in
                    DestinationOption(
                        destination: .coworkAccount(account),
                        // No email exists until a conversation does — it is only ever read out
                        // of session metadata — so a signed-in empty account is named by its
                        // install instead of by a pair of raw UUIDs.
                        title: account.emailAddress ?? store.variantDirName,
                        // The install name is only repeated in the detail when the title is an
                        // email; when the title *is* the install name, the org distinguishes
                        // the row instead.
                        detail: account.emailAddress == nil
                            ? "\(Self.conversationCount(account)) · org \(account.orgId.prefix(8))…"
                            : "\(store.variantDirName) · \(Self.conversationCount(account))",
                        warning: app.isRunning(store)
                            ? "\(store.variantDirName) is running — it must be quit first"
                            : nil)
                }
        }
    }

    /// "no conversations yet" rather than "0 conversations": an empty destination is a normal
    /// state here, not a shortfall.
    private static func conversationCount(_ account: AccountRef) -> String {
        switch account.sessionCount {
        case 0: return "signed in, no conversations yet"
        case 1: return "1 conversation"
        default: return "\(account.sessionCount) conversations"
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

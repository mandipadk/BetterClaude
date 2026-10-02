import CoworkKit
import SwiftUI

/// The main window: a full-height sidebar and one frosted surface, like Parallex.
struct MainWindow: View {
    @Environment(AppServices.self) private var services
    @State private var showsOnboarding = false
    /// Settings' Show Again clears this, and the welcome opens without a relaunch.
    @AppStorage("onboardingCompleted") private var onboardingCompleted = true

    static var firstRun: Bool {
        #if DEBUG
        // A capture asks for the screen it wants; onboarding only when that's the one.
        if let route = ProcessInfo.processInfo.environment["BC_UI_ROUTE"] {
            return route.hasPrefix("onboarding")
        }
        #endif
        return !UserDefaults.standard.bool(forKey: "onboardingCompleted")
    }

    var body: some View {
        @Bindable var services = services
        NavigationSplitView {
            Sidebar()
                .frame(minWidth: 208)
                .navigationSplitViewColumnWidth(min: 208, ideal: 208, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.window.ignoresSafeArea())
                // The toolbar's bottom edge.
                .overlay(alignment: .top) { Rectangle().fill(Theme.Surface.line).frame(height: 0.5) }
                .navigationTitle(services.windowTitle)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { services.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(services.backPlaces.isEmpty)
                    .help("Back (⌘[)")
                    .keyboardShortcut("[", modifiers: .command)
                Button { services.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(services.forwardPlaces.isEmpty)
                    .help("Forward (⌘])")
                    .keyboardShortcut("]", modifiers: .command)
            }
            if ![.conversations, .usage, .library].contains(services.destination),
               !(services.destination == .projects && services.projectPages.selectedID != nil) {
                ToolbarItem(placement: .primaryAction) {
                    SearchPill(prompt: "Search or ask") { services.showsPalette = true }
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbarBackground(Theme.Surface.bar, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .overlay {
            if services.showsPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { services.showsPalette = false }
                    CommandPalette { services.showsPalette = false }
                        .padding(.top, 70)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
        }
        .animation(Theme.Motion.fade, value: services.showsPalette)

        .background {
            // ⌘↩ on a search asks the question instead of matching words. Not while the
            // palette is open: a shortcut here would take ⌘↩ before the palette's own Ask.
            if !services.showsPalette {
                Button("") {
                    let question = services.query.trimmingCharacters(in: .whitespaces)
                    if !question.isEmpty { services.askHistory(question) }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .background {
            // ⌘F finds in the conversation you're reading, or opens ⌘K elsewhere.
            Button("") {
                if services.destination == .conversations, services.reader.conversation != nil {
                    services.reader.find()
                } else {
                    services.showsPalette = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onChange(of: services.query) { _, query in
            services.search.search(query)
            if !query.isEmpty, services.destination != .conversations {
                services.destination = .conversations
            }
        }
        .task {
            if !services.hasLoaded { services.refresh() }
            // After the window has its toolbar: a sheet raised during the very first layout
            // leaves the columns laid out as if there were none, scrolled up under the title.
            if MainWindow.firstRun {
                try? await Task.sleep(for: .milliseconds(350))
                showsOnboarding = true
            }
        }
        .onChange(of: onboardingCompleted) { _, completed in
            if !completed { showsOnboarding = true }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView { showsOnboarding = false }
                .environment(services)
                .interactiveDismissDisabled()
        }
        .sheet(item: $services.comparing) { pair in
            CompareSheet(pair: pair).environment(services)
        }
        .sheet(item: $services.replaying) { model in
            ReplaySheet(model: model) { services.replaying = nil }
                .environment(services)
        }
        .sheet(item: $services.openingMac) { request in
            OtherMacSheet(request: request) { services.openingMac = nil }
                .environment(services)
        }
        .sheet(item: $services.lookingBack) { model in
            MonthSheet(model: model) { services.lookingBack = nil }
                .environment(services)
        }
        .sheet(item: $services.watching) { model in
            TimelapseSheet(model: model) { services.watching = nil }
                .environment(services)
        }
        .sheet(item: $services.rewinding) { model in
            RewindSheet(model: model) { services.rewinding = nil }
                .environment(services)
        }
        .sheet(item: $services.handingOff) { model in
            HandoffSheet(model: model) { services.handingOff = nil }
                .environment(services)
        }
        .sheet(item: $services.forking) { request in
            ForkSheet(request: request).environment(services)
        }
        .sheet(item: $services.porting) { model in
            PortSheet(model: model) { services.endPort() }
                .environment(services)
        }
        .sheet(item: $services.continuing) { model in
            ContinueSheet(model: model) { services.endContinue() }
                .environment(services)
        }
        .alert(services.notice ?? "", isPresented: Binding(get: { services.notice != nil },
                                                          set: { if !$0 { services.notice = nil } })) {
            Button("OK") { services.notice = nil }
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { services.errorMessage != nil },
                                    set: { if !$0 { services.errorMessage = nil } })) {
            Button("OK") { services.errorMessage = nil }
        } message: {
            Text(services.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        #if DEBUG
        if services.previewsGallery {
            GalleryView()
        }
        #endif
        if services.previewsGallery {
            EmptyView()
        } else if services.previewsMenuBarPanel {
            MenuBarPanel()
                .clipShape(.rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.Surface.line))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            destinationView
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch services.destination {
        case .home:
            HomePage()
        case .thisMac:
            ThisMacPage()
        case .conversations, nil:
            ConversationsView()
        case .running:
            RunningPage()
        case .ask:
            AskPage()
        case .usage:
            UsagePage()
        case .files:
            FilesPage()
        case .prompts:
            PromptsPage()
        case .projects:
            ProjectsPage()
        case .secrets:
            SecretsPage()
        case .library:
            LibraryPage()
        case .history:
            HistoryPage()
        case .kept:
            KeptPage()
        case .storage:
            StoragePage()
        case .memory:
            MemoryPage()
        case .install(let id):
            if let install = services.install(id) {
                InstallPage(install: install)
            } else {
                EmptyState(systemImage: "questionmark.app", title: "Not found",
                           message: "This install isn't on this Mac anymore.")
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @Environment(AppServices.self) private var services
    @Environment(UpdateModel.self) private var updates

    /// Pages that live under a sidebar row keep that row selected.
    private var selected: SidebarDestination? {
        switch services.destination {
        case .kept, .storage, .secrets, .history: return .thisMac
        case .files, .memory: return .projects
        case .prompts: return .library
        case .running, .ask: return .home
        default: return services.destination
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    item(.home, "Home", "house", count: services.pulse.needingYou.count, attention: true)
                    item(.conversations, "Conversations", "bubble.left.and.bubble.right")
                    item(.projects, "Projects", "folder")
                    item(.usage, "Usage", "chart.bar.xaxis")
                    item(.library, "Library", "books.vertical")
                    if !services.installs.isEmpty {
                        Text("Sources")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.Surface.secondary)
                            .padding(.horizontal, 10)
                            .padding(.top, 14)
                            .padding(.bottom, 5)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(services.installs) { install in
                            sourceRow(install)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 2)
            }
            .scrollIndicators(.never)
            item(.thisMac, "This Mac", "laptopcomputer", count: services.secrets.open.count, attention: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Surface.sidebar.ignoresSafeArea())
    }

    private func item(_ destination: SidebarDestination, _ title: String, _ symbol: String,
                      count: Int = 0, attention: Bool = false) -> some View {
        SidebarRow(isSelected: selected == destination, action: { services.go(to: destination) }) {
            Image(systemName: symbol)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.accent)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 12, weight: attention ? .semibold : .regular))
                    .foregroundStyle(attention ? Theme.attention : Theme.Surface.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func sourceRow(_ install: Install) -> some View {
        let count = services.conversationCount(in: install)
        return SidebarRow(isSelected: selected == .install(install.id), action: { services.destination = .install(install.id) }) {
            InstallIcon(install: install, size: 22)
                .frame(width: 18, height: 18)
            Text(install.name).lineLimit(1)
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit()
            }
        }
        .help(services.isRunning(install) ? "\(install.name) is open" : install.name)
        .contextMenu {
            Button("Show Conversations") { services.showConversations(.install(install.id)) }
            if install.appURL != nil {
                Button(services.isRunning(install) ? "Show \(install.name)" : "Open \(install.name)") { services.open(install) }
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([install.dataRoot]) }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let version = updates.waiting {
            Button { updates.showWaiting() } label: {
                HStack(spacing: 8) {
                    Text("Better Claude \(version) is ready").font(.system(size: 12))
                        .foregroundStyle(Theme.Surface.secondary)
                    Spacer()
                    Text("Update…").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else if let progress = services.index.progress {
            HStack(spacing: 8) {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .controlSize(.small).frame(width: 48)
                Text("Reading \(progress.done) of \(progress.total)…")
                    .font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary).monospacedDigit().lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        } else if services.isLoading && !services.hasLoaded {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for Claude on this Mac…").font(.system(size: 12)).foregroundStyle(Theme.Surface.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
    }
}

/// A sidebar row: 28pt tall, 8pt corners, a neutral highlight when selected.
struct SidebarRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) { content }
                .font(.system(size: 13))
                .foregroundStyle(Theme.Surface.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isSelected ? Theme.Surface.selection : hovering ? Theme.Surface.fill.opacity(0.6) : .clear,
                            in: .rect(cornerRadius: 8, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct InstallRow: View {
    let install: Install
    let isRunning: Bool
    let count: Int

    var body: some View {
        Label {
            Text(install.name).lineLimit(1)
        } icon: {
            InstallIcon(install: install, size: 18)
        }
        .badge(count)
        .help(subtitle)
        .accessibilityElement(children: .combine)
        .accessibilityValue(subtitle)
    }

    private var subtitle: String {
        if isRunning { return "Open now" }
        switch count {
        case 0: return install.kind == .science ? "Projects and files" : "No conversations"
        case 1: return "1 conversation"
        default: return "\(count) conversations"
        }
    }
}

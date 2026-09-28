import CoworkKit
import SwiftUI

/// The main window: a full-height sidebar and one frosted surface, like Parallex.
struct MainWindow: View {
    @Environment(AppServices.self) private var services
    @State private var showsOnboarding = false
    @FocusState private var searchFocused: Bool

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
                .navigationSplitViewColumnWidth(min: 220, ideal: 244, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Content never scrolls up under the toolbar's title and controls.
                .clipped()
                .background(WindowGlassBackground(material: .sidebar).ignoresSafeArea())
                .navigationTitle("")
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 7) {
                    ForkMark(size: 16)
                    Text("Better Claude")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 6)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Better Claude")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    services.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Look for new conversations (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .searchable(text: $services.query, placement: .toolbar, prompt: "Search conversations")
        .modifier(SearchFocus(focused: $searchFocused))
        .background {
            // ⌘F finds conversations from anywhere in the window.
            Button("") {
                services.destination = .conversations
                searchFocused = true
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
        .tint(Theme.accent)
        .task {
            if !services.hasLoaded { services.refresh() }
            // After the window has its toolbar: a sheet raised during the very first layout
            // leaves the columns laid out as if there were none, scrolled up under the title.
            if MainWindow.firstRun {
                try? await Task.sleep(for: .milliseconds(350))
                showsOnboarding = true
            }
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingView { showsOnboarding = false }
                .environment(services)
                .interactiveDismissDisabled()
        }
        .sheet(item: $services.comparing) { pair in
            CompareSheet(pair: pair).environment(services)
        }
        .sheet(item: $services.forking) { request in
            ForkSheet(request: request).environment(services)
        }
        .sheet(item: $services.continuing) { model in
            ContinueSheet(model: model) { services.endContinue() }
                .environment(services)
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
        if services.previewsMenuBarPanel {
            MenuBarPanel()
                .background(.regularMaterial, in: .rect(cornerRadius: Theme.Radius.panel))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Theme.hairline))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            destinationView
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch services.destination {
        case .conversations, nil:
            ConversationsView()
        case .running:
            RunningPage()
        case .ask:
            AskPage()
        case .usage:
            UsagePage()
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

    var body: some View {
        @Bindable var services = services
        List(selection: $services.destination) {
            Section {
                Label("Conversations", systemImage: "bubble.left.and.bubble.right")
                    .tag(SidebarDestination.conversations)
                Label("Running", systemImage: "waveform.path.ecg")
                    .badge(services.pulse.needingYou.count)
                    .tag(SidebarDestination.running)
                Label("Ask", systemImage: "sparkle.magnifyingglass")
                    .tag(SidebarDestination.ask)
                Label("Usage", systemImage: "gauge.with.dots.needle.50percent")
                    .tag(SidebarDestination.usage)
                Label("Library", systemImage: "square.stack")
                    .tag(SidebarDestination.library)
            }

            if !services.installs.isEmpty {
                Section("Installs") {
                    ForEach(services.installs) { install in
                        InstallRow(install: install,
                                   isRunning: services.isRunning(install),
                                   count: services.conversationCount(in: install))
                            .tag(SidebarDestination.install(install.id))
                    }
                }
            }

            Section("Upkeep") {
                Label("Kept", systemImage: "archivebox")
                    .badge(services.kept.onlyHere.count)
                    .tag(SidebarDestination.kept)
                Label("Storage", systemImage: "internaldrive")
                    .tag(SidebarDestination.storage)
                Label("Memory", systemImage: "brain")
                    .tag(SidebarDestination.memory)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarDestination.history)
            }
        }
        .listStyle(.sidebar)
        .bottomBar {
            if let version = updates.waiting {
                Button { updates.showWaiting() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent)
                        Text("Better Claude \(version) is ready")
                            .font(Theme.Font.callout)
                        Spacer()
                        Text("Update…").font(Theme.Font.callout).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else if let progress = services.index.progress {
                HStack(spacing: 8) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .controlSize(.small)
                        .frame(width: 60)
                    Text("Reading \(progress.done) of \(progress.total) conversations…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else if services.isLoading && !services.hasLoaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Claude on this Mac…")
                        .font(Theme.Font.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }
}

struct InstallRow: View {
    let install: Install
    let isRunning: Bool
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            InstallIcon(install: install, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(install.name)
                    .font(Theme.Font.bodyMedium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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

/// Focus for the toolbar search field, where the system offers it (macOS 15 and later).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

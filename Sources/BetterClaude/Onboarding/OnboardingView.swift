import CoworkKit
import ServiceManagement
import SwiftUI

/// First run: what Better Claude found, what it does, and the two or three choices that
/// make it work well — each explained, each set to the recommended choice.
struct OnboardingView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("keepAutomatically") private var keepAutomatically = true
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @State private var openAtLogin = false

    @State private var page = 0
    @State private var forward = true
    let onFinish: () -> Void

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch page {
                case 0: WelcomePage().transition(pageTransition)
                case 1: WhatItDoesPage().transition(pageTransition)
                default:
                    SetupPage(keepAutomatically: $keepAutomatically, showInMenuBar: $showInMenuBar,
                              openAtLogin: $openAtLogin)
                        .transition(pageTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 780, height: 540)
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.smooth, value: page)
        .onAppear {
            #if DEBUG
            if let raw = ProcessInfo.processInfo.environment["BC_UI_ROUTE"],
               raw.hasPrefix("onboarding:"), let number = Int(raw.dropFirst("onboarding:".count)) {
                page = min(max(number, 0), pageCount - 1)
            }
            #endif
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: .offset(x: forward ? 48 : -48).combined(with: .opacity),
                           removal: .offset(x: forward ? -48 : 48).combined(with: .opacity))
    }

    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.primary.opacity(0.8) : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 16 : 6, height: 6)
                }
            }
            .animation(Theme.Motion.snappy, value: page)
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(pageCount)")

            HStack {
                if page > 0 {
                    Button("Back") { move(-1) }.quietAction().transition(.opacity)
                }
                Spacer()
                Button(page == 0 ? "Get Started" : page == pageCount - 1 ? "Start Using Better Claude" : "Continue") {
                    if page < pageCount - 1 { move(1) } else { finish() }
                }
                .prominentAction()
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.bottom, Theme.Space.xl + 4)
        .padding(.top, Theme.Space.m)
    }

    private func move(_ delta: Int) {
        forward = delta > 0
        page = min(max(page + delta, 0), pageCount - 1)
    }

    private func finish() {
        if openAtLogin { try? SMAppService.mainApp.register() }
        onboardingCompleted = true
        onFinish()
    }
}

// MARK: - Pages

private struct PageHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.4)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fanned = false

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            IconFan(installs: Array(services.installs.prefix(5)), fanned: fanned || reduceMotion)
                .frame(height: 150)
            VStack(spacing: 10) {
                Text("All your Claude, in one place.")
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-0.8)
                Text(found)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.smooth, value: found)
            }
            .opacity(fanned || reduceMotion ? 1 : 0)
        }
        .onAppear { withAnimation(Theme.Motion.smooth.delay(0.2)) { fanned = true } }
    }

    private var found: String {
        guard services.hasLoaded else { return "Looking for Claude on this Mac…" }
        let installs = services.installs.count
        let conversations = services.snapshot.conversations.count
        return "Found \(installs) \(installs == 1 ? "install" : "installs") and \(conversations) \(conversations == 1 ? "conversation" : "conversations") on this Mac."
    }
}

/// Real app icons, stacked, then fanned out: every Claude on the Mac.
private struct IconFan: View {
    let installs: [Install]
    let fanned: Bool

    var body: some View {
        let count = max(installs.count, 1)
        ZStack {
            ForEach(Array(installs.enumerated()), id: \.element.id) { index, install in
                let offset = Double(index) - Double(count - 1) / 2
                InstallIcon(install: install, size: 112)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .rotationEffect(.degrees(fanned ? offset * 8 : 0))
                    .offset(x: fanned ? offset * 92 : 0, y: fanned ? abs(offset) * 10 : 0)
                    .zIndex(Double(count) - abs(offset))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(installs.map(\.name).joined(separator: ", "))
    }
}

private struct WhatItDoesPage: View {
    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            PageHeading(title: "What Better Claude does",
                        subtitle: "It reads what every Claude on this Mac keeps, and never changes a thing without asking.")
            LazyVGrid(columns: [GridItem(.fixed(300), spacing: 16), GridItem(.fixed(300), spacing: 16)], spacing: 16) {
                Promise(symbol: "arrow.right.circle", title: "Continue anywhere",
                        detail: "Carry a conversation to another Claude or to Claude Code, and undo it any time.")
                Promise(symbol: "archivebox", title: "Keep",
                        detail: "Claude Code deletes conversations after 30 days. Better Claude keeps a copy.")
                Promise(symbol: "magnifyingglass", title: "Find",
                        detail: "Every conversation and everything Claude made, searchable in one place.")
                Promise(symbol: "internaldrive", title: "Tidy up",
                        detail: "See what Claude keeps on disk, and free what's safe to.")
            }
        }
    }
}

private struct Promise: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.Font.headline)
                Text(detail)
                    .font(Theme.Font.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(height: 104, alignment: .top)
        .groupSurface(cornerRadius: 18)
    }
}

private struct SetupPage: View {
    @Binding var keepAutomatically: Bool
    @Binding var showInMenuBar: Bool
    @Binding var openAtLogin: Bool

    var body: some View {
        VStack(spacing: Theme.Space.xxl) {
            PageHeading(title: "A few choices",
                        subtitle: "Each is set the way most people want it. You can change them later in Settings.")
            VStack(spacing: 0) {
                ExplainedToggle(title: "Keep conversations automatically",
                                detail: "Copies each Claude Code conversation as it changes, before Claude Code's cleanup deletes it.",
                                isOn: $keepAutomatically)
                    .padding(.vertical, 14)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ExplainedToggle(title: "Show in the menu bar",
                                detail: "Find any conversation from anywhere, without opening the window.",
                                isOn: $showInMenuBar)
                    .padding(.vertical, 14)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ExplainedToggle(title: "Open at login",
                                detail: "So conversations are kept even on days you don't open Better Claude.",
                                isOn: $openAtLogin)
                    .padding(.vertical, 14)
            }
            .padding(.horizontal, 20)
            .frame(width: 460)
            .groupSurface(cornerRadius: 18)
        }
    }
}

#if DEBUG
import CoworkKit
import SwiftUI

/// Every building block on one page, so each can be photographed in light and dark before a
/// screen uses it. Debug builds only: `BC_UI_ROUTE=gallery`.
struct GalleryView: View {
    @State private var on = true
    @State private var off = false
    @State private var segment = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Gallery").font(Theme.Font.display)
                Text("Every component the app is built from.")
                    .font(Theme.Font.body).foregroundStyle(.secondary)
                    .padding(.bottom, Theme.Space.xl)

                DetailSection(title: "Type") {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text("Display, 26 semibold").font(Theme.Font.display)
                        Text("Title, 20 semibold").font(Theme.Font.title)
                        Text("Section, 14 semibold").font(Theme.Font.section)
                        Text("Body, 13").font(Theme.Font.body)
                        Text("Callout, 12, secondary").font(Theme.Font.callout).foregroundStyle(.secondary)
                        Text("Caption, 11, secondary").font(Theme.Font.caption).foregroundStyle(.secondary)
                        Text("Reading, 14: Here's a plan that keeps each day to one neighbourhood.").font(Theme.Font.reading)
                        Text("pnpm test --filter webhooks").font(Theme.Font.code)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .groupSurface(cornerRadius: 6)
                    }
                }

                DetailSection(title: "Colour") {
                    HStack(spacing: Theme.Space.l) {
                        swatch("Accent", Theme.accent)
                        swatch("Fill", Theme.accentFill)
                        swatch("Bright", Theme.accentBright)
                        swatch("Attention", Theme.attention)
                        swatch("Failure", Theme.failure)
                        swatch("Group", Theme.groupFill)
                    }
                }

                DetailSection(title: "Buttons") {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        HStack(spacing: Theme.Space.s) {
                            Button("Continue in…") {}.buttonStyle(.borderedProminent)
                            Button("Show in Finder") {}.buttonStyle(.bordered)
                            Button("Not Now") {}.buttonStyle(.borderless)
                            Button("Disabled") {}.buttonStyle(.borderedProminent).disabled(true)
                            MoreMenu { Button("Export as Markdown…") {} }
                        }
                        HStack(spacing: Theme.Space.s) {
                            Button("Get Started") {}.prominentAction()
                            Button("Back") {}.quietAction()
                        }
                    }
                }

                DetailSection(title: "Controls") {
                    VStack(alignment: .leading, spacing: Theme.Space.l) {
                        ExplainedToggle(title: "Keep conversations automatically",
                                        detail: "A switch that's on, with one line of explanation.", isOn: $on)
                        ExplainedToggle(title: "When a model changes on its own",
                                        detail: "A switch that's off.", isOn: $off)
                        Picker("", selection: $segment) {
                            Text("Overview").tag(0)
                            Text("Conversations").tag(1)
                            Text("Files").tag(2)
                            Text("Memory").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        ProgressView(value: 0.62).frame(width: 240)
                    }
                }

                DetailSection(title: "Rows and state") {
                    VStack(spacing: 0) {
                        row("billing-service", detail: "Should the backoff cap at 10 minutes?") {
                            Text("Needs you").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.attention)
                        }
                        Divider().padding(.leading, 14)
                        row("journal-app", detail: "Migrate the date picker to the new API") {
                            Text("Working, 13 min").font(Theme.Font.callout).foregroundStyle(.secondary)
                        }
                        Divider().padding(.leading, 14)
                        row("Nightly dependency audit", detail: "Background job") {
                            Text("Failed").font(Theme.Font.callout.weight(.semibold)).foregroundStyle(Theme.failure)
                        }
                    }
                    .groupSurface()
                    FactRow(label: "Project", value: "billing-service")
                    FactRow(label: "Model", value: "Opus 5.5")
                }

                DetailSection(title: "Marks and icons") {
                    HStack(alignment: .bottom, spacing: Theme.Space.l) {
                        BMark(size: 64)
                        BMark(size: 32)
                        BMark(size: 16)
                        BMark(size: 16, tint: .primary)
                        GlyphTile(systemImage: "terminal.fill", size: 32)
                        KeyCaps(keys: ["⌥", "⌘", "Q"])
                    }
                }

                DetailSection(title: "Empty state") {
                    EmptyState(systemImage: "text.bubble", title: "Pick a conversation",
                               message: "Choose one on the left to read it here.")
                        .frame(height: 220)
                        .groupSurface()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color)
                .frame(width: 56, height: 40)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            Text(name).font(Theme.Font.caption).foregroundStyle(.secondary)
        }
    }

    private func row<Trailing: View>(_ title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.Font.bodyMedium)
                Text(detail).font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
#endif

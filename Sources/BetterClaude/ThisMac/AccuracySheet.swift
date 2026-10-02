import CoworkKit
import SwiftUI

/// Every count, checked against the disk: what each Claude lists, what was found but left out
/// and why, and anything that doesn't add up.
struct AccuracySheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var report: AccuracyCheck.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("How it's counted")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Theme.Surface.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Surface.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 3)
                    if let report {
                        content(report)
                    } else {
                        ProgressView().controlSize(.small).padding(.top, 24)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 12)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack {
                Spacer()
                Button("Check Again") { Task { await check() } }.buttonStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .frame(width: 560, height: 620)
        .background(Theme.Surface.window)
        .task { await check() }
    }

    private var subtitle: String {
        guard let report else { return "Checking every count against what's on this Mac…" }
        let total = report.total == 1 ? "One conversation is" : "\(report.total) conversations are"
        return report.issues.isEmpty
            ? "\(total) listed, and everything adds up."
            : "\(total) listed. Here's what was found, what was left out and why."
    }

    @ViewBuilder
    private func content(_ report: AccuracyCheck.Report) -> some View {
        SectionLabel(title: "Where they come from", top: 20)
        Card(inset: 14) {
            ForEach(report.sources.filter { $0.listed + $0.archived > 0 || !$0.leftOut.isEmpty }) { source in
                Row(title: source.name, detail: leftOut(source), detailLines: 3) {
                    EmptyView()
                } trailing: {
                    RowValue(text: listed(source))
                }
            }
        }
        if !report.issues.isEmpty {
            SectionLabel(title: "Worth knowing")
            Card(inset: 14) {
                ForEach(report.issues) { issue in
                    Row(title: "\(issue.title): \(issue.count)", detail: issue.detail, detailLines: 3) {
                        EmptyView()
                    } trailing: { EmptyView() }
                }
            }
        }
    }

    private func listed(_ source: AccuracyCheck.Source) -> String {
        var text = "\(source.listed) listed"
        if source.archived > 0 { text += ", \(source.archived) archived" }
        return text
    }

    private func leftOut(_ source: AccuracyCheck.Source) -> String {
        var lines: [String] = []
        if source.withoutMessages > 0 {
            lines.append(source.withoutMessages == 1 ? "1 is listed without its messages."
                         : "\(source.withoutMessages) are listed without their messages.")
        }
        lines.append(source.leftOut.isEmpty ? "Every conversation found is listed."
                     : "Not listed: " + source.leftOut.joined(separator: "; ") + ".")
        return lines.joined(separator: " ")
    }

    private func check() async {
        let snapshot = services.snapshot
        let index = services.index.index
        report = await Task.detached(priority: .userInitiated) {
            await AccuracyCheck.run(snapshot: snapshot, index: index)
        }.value
    }
}

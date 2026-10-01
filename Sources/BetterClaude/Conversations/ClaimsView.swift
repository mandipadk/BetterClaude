import CoworkKit
import SwiftUI

/// Under a conversation's header: what Claude and its sub-agents said they did, checked
/// against what the transcript shows they did.
struct ClaimsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversation: ConversationRef
    /// In the inspector: no disclosure, the detail straight away.
    var alwaysOpen = false
    @AppStorage("claimsOpen") private var open = false
    @State private var claims: [Claims.Claim] = []
    @State private var agents: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if !claims.isEmpty {
                if !alwaysOpen { Button {
                    withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { open.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                        Text(claims.count == 1 ? "1 claim checked" : "\(claims.count) claims checked").font(Theme.Font.headline)
                        Text(summary)
                            .font(Theme.Font.callout)
                            .foregroundStyle(doubtful.isEmpty ? .secondary : Theme.attention)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain) }

                // What didn't check out is always shown; the rest when opened.
                let shown = open || alwaysOpen ? claims : doubtful
                if !shown.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        ForEach(shown) { claim in row(claim) }
                    }
                    .padding(Theme.Space.m)
                    .background(Theme.subtleFill, in: .rect(cornerRadius: Theme.Radius.tile))
                }
            }
        }
        .task(id: "\(conversation.id)#\(services.index.generation)") {
            guard let index = services.index.index else { return }
            claims = (try? await Claims.check(conversationID: conversation.id, index: index)) ?? []
            let runs = (try? await Subagents.runs(conversationID: conversation.id, index: index)) ?? []
            agents = Dictionary(runs.map { ($0.agentID, $0.title) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private var doubtful: [Claims.Claim] {
        claims.filter { if case .contradicted = $0.verdict { return true }; return $0.verdict == .noEvidence }
    }

    private var summary: String {
        let contradicted = claims.filter { if case .contradicted = $0.verdict { return true }; return false }.count
        let unbacked = claims.filter { $0.verdict == .noEvidence }.count
        var parts: [String] = []
        if contradicted > 0 { parts.append("\(contradicted) contradicted by the transcript") }
        if unbacked > 0 { parts.append("\(unbacked) with nothing to back \(unbacked == 1 ? "it" : "them")") }
        return parts.isEmpty ? "Every one is backed by what was done." : parts.joined(separator: ", ") + "."
    }

    private func row(_ claim: Claims.Claim) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon(claim.verdict))
                .foregroundStyle(isBacked(claim.verdict) || claim.verdict == .unclear ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.attention))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("“\(claim.sentence)”").font(Theme.Font.callout).fixedSize(horizontal: false, vertical: true)
                Text("\(who(claim)): \(verdict(claim.verdict))")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isBacked(_ verdict: Claims.Claim.Verdict) -> Bool {
        if case .backed = verdict { return true }
        return false
    }

    private func icon(_ verdict: Claims.Claim.Verdict) -> String {
        switch verdict {
        case .backed: return "checkmark.circle"
        case .contradicted: return "xmark.octagon"
        case .noEvidence: return "questionmark.circle"
        case .unclear: return "circle.dashed"
        }
    }

    private func who(_ claim: Claims.Claim) -> String {
        guard let agent = claim.agentID else { return "Claude" }
        return "Sub-agent \(agents[agent].map { "“\($0)”" } ?? "")"
    }

    private func verdict(_ verdict: Claims.Claim.Verdict) -> String {
        switch verdict {
        case .backed(let evidence): return "backed, \(evidence)"
        case .contradicted(let evidence): return "contradicted, \(evidence)"
        case .noEvidence: return "nothing in the transcript does this"
        case .unclear: return "couldn't check, a script or command ran that might have"
        }
    }
}

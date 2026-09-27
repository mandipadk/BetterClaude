import CoworkKit
import SwiftUI

/// Everything Claude has made, gathered from every conversation.
struct LibraryPage: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let legacy = services.legacy
        LibraryView(summary: legacy.harvest,
                    isHarvesting: legacy.isHarvesting,
                    query: Binding(get: { legacy.libraryQuery }, set: { legacy.libraryQuery = $0 }),
                    kindFilter: Binding(get: { legacy.libraryKind }, set: { legacy.libraryKind = $0 }),
                    selected: Binding(get: { legacy.selectedArtifact }, set: { legacy.selectedArtifact = $0 }),
                    onHarvest: { Task { await legacy.runHarvest() } },
                    onReveal: { artifact in
                        if let url = artifact.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } else if let conversation = services.snapshot.conversations.first(where: {
                            $0.cliSessionId == artifact.conversationID
                                || $0.coworkSession?.sessionId == artifact.conversationID
                        }) {
                            services.show(conversation)
                        }
                    },
                    onCopy: { legacy.copyArtifact($0) })
            .task {
                if legacy.harvest == nil { await legacy.runHarvest() }
            }
    }
}

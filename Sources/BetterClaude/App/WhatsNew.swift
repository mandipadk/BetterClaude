import AppKit
import SwiftUI

/// What changed, shown once after an update. Written for people, per release, rather than
/// taken from commit messages.
enum ReleaseHighlights {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let byVersion: [String: [Item]] = [
        "0.31.0": [
            Item(symbol: "text.bubble", title: "The conversation first",
                 detail: "A conversation opens on its messages. Sub-agents setting off, the model changing, and coming back after the cache expired show as one line where they happened."),
            Item(symbol: "sidebar.right", title: "Details beside it",
                 detail: "⌥⌘I shows the conversation's facts, who was working when, what it cost, the files it changed and what didn't check out, in one panel beside the reader."),
            Item(symbol: "exclamationmark.bubble", title: "Claims, where they were made",
                 detail: "When Claude says it did something the transcript doesn't show, the line sits right under that reply."),
        ],
        "0.30.0": [
            Item(symbol: "house", title: "Home",
                 detail: "Where the app now opens: what needs you, what's running, your limits, where you left off, and what's worth a look, which fills only when something has been found."),
            Item(symbol: "sidebar.left", title: "Five places",
                 detail: "Home, Conversations, Projects, Usage and Library, then your installs, then This Mac for upkeep. ⌘1 to ⌘6 go to each, and everything else is a click inside, or ⌘K away."),
        ],
        "0.29.0": [
            Item(symbol: "command", title: "⌘K finds anything",
                 detail: "One field for every page, every action on the conversation you're reading, and every conversation by name. Words you'd use work too: “rewind” finds Show Changes. ⌘↩ asks your history instead."),
            Item(symbol: "chevron.left", title: "Back and forward",
                 detail: "⌘[ and ⌘] go back to where you were, with what you had selected, after opening a conversation from Projects, a notification or a link."),
            Item(symbol: "contextualmenu.and.cursorarrow", title: "Right-click anything",
                 detail: "Conversations, search results, projects, files, library items, running sessions and installs have context menus, with the same words as their ⋯ menus."),
        ],
        "0.28.0": [
            Item(symbol: "macwindow", title: "A new look",
                 detail: "Better Claude now uses macOS's own design: its toolbar, sidebar, buttons and switches are the system's, in a new accent, Lagoon. Status is said in words, never with tinted panels."),
            Item(symbol: "b.square", title: "A new icon",
                 detail: "A lowercase b whose bowl is a speech bubble, with a smaller one inside. Drawn for macOS's glass, in light, dark, clear and tinted."),
            Item(symbol: "checkmark.circle", title: "Small things, put right",
                 detail: "Kept shows when you last backed up. Model changes and background jobs have their own alert switches. Removing imported history and putting back a kept conversation ask first."),
        ],
        "0.27.0": [
            Item(symbol: "chart.bar.xaxis", title: "Who was working when",
                 detail: "A conversation's sub-agents open with a timeline: the conversation and each sub-agent as a lane, nested ones under their parent, so a run that fanned out finally makes sense."),
        ],
        "0.26.0": [
            Item(symbol: "moon.zzz", title: "Unattended",
                 detail: "Running shows background jobs and conversations that loop on their own: how each ended, what it came back with, and the ones that stopped without finishing. A job that finishes, fails or stalls sends a notification."),
        ],
        "0.25.0": [
            Item(symbol: "brain", title: "Memory Claude never sees",
                 detail: "The Memory page says when a MEMORY.md runs past the 200 lines Claude reads, when notes aren't linked from it so Claude can't find them, and when it links to notes that are gone. Link the missing ones in one step."),
        ],
        "0.24.1": [
            Item(symbol: "checkmark.seal", title: "Claims, checked, without the false alarms",
                 detail: "A claim is weighed against everything done before it, a script that might have done it counts as \u{201C}couldn't check\u{201D} rather than a miss, and Codex conversations aren't judged by Claude Code's tools."),
        ],
        "0.24.0": [
            Item(symbol: "checkmark.seal", title: "Claims, checked",
                 detail: "When Claude or a sub-agent says the tests pass, a file was updated, or work was committed, the conversation shows whether the transcript backs it up, and flags the ones it contradicts."),
        ],
        "0.23.0": [
            Item(symbol: "exclamationmark.bubble", title: "What compaction forgot",
                 detail: "Where Claude compacted a conversation, the reader lists what you'd told it before that its summary no longer mentions, like \u{201C}don't change the CSV date format\u{201D}, with one click to add them to the project's CLAUDE.md."),
        ],
        "0.22.0": [
            Item(symbol: "clock.badge.exclamationmark", title: "Coming back after a break",
                 detail: "Usage shows what re-reading conversations after the prompt cache expired cost this month, and where. The cost chart marks those replies."),
            Item(symbol: "bell.badge", title: "Before a waiting session's cache expires",
                 detail: "Two minutes before a big conversation's cache goes cold while it waits on you, a notification, so you can reply, compact or hand off first."),
        ],
        "0.21.0": [
            Item(symbol: "arrow.triangle.swap", title: "Model changes you didn't ask for",
                 detail: "A conversation says when its replies switched model and whether anyone asked, with /model or a fallback. Usage lists the ones nobody asked for, and a running session that switches on its own sends a notification."),
            Item(symbol: "person.2.wave.2", title: "Sub-agents on the wrong model",
                 detail: "A sub-agent asked to run on one model that ran on another is marked."),
        ],
        "0.20.0": [
            Item(symbol: "person.2.wave.2", title: "Sub-agents",
                 detail: "Every sub-agent a Claude Code conversation spawned, under its title: what it was asked, what it came back with, what it cost, and the ones it spawned in turn."),
            Item(symbol: "sum", title: "Every total counts them",
                 detail: "Sub-agents' replies were missing from Usage, costs, projects and your month. They're counted now; on busy Macs that's about a third of all replies. The index rebuilds once."),
        ],
        "0.19.1": [
            Item(symbol: "menubar.rectangle", title: "⌘Q keeps it in the menu bar",
                 detail: "With the menu bar icon on, ⌘Q closes the window and Better Claude stays in the menu bar, still keeping conversations and sending alerts. ⌥⌘Q, or Quit in the menu bar, quits completely."),
        ],
        "0.19.0": [
            Item(symbol: "film.stack", title: "Watch it change",
                 detail: "Watch It Change… in a conversation's ⋯ menu plays a file through the conversation step by step, from before it to now, each change beside what was asked for it."),
        ],
        "0.18.0": [
            Item(symbol: "laptopcomputer", title: "Another Mac's history",
                 detail: "File, Open Another Mac's Backup… opens a backup made on your other Mac. The conversations it kept join your timeline and search under that Mac's name, read-only."),
        ],
        "0.17.0": [
            Item(symbol: "square.stack.3d.up", title: "Shortcuts and Siri",
                 detail: "Search Claude History and Show Claude Limits are actions in Shortcuts, and work from Spotlight and Siri: “Search Better Claude history”, “Show my Better Claude limits”."),
        ],
        "0.16.0": [
            Item(symbol: "signpost.right.and.left", title: "Decisions",
                 detail: "A project's page lists what was settled in its conversations, from what you said and Claude's summaries, each linked to where. Claude's history tools can check them before deciding the same thing again."),
        ],
        "0.15.0": [
            Item(symbol: "text.badge.checkmark", title: "What you keep correcting",
                 detail: "A project's page shows things you've told Claude in more than one conversation, like which package manager to use, worded as lines for its CLAUDE.md. Edit them, add them, and undo it from History."),
            Item(symbol: "line.3.horizontal.decrease", title: "Only what you typed",
                 detail: "Task notifications, command echoes and Codex's session goals no longer count as prompts, so search, Ask, Replay and your month are about what you actually asked."),
        ],
        "0.14.0": [
            Item(symbol: "gauge.with.needle", title: "Context coach",
                 detail: "A heads-up when a running session has read 75% or 90% of its context window, while compacting or a handoff still saves the most. Clicking it opens the conversation."),
        ],
        "0.13.0": [
            Item(symbol: "safari", title: "Send a conversation as a page",
                 detail: "Export as Web Page… in a conversation's ⋯ menu saves it as one page that opens in any browser, with keys and tokens hidden and your home folder shortened to ~."),
        ],
        "0.12.0": [
            Item(symbol: "calendar", title: "Your month with Claude",
                 detail: "Every Claude on your Mac over a month on one card: days and hours you worked, models, tools, projects and what it all came to. Save it as an image from Usage."),
        ],
        "0.11.0": [
            Item(symbol: "key", title: "Secrets",
                 detail: "API keys and tokens that ended up in a conversation, with who put them there and where to rotate them. A key is never shown or kept whole."),
            Item(symbol: "eye.slash", title: "Keys stay out of sight",
                 detail: "Keys in your history are hidden from what Claude reads through its history tools, from Markdown exports, and from handoffs."),
        ],
        "0.10.0": [
            Item(symbol: "folder", title: "Projects",
                 detail: "Everything about a project in one place: its conversations from every Claude and account, pull requests, the files Claude changed, what it cost, when you worked on it, and its memory."),
        ],
        "0.9.0": [
            Item(symbol: "chart.xyaxis.line", title: "Cost and context",
                 detail: "Every Claude Code conversation shows how full its context was at each reply, where it compacted, and which replies cost the most."),
            Item(symbol: "bell.badge", title: "Before you hit a limit",
                 detail: "A notification when an account passes 80% or 95% of its five-hour or weekly limit, naming the account with the most room left. Turn it off on Usage."),
        ],
        "0.8.0": [
            Item(symbol: "clock.arrow.circlepath", title: "What a conversation changed",
                 detail: "Every file a conversation edited or created, compared with how it was before, from the conversation's ⋯ menu. Put any of them back in one step, and undo that from History."),
            Item(symbol: "doc.text.magnifyingglass", title: "More of your file history",
                 detail: "Claude Code names most files relative to where a session started. Better Claude now finds those versions too, so Files shows far more of them."),
            Item(symbol: "sparkle.magnifyingglass", title: "Claude sees what a session did",
                 detail: "Claude's history tools can list what an earlier conversation changed in your code."),
        ],
        "0.7.0": [
            Item(symbol: "clock.arrow.circlepath", title: "Every file version",
                 detail: "Newer Claude Code saves many file versions on their own rather than in its snapshots. Files now has them all; the index rebuilds once to find them."),
            Item(symbol: "arrow.triangle.pull", title: "Pull requests and forks",
                 detail: "A conversation shows the pull request it opened and the conversation it was forked from or continued in, and Claude's history tools know them too."),
            Item(symbol: "checkmark.shield", title: "Ready for Claude Code's next change",
                 detail: "Better Claude checks what every version of Claude Code and Codex writes, and says on Claude Code's page if a new one records something differently."),
        ],
        "0.6.0": [
            Item(symbol: "text.quote", title: "Prompts",
                 detail: "The prompts you type again and again, from Claude Code's own history, and any of them made into a skill in a click."),
            Item(symbol: "stethoscope", title: "What needs attention",
                 detail: "Each install says which MCP servers failed or need signing in and which hooks failed, and Claude Code's page offers rules for the commands it keeps asking about."),
            Item(symbol: "square.on.square", title: "Set up one Claude like another",
                 detail: "Copy an MCP server from one Claude to another from Compare, and undo it from History."),
            Item(symbol: "arrow.triangle.2.circlepath", title: "Replay",
                 detail: "Ask a newer model what a past conversation asked, with your own API key, and compare its answers with the ones you got. The cost is shown first."),
        ],
        "0.5.0": [
            Item(symbol: "doc.text", title: "Handoffs",
                 detail: "Turn a long conversation into a one-page brief, tightened on your Mac, and start a fresh Claude Code session with it."),
            Item(symbol: "globe", title: "Your claude.ai history",
                 detail: "Import the export claude.ai emails you, and those conversations join the timeline, search, Ask, and Claude's own history."),
            Item(symbol: "chevron.left.forwardslash.chevron.right", title: "Codex, too",
                 detail: "Codex sessions on this Mac appear beside everything else, read-only, so one search covers both."),
            Item(symbol: "lock.doc", title: "Encrypted backups",
                 detail: "Everything Better Claude keeps, in one password-protected file in iCloud Drive, ready to restore on another Mac."),
        ],
        "0.4.0": [
            Item(symbol: "gauge.with.dots.needle.50percent", title: "Usage",
                 detail: "Every account's five-hour and weekly limits in one place, when each resets, and where the week is heading at your current pace."),
            Item(symbol: "chart.bar.xaxis", title: "What used it",
                 detail: "The projects and conversations that used the most of this week, from the tokens every reply used."),
            Item(symbol: "arrow.right.circle", title: "Continue where there's room",
                 detail: "Continue in… shows how much of its limit each account has left, and lists the one with the most room first."),
            Item(symbol: "doc.text.magnifyingglass", title: "Files",
                 detail: "Every file Claude changed: the conversations that changed it, every version saved before each change, and the commit each likely became. Put any version back, and undo it."),
            Item(symbol: "rectangle.compress.vertical", title: "See what compaction kept",
                 detail: "The reader marks where Claude compacted a conversation, and shows the summary it kept of everything above."),
        ],
        "0.3.0": [
            Item(symbol: "text.magnifyingglass", title: "Search every message as you type",
                 detail: "Every conversation is indexed on your Mac, so search looks inside every message instantly, even ones Claude Code has since deleted."),
            Item(symbol: "waveform.path.ecg", title: "Running",
                 detail: "Every Claude Code session on the Mac, in any terminal or Claude's Code tab, and whether it's working, done, or waiting for you."),
            Item(symbol: "bell.badge", title: "Know when Claude needs you",
                 detail: "An alert the moment an agent asks for a permission or an answer, and when a long turn finishes. Click it to jump to the right app."),
            Item(symbol: "books.vertical", title: "Claude can search your history",
                 detail: "Switch it on for any Claude, and it can look up and quote your past conversations when you mention earlier work. Each account sees only its own unless you say otherwise."),
            Item(symbol: "sparkle.magnifyingglass", title: "Ask",
                 detail: "Ask a question about your past work and get an answer with its sources, from the model built into macOS."),
            Item(symbol: "magnifyingglass", title: "Conversations in Spotlight",
                 detail: "Find any conversation by title or by what you first asked, from Spotlight, and open it here."),
        ],
        "0.2.0": [
            Item(symbol: "rectangle.stack", title: "Every Claude, in one window",
                 detail: "Conversations from Claude, its Parallex copies, Claude Code and the Code tab, in one timeline with a reader beside it."),
            Item(symbol: "arrow.right.circle", title: "Continue anywhere, and undo it",
                 detail: "Carry a conversation to another Claude or into Claude Code, fork one from any message, and take either back from History."),
            Item(symbol: "archivebox", title: "Kept",
                 detail: "Claude Code deletes conversations after 30 days. Better Claude now keeps a copy first."),
            Item(symbol: "internaldrive", title: "Storage and Memory",
                 detail: "See what Claude keeps on disk and free what's safe to, and read what it remembers about every project."),
        ],
    ]

    /// A fix release shows its release's highlights: 0.7.1 shows 0.7.0's.
    static func items(for version: String) -> [Item]? { byVersion[version] ?? byVersion[series(of: version) + ".0"] }

    /// "0.7" for "0.7.1".
    static func series(of version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }
}

struct WhatsNewSheet: View {
    let version: String
    let onClose: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.l) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text("What's new in Better Claude").font(Theme.Font.display)
                Text("Version \(version)").font(Theme.Font.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(Array((ReleaseHighlights.items(for: version) ?? []).enumerated()), id: \.element.id) { index, item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(Theme.Font.headline)
                            Text(item.detail)
                                .font(Theme.Font.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .opacity(shown || reduceMotion ? 1 : 0)
                    .offset(y: shown || reduceMotion ? 0 : 8)
                    .animation(Theme.Motion.smooth.delay(0.12 + 0.06 * Double(index)), value: shown)
                }
            }
            .frame(width: 400)
            Spacer(minLength: 0)
            Button("Continue", action: onClose)
                .prominentAction()
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 500, height: 560)
        .onAppear { shown = true }
    }
}

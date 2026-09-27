import Foundation

/// The invented conversations a sample Mac holds. Everything here is fiction: no real person,
/// address, or conversation.
enum Script {

    struct Tool {
        let name: String
        let input: [String: String]
        let result: String
    }

    struct Turn {
        let user: String
        let assistant: String
        var tools: [Tool] = []
    }

    struct Conversation {
        let title: String
        let model: String
        /// Seconds before "now" the conversation started.
        let age: TimeInterval
        var project: String? = nil
        var branch: String? = nil
        var starred = false
        var transcriptGone = false
        var outputs: [(String, String)] = []
        let turns: [Turn]

        var id: String { Transcriber.uuid(seed: "session:" + title, index: 0) }
        var cliId: String { Transcriber.uuid(seed: "cli:" + title, index: 0) }
        var processName: String {
            let words = ["brave", "quiet", "amber", "swift", "lucid", "gentle", "bold", "calm"]
            let animals = ["otter", "heron", "lynx", "finch", "orca", "badger", "wren", "ibex"]
            let hash = title.utf8.reduce(7) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
            return "\(words[hash % words.count])-\(animals[(hash / 8) % animals.count])"
        }
    }

    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    static let projects = ["Code/journal-app", "Code/billing-service", "Code/northwind-web",
                           "Documents/thesis", deletedProject]
    static let deletedProject = "Code/old-prototype"

    // MARK: Claude (personal)

    static let personalCowork: [Conversation] = [
        Conversation(
            title: "Plan a three-day trip to Lisbon", model: "claude-opus-5-5", age: 2 * hour,
            outputs: [("lisbon-itinerary.md", "# Lisbon in three days\n\n## Day 1: Alfama\n- Castelo de São Jorge at opening\n- Lunch at a tasca near Largo do Chafariz\n")],
            turns: [
                Turn(user: "I have three days in Lisbon in October. I like walking, food markets and views. Can you plan it?",
                     assistant: """
                     Here's a plan that keeps each day to one neighbourhood, so you walk more and ride less.

                     ## Day 1: Alfama and the castle
                     - **Morning:** Castelo de São Jorge right at opening, before the tour groups.
                     - **Lunch:** a small tasca near Largo do Chafariz de Dentro.
                     - **Evening:** sunset at Miradouro da Senhora do Monte.

                     ## Day 2: Baixa, Chiado and the river
                     - Time Out Market for lunch, but go at 11:30.
                     - Walk the riverfront to Cais do Sodré.

                     ## Day 3: Belém
                     - Pastéis de Belém early, then the Jerónimos Monastery.

                     I saved the full itinerary with opening hours as **lisbon-itinerary.md**.
                     """),
                Turn(user: "Can you swap day 3 for something less touristy?",
                     assistant: "Sure. Try **LX Factory** in the morning, then the **Gulbenkian** gardens and museum in the afternoon. Both are quieter, and the Gulbenkian café is excellent."),
            ]),
        Conversation(
            title: "Rewrite the landing page hero", model: "claude-opus-5-5", age: 1 * day + 3 * hour,
            turns: [
                Turn(user: "My studio's landing page says \"We craft digital experiences.\" It's bland. Give me options.",
                     assistant: """
                     Three directions, from calm to bold:

                     1. **Clear:** "Websites and apps for small teams who care how things feel."
                     2. **Specific:** "We design and build products people open twice a day."
                     3. **Bold:** "Software with manners."

                     I'd lead with the second. It says what you make and why it matters, in eleven words.
                     """),
            ]),
        Conversation(
            title: "Compare three standing desks", model: "claude-sonnet-5", age: 3 * day,
            turns: [
                Turn(user: "Compare the Fully Jarvis, Uplift V2 and IKEA Trotten for a small apartment.",
                     assistant: """
                     | Desk | Motor | Height range | Footprint |
                     |---|---|---|---|
                     | Jarvis | Dual | 60–125 cm | Medium |
                     | Uplift V2 | Dual | 64–130 cm | Medium |
                     | Trotten | Crank | 72–122 cm | Small |

                     For a small apartment, the **Trotten** wins on footprint and price. If you'll switch heights several times a day, the crank gets old fast, and the **Uplift** is the better buy.
                     """),
            ]),
        Conversation(
            title: "Draft a note to the landlord about the heater", model: "claude-sonnet-5", age: 6 * day,
            turns: [
                Turn(user: "The heater has been broken for a week. Help me write a polite but firm note.",
                     assistant: "Here's a draft:\n\n> Hi Dana, the heater in unit 4B stopped working on Monday the 14th. With nights dropping below 5°C, could someone look at it this week? I'm home after 5 pm any weekday. Thanks, Alex"),
            ]),
        Conversation(
            title: "Summarize the sleep study", model: "claude-opus-5-5", age: 12 * day,
            turns: [
                Turn(user: "Summarize this sleep study in five bullet points for a non-scientist.",
                     assistant: "- People who kept a fixed wake time slept better within two weeks.\n- Screens mattered less than bedtime consistency.\n- A 20-minute afternoon nap didn't hurt night sleep.\n- Caffeine after 2 pm cut deep sleep by about 15%.\n- The effects were strongest in people over 40."),
            ]),
        Conversation(
            title: "Weekly meal plan with a grocery list", model: "claude-sonnet-5", age: 20 * day,
            turns: [
                Turn(user: "Vegetarian meal plan for two, weeknights only, under 30 minutes each.",
                     assistant: "**Monday:** chickpea curry with rice\n**Tuesday:** halloumi and roast vegetable wraps\n**Wednesday:** miso noodle soup\n**Thursday:** black bean tacos\n**Friday:** mushroom risotto\n\nThe grocery list is grouped by aisle below."),
            ]),
        Conversation(
            title: "Explain compound interest with an example", model: "claude-sonnet-5", age: 40 * day,
            turns: [
                Turn(user: "Explain compound interest like I'm starting my first job.",
                     assistant: "Put away 200 a month at 6% a year. After 10 years you've saved 24,000, but you'd have about **32,800**. The extra 8,800 is interest earning interest on itself. Start five years later and you'd need to save roughly 330 a month to catch up."),
            ]),
        Conversation(
            title: "Birthday toast for Sam", model: "claude-opus-5-5", age: 70 * day,
            turns: [
                Turn(user: "Short, warm birthday toast for my friend Sam who just ran her first marathon.",
                     assistant: "To Sam, who taught all of us that 42 kilometres is just one kilometre, forty-two times. Happy birthday. May this year be all downhill, in the good way."),
            ]),
    ]

    static let personalCodeTab: [Conversation] = [
        Conversation(
            title: "Add dark mode to the settings screen", model: "claude-opus-5-5", age: 1 * day + 7 * hour,
            project: "Code/journal-app", branch: "dark-mode", starred: true,
            turns: [
                Turn(user: "Add a dark mode toggle to SettingsView and persist it.",
                     assistant: "Done. The toggle writes to `@AppStorage(\"appearance\")`, and the root view applies it with `.preferredColorScheme`.\n\n```swift\n@AppStorage(\"appearance\") private var appearance = Appearance.system\n\nvar body: some Scene {\n    WindowGroup { RootView().preferredColorScheme(appearance.colorScheme) }\n}\n```",
                     tools: [Tool(name: "Read", input: ["file_path": "Sources/Settings/SettingsView.swift"], result: "struct SettingsView: View { … }"),
                             Tool(name: "Edit", input: ["file_path": "Sources/Settings/SettingsView.swift"], result: "Applied 1 edit.")]),
            ]),
        Conversation(
            title: "Fix the flaky upload test", model: "claude-sonnet-5", age: 5 * day,
            project: "Code/journal-app", branch: "fix-upload-test", transcriptGone: true,
            turns: [Turn(user: "UploadTests fails one run in ten. Find out why.",
                         assistant: "It races the mock server's startup. Awaiting `server.ready` before the first request fixes it.")]),
    ]

    // MARK: Claude Work (a Parallex copy)

    static let workCowork: [Conversation] = [
        Conversation(
            title: "Q4 hiring plan for the platform team", model: "claude-opus-5-5", age: 5 * hour,
            turns: [
                Turn(user: "We can open four roles in Q4. Help me sequence them for the platform team.",
                     assistant: "Hire in this order:\n\n1. **Staff engineer, reliability.** Everything else depends on the on-call load dropping.\n2. **Senior backend engineer** for the billing migration.\n3. **Engineering manager** once the team passes eight people.\n4. **Developer experience engineer** in December, when onboarding volume peaks."),
            ]),
        Conversation(
            title: "Customer interview synthesis: onboarding", model: "claude-opus-5-5", age: 2 * day + 2 * hour,
            turns: [
                Turn(user: "Here are notes from nine onboarding interviews. What are the themes?",
                     assistant: "Three themes came up in at least six of nine interviews:\n\n- **The import step is where people give up.** Seven people mentioned it unprompted.\n- **Teams want a sandbox** before inviting colleagues.\n- **Pricing felt hidden** until the second week."),
            ]),
        Conversation(
            title: "Incident write-up for the Tuesday outage", model: "claude-opus-5-5", age: 4 * day,
            outputs: [("incident-2026-09-22.md", "# Incident: API latency, Tuesday\n\n**Impact:** 38 minutes of elevated latency for EU customers.\n")],
            turns: [
                Turn(user: "Draft a blameless incident write-up from this timeline.",
                     assistant: "I drafted it as **incident-2026-09-22.md**. The summary: a connection-pool limit set for the old database was carried over during the migration, and EU traffic hit it first. Three follow-ups are listed at the end."),
            ]),
        Conversation(
            title: "Board update, October draft", model: "claude-opus-5-5", age: 9 * day,
            turns: [Turn(user: "Turn these bullet points into a one-page board update.",
                         assistant: "Here's a one-page draft, leading with revenue and the two decisions we need from the board.")]),
        Conversation(
            title: "Pricing page copy review", model: "claude-sonnet-5", age: 25 * day,
            turns: [Turn(user: "Review our pricing page copy for clarity.",
                         assistant: "The tiers are clear. The word \"seats\" appears before it's explained, and the annual discount only shows on hover. Move both up.")]),
    ]

    // MARK: Claude Code

    static let claudeCode: [Conversation] = [
        Conversation(
            title: "Retry failed webhook deliveries with backoff", model: "claude-opus-5-5", age: 3 * hour,
            project: "Code/billing-service",
            turns: [
                Turn(user: "Webhook deliveries that fail are dropped. Add retries with exponential backoff.",
                     assistant: """
                     Failed deliveries now retry up to five times, with jittered exponential backoff.

                     ```ts
                     export function nextDelay(attempt: number): number {
                       const base = 2 ** attempt * 1_000
                       return base / 2 + Math.random() * (base / 2)
                     }
                     ```

                     After the fifth failure the delivery moves to the dead-letter queue and shows up on the dashboard. Tests cover the delay curve and the hand-off.
                     """,
                     tools: [Tool(name: "Read", input: ["file_path": "src/webhooks/deliver.ts"], result: "export async function deliver(event) { … }"),
                             Tool(name: "Edit", input: ["file_path": "src/webhooks/deliver.ts"], result: "Applied 2 edits."),
                             Tool(name: "Bash", input: ["command": "npm test -- webhooks"], result: "12 passed")]),
                Turn(user: "Can we cap the total wait at ten minutes?",
                     assistant: "Yes. `nextDelay` now clamps to whatever remains of a ten-minute budget, so a delivery never waits longer than that in total."),
            ]),
        Conversation(
            title: "Migrate the date picker to the new API", model: "claude-sonnet-5", age: 2 * day + 5 * hour,
            project: "Code/journal-app",
            turns: [Turn(user: "Move EntryEditor off the deprecated DatePicker initializer.",
                         assistant: "Done in three files. The new initializer takes a `ClosedRange<Date>`, so entries can no longer be dated in the future.",
                         tools: [Tool(name: "Grep", input: ["pattern": "DatePicker("], result: "3 matches")])]),
        Conversation(
            title: "Why is the checkout page slow?", model: "claude-opus-5-5", age: 8 * day,
            project: "Code/northwind-web",
            turns: [Turn(user: "Checkout takes four seconds to become interactive. Why?",
                         assistant: "Two things: the address autocomplete library is 310 KB and loads eagerly, and the tax estimate blocks rendering. Lazy-loading the first and streaming the second brings it to about 1.2 seconds.")]),
        Conversation(
            title: "Add a health check endpoint", model: "claude-sonnet-5", age: 16 * day,
            project: "Code/billing-service",
            turns: [Turn(user: "Add /healthz that checks the database and the queue.",
                         assistant: "Added `/healthz`. It returns 200 with each dependency's latency, or 503 naming the one that failed.")]),
        Conversation(
            title: "Tidy up the thesis bibliography", model: "claude-sonnet-5", age: 27 * day,
            project: "Documents/thesis",
            turns: [Turn(user: "My BibTeX file has duplicates and inconsistent capitalization. Clean it up.",
                         assistant: "Merged 14 duplicates and protected proper nouns in titles with braces. Two entries were missing a year; I flagged them with a comment instead of guessing.")]),
    ]

    /// Deleted by Claude Code's cleanup; only Better Claude's copy remains.
    static let alreadyDeleted = Conversation(
        title: "Draft the conference talk abstract", model: "claude-opus-5-5", age: 44 * day,
        project: "Documents/thesis",
        turns: [
            Turn(user: "Turn my thesis summary into a 200-word abstract for the systems conference.",
                 assistant: "Here's a draft that leads with the result:\n\n> We show that a scheduler aware of cache topology cuts tail latency by 38% on commodity hardware, without changing application code…"),
        ])

    // MARK: Memory and skills

    static let memory: [(String, [(String, String)])] = [
        ("Code/billing-service", [
            ("MEMORY.md", "- [Retry policy](retry-policy.md) — five attempts, ten-minute cap\n"),
            ("retry-policy.md", "---\nname: retry-policy\ndescription: How webhook retries work\n---\n\nFive attempts with jittered backoff, capped at ten minutes in total.\n"),
        ]),
        ("Code/journal-app", [
            ("MEMORY.md", "- Uses SwiftData; never add Core Data.\n- Screenshots go in docs/shots.\n"),
        ]),
        (deletedProject, [
            ("MEMORY.md", "- Prototype for the reading tracker. Superseded by journal-app.\n"),
        ]),
    ]

    static let skills: [(String, String)] = [
        ("release-notes", "Write release notes for people, from a list of merged changes"),
        ("screenshot-review", "Review app screenshots against the design checklist"),
        ("weekly-review", "Summarize the week's commits, issues and decisions"),
    ]
}

# Better Claude

Move Claude Desktop **Cowork conversations** between Claude installs, and into **Claude Code** — with the chat intact.

macOS app plus a command line tool sharing one engine.

---

## Why this exists

If you run more than one Claude Desktop install — a personal one, a work one, a second
account — a conversation started in one is stranded there. There is no export, no import,
no way to pick up a thread in Claude Code where you left it in Cowork.

The conversations are on your disk in a readable format. This tool moves them.

## What it does

**Move a conversation.**

| From | To | Status |
|---|---|---|
| Cowork session | another Claude Desktop install | works |
| Cowork session | a Claude Code project | works |
| Claude Code session | a Cowork install | works |

Every transfer carries the full conversation: user turns, assistant turns, tool calls, and
inline images and documents byte-for-byte. Attachments and generated files are opt-in.

**Find a conversation.** Filtering the selected account is instant. "Search every
conversation" reads every transcript on the machine once — across every install and every
Claude Code project — and ranks whole conversations, with the matching passages underneath
as evidence. ⌘F focuses the field.

**Read a conversation.** Open any conversation in the app without launching Claude, with
inline Markdown, code blocks, and its own search. ⌘O.

**Take a conversation with you.** Export to Markdown — speakers, timestamps, and prose,
with the tool plumbing left behind.

## What it deliberately does not carry

Credentials are never exported, in any mode — not OAuth tokens, not the audit-log signing
key, not connector authentication caches. Neither are audit logs, shell snapshots, or debug
logs.

Two further categories are dropped regardless of settings:

- **Permission grants.** A session that was allowed to bypass permission checks, granted
  computer-use access to specific apps, or allowed unrestricted network egress does not
  hand those privileges to the destination. You would not have created a session with those
  settings there; an import should not create one either.
- **Host activity traces.** Detected-file paths, per-session approved URLs, and recorded
  answers to in-chat questions disclose things — directory names alone can reveal a lot —
  and none of it is needed to replay a conversation.

Before a bundle is written, the **assembled** bundle is scanned for credential-shaped
content. A hit blocks the export. The scan reports the file and the rule that matched and
never the matched value, because a report containing the secret is a second copy of it.

## Install

Requires macOS 14+ and Xcode's Swift toolchain.

```bash
git clone <this repo> && cd better-claude
./Scripts/make-app.sh
open dist/BetterClaude.app
```

Optional command line tool:

```bash
ln -sf "$PWD/dist/BetterClaude.app/Contents/MacOS/cowork" ~/.local/bin/cowork
```

There is nothing to allow in System Settings. The app is not sandboxed — a sandboxed app
cannot read another app's data directory without you picking it in an open panel every
time — but the directories it reads are not in a privacy-protected category, so no
permission prompt appears and Full Disk Access is not required. It is not on the Mac App
Store and cannot be: writing into another app's data directory is not permitted there.

## Using it

Pick a source on the left, select conversations, press **Transfer…**. You get a plan
first — every check, every path that will be created — and nothing is written until you
confirm.

From the command line:

```bash
cowork stores                                   # what is installed, and which accounts
cowork list --store Claude                      # conversations in an install
cowork list --code                              # conversations in Claude Code

cowork export <sessionId> --out chat.coworkbundle
cowork inspect chat.coworkbundle                # manifest + scan report, no extraction

cowork import chat.coworkbundle --to code:/path/to/project --dry-run
cowork import chat.coworkbundle --to cowork:Claude-Work

cowork receipts                                 # every import this tool made
cowork undo <receiptId>                         # roll one back
```

After importing into Claude Code, run `claude --resume` from that project directory. The
first run there shows a one-time trust prompt.

## Safety model

**Imports create; they never overwrite.** Every import writes a receipt listing exactly
what it created, and `cowork undo` removes precisely that — refusing to delete anything
you have edited since.

**It will not write to a running Claude.** A running install holds sessions in memory and
can overwrite an imported one from its own stale copy. Quitting the destination app first
is enforced, not suggested.

Detecting *which* install is running is subtler than it looks: every variant runs the same
binary under the same bundle identifier, so the running app's identity comes from its
process arguments rather than its bundle. Checking the bundle identifier gives the wrong
answer on a machine with more than one install.

**Workspace first, metadata last.** Claude Desktop reaps workspace directories that no
session file claims, so ordering the writes the other way round is the one sequence that
can lose data.

## Limitations

- **macOS only.** The layout and the process inspection are both platform-specific.
- **The on-disk format is undocumented.** It was derived by reading real sessions, and it
  demonstrably changes over time — fields have been added and retired across releases.
  A future update can change it again. Session data is therefore never modelled with
  fixed structs: unknown fields are preserved untouched rather than dropped.
- **Verified against one machine's data.** The path encoder is checked against every
  project directory present there, and transfers are verified by comparing per-message
  checksums, but this has not been tested across many accounts or versions.
- **A destination install must have been signed into once** before it can receive a
  session. Claude Desktop only ever reads the account it is signed into, so a session filed
  under any other account is invisible rather than broken.
- **Model availability is not checked.** A conversation that used a model the destination
  does not offer will import, and the destination picks a model when you continue it.

## Layout

```
Sources/CoworkKit/     the engine — discovery, transcripts, path encoding, bundles,
                       transfer, search index, Markdown export
Sources/cowork/        command line front end
Sources/BetterClaude/  SwiftUI app
Scripts/make-app.sh    assembles and ad-hoc signs the .app
```

The app and the CLI share the engine completely. Any check added to one applies to both.

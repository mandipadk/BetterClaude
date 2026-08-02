# Better Claude

Your Claude conversations are already on your disk. Better Claude is a macOS app that lets
you **move them between installs, fork them, audit what every install is configured with,
and find everything Claude ever made for you.**

A macOS app plus a command line tool sharing one engine. Nothing leaves the machine.

---

## Why this exists

If you run more than one Claude Desktop install — a personal one, a work one, a second
account — a conversation started in one is stranded there. There is no export, no import,
no way to pick up a thread in Claude Code where you left it in Cowork. Meanwhile the
skills, MCP servers and hooks each install is running are invisible to each other, and the
files Claude wrote for you three weeks ago are somewhere in a session directory you will
never find again.

All of it is on your disk in a readable format. This tool operates on it.

## The four things it does

### 1. Transfer a conversation, with the chat intact

| From | To | Status |
|---|---|---|
| Cowork session | another Claude Desktop install | works |
| Cowork session | a Claude Code project | works |
| Claude Code session | a Cowork install | works |

Every transfer carries the full conversation: user turns, assistant turns, tool calls, and
inline images and documents byte-for-byte. Attachments and generated files are opt-in.

Verified by comparing per-message SHA-256 fingerprints: every message and every inline
image or document is byte-identical in all three directions.

### 2. Control what every install is running

Inventories every skill, MCP server, subagent, slash command, hook and memory file across
every install on the machine, then diffs two of them so you can see what one has that the
other does not. It is read-only — it reports, it changes nothing.

On the development machine: 215 configuration items across 16 scopes — one global Claude
Code config, ten projects, and five Desktop installs.

### 3. Keep a library of everything Claude produced

Every code block, generated file and upload, deduplicated by content hash, each carrying
provenance back to the conversation it came from. The script you half-remember from three
weeks ago becomes findable.

On the development machine: 699 artifacts, 178.9 MB, across 102 conversations, with 90
duplicates collapsed — in about a second.

### 4. Branch a conversation at any message

Choose a message and fork the conversation there into a new one. The original is left as it
was. Neither Claude app can do this. The fork follows the `parentUuid` chain rather than
line order, so its ancestry is intact rather than merely plausible.

## And the smaller things

**Find a conversation.** Filtering the selected account is instant. "Search every
conversation" reads every transcript on the machine once — across every install and every
Claude Code project — and ranks whole conversations, with the matching passages underneath
as evidence. ⌘F focuses the field.

**Read a conversation.** Open any conversation in the app without launching Claude, with
inline Markdown, code blocks, and its own search. ⌘O.

**Take a conversation with you.** Export to Markdown — speakers, timestamps, and prose,
with the tool plumbing left behind.

## Works best with Parallex

[**Parallex**](https://github.com/mandipadk/parallex) runs multiple fully isolated
instances of any macOS app — each with its own Dock icon, its own data, and its own
settings.

The pairing is not a cross-promotion, it is causal. Parallex is what creates several
isolated Claude installs in the first place: a personal one, a work one, a second account,
each genuinely separate on disk. Better Claude is what moves work between them. One makes
the installs; the other makes them a single workspace. Neither needs the other, and each is
more useful with it.

A site and packaged releases for Parallex are coming.

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

## Projects and folders

A conversation is attached to folders two ways, and both are handled.

`userSelectedFolders` lists folders attached to that one conversation. A **Project** — a
*space* on disk — owns a folder list shared by every conversation in it, and a session points
at one by `spaceId`.

Spaces are defined per organisation, so a `spaceId` means nothing in another install. Moving a
conversation used to carry the id but not the project, leaving it pointing at nothing; Claude
Desktop then reports the project folder as no longer connected.

A transfer between your own installs now carries the project itself. At the destination it
resolves in that order: the same project is reused if it is already there; a project with the
same name and folders is matched and the conversation is pointed at it, rather than creating a
second project with an identical name; otherwise the project is created, recorded in the
receipt, and removed again by `cowork undo` — unless you have renamed it since, in which case
undo leaves it alone.

Because folders are absolute paths on one machine, this only applies to the **same-user**
profile. Under *another account* or *share*, the project and the folder list do not travel and
the `spaceId` is cleared rather than left dangling. `userApprovedFileAccessPaths` is always
cleared in every mode: it is a permission grant, not a preference, and re-granting it silently
at the destination would hand over access that was never approved there.

A project also owns a memory directory — what it has learned across every conversation in it.
That travels too, but only into a project this import *creates*. A project that already exists
at the destination has its own memory, written by conversations that live there, and copying
over it would destroy work the transfer has no claim on.

The plan says which projects will be created before anything is written, and names any project
folder that no longer exists on this Mac.

## Install

Requires macOS 14 or later. Download the latest `.dmg` from
[Releases](https://github.com/mandipadk/BetterClaude/releases/latest) and drag the app to
Applications.

The build is ad-hoc signed and **not notarised**, so a browser download arrives
quarantined and Gatekeeper blocks the first launch. Right-click the app and choose
**Open**, then confirm — once per installed version. See [Updates](#updates) for what that
means for the update checksum.

### Building from source

Needs Xcode's Swift toolchain in addition to macOS 14.

```bash
git clone https://github.com/mandipadk/BetterClaude.git && cd BetterClaude
./Scripts/make-app.sh
open dist/BetterClaude.app
```

A locally built bundle never acquires the quarantine attribute, so it launches with no
Gatekeeper prompt at all.

Optional command line tool:

```bash
ln -sf "$PWD/dist/BetterClaude.app/Contents/MacOS/cowork" ~/.local/bin/cowork
```

There is nothing to allow in System Settings. The app is not sandboxed — a sandboxed app
cannot read another app's data directory without you picking it in an open panel every
time — but the directories it reads are not in a privacy-protected category, so no
permission prompt appears and Full Disk Access is not required. It is not on the Mac App
Store and cannot be: writing into another app's data directory is not permitted there.

### Updates

**Better Claude → Check for Updates…** compares against a published release, downloads it,
and swaps the bundle in place.

The download is fetched over HTTPS and its SHA-256 is checked against the value published
with the release before anything is unpacked. That catches a corrupted or altered file in
transit. It does **not** defend against a compromised release account: the archive and its
checksum are published by the same account, so whoever can publish one can publish the
other. Real protection needs a signature verified against a key compiled into the app
(Sparkle's EdDSA scheme) or a Developer ID identity plus notarisation. This app is ad-hoc
signed and has neither, so the app states the limit before every install rather than
hiding it behind a progress bar.

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

cowork library                                  # every artifact Claude ever produced
cowork library --kind code --limit 50           # narrowed to one kind

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
                       transfer, branching, config inventory, artifact harvest,
                       search index, Markdown export, updates
Sources/cowork/        command line front end
Sources/BetterClaude/  SwiftUI app
Scripts/make-app.sh    assembles and ad-hoc signs the .app, generating the icon
Scripts/make-icon.swift  draws the app icon at every size from one geometry
site/                  the public website (static, no scripts, no third-party assets)
```

The app and the CLI share the engine completely. Any check added to one applies to both.

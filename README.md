# Better Claude

Your Claude conversations are already on your disk. Better Claude is a macOS app that puts
**every Claude on your Mac in one place** — Claude, its copies, Claude Science and Claude
Code — so you can read any conversation, continue it somewhere else, keep it before Claude
Code deletes it, and see what each install is set up with and how much space it takes.

A macOS app plus a command line tool sharing one engine. Nothing leaves the machine.

---

## Why this exists

If you run more than one Claude Desktop install — a personal one, a work one, a second
account — a conversation started in one is stranded there. There is no export, no import,
no way to pick up a thread in Claude Code where you left it in Cowork. Meanwhile the
skills, MCP servers and hooks each install is running are invisible to each other, and the
files Claude wrote for you three weeks ago are somewhere in a session directory you will
never find again — if Claude Code hasn't already deleted the conversation, which it does 30
days after you last used it.

All of it is on your disk in a readable format. This tool operates on it.

## What it does

### Every conversation, in one timeline

Conversations from every install appear together, newest first: Cowork sessions from
Claude and any copy of it (including copies made by [Parallex](https://github.com/mandipadk/parallex)),
Claude Code sessions, and the Desktop app's Code tab. Filter by install or project, or
search inside every message as you type: every conversation is read once into a SQLite
full-text index in `~/Library/Application Support/BetterClaude/Index`, then only what Claude
appends, and the index keeps conversations Claude Code has since deleted. Read any conversation without opening
Claude — Markdown, code, tables and tool use included — and it updates live while Claude
writes to it. A menu bar panel finds any conversation from anywhere.

### Claude remembers your past work

Better Claude ships an MCP server, `bc-recall`, inside the app. Switch it on from an
install's page and that Claude gets four read-only tools: `search_history`,
`read_conversation`, `recent_work` and `file_history`. It can then find and quote what was
decided in an earlier conversation, pick up where you left off, or tell which conversation
changed a file — across Claude Desktop, Cowork, Claude Code and the Code tab.

Each Claude reads only its own account's history. Letting one account's Claude read another
account's is a door you open in Better Claude, one direction at a time. Claude Code is
changed through `claude mcp`; a Desktop install gets one entry in its
`claude_desktop_config.json`, which is backed up first. Turning the switch off takes it out.

### Running, and knowing when Claude needs you

Every running Claude Code session, in any terminal or a Desktop app's Code tab, read from
the status file Claude Code keeps for each one: working, done, or waiting on a permission or
an answer. A notification arrives the moment one needs you, or a long turn finishes, and
clicking it brings the right app forward. An optional switch adds three hooks to Claude
Code's settings so notifications can say what Claude asked; switching it off removes
exactly those hooks.

### Usage

Every account's five-hour and weekly limits, as Claude itself last reported them: Claude
Code's cached limits and the usage history each Desktop install keeps, merged per account.
When Claude hasn't said when the week resets, it's worked out from the history and marked
as an estimate. A forecast carries the week's pace to the reset, and what used it is shown
by project and conversation, from the tokens every reply used weighed at list prices.
**Continue in…** shows how much room each destination account has left.

### Files

Every file Claude wrote or edited: the conversations that read or changed it, every version
Claude Code saved before a change with a diff against the file now, and its commits with
the conversation each most likely came from. Any version can be put back and the restore
undone from History. Saved versions and plans are kept before Claude Code's cleanup deletes
them. The reader also marks where Claude compacted a conversation and shows what it kept.

### Ask

A question about your past work, answered by the model built into macOS from passages the
index finds, with the conversations it cites listed below. Needs macOS 26 or later with
Apple Intelligence; nothing is sent anywhere.

### Continue anywhere, and undo it

**Continue in…** carries a conversation to another install or into a Claude Code project,
with the chat intact: user turns, assistant turns, tool calls, and inline images and
documents byte for byte. You see where it's going and what will happen before anything is
written, and afterwards you can open it there directly — or resume it in Terminal.

**Fork from here** starts a new Claude Code conversation from any message; the original is
not changed, and a fork of a Code tab session is listed in that app's Code tab. Every copy and fork is listed in **History** with **Undo**.

| From | To | Status |
|---|---|---|
| Cowork session | another Claude Desktop install | works |
| Cowork session | a Claude Code project | works |
| Claude Code session | a Cowork install | works |

### Kept: conversations Claude Code would delete

Claude Code deletes a conversation 30 days after it was last used. Better Claude keeps a
copy as each one changes — as APFS clones that take no space until the original is gone —
so you can still read it, continue it, or put it back where `claude --resume` finds it.

### What each install is set up with

Each install has its own page: who it's signed into, its conversations, and everything it's
set up with — skills, MCP servers, plugins (including Cowork plugins kept per organisation),
hooks, memory and settings. **Compare** puts two installs side by side. A notice points out
API keys saved in plain text in settings, by name only.

### Library, Storage and Memory

- **Library** gathers what Claude made in every conversation — files, images, code, and what
  you gave it — each linked back to the conversation it came from.
- **Storage** shows where Claude's disk space goes and moves only what is safe to the Trash:
  caches, stuck uploads, older bundled Claude Code versions, and Cowork's virtual machine in
  an install that has no Cowork conversations. Conversations and credentials are never
  offered, and everything can be put back.
- **Memory** shows what Claude is told to remember — global and project `CLAUDE.md` files,
  Claude Code project memory, Cowork project memory — and flags memory whose folder is gone.


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

Requires macOS 14 or later. [Download Better Claude](https://github.com/mandipadk/BetterClaude/releases/latest/download/BetterClaude.dmg)
(or see [betterclaude.mandip.dev](https://betterclaude.mandip.dev)) and drag the app to
Applications.

The build is ad-hoc signed and **not notarized**, so a browser download arrives
quarantined and macOS blocks the first launch: open System Settings, then Privacy &
Security, and choose **Open Anyway**. Updates installed from inside the app don't ask again.

### Building from source

Needs Xcode's Swift toolchain in addition to macOS 14.

```bash
git clone https://github.com/mandipadk/BetterClaude.git && cd BetterClaude
make app-install     # or: make app, then open dist/BetterClaude.app
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

Better Claude checks for a new version once a day (and whenever you choose **Better Claude →
Check for Updates…**), then downloads it, verifies it against the release signature
compiled into the app, and replaces itself in place. It installs nothing that isn't signed
with Better Claude's release key. Releasing is described in
[Scripts/RELEASING.md](Scripts/RELEASING.md).

## Using it

Pick a conversation in the timeline, read it, and press **Continue in…**. You see where it
is going and what will happen first; nothing is written until you confirm.

From the command line:

```bash
cowork installs                                 # every Claude on this Mac
cowork storage                                  # where Claude's disk space goes
cowork stores                                   # Desktop installs and their accounts
cowork list --store Claude                      # conversations in an install
cowork list --code                              # conversations in Claude Code

cowork export <sessionId> --out chat.coworkbundle
cowork inspect chat.coworkbundle                # manifest + scan report, no extraction

cowork import chat.coworkbundle --to code:/path/to/project --dry-run
cowork import chat.coworkbundle --to cowork:Claude-Work

cowork index                                    # bring the history index up to date
cowork search retry cap webhook                 # search every message, from the index
cowork live                                     # Claude Code sessions running now
cowork usage                                    # every account's limits and what used them
cowork file ~/Code/app/src/main.swift           # where a file came from
cowork library                                  # every artifact Claude ever produced
cowork library --kind code --limit 50           # narrowed to one kind

cowork receipts                                 # every import this tool made
cowork undo <receiptId>                         # roll one back
```

After importing into Claude Code, run `claude --resume` from that project directory. The
first run there shows a one-time trust prompt.

## Safety model

**Imports create; they never overwrite.** Every import, fork and restore writes a receipt
listing exactly what it created, and Undo — in History, or `cowork undo` — removes precisely
that, refusing to delete anything you have edited since.

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
Sources/CoworkFixtures/  a sample Mac with invented conversations, for tests and screenshots
Sources/cowork/        command line front end
Sources/BetterClaude/  SwiftUI app
Scripts/make-app.sh    assembles and ad-hoc signs the .app, generating the icon
Scripts/make-icon.swift  draws the app icon at every size from one geometry
Scripts/capture.sh     photographs every screen from the sample Mac, in light and dark
site/                  the website, on Cloudflare (static, loads nothing from elsewhere)
```

The app and the CLI share the engine completely. Any check added to one applies to both.

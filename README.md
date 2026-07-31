# Claude WM

A kanban board for your projects that mirrors a linked repository's GitHub
issues and hands work to Claude Code — without leaving the window.

This repository holds **two unrelated products**. They share no code, no build
system and no Swift language mode; neither depends on the other.

| | Lives in | Is |
|---|---|---|
| **Claude WM** | `workflow-manager.xcodeproj`, `workflow-manager/` | A macOS SwiftUI + SwiftData app: kanban board, GitHub issue mirror, real terminal, file browser. |
| **WorkflowHost** | `Package.swift`, `Packages/`, `Apps/` | A headless daemon that polls GitHub, serves a dashboard, and can dispatch Claude Code runs across repos. |

Both reach GitHub, and deliberately do it differently: the app shells out to
`gh`, which already holds your auth, so it never handles a token; the host uses
`URLSession` with a PAT because it runs headless and needs Projects v2 over
GraphQL.

`CLAUDE.md` is the working document — it records *why* things are built the way
they are, including a number of constraints that only show up when you get them
wrong.

---

## Claude WM (the app)

### What it does

Each project is a board. Point one at a local Git clone and the
repository-backed views light up. Switch between them from the toolbar, or with
**⌥⌘1–6**:

- **Board** — kanban columns, drag to reorder, ⌘Z to undo.
- **List** — the same items as a sortable table.
- **Timeline** — items laid out across their dates.
- **Issues** — the repository's open GitHub issues, fetched with `gh` and cached
  so the board paints instantly.
- **Terminal** — saved commands and live interactive shells for the repository.
- **Files** — a read-only browser of the working copy, with syntax highlighting.

Cards carry priority, owner, dates, tags, Markdown notes and a subtask
checklist. A card can be **blocked by** other cards — the picker refuses to
create a cycle — and a blocked card can't be handed to an agent.

### GitHub

Issues are **cached but never owned**. Columns are `Unclaimed` / `Claimed`,
derived from assignment on GitHub — the real cross-machine lock — rather than
invented board columns. State flows GitHub → app, with exactly one exception:
"Create GitHub Issue…" files a board card as a *new* issue, showing you the
title, body and labels first. Nothing in the app can edit, close, assign or
comment on an issue that already exists.

Linking a card to an issue is always explicit. Titles are matched only to
*propose* a link for confirmation — never as the ongoing join, because a rename
on either side would silently repoint the card.

### Terminal

A real terminal, not a log view: each session is a persistent interactive login
shell on a pty, so `oh-my-zsh` draws its own prompt, history and arrow keys
work, `cd` persists, Ctrl-C interrupts, and `vim` and `htop` run on the
alternate screen. A saved command isn't a special kind of process — the session
starts a shell and *types* the command into it, so you can interrupt it and keep
using the shell afterwards. **Run All** starts everything you've opted in,
staggered so a worker doesn't lose the race with the server it talks to.

Sessions are owned by the project, not the tab: switching views or projects
leaves them running.

### Board sync with Claude

Opt-in per project, off by default — enabling it means writing into your
repository and letting an agent move your cards.

Turn on **Sync Board with Claude** and the board is mirrored into
`.taskboard/tasks.json`, which a Claude Code session reads and writes. **Send to
Claude** flags a card as requested; the session picks it up, reports
`in_progress` when it starts and `review` with a branch and PR URL when it opens
one.

Conflicts are resolved by **field ownership**, not last-writer-wins: Claude owns
`status`, `branch` and `prUrl`; the app owns `title`, `details`, `githubIssue`
and `requested`. Everything the agent writes is treated as untrusted — malformed
JSON keeps the last good board rather than clearing it.

### Requirements

- macOS 26.5 or later
- Xcode 26
- [`gh`](https://cli.github.com), authenticated (`gh auth login`) — required for
  the Issues view
- `claude` on your machine for the Claude features (npm, nvm, bun and volta
  installs are all located automatically)

### Build and run

```bash
xcodebuild -project workflow-manager.xcodeproj -scheme workflow-manager -destination 'platform=macOS' -derivedDataPath .xcbuild build
```

Or just open `workflow-manager.xcodeproj` and hit run. The product is
`Claude WM.app`; the Xcode target and source folder are still named
`workflow-manager`, which is deliberate — see `CLAUDE.md`.

**The app is not sandboxed**, and can't be. A sandboxed process cannot launch an
arbitrary binary, and the whole GitHub integration is built on spawning `gh`.
That rules out the Mac App Store, which is a trade this repo makes knowingly.

---

## WorkflowHost (the daemon)

Progress across several products otherwise has to be reconstructed from session
transcripts and commit logs. WorkflowHost decides what runs next and shows where
everything stands.

Each person runs their own host on their own Mac, under their own Claude
subscription. **There is no shared server** — teammates see each other's
progress through GitHub, and issue assignment is the cross-machine lock.

### Requirements

- macOS 15 or later, Swift 6.1+
- `git`, `gh`, `claude`, and `cloudflared` for `--tunnel`
- A **fine-grained PAT with repo + project scope**, in the login Keychain.
  Projects v2 needs the project scope; a token without it authenticates fine and
  then fails only on the board query. `gh auth token` is *not* a substitute —
  its default scopes omit projects.

```bash
security add-generic-password -U -s dev.workflowhost -a github-token -w
```

The host only ever reads that token. It never writes, prompts for, or logs one.

### Configure

`~/Library/Application Support/WorkflowHost/config.json`. Running the host with
no config prints a template and writes nothing — a daemon shouldn't create files
nobody asked for.

```json
{
  "maxConcurrentPerRepo": 1,
  "pollIntervalSec": 60,
  "repos": [
    {
      "owner": "kmrifat",
      "name": "claude-workflow-manager",
      "path": "/Users/you/code/claude-workflow-manager",
      "projectNumber": 1,
      "readyColumn": "Ready",
      "activeColumn": "In Progress",
      "reviewColumn": "In Review"
    }
  ]
}
```

Bad config fails at boot naming the offending field and exits **78**
(`EX_CONFIG`), so launchd and CI can tell "misconfigured" from "crashed".

### Run

```bash
swift build
```

```bash
swift test
```

```bash
swift run WorkflowHost
```

Loads the config, opens the database and prints what it found.

```bash
swift run WorkflowHost poll --once
```

```bash
swift run WorkflowHost ready
```

```bash
swift run WorkflowHost serve
```

Polls continuously and serves the dashboard on `127.0.0.1:8420`. Add `--tunnel`
to expose it through a `cloudflared` quick tunnel — that's how the phone is
served, rather than a native iOS client. The dashboard token is printed exactly
once at startup and otherwise only lives in the Keychain.

```bash
swift run HostApp
```

The macOS menu bar client.

`WORKFLOWHOST_HOME` relocates the whole data directory — use it for tests, or to
run a second instance against a scratch database while the real one is live.

### The dispatcher

`serve --dispatch` is the only thing in the host that writes to GitHub. It
assigns issues, pushes branches, opens PRs and moves board cards. Everything
else — the poller, the dashboard — is read-only.

> **It has been written and unit-tested but never run against a real
> repository.** Point it at a repo you don't mind noise in, watch one issue go
> through, and only then raise `maxConcurrentPerRepo`.

Rules that exist for a reason:

- **Assignment is the lock.** The issue is assigned on GitHub first and alone,
  before any local work. Two hosts share no state; the second one sees the claim
  and skips. A failed dispatch un-assigns.
- **The area lock** keeps two runs out of one module. Worktrees isolate files,
  not meaning — two runs in the same area produce conflicting PRs that each look
  fine alone.
- **Nothing merges.** Every run ends at "PR opened" and waits for a human.

---

## Layout

```
workflow-manager.xcodeproj                     the app
workflow-manager/                              its source; Xcode-synchronized group
Package.swift                                  the host's root manifest
Packages/WorkflowCore/                         models + DTOs, no I/O, no dependencies
Packages/WorkflowHost/…/WorkflowHostKit/       all daemon logic (testable)
Packages/WorkflowHost/…/WorkflowHost/          main.swift, ~10 lines, forever
Apps/HostApp/                                  macOS menu bar client
```

`WorkflowCore` is the point of writing the host in Swift: change a DTO once and
every target fails to compile until it's fixed.

## Status

Both products are built and in use. What remains for the host is operational
rather than constructional — run the poller against a real project board, then
try a single dispatch.

Deliberately not built: a native iOS client (the tunnel serves a browser
instead), and GitHub OAuth for the dashboard (the token path is sufficient for a
single user).

Deliberately never to be built: a shared backend, a user table, or a sync
server. GitHub is the sync layer.

## Contributing

Read `CLAUDE.md` first. It's short, and most of it is the reasoning behind
decisions that look arbitrary until you know why — the concurrency rule, why
issues are cached as one blob, why the terminal forks instead of spawning, and
why the two products must never take a dependency on each other.

# CLAUDE.md

## This repo holds two unrelated products

| | Lives in | Is |
|---|---|---|
| **WorkflowHost** | `Package.swift`, `Packages/`, `Apps/` | A local daemon that orchestrates Claude Code runs across repos. SPM, Swift 6 language mode, unsandboxed. |
| **Claude WM** | `workflow-manager.xcodeproj`, `workflow-manager/` | A macOS SwiftUI + SwiftData kanban app that also mirrors a linked repository's GitHub issues. Xcode project, Swift 5 mode, **not sandboxed**. |

The app ships as **Claude WM** (`PRODUCT_NAME`, `CFBundleDisplayName`), but its
Xcode project, target, source folder and bundle identifier are all still
`workflow-manager`. Renaming those buys nothing and costs something: the bundle
identifier is where SwiftData puts the store, so changing it strands an existing
board. Same for `WorkflowDirectory.claudeMemoryBeginMarker` — it is already in
other people's `CLAUDE.md` files. Use "Claude WM" in anything the user reads;
leave the identifiers alone.

They share no code, no build system and no Swift language mode. **Never add the
SPM package as a dependency of the Xcode project, or the reverse.** A change to
one does not touch the other. The Xcode target uses a file-system-synchronized
group scoped to `workflow-manager/`, so files added under `Packages/` are never
picked up by it — don't add a synchronized group at the repo root, which would
break that.

Both reach GitHub, and they do it differently on purpose: the host uses
`URLSession` with a PAT because it runs headless and needs Projects v2 via
GraphQL; the app shells out to `gh`, which already holds the user's auth, so the
app never handles a token. Duplicated concepts (`GitHubIssue` exists in both) are
deliberately *not* shared — one is a Swift 6 SPM value type, the other decodes
`gh`'s JSON inside a Swift 5 SwiftData target.

Everything below concerns WorkflowHost.

---

## What WorkflowHost is

Progress across several products otherwise has to be reconstructed from session
transcripts and commit logs. WorkflowHost decides what runs next and shows where
everything stands. Each team member runs their own host on their own Mac, under
their own Claude subscription. There is no shared server; teammates see each
other's progress **through GitHub**.

## Stack

- Swift 6.3, language mode 6, strict concurrency
- **GRDB 7** for SQLite, WAL mode
- **Vapor** for HTTP + WebSocket (phase 3)
- Foundation `Process` for spawning `claude` and `git` (phase 2)
- `URLSession` for the GitHub REST and GraphQL APIs — no SDK
- SwiftUI + APNs for the clients (phase 5)
- External CLIs: `git`, `gh`, `claude`, `cloudflared`

## Layout

```
Package.swift                                        root manifest
Packages/WorkflowCore/Sources/WorkflowCore/          models + DTOs, shared with both clients
Packages/WorkflowHost/Sources/WorkflowHostKit/       all daemon logic (testable)
Packages/WorkflowHost/Sources/WorkflowHost/          main.swift, ~10 lines, forever
Apps/                                                HostApp + MobileClient, phase 5
```

`WorkflowCore` is the point of writing this in Swift: change a DTO once and all
three targets fail to compile until fixed. It has no dependencies and does no
I/O — keep it that way.

The `WorkflowHostKit` / `WorkflowHost` split exists so tests can depend on the
logic. Do not collapse it.

## Commands

```bash
swift build
```

```bash
swift test
```

```bash
WORKFLOWHOST_HOME=/tmp/wfh swift run WorkflowHost
```

```bash
swift run WorkflowHost poll --once
```

```bash
swift run WorkflowHost ready
```

```bash
swift run WorkflowHost serve
```

```bash
swift run WorkflowHost serve --tunnel
```

```bash
swift run HostApp
```

```bash
swift test --filter ConfigLoaderTests
```

Keep the app's DerivedData out of `.build/`, which belongs to SPM:

```bash
xcodebuild -project workflow-manager.xcodeproj -scheme workflow-manager -destination 'platform=macOS' -derivedDataPath .xcbuild build
```

## Data locations

`~/Library/Application Support/WorkflowHost/` holds `config.json` and
`db.sqlite` (plus its `-wal` and `-shm` sidecars). `WORKFLOWHOST_HOME` relocates
the whole directory — use it for tests and for running a second instance against
a scratch database while the real one is live.

`HostPaths` is the **only** file allowed to mention `applicationSupportDirectory`
or `~/Library`. A test enforces this.

## The kanban app's GitHub integration

A `Project` can link a local clone (`repoPath`, `repoOwner`, `repoName`,
`repoDefaultBranch` — all optional, so it stays a lightweight SwiftData
migration). The **Issues** view mode then shows that repository's open issues,
fetched through `gh`.

**The app is not sandboxed.** A sandboxed process cannot launch an arbitrary
binary, and the whole integration is built on spawning `gh`. This rules out the
Mac App Store for the app, the same trade the host already makes. Do not
re-enable `ENABLE_APP_SANDBOX` without replacing the `gh` path entirely. Because
there is no sandbox, a plain path is enough — no security-scoped bookmarks.

`CommandRunner` is the *only* place the app spawns a subprocess: arguments as an
array (never a shell string), stdout and stderr drained concurrently, a timeout,
and non-zero exit thrown as an error. Two things it gets right that are easy to
get wrong:

- **`gh` is resolved by absolute path.** A GUI app launched from Finder does not
  inherit a login shell's `PATH`, so looking up `gh` by name fails in the built
  app while working fine from a terminal.
- **Both pipes are drained concurrently.** Reading stdout to EOF first deadlocks
  once the child fills stderr's 64KB buffer. Verified against 440KB of output.

**Issues are cached but never owned, and read-only with one exception.**
Columns are `Unclaimed` / `Claimed`, derived from assignment — the real
cross-machine lock — rather than invented board columns.

The exception is `GitHubCLI.createIssue`, which files a board card as a *new*
issue (`gh issue create`) and links the card to it. It is the only thing in the
app that changes anything on GitHub. It is additive only — it cannot edit,
close, assign, label-after-the-fact or comment on anything that already exists —
and `CreateIssueSheet` shows the exact title, body and labels before it runs.
Keep both properties: state flows GitHub → app everywhere else, and an issue,
once filed, cannot be un-filed. Tags are offered as labels only when they match
a label already seen in the cache, because `gh issue create` fails outright on a
label the repository doesn't have.

`IssueCacheEntry` keeps the last fetch as one opaque JSON blob per project, so
the board paints instantly instead of showing a spinner. It is a cache in the
strict sense: a fetch **replaces** it wholesale (which is how closed and
transferred issues disappear — `gh issue list --state open` stops returning them),
a *failed* fetch leaves it alone and the header says so, and deleting every row
loses nothing. One TTL, `IssueCache.ttl`, decides both whether entering the view
refetches and how often the on-screen loop does.

Per-issue rows were considered and rejected: issues nest labels, assignees, an
author and a milestone, so it would mean four more models with four more cascade
rules, in exchange for `#Predicate` querying nothing asks for — the board filters
≤100 issues in memory through `GitHubIssue.matches`. The blob is also the
envelope pattern the host's `cache` table already uses.

A card can point at an issue (`WorkItem.githubIssueNumber`, plus
`githubRepoSlug` so relinking a project cannot silently repoint every number).
The link is **always explicit** — created from an issue, or chosen by hand.
`IssueLinkSuggester` matches titles only to *propose* links for confirmation;
titles are never the ongoing join, because a rename on either side would
silently repoint a card. A closed issue leaves the cache but the card keeps its
number and greys the badge: inferring board state from GitHub state is the
reverse of the rule this repo follows everywhere else.

Issue bodies are Markdown, and `Text(markdown:)` only handles *inline* syntax —
a body handed to it directly shows literal `###` and loses fenced code. Block
parsing lives in `GitHub/MarkdownBlock.swift` (pure Foundation, so it is testable
on its own); rendering and inline styling live in `Views/GitHub/`. Inline code
needs an explicit background: SwiftUI makes it monospaced and nothing else, which
in a body full of paths reads as random font switches.

**Card detail is a popover on both boards**, anchored to the card, so the board
stays visible behind it. A GitHub issue shows `GitHubIssueDetailSheet`
(`presentation: .popover`, fixed size); a local card shows `WorkItemPopover`,
which is a glance plus quick actions rather than a second editor —
`WorkItemInspector` remains the long-form one, reached by "Edit Details" and
still used by the list and timeline views.

Two macOS constraints shape this. A `.sheet` is neither freely resizable nor
dismissable by clicking away, which is why the panel mode of
`GitHubIssueDetailSheet` still exists and owns its own size. And **a sheet
presented from inside a popover is torn down with it** when focus moves — so
"Create GitHub Issue…" and "Link to Existing Issue…" close the popover and ask
`BoardColumnView` to present, rather than presenting themselves.

## The app's Terminal and Files views

Two more `BoardViewMode` cases, both requiring a linked repository
(`requiresRepository`, which also hides the work-item filters).

**Terminal** is a real terminal, not a log view. Each session is a persistent
interactive login shell on a pty (`zsh -il`), so `oh-my-zsh` loads and draws its
own themed prompt with the git branch, history and arrow keys work because `zle`
is there, `cd` persists, and Ctrl-C interrupts. A *saved command* is not a
special kind of process — the session starts a shell and **types** the command
into it, which is why there is only one code path and why you can interrupt and
reuse it afterwards. `TerminalCommand` stores a shell line plus a directory
relative to the repository, so it survives a re-clone; **Run All** starts
everything opted in, staggered 400ms because a worker started in the same instant
as the server it talks to loses that race. Sessions are owned by
`ProjectDetailView`, not `TerminalView` — switching tabs must not kill a shell.

Facts behind it, all measured rather than assumed:

- **The child needs a controlling terminal, and only `TIOCSCTTY` grants one.**
  Without it the tty's foreground process group stays 0 and SIGINT is delivered
  to nothing — while `^C` still *echoes*, because the line discipline draws it,
  so Ctrl-C looks like it works right until you notice the job never died. The
  giveaway is `ps -o tpgid= -p $$` reporting 0. Two simpler routes were tried and
  both fail: `POSIX_SPAWN_SETSID` alone leaves no controlling terminal, opening
  the slave by path through a spawn file action does not confer one, and setting
  `TIOCSPGRP` from the parent fails because a process group cannot be foreground
  for a terminal belonging to no session. Hence `fork` + `setsid` + `TIOCSCTTY` +
  `execve`, with `fork` resolved through `dlsym` since Swift marks it
  unavailable. Everything between fork and exec is async-signal-safe C, and every
  allocation happens before it.
- **`TerminalEmulator` is a grid, not a buffer.** A prompt addresses the cursor —
  `oh-my-zsh` moves right, writes, moves back; readline redraws the line in
  place; `git log` clears the screen. None of that is expressible as "append a
  line", which is what the first version did and why it looked nothing like a
  terminal. Implemented: cursor positioning and movement, erase in line/display,
  insert/delete lines and characters, scroll regions, the alternate screen (so
  `vim` and `htop` work), save/restore cursor, autowrap with deferred wrap,
  tab stops, reverse index, and SGR including 256-colour and 24-bit.
- **The parse loop must advance on every byte, including ones it ignores.**
  `feed`'s `default` branch scans forward to the next control byte, but
  `isControl` is true for *everything* under `0x20` while the `switch` only has
  cases for `0x00`, `0x07`–`0x0D` and `0x1B`. Any other C0 byte therefore left
  `end == index`, and `index = end` made no progress: the main thread spun on
  one byte forever, needing no further input to keep going. A Claude Code
  session froze the app this way; a shell and a dev server never emit those
  bytes, so it looked solid for months. Diagnosed from the child sitting at 0%
  CPU while the app held a core — output volume cannot do that. The profile
  blamed an `Array` allocation, which was the empty array being allocated
  inside the spin, not the cause.
- **No `COLUMNS`/`LINES` in the environment.** The pty's window size is the
  truth and the shell keeps it current on SIGWINCH; exporting them just creates
  a second copy that goes stale on the first resize.
- **Keys are encoded, not typed.** Arrows must arrive as `ESC[A`, Ctrl-C as a
  single `0x03` so the line discipline raises SIGINT, Tab as a literal tab so
  completion runs in the shell instead of moving focus.
- Output is buffered under a lock and folded into the emulator at 20fps. A
  webpack rebuild emits hundreds of writes a second, and one observable mutation
  each spends the whole frame budget in diffing.
- The pane's size is derived from the measured monospaced advance and pushed to
  the pty, so `$COLUMNS` matches what is on screen.

**Files** is a read-only browser: lazy per-directory listing (a repository with
`node_modules` has hundreds of thousands of files, so nothing is walked up
front), a 2MB preview cap, NUL-byte binary sniffing, and images shown inline.
It does not edit, create, rename or delete — an editor that quietly disagrees
with the one you actually use is worse than no editor.

`SyntaxHighlighter` scans left to right in one pass and consumes comments and
strings *first*. That ordering is the design: a `//` inside a string literal, or
the word `class` inside a comment, is what a bank of independent regexes gets
wrong, and those are exactly the lines you are reading when you notice.

**`standardizedFileURL.path` keeps a trailing slash for directories.** So a
containment check written as `hasPrefix(rootPath + "/")` tests for `…/repo//` and
is false for *every* subfolder. `TerminalCommand.path(_:isInside:)` strips it
first. This one is nasty because it fails silently and looks exactly like the
path-escape rejection it is meant to be.

## The app's Claude integration

The app starts a Claude Code Remote Control server in a linked repo and mirrors
the board into `.taskboard/tasks.json`, which a session then reads and writes.
It is entirely standalone — it does **not** talk to WorkflowHost, and must not.
Opt-in per project (`Project.workflowSyncEnabled`), off by default, because
enabling it means writing into someone's repository and letting an agent move
their cards.

Facts that shaped this, all verified against the real binary:

- **`claude remote-control` accepts no prompt.** No positional argument, no
  `--prompt`. So the contract cannot be passed at spawn — it has to be readable
  *from the repo*. That is why `.taskboard/README.md` and the marker-delimited
  `CLAUDE.md` block exist, and why "send this card to Claude" is a `requested`
  flag in the JSON rather than a command-line argument.
- **`--spawn same-dir`, never `worktree`.** A worktree session gets its own
  checkout and therefore its own `.taskboard/tasks.json` — a different file from
  the one the app watches. WorkflowHost uses `worktree` because it creates the
  worktree itself; that reasoning does not transfer.
- **`claude` is not on `CommandRunner.searchPaths`.** It ships via npm/nvm/bun/
  volta, and an nvm path is version-stamped so it cannot be hardcoded.
  `locateClaude()` searches its own list, newest Node first, with a
  `UserDefaults` override. `searchPaths` is left alone so `gh` and `git` resolve
  exactly as documented above.
- Null stdin is fine — the Ink TUI does not reject it. Launch failures are
  almost always "not signed in", which `ClaudeLauncher.diagnose` names outright
  instead of quoting a log. `CommandRunner.spawn` is still the only way the app
  starts a process.

**Watch the `.taskboard` directory, never the `tasks.json` file descriptor.**
Claude, `Data.write(.atomic)` and every editor write a temp file and `rename()`
it, which unlinks the inode a per-file fd points at — that watch reports
`.delete` once and is deaf forever. A rename *into* a directory is a directory
write, and the directory inode survives. There is also a 10s poll fallback,
because a branch checkout can replace the directory itself.

Echo suppression is by **content hash, not a time window** — immune to clock
skew and to a slow write landing late. This is why the encoder uses
`.sortedKeys`: a stable byte order is what makes the hash meaningful.

**Conflict resolution is field ownership, not last-writer-wins.** Claude owns
`status`, `branch`, `prUrl` — it is the only party that observes them. The app
owns `title`, `details`, `githubIssue`, `requested`. Timestamps only break ties
within one side. Plain last-writer-wins fails here because the agent rewrites
the whole array in one atomic write, so every row carries the same timestamp and
a title typed a second earlier gets clobbered by a rewrite that never meant to
touch it. Deletion flows app → file only; a card missing from the file is
re-added, and a tombstone stops an agent resurrecting a deleted one.

Everything the agent writes is untrusted: an unknown status or a bad date falls
back rather than throwing the file out, malformed JSON keeps the last good board,
and a `version` newer than ours is neither applied nor overwritten.

### Two SwiftData behaviours this depends on

Both were found by testing, and both are silent when wrong:

- **SwiftData registers its undo action when the context *saves*, not when an
  object is mutated.** So `disableUndoRegistration()` around a mutation does
  nothing on its own — the next autosave registers it after the window closed.
  The save has to happen *inside* the disabled window. `IssueCache.withoutUndo`
  and `WorkflowSyncModel.apply` both do this; without it ⌘Z undoes a background
  refresh or an agent's status change, invisibly.
- **A deleted object stays in its relationship array until the context saves.**
  So `snapshot(of:)` and `boardRevision(of:)` filter `isDeleted` explicitly.
  Without it a just-deleted card is still written to the file, and the agent
  recreates it from our own row.

## Local git state (build plan phase 2)

`Git/GitReader.swift` answers what is on a branch: commits, files changed,
insertions, deletions, last commit — all read-only, all through `CommandRunner`.
It handles the cases that actually occur: a branch that doesn't exist, a branch
created but not yet committed to, a default branch that isn't `main` (read from
what `gh` reported, never assumed), and a base that only exists as
`origin/<base>` in a fresh clone.

`IssueBranchMatcher` maps issue #N to a local branch, preferring the `issue-<n>`
convention the dispatcher will create in phase 6. It only matches whole segments,
so issue #1 cannot claim `issue-123`.

Summaries are cached for 30s (`RepositoryStatusModel`) — the board asks for one
per visible card, and shelling out to git on every redraw would be absurd.

## Running as a daemon

`serve` runs in the foreground until signalled. Two things it has to get right,
both of which were wrong once:

- **Stop the task group when the server stops.** Vapor installs the signal
  handlers and `app.execute()` returns on SIGINT/SIGTERM, but the poller loops
  forever. Without `await group.next()` then `group.cancelAll()`, the group never
  completes and the process ignores SIGTERM entirely — it needs `kill -9`, which
  means launchd cannot stop it and the menu bar app cannot quit cleanly.
- **Line-buffer stdout.** It is block-buffered when not a terminal, so a daemon
  with redirected output never flushes its banner — including the dashboard
  token, which is printed exactly once and then only lives in the Keychain.

Verified: survives repeated GitHub auth failures without dying (the poll loop
must never hard-fail), stops on SIGTERM, and releases its port.

## The dispatcher is opt-in and has never been run live

`serve --dispatch` is the only thing *in the host* that writes to GitHub. It
assigns issues, pushes branches, opens PRs and moves board cards. The poller and
the dashboard are read-only.

The app's one write is `GitHubCLI.createIssue` — filing a new issue from a card,
confirmed each time, additive only. Everything else it does toward GitHub is
read-only, and its other writes are local: `.taskboard/` inside a linked repo,
and spawning `claude`.

**It has been written and unit-tested but never executed against a real
repository.** Before turning it on: point it at a repo you don't mind noise in,
watch one issue go through, and only then raise `maxConcurrentPerRepo`.

Rules that exist for a reason, in `Dispatcher/DispatchRules.swift`:

- **Assignment is the cross-machine lock.** The issue is assigned on GitHub
  *first and alone*, before any local work. Two hosts share no state; the second
  one sees the claim and skips. A failed dispatch un-assigns, so nothing is left
  stranded.
- **The area lock** (`api`/`ui`/`db`/`infra`) keeps two runs out of one module.
  Worktrees isolate files, not meaning — two runs in the same area produce
  conflicting PRs that each look fine alone. Do not remove it for speed.
- **`blocked-by #N` counts only if N is still open.** Matching on the text alone
  would stall the queue forever on work that is already done.
- **Rebase onto the default branch before opening the PR.** A run that started an
  hour ago is opening against a base that moved.
- **Nothing merges.** Every run ends at "PR opened" and waits for a human.
- **Boot reconciliation.** Any run still marked `running` whose process is gone
  died with the host — the Mac slept, or the app quit. It becomes `failed` so the
  dashboard stops claiming work is in flight.
- Worktrees live *beside* the clone, never inside it, and are left in place after
  a failure or a stop so they can be inspected.

## Deliberately not built

- **The iOS client (part of plan phase 5).** The macOS menu bar `HostApp` is
  built; the phone is served by `serve --tunnel` in a browser instead. If a
  native iOS client is wanted later, note the plan's own warning: iOS kills
  background sockets, so refresh on foreground and use APNs for anything that
  must arrive while the app is closed.
- **GitHub OAuth (part of plan phase 4).** Remote access works today via
  cloudflared plus the bearer token. OAuth needs an OAuth app registered under
  your account (client id and secret), which is yours to create — the token path
  is already sufficient for a single user.

## GitHub access (the host)

The token is a **fine-grained PAT with repo + project scope**. Projects v2 needs
the project scope; a token without it authenticates fine and then fails only on
the board query. Note that `gh auth token` is *not* a substitute — its default
scopes omit projects.

The host only ever reads the token. It never writes, prompts for, or logs one;
provisioning is the operator's job:

```bash
security add-generic-password -U -s dev.workflowhost -a github-token -w
```

`WORKFLOWHOST_GITHUB_TOKEN` overrides it, for scratch instances that shouldn't
touch the login Keychain.

REST covers issues and pull requests; **GraphQL covers Projects v2 only**,
because the board's Status field has no REST equivalent. The board's column field
is assumed to be named `Status` — config names the *options*, not the field.

Collections are fetched with `sort=updated&direction=desc`, which is what makes a
single page-one ETag trustworthy: any change to any item reorders page one, so a
304 there really does mean nothing changed. The ETag is stored inside the cached
value's JSON envelope rather than in its own column, so the cache table stays
generic and no migration is needed to cache something new.

Bad config fails at boot naming the offending field, and exits **78**
(`EX_CONFIG`) so launchd and CI can tell "misconfigured" from "crashed". A
missing config file prints a template and writes nothing — a daemon must not
create files nobody asked for.

## Concurrency rule

Exactly one owner per piece of mutable state.

1. **Database state is owned by GRDB.** `AppDatabase` is a `Sendable final class`
   over a `DatabasePool`, **never an `actor`**. Every subsystem holds the same
   instance and calls it directly. GRDB already serializes writes and runs
   readers concurrently under WAL; an actor would add a second queue in front of
   one that exists and re-serialize the reads that made `DatabasePool` the right
   choice. It would also imply atomicity it does not provide — actors are
   reentrant, so two `await`s in a row are not one operation.
2. **Every other piece of mutable shared state is owned by exactly one actor** —
   `Dispatcher` (in-flight runs, per-repo counters, child `Process` handles),
   `GitHubPoller` (cursors, ETags, backoff), `EventHub` (WebSocket subscribers).
   Nothing else holds a copy.
3. **Never `await` inside a GRDB `read`/`write` closure.** Multi-step invariants
   go inside one transaction, not across two `await`s. `write { db in … }` is
   synchronous and cannot suspend — that is the real atomicity boundary.
4. **Actors never form a call cycle.** `Poller → Dispatcher → AppDatabase` is the
   only direction. Notifications flow back through `EventHub`, never by calling
   upward.
5. **Nothing under `Packages/` is `@MainActor`.** `@MainActor` exists only in
   `Apps/`.
6. Anything crossing a boundary is a `Sendable` value type. `Database`, `Row` and
   `Statement` never escape a GRDB closure — decode inside it.

Loaded config is an immutable `Sendable` struct copied everywhere. Reloading
builds a new value; it never mutates one.

## Schema notes

Migrations are **raw SQL** in `Database/Migrations.swift`. The DDL text is the
contract — it is what the build plan specifies and what `sqlite3 db.sqlite
'.schema'` is checked against. Do not restate it through GRDB's schema DSL.

GRDB enables `PRAGMA foreign_keys = ON`, and `events.run_id` references
`runs(id)` with no `ON DELETE` clause. Consequence: `DELETE FROM runs` fails
while the run still has events. Delete events first. Adding `ON DELETE CASCADE`
would be a deliberate future migration, not a silent edit to `v1_initialSchema`.

`busyMode` is set to `.timeout(5)`; GRDB's default is `.immediateError`, and WAL
is multi-process.

## Phases

0. **Scaffold** — manifest, config decoding, GRDB open + WAL + migrations, boot
   summary. ✅ done
1. **GitHub sync, read only** — REST for issues and PRs, GraphQL for Projects v2,
   into the `cache` table; `poll` and `ready` subcommands. ✅ done
2. **Git reader** — commits and diffstat for a branch, via one properly-wrapped
   `Process`. ✅ done (host and app both)
3. **Dashboard** — Vapor serving `/api/state`, `/api/runs/:id`, a WebSocket and
   one static HTML page. ✅ done
4. **Remote access** — `cloudflared` quick tunnel. ✅ done (OAuth deferred)
5. **Clients** — macOS menu bar `HostApp`. ✅ done (iOS deferred)
6. **Dispatcher** — the part that spawns `claude`. ✅ written and unit-tested,
   **never run live**

All phases are built. What remains is operational, not constructional: run the
poller against a real project board, then try one dispatch.

## Non-goals

- **Do not render or proxy Claude's session output.** The Claude mobile app does
  that through Remote Control. Store a session id and deep link to it.
- **Do not treat our database as the source of truth** for issues, PR state or
  board columns. Those live in GitHub. We cache them, timestamped. If our status
  and GitHub's disagree, GitHub wins: overwrite local, log an event, never
  reconcile the other way.
- **`db.sqlite` is disposable.** Deleting it must lose run history and nothing
  else, and the dashboard must rebuild on the next poll. Config, credentials and
  any other non-re-derivable state must never live there.
- **Do not build a shared backend**, a user table, or a sync server. GitHub is
  the sync layer, and issue assignment is the cross-machine lock.
- **Do not auto-merge PRs.** Every run stops at "PR opened".
- **The host is read-only until phase 6.** `ProjectBoardMutation` exists so its
  shape is settled, but nothing may call it before the dispatcher lands — a test
  asserts the mutation is referenced in that one file and nowhere else.
- **Do not sandbox the host.** It spawns `claude` and `git`. It ships as an SPM
  executable with no entitlements, which rules out the Mac App Store. (Phase 5's
  menu-bar `HostApp` will default to the App Sandbox — the answer is to keep the
  daemon a separate unsandboxed process, not to relax the app.)
- **No credential handling of our own.** GitHub auth is whatever the local `gh`
  CLI or the Keychain already holds. Never read, store or log a token.
- **No SwiftData, no ORM, no schema DSL in the host.** Raw SQL migrations and
  explicit record structs.
- **No Xcode project for the host.** SPM only.
- Do not build the SwiftUI clients before phase 5. The web dashboard comes first,
  deliberately — it renders in days rather than weeks, and redesigning HTML is
  cheaper than redesigning SwiftUI.

<!-- workflow-manager:begin -->
## Claude WM

This repository is tracked on a Claude WM board. `.taskboard/tasks.json`
is the shared task list: rows with `"requested": true` are work assigned to
you, and you report progress by setting a row's `status` to `in_progress`
when you start and `review` when you open a PR.

Read `.taskboard/README.md` for the full contract before touching that file.
<!-- workflow-manager:end -->

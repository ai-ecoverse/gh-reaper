# Changelog

All notable changes to `gh-reaper` are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.7.0] - 2026-08-07

### Added
- **`busy` — never sweep a worktree someone is working in.** A worktree whose
  branch is merged still reads as reapable while a coding agent is running
  inside it, so `gh reaper --merged --reap --yes` would delete an active session
  out from under itself. Found in the field: a 20-hour agent run classified as
  plain `merged`, one flag away from being swept. A worktree now reads `busy`
  when a live process has its current directory inside the tree, and `busy` is
  risky — skipped unless you pass `--force`. One process-table scan per run
  (`/proc` on Linux, `lsof` elsewhere, ~0.5s) covers every worktree at once.
  Idle interactive shells are deliberately excluded: a terminal tab parked in a
  finished worktree is not work in progress, and counting it would pin half the
  fields forever. `gh reaper`'s own process chain is excluded too, so running it
  from inside a worktree doesn't make that worktree un-reapable.

### Fixed
- **A stale `git worktree lock` no longer pins a worktree forever.** Agent
  harnesses lock the tree for a session and stamp the reason with their pid
  (`claude session foo (pid 832 …)`); if that session dies the lock outlives it,
  and `git worktree remove` refuses the tree outright — `--force` does *not*
  override a lock, only `remove -f -f` does. Reaping now reads the lock reason,
  and lifts the lock with `git worktree unlock` when its owning process is gone.
  A lock whose owner is still alive reads as `busy` instead and is spared. Both
  states surface as a `locked` status flag and a `locked` JSON field.
- **Busy detection sees through symlinked roots.** The process table reports
  resolved paths (`/private/var/…`) while `pwd` keeps the symlink (`/var/…`), so
  worktrees under `/tmp`, `/var`, or a symlinked home would never have looked
  busy. Paths are now compared in both forms.

## [1.6.0] - 2026-06-08

### Added
- **Native agent worktrees are first-class.** Gemini CLI (`gemini --worktree`)
  and Qwen Code (`qwen --worktree`) now create their own git worktrees nested in
  the repo — `<repo>/.gemini/worktrees/<slug>/` and `<repo>/.qwen/worktrees/<slug>/`,
  alongside Claude Code's `<repo>/.claude/worktrees/`. Discovery already finds
  these (they sit under scanned roots and aren't pruned); verified end-to-end by
  driving both agents and reaping the result with `gh reaper --merged --reap`.

### Fixed
- **Agent session markers no longer mark a worktree `dirty`.** Qwen Code drops a
  `.qwen-session` session-id pointer into every worktree it creates. That lone
  untracked file made each finished Qwen worktree classify as `dirty`, so
  `gh reaper --merged --reap` skipped it (it needs `--force`). Such markers are
  now treated like `.gitignore`d files — unconditionally, with no
  `--no-ignore-locks` opt-out, since a session pointer is never authored work —
  so abandoned agent worktrees read as `merged`/`clean` and sweep cleanly. Added
  a regression test.

## [1.5.1] - 2026-06-05

### Fixed
- Reaping a `merged`/`clean` worktree that still carried regenerable lock-file
  churn failed: `git worktree remove` refused it with "contains modified or
  untracked files." `reap_one` now forces past that mechanical check for
  worktrees already judged reapable, so the 1.5.0 lock-file feature can actually
  delete them. Added a test that reaps a lock-only merged worktree end-to-end.

## [1.5.0] - 2026-06-05

### Added
- **Lock files are treated like `.gitignore`d files.** A worktree whose only
  uncommitted change is a regenerable dependency lock file (`package-lock.json`,
  `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `go.sum`, `Gemfile.lock`,
  `poetry.lock`, `composer.lock`, `flake.lock`, …) is no longer flagged `dirty`,
  and lock-file mtimes no longer count toward its age. A stray `npm install` can't
  pin an otherwise-done worktree as un-reapable. Lock changes alongside any real
  edit still count as dirty.
- **`--no-ignore-locks`** to opt out and treat lock-file changes as dirty (the
  pre-1.5 behavior).

## [1.4.0] - 2026-06-05

### Added
- **`merged` status.** Each worktree is now checked for whether its `HEAD` is
  already contained in the repo's default branch (`git merge-base --is-ancestor`),
  an age-independent "this work is done" signal. Merged worktrees are reapable
  without `--force` (when otherwise clean).
- **`-m, --merged` filter.** Show (and with `--reap`, sweep) only worktrees whose
  work is already merged — e.g. `gh reaper --merged --reap`.
- **`--check-prs` (opt-in, networked).** For branches that aren't ancestors of the
  default branch, ask `gh` whether their pull request was merged, tagging them
  `pr-merged`. Catches GitHub squash/rebase-merges that rewrite commit history.
- `merged` boolean field in `--json` output.

### Changed
- **`AGE` now tracks the newest _non-gitignored_ change** (tracked/unignored file
  mtime, or last commit), instead of `max(dir-mtime, reflog, commit)`. A routine
  `npm install`, build, or automated `git checkout` no longer resets a worktree's
  apparent age — fixing worktrees that looked "0 days old" while their actual work
  was months stale. `--min-age` filters on this corrected value. Orphans (no usable
  git) still fall back to the working-dir / reflog mtime.

## [1.3.0] - 2026-06-04

### Added
- Scan Codex's worktree pool by default: `~/.codex/worktrees/<id>/<repo>` is now a
  default root. Codex creates these on demand in the home dotdir (not nested under a
  code root), so it needs an explicit root — unlike Claude Code, whose
  `<repo>/.claude/worktrees/<slug>` checkouts are already discovered inside scanned
  repos.

## [1.2.0] - 2026-06-04

### Added
- **Parallel inspection.** Worktrees are now sized/classified concurrently across
  workers (default: CPU count), instead of one at a time. A real 238-worktree /
  114 GB scan dropped from ~121s to ~31s (~4× on 16 cores), with identical results.
- `-j, --jobs N` to control worker count (`--jobs 1` restores serial behavior).

### Changed
- `inspect_marker` now emits a TSV record on stdout; main() fans markers out to
  per-PID temp files (no output interleaving, no reliance on pipe atomicity).

## [1.1.0] - 2026-06-04

### Added
- Scan intent's worktree pool by default: `~/intent/workspaces/<workspace>/<repo>`
  is now a default root, alongside Conductor's `.conductor` and yolo's `.yolo`.
- Prune intent's `.workspace/` metadata directories during discovery (they hold no
  worktrees) to keep scanning fast.

### Note
- Reaping an intent worktree removes the `<repo>` checkout but leaves intent's
  sibling `.workspace/` metadata, which may leave the intent app with a dangling
  workspace. Listing is read-only and safe; use `--reap` here deliberately.

## [1.0.0] - 2026-06-04

### Added
- Initial release.
- Machine-wide discovery of linked git worktrees across curated developer roots
  (`~/Developer`, `~/conductor`, `~/Projects`, `~/go/src`, …) plus the current directory.
- Per-worktree reporting of last-touched age and disk size, sorted oldest-first.
- Status classification: `clean`, `dirty`, `unpushed`, `orphan`.
- **Read-only by default**: bare `gh reaper` only lists and changes nothing.
- `--reap` performs deletion via `git worktree remove` — interactive
  (`[y]es / [n]o / [a]ll / [q]uit`), or `--yes` to skip prompts. `--yes`/`--force`
  do nothing without `--reap`.
- `--force` gate for dirty/unpushed/orphan worktrees; `--prune` to tidy admin entries.
- `--json` for machine-readable inventory; `--dry-run` as the explicit form of the
  default read-only behavior.
- `--min-age`, `--min-size`, `--path`, and `--all` filters.
- macOS TCC-safe scanning: protected directories (Desktop, Documents, Downloads,
  Pictures, Library, Volumes, …) are never traversed.

# Agent Instructions

Single source of agent instructions for this repo; `CLAUDE.md` imports it.

## Build & Test

```bash
mise run gen      # regenerate Pewter.xcodeproj from project.yml (xcodegen)
mise run build    # build the app (pass-through signing via mise.local.toml)
mise run test     # Core unit tests: swift test --package-path Core
mise run format   # swiftformat + markdownlint --fix
mise run lint     # swiftformat, markdownlint, actionlint, zizmor
mise run ci       # lint + test + build in parallel (pre-push check)
mise run icon     # re-render AppIcon PNGs from App/AppIcon.svg
mise run run      # build and relaunch
mise run logs     # tail the app's unified-logging output
```

Git hooks are managed by lefthook (`lefthook install` after clone; tools come
from `mise.toml`). Pre-commit runs swiftformat on staged Swift, markdownlint
on staged markdown, actionlint and zizmor on staged workflows, and the beads
sync hook; commit-msg enforces Conventional Commits via
commitlint (`type(scope): subject`); the scope list in `.commitlintrc.yml`
feeds czg's prompt, not the linter. Pre-push runs the Core tests.

## Architecture Overview

- `Core/` — SwiftPM package `PewterCore`: all testable logic, no AppKit.
  Item model, markdown parse/serialize, file storage with self-protection,
  capture orchestration, tap-detection state machine.
- `App/` — thin AppKit/SwiftUI shell: non-activating floating panel, status
  item, three-tier capture (AX selection — focused element, then a bounded
  window walk → synthetic Cmd+C with clipboard restore → recent-clipboard
  assist for TUIs), permissions/onboarding.
- Notes live in one hand-editable markdown file under Application Support;
  external edits are watched and merged wholesale.

## Conventions & Patterns

- Swift 6 strict concurrency: `@MainActor` UI, `isolated deinit` for observers
  and timers, `DispatchQueue.main.async` (FIFO) over unstructured `Task` when
  event order matters.
- New logic goes in `Core/` with tests when it has no AppKit dependency;
  UI/window behavior is covered by `docs/manual-testing.md` instead.
- Log privacy: Copy Diagnostics reads our own log store, where
  default-privacy interpolations render verbatim — mark anything that can
  carry note or clipboard content `privacy: .private`.
- TCC/signing gotchas (stable identity, `tccutil reset`, WWDR G3) live in
  CONTRIBUTING.md — read it before touching capture or entitlements.

## Pull Requests

PR bodies follow `.github/PULL_REQUEST_TEMPLATE.md`: a `Summary` (problem
first, then the change and why this approach), plus a `Notes` section only
when something non-obvious earned it — rejected alternatives, accepted
limitations, dismissed review findings with their evidence, relevant
`docs/manual-testing.md` items, follow-up issues.

- Squash-merge uses the PR title and body as the mainline commit message,
  so the body is permanent history — write it commit-worthy and delete the
  template's guidance comments. The canonical don't-include list lives in
  the template.
- The PR title is the commit subject: it must satisfy commitlint
  (`type(scope): subject`); the local commit-msg hook cannot run on
  GitHub's squash commit, so the title is checked by eye.
- No Claude session links in PR bodies — this overrides the default
  Claude Code PR-body footer. The `Claude-Session` trailer goes in branch
  commit messages instead, reachable via the PR's commits tab (squash
  keeps it out of mainline).
- After merging changes that affect App-layer behavior, switch back and
  update (`git checkout main && git pull --ff-only`) before `mise run run`,
  so the `docs/manual-testing.md` checklist runs against the merged
  binary, not a stale per-branch build. If `open` fails with LaunchServices error
  -600, the shell is sandboxed — run the launch step unsandboxed.
- Watch PR checks with one background command instead of timed re-checks:
  `sleep 20 && gh pr checks <number> --watch --fail-fast` (exit 0 = all
  pass; exit 1 = a check failed *or* gh errored — read the output before
  concluding CI is red). The sleep matters — checks register a few
  seconds after push, and an immediate watch dies with "no checks
  reported", which also exits 1. `--watch` blocks until every check
  reports, so a third-party reviewer's check can hold it open long after
  our own jobs are green; `gh pr checks <number>` without `--watch` gives
  the current state immediately when that happens.
- A green check from a bot reviewer does not mean a review happened.
  CodeRabbit reports `pass` with "Review rate limited" in the output line
  when it declines to run, so read the reason rather than the colour, and
  re-request with an `@coderabbitai review` comment if the change needs it.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**

```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**

- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->

## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See <https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md> for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:

   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```

5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**

- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

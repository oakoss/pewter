# Contributing to smart-list

## Setup

```sh
mise install            # xcodegen, swiftformat, lefthook, markdownlint-cli2, commitlint, czg
lefthook install        # git hooks: format/lint on commit, commit-msg lint, tests on push
make gen                # generate SmartList.xcodeproj
make build              # CLI build into build/
make test               # Core package unit tests
make run                # build + launch
```

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
(`type(scope): subject`), enforced by commitlint at commit time; run `czg` for
a guided prompt. Scopes live in `.commitlintrc.yml`. If you use
[beads](https://github.com/gastownhall/beads) for issue tracking, don't run
`bd hooks install` — it appends a second copy of bd's logic into
`.git/hooks/`, so the sync runs twice and gets clobbered by the next
`lefthook install`; lefthook already delegates to bd's shims in
`.beads/hooks/`. Likewise skip `bd setup claude` / `bd setup codex`: they
re-add managed blocks and files this repo has deliberately consolidated
into `AGENTS.md` (CLAUDE.md is a bare `@AGENTS.md` import, and `--check`
warnings about it are cosmetic).

The `.xcodeproj` is generated and gitignored — edit `project.yml`, never the
project file. Prefer adding logic to `Core/` (plain SwiftPM, unit-testable);
the `App/` target should stay a thin AppKit/SwiftUI shell.

## The TCC / signing gotchas

Capture (double-shift + selection reading) requires the **Accessibility**
grant, and macOS ties that grant to the app's code signature and location.
Things that will bite you:

1. **Ad-hoc signing breaks the grant on every rebuild.** The default build
   signs ad-hoc (`CODE_SIGN_IDENTITY=-`) so a clean clone builds with no Apple
   account — but each build gets a new signature, and TCC silently invalidates
   the grant: the checkbox in System Settings stays on while
   `AXIsProcessTrusted()` returns false. To work on the capture pipeline, use
   a real (free) Apple Development certificate via the Makefile's SIGNING
   pass-through (env vars and Xcode pane edits do NOT work — the pane is wiped
   by `make gen`, and env vars lose to project.yml):
   `make build SIGNING='CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<your team id>'`
   — or persist it in an untracked `Makefile.local` (`SIGNING := …`) so every
   build is signed. Your team id is the OU field shown by
   `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`.
   If `security find-identity -v -p codesigning` says the cert is invalid,
   you're likely missing Apple's WWDR G3 intermediate — download it from
   <https://www.apple.com/certificateauthority/> and add it to your login
   keychain.
2. **Unwedge a stale grant** with
   `tccutil reset Accessibility com.oakoss.SmartList`, then re-grant.
3. **Run from a stable path.** `make run` uses a fixed derived-data path
   (`build/`) so TCC doesn't accumulate entries for changing locations.
4. **Global monitors registered before the grant never fire** — no error,
   nothing. The app re-registers after the grant lands; keep that behavior if
   you touch `AccessibilityPermission` or `ModifierTapMonitor`.
5. **Global NSEvent monitors don't see our own app's events.** The local
   monitor mirror in `ModifierTapMonitor` is what makes the double-tap work
   while the panel is key. Don't remove it.
6. **Synthetic Cmd+C with other modifiers physically held becomes a different
   chord** in the target app. The pipeline waits (up to ~300 ms) for physical
   modifiers to clear before synthesizing, and sets `CGEvent.flags`
   explicitly. Preserve both.
7. **Pasteboard restore races clipboard managers.** The restore only runs when
   `changeCount` still matches the value observed at copy time — never restore
   unconditionally, or you'll clobber whatever a clipboard manager (or the
   user) wrote in between.
8. **Atomic writes change the file's inode**, so the watcher's descriptor goes
   stale on every save. `FileStorage` re-opens and re-arms after each write
   and hashes its own output to ignore self-events. Both halves are required.
9. **The panel must override `canBecomeKey` to true** or its text fields can't
   take input — and because the app never becomes _active_, SwiftUI `Commands`
   shortcuts don't fire; panel keys go through `.onKeyPress` instead.
10. **Don't switch to `MenuBarExtra`.** It activates the app on open, which
    steals focus from the app the user is capturing from and breaks the
    non-activating panel design.

## Code style

`swiftformat .` before pushing (CI lints). No SwiftLint — one auto-formatter
is the whole style discussion.

## Testing

- Everything in `Core/` needs unit tests (Swift Testing, `make test`).
- AX reads, CGEvent posting, and TCC can't run in CI — cover changes to those
  with the checklist in `docs/manual-testing.md` and say so in your PR.

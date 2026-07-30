# Manual test checklist

Capture and permissions can't run in CI (no Accessibility grant on runners).
Run through this before release, and after any change to `App/Sources/Capture/`
or the status item / panel / window layer.

## Permissions

- [ ] `tccutil reset Accessibility com.oakoss.Pewter`, launch → onboarding
      window appears
- [ ] Grant access in System Settings → within a second or two the banner
      clears and onboarding flips to "You're all set", **without relaunching**
- [ ] With access still missing, panel works: add, check, search, copy — and
      shows the orange capture banner
- [ ] Revoke access while the app runs → within ~5 s the banner reappears and
      double-shift stops responding; re-grant → capture works again
- [ ] Dismiss onboarding with "Later" → status item right-click →
      Permissions… reopens it (shows "You're all set" when already trusted)
- [ ] Onboarding's "Open System Settings" lands on Privacy & Security →
      Accessibility

## Capture trigger configuration

- [ ] Status item right-click → Capture Shortcut → Double-tap ⌃ Control →
      double-tap Control captures; double-tap Shift no longer does
      (note: double-tap ⌘ conflicts with macOS's Type to Siri shortcut when
      that's enabled, and double-tap ⇧ conflicts with Karabiner SpaceCadet —
      Control and Option are the conflict-free choices)
- [ ] Capture Hotkey → ⌃⇧C → pressing it fires even with Accessibility
      revoked (Carbon hotkeys need no permission), but the capture itself is
      blocked: expect the onboarding/not-permitted flow, not a captured item
- [ ] Settings survive relaunch; the panel's empty-state hint matches the
      chosen modifier

## Double-tap detection (default: Shift)

- [ ] Double-tap Shift with a selection in TextEdit → captured
- [ ] Type "AAbbCC" quickly (shift-taps while typing) → never triggers
- [ ] Cmd+Shift+something shortcuts → never trigger
- [ ] Single shift tap, wait a second, single shift tap → does not trigger
- [ ] Double-shift while the Pewter panel itself is focused → still works
      (local monitor path)

## Selection reading

- [ ] Safari, TextEdit, Notes: capture works and the clipboard is **unchanged**
      afterwards (AX path — copy something first, capture, paste to verify)
- [ ] VS Code / Slack / a terminal: capture works and the previous clipboard
      contents come back (fallback path)
- [ ] Multi-line selection captures with line breaks intact
- [ ] Ghostty (plain shell): select output, double-tap → captures via the AX
      window walk (clipboard untouched)
- [ ] TUI with its own select-to-copy (Claude Code in a terminal): select,
      double-tap within ~3 s → captures via the recent-clipboard assist;
      waiting longer than ~3 s with no selection → "No text selected"
- [ ] Nothing selected + double-shift → status icon shows ✕, toast if panel
      open, clipboard untouched

## Status item menu

- [ ] Right-click the status item → menu opens just below the menu bar like
      other system menus, aligned with the icon, with every item visible —
      "Reveal Notes File in Finder" first, no scroll chevron at the top
- [ ] Status item near the right screen edge (Cmd-drag it as far right as it
      goes) → menu stays fully on screen
- [ ] Quit the app, then relaunch it right-to-left:
      `open build/Build/Products/Debug/Pewter.app --args
      -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`
      → right-click menu right-aligns with the icon (not offset to either
      side)

## Panel behavior

- [ ] Status-item click toggles the panel
- [ ] Typing in the panel does NOT deactivate the frontmost app (its title bar
      stays active)
- [ ] Panel floats above a full-screen app and follows across Spaces
- [ ] Esc: clears search if non-empty, else hides the panel
- [ ] Keyboard: ↑/↓ select, Space toggles, Enter edits, Delete removes,
      Cmd+C copies item, Cmd+Shift+C copies list, Cmd+F focuses search
- [ ] Hover a row → copy button appears on the right; click copies (brief
      checkmark); ⌥-click copies AND marks done (already-done items stay done)

## Storage

- [ ] `cat ~/Library/Application\ Support/Pewter/pewter.md` is readable
      markdown
- [ ] Edit that file in another editor while the app runs → panel updates
- [ ] Delete the file in Finder, recreate it with new content → panel updates
      (directory-watch fallback)
- [ ] `chmod 000` the notes file, relaunch → red "saving is off" banner; the
      file's bytes are untouched by any in-app edit; `chmod 644` + relaunch
      recovers
- [ ] Quit immediately after adding an item → item survived (flush on quit)
- [ ] An item with a blank line in the middle (captured multi-paragraph
      prompt) survives an external editor that strips trailing whitespace

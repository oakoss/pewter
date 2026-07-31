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
- [ ] Copy as List Style submenu switches the copy format between numbered
      (1. 2. 3., the default), bulleted (-), and task list (- [ ]); the
      choice persists across relaunch and applies to both Cmd+Shift+C and
      the context menu's Copy as List
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
- [ ] Esc: clears a multi-selection if one exists, else clears search if
      non-empty, else hides the panel (capture → Esc still hides in one
      press despite the new note being selected)
- [ ] Keyboard: ↑/↓ select, Space toggles, Enter edits, Delete removes,
      Cmd+C copies item, Cmd+Shift+C copies list, Cmd+F focuses search
- [ ] Hover a row → copy button appears on the right; click copies (brief
      checkmark); ⌥-click copies AND marks done (already-done items stay done)
- [ ] Select rows, then click into another app so it becomes frontmost —
      while it is still frontmost, look at the panel: selected rows keep the
      full accent fill, not just the outline (the panel never activates the
      app, so selection styling must not depend on app-active state)
- [ ] After that app has keyboard focus, click a row (not a text field) in
      the panel → Cmd+C copies from the panel again; the keystroke must not
      leak into the other app, and no status-item re-toggle is needed

## Multi-select

- [ ] Cmd+click adds/removes rows from the selection; Shift+click selects the
      range from the anchor — the last row you plain- or Cmd+clicked; plain
      click collapses to one
- [ ] Shift+↑/↓ extends the selection; crossing the starting row flips the
      range direction; plain ↑/↓ collapses to a single row again
- [ ] Cmd+A (list focused) selects all visible rows; with a filter active it
      selects only the matches
- [ ] Cmd+A while the search or quick-add field is focused selects the
      field's text and leaves the note selection alone
- [ ] Right-click Delete on an unselected row removes only it and leaves the
      existing multi-selection in place
- [ ] With several rows selected: Space marks all done (mixed selection
      converges; pressing again marks all not done); Delete removes them all
      and selects the nearest surviving neighbor
- [ ] Cmd+C with a multi-selection copies the notes separated by blank lines;
      Cmd+Shift+C copies just the selection as a list (single/no selection
      still copies the whole visible list)
- [ ] Right-click on a selected row → Copy / Copy as List / Mark as Done /
      Delete act on the whole selection; right-click on an unselected row
      acts on that row alone
- [ ] Checkbox and hover-copy-button always act on their own row, even when
      it is part of a multi-selection
- [ ] Changing the search filter drops now-hidden rows from the selection
- [ ] Clicking empty space in the list (below the rows) clears the selection
- [ ] Clicking into the composer ("Add a note or a prompt…") clears the
      selection; the note added on Return is selected as feedback
- [ ] Double-click a row → it enters edit mode and stays there (the
      single-click selection fires first and must not tear the editor back
      down); Esc cancels, Return commits
- [ ] Click a row, then press Space or Delete without any other click →
      they act on that row (a row click arms the list shortcuts)

## Undo for delete

- [ ] Delete a note mid-list, Cmd+Z (list focused) → it returns at its
      original position, selected, briefly highlighted, and scrolled into view
- [ ] Delete a multi-selection, Cmd+Z → every note returns at its original
      position and the restored set becomes the selection
- [ ] Cmd+Z again walks back through earlier deletes, one batch per press
- [ ] Edit a note's text to empty (which deletes it) → Cmd+Z brings it back
- [ ] Cmd+Z while the search or quick-add field is focused does not restore
      a note (the key keeps its text-field meaning)
- [ ] Delete a note, type a filter that would hide it, click the list to
      move focus off the search field, Cmd+Z → note is restored to the file
      but stays hidden; clearing the filter shows it unselected
- [ ] Delete a note, then edit the notes file in another editor → Cmd+Z does
      nothing (an external edit clears the undo history)

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

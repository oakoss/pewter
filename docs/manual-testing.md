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
      Accessibility (the deep link uses a legacy settings anchor — re-verify
      on each new macOS major)

## Settings window

- [ ] Status item right-click → Settings… opens an activating titled window;
      Esc does NOT close it (Esc is panel behavior); the red close button
      does; position survives reopen
- [ ] Launch at login toggle on → Pewter appears in System Settings →
      General → Login Items & Extensions; log out and back in (or reboot) →
      Pewter is running; toggle off → removed from Login Items
- [ ] Disable Pewter's login item in System Settings while the settings
      window is closed → reopening shows the toggle off; flipping it on
      shows the "Approve Pewter under Login Items to finish" hint with the
      Open Login Items… button (register lands in requiresApproval)
- [ ] With the settings window open and the approval hint showing, click
      Open Login Items…, approve Pewter in System Settings, and switch
      back → the toggle reads on and the hint clears (re-sync on app
      activation)
- [ ] The one-time "added items that can run in the background" system
      notification after first enable is expected macOS behavior — no
      Pewter bug
- [ ] Capture gesture picker → Double-tap ⌃ Control → double-tap Control
      captures; double-tap Shift no longer does; the panel's empty-state
      hint matches the chosen modifier
      (note: double-tap ⌘ conflicts with macOS's Type to Siri shortcut when
      that's enabled, and double-tap ⇧ conflicts with Karabiner SpaceCadet —
      Control and Option are the conflict-free choices)
- [ ] Capture selection → Change → badge flips to "Press shortcut…"; typing
      leaks nothing into fields behind it; Esc cancels recording and keeps
      the old value; a bare key or shift-only chord shows the inline
      "Include ⌃, ⌥, or ⌘" hint and keeps recording; a ⌘-only chord
      like ⌘Q shows the "would shadow a standard shortcut" hint (and does
      not quit) and keeps recording
- [ ] Any inline hint is fully visible when it appears — the form scrolls
      if space runs short; the hint row is never clipped
- [ ] With the settings window key, press ⌘, → it stays the settings
      window (the empty SwiftUI Settings scene never opens)
- [ ] Record ⌃⇧C for capture → pressing it fires even with Accessibility
      revoked (Carbon hotkeys need no permission), but the capture itself is
      blocked: expect the onboarding/not-permitted flow, not a captured item
- [ ] Show or hide panel → record ⌃⇧P → pressing it shows the panel from any
      app and pressing it again hides it; Turn Off stops it; both shortcuts
      survive relaunch; re-recording a different chord stops the old one
- [ ] While a shortcut is armed, press Change and then press that same
      chord → it is recorded (the live hotkey is suspended during
      recording), and re-armed on cancel
- [ ] Record a chord already claimed by another app → inline "shortcut is
      taken" error under the recorder and the previous shortcut keeps
      working — no toast, no panel popping open
- [ ] Record the capture shortcut's chord as the panel shortcut → inline
      "Already used by Capture selection" error, nothing re-registered
- [ ] Press Change, then close the window with the red close button →
      typing in the panel still works, armed shortcuts still fire, and
      reopening Settings shows the recorder idle
- [ ] Press Change on one shortcut, then Change on the other → the first
      recorder returns to idle; only the second records
- [ ] Press Change, then click into another app (or summon the panel) →
      recording cancels when Settings loses key; typing elsewhere is not
      swallowed
- [ ] Press Change, then switch the Capture gesture picker → the gesture
      choice applies but the tap monitor and hotkeys stay suspended until
      recording ends (no capture can fire mid-recording)
- [ ] While recording, double-tap the capture modifier → no capture fires
      (the tap monitor pauses during recording, and resumes after)
- [ ] Bind the suspended chord in another app while recording → on cancel
      the badge flips to Off with the inline "Another app claimed this
      shortcut" hint (no toast)
- [ ] Copy as List style picker switches the copy format between numbered
      (1. 2. 3., the default), bulleted (-), and task list (- [ ]); persists
      across relaunch and applies to both Cmd+Shift+C and the context
      menu's Copy as List
- [ ] About shows the version; the GitHub link opens the repo
- [ ] With both hotkeys set (capture ⌃⇧C, panel ⌃⇧P), each fires its own
      action — neither swallows the other
- [ ] Quit Pewter, bind its panel chord in another hotkey utility, then
      relaunch → the panel appears with the "Couldn't set up the panel
      hotkey" toast and Settings shows the shortcut Off; same flow for the
      capture chord (launch-time arming is the only toast path)

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
- [ ] The menu is a launcher only: Reveal Notes File, Settings…,
      Permissions…, Quit — no configuration submenus
- [ ] Menu bar style set to Tinted (macOS 26, Appearance settings) with
      Reduce Transparency on → the status icon stays legible
- [ ] Status item near the right screen edge (Cmd-drag it as far right as it
      goes) → menu stays fully on screen
- [ ] Quit the app, then relaunch it right-to-left:
      `open build/Build/Products/Debug/Pewter.app --args
      -AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`
      → right-click menu right-aligns with the icon (not offset to either
      side)

## Panel behavior

- [ ] Status-item click toggles the panel
- [ ] Ellipsis (…) button at the right of the search field renders bare
      (no bordered button background or chevron) and opens the launcher
      menu from the non-activating panel: Settings…, Reveal Notes File in
      Finder, Permissions…, Quit Pewter — every item fires, and Settings…
      brings its window frontmost
- [ ] Permissions… opens the onboarding window even when access is
      already granted (shows "You're all set")
- [ ] Clicking the ellipsis does not steal focus from the frontmost app's
      title bar (panel stays non-activating until a menu item runs)
- [ ] Typing in the panel does NOT deactivate the frontmost app (its title bar
      stays active)
- [ ] Panel floats above a full-screen app and follows across Spaces
- [ ] Esc: clears a multi-selection if one exists, else clears search if
      non-empty, else hides the panel (capture → Esc still hides in one
      press despite the new note being selected)
- [ ] Keyboard: ↑/↓ select, Space toggles, Enter edits, Delete removes,
      Cmd+C copies item, Cmd+Shift+C copies list, Cmd+F focuses search
- [ ] Select two or more notes → Cmd+Shift+M (or right-click → Merge
      Notes) merges them into the topmost note's position, texts joined
      in list order with a blank line between them; the merged note is
      selected, briefly highlighted, and scrolled into view;
      done state carries over only when every source was done
- [ ] Cmd+Z after a merge restores the original notes exactly (the
      merged note splits back apart); Merge Notes shows grayed out in the
      context menu with a single selection, and Cmd+Shift+M does nothing
      while typing in a text field
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

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
      "Already used by Capture selection" error, nothing re-registered,
      and the recorder keeps recording (pick another chord or Esc)
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
      relaunch → the panel appears with the "Couldn't set up the Show or
      hide panel shortcut" toast and Settings shows the shortcut Off; same
      flow for the capture chord (launch-time arming is the only toast
      path)

## Double-tap detection (default: Shift)

- [ ] Double-tap Shift with a selection in TextEdit → captured
- [ ] Type "AAbbCC" quickly (shift-taps while typing) → never triggers
- [ ] Cmd+Shift+something shortcuts → never trigger
- [ ] Single shift tap, wait a second, single shift tap → does not trigger
- [ ] Double-shift while the Pewter panel itself is focused → still works
      (local monitor path)

## Selection reading

- [ ] TextEdit, Notes: capture works and the clipboard is **unchanged**
      afterwards (AX path — copy something first, capture, paste to verify)
- [ ] Safari or Chrome: capture works and the previous clipboard contents
      come back (browsers route to the pasteboard tier so formatting
      survives; the AX read is only their rescue)
- [ ] VS Code / Slack / a terminal: capture works and the previous clipboard
      contents come back (fallback path)
- [ ] Multi-line selection captures with line breaks intact
- [ ] Ghostty (plain shell): select output, double-tap → captures via the AX
      window walk (clipboard untouched)
- [ ] TUI with its own select-to-copy (Claude Code in a terminal): select,
      double-tap within ~3 s → captures via the recent-clipboard assist;
      waiting longer than ~3 s with no selection → "No text selected"
- [ ] Same TUI, third selection + capture → near-instant feedback (the
      first two captures teach that the app's synthetic copies are dead —
      one coincidence must not classify an app; later ones skip straight
      to the assist). Quitting and relaunching the terminal app keeps it
      fast (trust is per-app, not per-process); relaunching Pewter resets
      the learning. Roughly every eighth fast capture deliberately runs
      the slow sequence again to re-verify the app still behaves this way
- [ ] Nothing selected + double-shift → status icon shows ✕ and a "No text
      selected" HUD appears near the caret (or mouse), clipboard untouched
- [ ] Capture the same selection twice within ~2 s (double-tap fired twice,
      or tap then hotkey) → one note; when the second fire lands after the
      first completes, it re-highlights the existing note (a fire during
      the fallback capture is swallowed by the in-flight guard instead).
      Capture the same selection again after more than 2 s → a second
      note (the window is inclusive at exactly 2 s)
- [ ] Capture, delete the note, capture the same selection within 2 s →
      a fresh note appears (deleting opts out of the duplicate guard)

## Rich-text capture (pasteboard tier)

Conversion happens on the pasteboard tier. Browsers prefer that tier so
formatting survives; other apps reach it only when the AX read fails, and
an AX answer delivers plain text that passes through untouched.

- [ ] Select web content with bold, a link, and a bullet list in Chrome or
      Safari, double-tap → the captured note holds `**bold**`,
      `[text](url)`, and `-` list lines, with block boundaries on their own
      lines (no mashed `sentence.Next` joins)
- [ ] Same capture in a browser with something on the clipboard → the
      previous clipboard contents come back afterwards
- [ ] Copy code from VS Code → captured as exact plain text with
      indentation intact (its clipboard HTML carries styling but no
      semantic structure, so the converter steps aside for the plain
      flavor)
- [ ] Copy code from a web page's `<pre>` block → captured as a fenced
      code block
- [ ] Plain-text source (terminal shell output) → captured byte-identical:
      no markers appear, `*stars*` and `_underscores_` in the text stay as
      typed
- [ ] TextEdit rich-text document (RTF flavor, no HTML): bold/italic/lists
      convert; a fully monospaced paragraph becomes a fenced line, and a
      code fragment inside a sentence stays `inline code`
- [ ] An indented (⌘]) TextEdit paragraph captures as plain text — no `>`
      quote marker (RTF indentation is layout; quotes convert only from
      HTML's explicit blockquote)
- [ ] A huge rich selection → conversion happens first, then the length cap
      (note ends with … at 20k)
- [ ] After a rich capture the previous clipboard contents still come back

## Capture feedback (HUD)

- [ ] Capture in TextEdit with the panel closed → a "Captured" capsule
      appears just below the selection and fades out; the panel stays
      closed and TextEdit keeps focus (keep typing — no keystroke is lost)
- [ ] Capture a selection near the bottom of the screen → the HUD flips
      above the selection instead of clipping offscreen
- [ ] Capture in a browser (pasteboard tier — no AX element) → the HUD
      anchors at the mouse pointer
- [ ] Ghostty plain shell: select output, capture → the HUD anchors at
      the selection (the window walk that found the text also reads its
      bounds)
- [ ] Capture with the panel already open → the HUD still shows, and the
      new note scrolls into view highlighted; the panel does not move
- [ ] Two captures in quick succession → the second HUD replaces the first
      and stays up its full duration (no early disappearance, none stuck)
- [ ] Capture over a full-screen app → the HUD is visible above it
- [ ] The HUD never takes clicks: mouse through where it showed while
      fading → clicks land in the app underneath

## Status item menu

- [ ] Right-click the status item → menu opens just below the menu bar like
      other system menus, aligned with the icon, with every item visible —
      "Reveal Notes File in Finder" first, no scroll chevron at the top
- [ ] The menu is a launcher only: Reveal Notes File, Settings…,
      Permissions…, Copy Diagnostics, Quit — no configuration submenus
- [ ] Copy Diagnostics after a few captures → clipboard holds a report with
      an app/macOS version header and timestamped entries, including the
      info-level capture decisions (e.g. flavor skips); the status icon
      flashes a clipboard symbol
- [ ] The report header states the active settings — trigger, both hotkey
      chords (or "off"), Accessibility state, Launch at login — matching
      what the settings window shows
- [ ] Delete, merge, and undo in the panel, edit the notes file externally,
      change the trigger or a hotkey → each leaves a breadcrumb in the next
      Copy Diagnostics report (counts and chord names, never note text)
- [ ] Copy Diagnostics from the panel's ellipsis menu with the panel open →
      same report, plus a "Diagnostics copied" toast
- [ ] Copy Diagnostics right after a fresh launch with no activity →
      report renders with "No log entries in the window." (or only the
      launch entries), not an error
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
- [ ] Cmd+N moves focus to the composer from the list, the search field,
      and mid-edit of a note
- [ ] Cmd+N with an active search filter clears it — the note added next is
      visible in the list
- [ ] Cmd+W hides the panel from the list, the search field, and the
      composer
- [ ] Cmd+W while editing a note → panel hides; reopening shows the note
      with its original text (the in-progress edit is discarded, same as
      clicking away)
- [ ] Esc keeps its ladder outside an edit (clear multi-selection → clear
      filter → hide); while editing, Esc cancels the edit and the panel
      stays up
- [ ] Drag the panel's edge as narrow/short as it will go → it stops at a
      usable minimum (320×360) instead of clipping the list into a sliver
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
- [ ] Two displays: drag the panel to display A, hide it, move the mouse
      to display B → the panel hotkey summons it onto display B at the
      same offset from the top-left; hide it and summon again on A → back
      at the original spot (round trip — exact only while the panel lands
      fully inside both displays; if a move has to clamp, the clamped
      frame becomes the new saved position)
- [ ] Two displays: capture (double-tap or hotkey) on display B while the
      panel's saved frame is on A → the panel stays hidden; the "Captured"
      HUD appears on B near the selection
- [ ] Two displays: with the panel's saved frame on A, clicking the status
      item on either display shows it at its saved position on A (only the
      hotkey follows the active screen)
- [ ] Esc: clears a multi-selection if one exists, else clears search if
      non-empty, else hides the panel (capture with the panel open → Esc
      still hides in one press despite the new note being selected)
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
- [ ] A note longer than 6 lines shows "Show more" under the clamped text;
      a short note shows no disclosure. Click it → the full text appears
      instantly (deliberately unanimated — an animated frame lags the text
      view's re-clamp and flickers); the label flips to "Show less" and
      clicking again re-clamps
- [ ] Cmd+E with a selection expands it; Cmd+E again collapses. A mixed
      selection (some expanded) fully expands first, then a second press
      collapses. Short notes swept up in the selection (e.g. via Cmd+A)
      never show a disclosure. While typing in the search or quick-add
      field, Cmd+E does nothing to the list
- [ ] Expansion is transient and per-note: search-filter an expanded note
      away and clear the filter → still expanded AND still showing "Show
      less"; scroll an expanded note far off-screen and back → still
      expanded, still showing "Show less"; hide and reopen the panel →
      still expanded; relaunch Pewter → collapsed
- [ ] Collapse a tall expanded note scrolled deep in the list (chevron or
      Cmd+E) → the collapsed row scrolls back into view; the list is never
      left showing a blank viewport past the end of the content
- [ ] Cmd+E on a short note (or a selection of only short notes) changes
      nothing visibly — no disclosure appears, before or after
- [ ] Expand a long note, then edit it down to a couple of lines → the
      disclosure disappears (nothing is clamped anymore) and the note
      renders normally; links in the revealed lines of an expanded note are
      clickable with the pointing-hand cursor
- [ ] Select rows, then click into another app so it becomes frontmost —
      while it is still frontmost, look at the panel: selected rows keep the
      full accent fill, not just the outline (the panel never activates the
      app, so selection styling must not depend on app-active state)
- [ ] After that app has keyboard focus, click a row (not a text field) in
      the panel → Cmd+C copies from the panel again; the keystroke must not
      leak into the other app, and no status-item re-toggle is needed

## Links and cursors

- [ ] Capture rich text containing a link from a browser (or add a note
      with `[text](https://example.com)`) → the link renders in link color
      with an underline; the rest of the note stays plain
- [ ] Hover the link → pointing-hand cursor; hover the surrounding note
      text → default arrow
- [ ] Click the link → opens in the default browser; the row does NOT
      become selected and the panel stays non-activating
- [ ] Click the note's plain text → selects the row (link untouched);
      double-click plain text → enters edit mode showing the raw markdown
- [ ] Press down on a link, drag off it, release → nothing opens
      (drag-off cancels, matching button behavior)
- [ ] Double-click a link → opens exactly once (no second tab, no edit
      mode)
- [ ] Click just past the end of a line that ends in a link → selects the
      row, nothing opens
- [ ] Hover a link → the row's hover copy button stays visible
- [ ] Control-click a link → the Open Link / Copy Link menu appears and
      nothing navigates
- [ ] Hover a link, then the checkbox, then the copy button, then back to
      the link in quick succession → cursor tracks pointing hand / arrow
      correctly at each stop (sliding from a button directly onto a link
      must not leave an arrow stuck over the link)
- [ ] Right-click a link → Open Link / Copy Link menu (Copy Link puts the
      URL on the clipboard); right-click on plain text → the row's normal
      context menu (Copy, Edit, Delete…)
- [ ] A done note with a link keeps strikethrough + secondary color on its
      plain text; the link still opens
- [ ] Bold/italic/inline-code markdown still renders styled in rows
- [ ] Long notes still truncate at 6 lines; a link in the visible lines
      still opens
- [ ] A note that is entirely one link: select it with ↑/↓ and press
      Enter → edit mode still reachable (its text offers no plain-text
      click target)
- [ ] Hand-edit the notes file to give a note a `file:///` or
      `javascript:` destination → the label renders as plain text: no
      link color, no pointing hand, click selects the row
- [ ] Externally edit the notes file to change a link's text or URL while
      the panel is open → the row re-renders and the click target and
      pointing-hand region follow the new link
- [ ] Pointing-hand cursor on hover over: row checkbox, hover copy button,
      the ellipsis menu button, and the permission banner's Enable… button
- [ ] Hover the copy button, then move the mouse straight off the row (the
      button disappears) → cursor returns to the arrow, not stuck as a
      pointing hand

## Sections

- [ ] Add `## Research` and `## Config` heading lines to the notes file in an
      external editor, with notes under each → the panel groups the notes
      under uppercase section headers in file order; notes above the first
      heading render first, without a header
- [ ] A heading with no notes under it still shows its header
- [ ] `# Title` and `### Deep` lines do NOT create sections
- [ ] Search: a query matching a section's name shows that whole section
      (all its notes); otherwise only sections with matching notes keep
      their header, narrowed to those notes; clearing the search restores
      all sections
- [ ] Search matching only an empty section's name shows that header alone —
      no "No matches" beneath it
- [ ] Headings keep their original casing in the file (uppercase is
      display-only); adding/completing/deleting notes leaves heading lines
      untouched
- [ ] Keyboard: ↑/↓ walk rows straight across section boundaries; Cmd+A
      selects rows in every section
- [ ] With sections present: Cmd+Z after a delete and after a merge still
      scrolls to and flashes the restored/merged note (rows sit one ForEach
      level deeper, so reveal-by-id is worth re-checking)
- [ ] Quick-add and capture append to the end of the file, so with headings
      present new notes land under the last section (expected for now —
      routing to a chosen section is separate upcoming work)
- [ ] With headings present, start editing a note inline, then edit a
      DIFFERENT part of the notes file externally → the reload keeps the
      row's uncommitted edit text and focus (section identity must survive
      a re-parse)

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

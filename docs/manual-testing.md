# Manual test checklist

Capture and permissions can't run in CI (no Accessibility grant on runners).
Run through this before release, and after any change to `App/Sources/Capture/`
or the status item / panel / window layer.

Panel-state items don't have to be judged by eye. With the panel open,
`swift tools/axdump.swift --grep panel.` prints every element the panel
exposes, keyed by the identifiers in `PanelAccessibilityID` — so "the banner
names the permission repair" or "the refused draft is still in the field"
become strings you can read rather than questions you answer from memory.
Transient surfaces need the dump run while they are up; the refusal toast
clears after four seconds.

Selection state reads correctly from a terminal dump even though running
axdump takes key away from the panel — checked 2026-08-11 on macOS 26.5 by
selecting all in the composer and dumping from the terminal, which still
reported the full range. Re-check it the same way if a `sel=` item ever fails
in a way that smells like the instrument rather than the app.

What the range will not do is track your own typing: it reports what the app
last set, so read it before editing the field, not after. Assertions about a
caret the app just placed are sound; assertions about one you moved are not.

## Permissions

- [ ] `tccutil reset Accessibility com.oakoss.Pewter` and
      `defaults delete com.oakoss.Pewter onboardingDeclined`, launch →
      onboarding window appears
- [ ] Grant access in System Settings → within a second or two the banner
      clears and onboarding flips to "You're all set", **without relaunching**
- [ ] With access still missing, panel works: add, check, search, copy — and
      shows the orange capture banner
- [ ] Revoke access while the app runs → within ~5 s the banner reappears and
      double-shift stops responding; re-grant → capture works again
- [ ] Dismiss onboarding with "Later" (or the close button) → status item
      right-click → Permissions… reopens it (shows "You're all set" when
      already trusted)
- [ ] Dismiss with "Later" (or the close button) while untrusted → relaunch →
      onboarding does NOT reappear; the orange banner still shows, its
      Enable… button reopens onboarding, and so does a capture attempt
      (double-shift)
- [ ] Grant access, then revoke it → next launch shows onboarding once again
      (granting clears the recorded decline; test both ways — grant while
      Pewter is running, and grant from System Settings while it's quit,
      before revoking)
- [ ] Launch untrusted with no decline recorded, Cmd+Q with onboarding still
      open → relaunch → onboarding appears again (quitting is not a decline)
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
      first completes, it re-surfaces the existing note — scrolled into
      view and briefly highlighted, even though no note was added (a fire
      during the fallback capture is swallowed by the in-flight guard
      instead).
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
      menu from the non-activating panel with the same items and order as
      the status item's menu: Reveal Notes File in Finder, then Settings…,
      Permissions…, Copy Diagnostics, then Quit Pewter — every item fires,
      and Settings… brings its window frontmost
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
- [ ] Quick-add with the list scrolled to the top of many notes → the new
      note is selected, briefly highlighted, and scrolled into view; with
      an active search filter, quick-add clears the filter first so the
      new note is visible
- [ ] Delete a mid-list note with the tail off-screen → the viewport stays
      put (no jump to the end of the list)
- [ ] With 300+ notes (populate a scratch copy of the notes file), typing
      in search or quick-add keeps up with the keystrokes — no visible
      lag from the eager list re-rendering every row
- [ ] Switch System Settings → Appearance between Light and Dark with the
      panel open → note text, strikethrough, and link color all follow
      (cached renders hold dynamic colors, not resolved ones)
- [ ] Capture with the panel hidden and the list scrolled to the top,
      wait a few seconds, summon the panel → the list is scrolled to the
      new note (the reveal target survives until the next summon)
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
      the ellipsis menu button, the permission banner's Enable… button, and
      the storage banner's Reveal button
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

## Shortcut guide (Cmd+/)

- [ ] Cmd+/ with the list focused (or nothing focused) → an overlay lists
      the shortcut groups; the capture line matches the configured trigger
- [ ] Cmd+/ while typing in search, quick-add, or a note editor does
      nothing — the guide never covers a focused text field
- [ ] While the guide is open: arrows, Space, Return, Delete, Cmd+Z, Cmd+C,
      Cmd+F, Cmd+N do nothing; Esc closes the guide without touching the
      selection or filter; Cmd+/ toggles it closed; a click anywhere closes
- [ ] Cmd+W with the guide open hides the panel AND closes the guide — the
      next summon shows the list, not the overlay
- [ ] Change the tap modifier in Settings, reopen the guide → the capture
      line reflects the new trigger
- [ ] When a panel binding changes in code, the guide's table changes in the
      same PR (check the diff touches ShortcutGuideView.swift)

## VoiceOver

- [ ] VO to a note row → reads the note text with "Done" or "Not done" as
      the value; done state is never conveyed by strikethrough alone
- [ ] Hover the pointer over an unselected row with VO running → the row is
      spoken (rows must not be skipped as unknown elements)
- [ ] VO-arrow through the list → every row is reachable in order, and the
      list container announces as "Notes", not a bare "scroll area"
- [ ] VO to the search and quick-add fields → they announce as "Search
      notes" and "New note"
- [ ] Activate a row (VO-Space) → it becomes selected
- [ ] VO to a selected row (activate it, then re-read it) → it still
      speaks the note text plus "Done"/"Not done"; selection must not
      empty the label
- [ ] With a row's inline editor open, VO-Space on the row → the editor
      stays up and the uncommitted text survives (the row's activation is
      inert while editing)
- [ ] Row actions menu (VO-⌘-Space) lists Edit, Mark as Done/Not Done,
      Copy, Expand/Collapse (long notes), Delete — each acts on that row
      only
- [ ] Select three notes (shift-arrow), VO to one of them, invoke Delete →
      only that row is deleted, not the selection
- [ ] Invoke Edit from the row actions menu → the text field takes VO focus
      and typed text lands in the note
- [ ] The row's checkbox is not exposed separately (no double-speak of the
      done state)
- [ ] With VO running, rest the pointer on a row's copy button and on its
      checkbox → they announce "Copy" and "Mark as done"/"Mark as not
      done", and the row itself still reads only the note text plus its
      value
- [ ] GATING: capture from another app with VO running → the outcome is
      audible without looking, as a distinct sound per result (captured /
      nothing selected / capture failed / unreadable notes / adoption in
      flight), and all five are tellable apart by ear. Speech is deliberately
      not the channel: macOS speaks announcements only for the frontmost app
      and the capture source is frontmost by design — if nothing is audible,
      the feedback design needs rework, not a checked box
- [ ] Two captures in quick succession with VO running → a repeat of the
      same outcome restarts its sound; two different outcomes both stay
      audible (losing the first would hide that a capture failed)
- [ ] With VoiceOver's speech routed to a different output device than the
      system default, capture → the sound follows the system default, so it
      may be inaudible; accepted limitation, no in-process way to detect it
- [ ] With VO running and the notes file unreadable, capture → the
      notes-unavailable sound plays and is distinct from the capture-failed
      one; the remedies differ (fix the file vs fix the selection), so
      hearing them as the same would send the user to debug the wrong thing
- [ ] OPPORTUNISTIC — same unforceable window as its storage-section twin.
      With VO running, a refused capture plays the adoption-in-flight sound,
      distinct from the notes-unavailable one. By ear these are the only thing
      separating "go and repair your file" from "press the key again". Both
      sounds are confirmed present, so silence is not a missing asset — but
      it is not proof the window was missed either, since the output-device
      limitation above makes any sound inaudible. Record silence as
      unconfirmed, never as a pass
- [ ] With VO running and the notes file unreadable, VO-navigate the empty
      list → it announces "Notes unavailable". The symbol restates the
      message, so leaving it visible to VoiceOver makes it the stop and the
      words are never reached — the state then reads as an ordinary empty
      list, which is the one thing this empty state exists to prevent
- [ ] With VO running and the notes file unreadable, VO-focus the panel's
      composer → it is still reachable (not skipped as dimmed) and its hint
      reads "Unavailable until your notes file can be read"; type and press
      Return → the refusal is announced and focus stays on the field
- [ ] Capture with VO turned off → no sound (the HUD is the feedback;
      capture stays silent for everyone else)
- [ ] Turn VO on without relaunching Pewter, then capture → the sound
      plays (the gate is read per capture, not cached at launch)
- [ ] Copy Diagnostics from the status item with the panel open → the
      outcome is announced once, not twice (the toast suppresses its own
      announcement when the flash carried it)
- [ ] Panel-only toasts (e.g. a shortcut arming failure at launch) are
      announced
- [ ] Open the guide (⌘/) with VO running → it announces as "Keyboard
      shortcuts" and VO-arrow drills into the content: title, capture
      hint, group headers (reachable via the rotor's headings list), and
      each shortcut's keys spoken as names ("Shift Command Z"), not
      Unicode symbols, ending on the footer read as "Escape or Command
      slash closes this guide."
- [ ] With the guide open, the notes list, search, and quick-add are not
      reachable by VO (the panel hides its content from the accessibility
      tree while the guide is up)

## Redo (Shift-Cmd-Z)

- [ ] Delete a multi-selection, Cmd+Z, Shift-Cmd-Z → all the notes vanish
      again and the selection drops every one of them
- [ ] Merge two notes, Cmd+Z, Shift-Cmd-Z → the merged note reappears,
      selected, briefly highlighted, and scrolled into view
- [ ] Delete, Cmd+Z, Shift-Cmd-Z, Cmd+Z → the note is back (redo is itself
      undoable)
- [ ] Delete, Cmd+Z, then add a note (or toggle one done) → Shift-Cmd-Z
      does nothing (a fresh change forks history and clears redo)
- [ ] Shift-Cmd-Z while the search or quick-add field is focused does not
      re-delete (the key keeps its text-field meaning)
- [ ] Shift-Cmd-Z while editing a note's text redoes the text edit, never a
      note re-delete (editor focus keeps the key)
- [ ] Merge, Cmd+Z, type a filter that hides the would-be product, click
      the list, Shift-Cmd-Z → the merge re-applies in the file but stays
      hidden; clearing the filter shows the merged note unselected
- [ ] Cmd-Opt-Z and Cmd-Opt-Shift-Z stay unclaimed by the panel (no note
      restore or re-delete)

## Storage

- [ ] `cat ~/Library/Application\ Support/Pewter/pewter.md` is readable
      markdown
- [ ] Edit that file in another editor while the app runs → panel updates
- [ ] Delete the file in Finder, recreate it with new content → panel updates
      (directory-watch fallback)
- [ ] `chmod 000` the notes file, relaunch → red "saving is off" banner; the
      file's bytes are untouched by any in-app edit; `chmod 644` + relaunch
      recovers
- [ ] That banner names the *permission* repair ("check its permissions"), and
      a non-UTF8 file's banner names the *encoding* one ("re-save it as
      UTF-8") — two causes must not render one string, or half the users are
      sent to debug something that was never wrong
- [ ] Either banner has a Reveal button that opens the notes file in Finder.
      Without it the banner names a file the user has never been told the
      location of
- [ ] `chmod 000` the notes file, relaunch, open the panel → the list reads
      "Notes unavailable", not the capture hint: an empty list here would be
      indistinguishable from a fresh install
- [ ] With that same unreadable file, type into the composer and press Return
      → a toast names the repair for that cause, the text stays in the field,
      and nothing is added
- [ ] That refusal toast reads as a distinct surface against the translucent
      panel — visible capsule edge and shadow, not floating text — and carries
      a leading warning-triangle symbol. Compare it against a confirmation
      toast (Copy Diagnostics with the panel open): the two must not look
      alike, since one says the work landed and the other says it was thrown
      away. Check in both light and dark appearance, and with System Settings
      → Accessibility → Display → Reduce Transparency on, since the design
      leans on materials
- [ ] Walk every *other* mutation and confirm each refuses rather than
      appearing to work. This needs its own setup — do NOT chain it off the
      `chmod 000` + relaunch above, which loads a placeholder with an empty
      list, leaving no row to click, no selection to delete and no two rows
      to merge. Instead: with real notes loaded, delete two notes separately,
      then press Cmd+Z *once* — undo moves a batch from one stack to the
      other rather than copying it, so a single delete-then-undo would leave
      the undo stack empty and Cmd+Z below would report nothing to do instead
      of refusing. Then `chmod 000` the file *without relaunching* and summon
      the panel, which retries and notices the break.
      Now: click a row's checkbox, Space on a selection, Delete on a
      selection, the context menu's Delete and Mark as Done, Cmd+M on two
      selected rows, Cmd+Z, Cmd+Shift+Z. Each shows the same repair toast the
      composer does and leaves the list untouched — no row vanishes, no
      checkbox flips — and none of the shortcuts draws an alert beep, since a
      refusal is handled rather than passed along the responder chain. Before
      the refusal moved into the store these all reported success for a change
      that never reached disk, and the undo cases were worse than they looked:
      the batch was consumed on the way out, so the retry the toast asks for
      had nothing left to restore
- [ ] Still unreadable, Return on a row to edit it, change the text, press
      Return → the toast appears and *the editor stays open with the edit in
      it*, the same way the composer keeps its draft. Closing it would throw
      the text away at the one moment it cannot be recovered from disk, and
      submit resigns first responder, which independently tears the editor
      down — so this is checking that the commit path puts it back. Then
      `chmod 644` and press Return in that same editor → the edit commits with
      no relaunch and no re-summon: every mutation path re-reads the file the
      way the composer does, which is the only thing that can notice a
      permission repair (it fires no watcher event)
- [ ] Same again, but repair the file by *rewriting* it from another editor
      while a row editor is open, then press Return. A rewrite is adopted
      rather than reconciled, so which of two things happens depends on
      whether the rewritten line kept its `<!--sl id=…-->` metadata — check
      both:
  - [ ] Rewrite keeping the edited note's `id=` → the toast reads "Your notes
        just changed on disk — try again" and the editor stays open holding
        what you typed, not what the file now says
  - [ ] Rewrite dropping that note's line (or its `id=`, which mints a new
        one) → the note being edited no longer exists, so there is no editor
        to return to. The typed text moves into the composer, which takes
        focus, and the search field is cleared so it is visible. Losing it
        would be the one thing here that cannot be recovered from disk. The
        toast must read "That note is gone — your edit moved to the new-note
        field", NOT "try again" — there is nothing left to retry against
  - [ ] The same, but with something already typed in the composer first →
        the rescued edit is appended below a blank line and the toast reads
        "That note is gone — your edit was added to your draft". They
        become one note on Return, since
        the composer never splits on newlines; the blank line is what makes
        the seam visible enough to split by hand
- [ ] An adoption clears both history stacks, so nothing from before an
      external rewrite may ever replay. Build both stacks first with the
      two-delete/one-undo setup above — checking only one would leave a stale
      redo entry free to come back. With the panel open, rewrite the file
      externally, then press Cmd+Z and Cmd+Shift+Z. Neither may resurrect a
      note from before the rewrite; that is the whole assertion here.
      Whether you get the "Your notes changed on disk — undo history was
      cleared" toast or the ordinary nothing-to-do beep is a race and both
      are correct: the toast belongs to the case where the keypress's own
      retry discovers the rewrite, and with the panel open the watcher
      usually adopts first, which leaves simply an empty history. To see the
      toast deliberately, make the change where the watcher can't see it —
      the same trick the `chmod` items above rely on
- [ ] With that same unreadable file, select text in another app and
      double-tap Shift → the HUD reads "Can't read your notes file — check its
      permissions", rather than appearing to capture. The matching sound plays
      only with VoiceOver running — capture is silent for everyone else by
      design, so turn VO on before expecting one (see the VoiceOver section).
      A non-UTF8 file instead reads "Can't read your notes file — re-save it
      as UTF-8": the HUD names the same repair the banner does
- [ ] Still with the app running, `chmod 644`, then summon the panel, press
      Return in the composer, or capture again → the notes reappear, the red
      banner clears, and saving works, with no relaunch. A mode change fires
      no watcher event and every input is refused, so one of those retries is
      what re-reads the file
- [ ] Same, but recover via capture alone: with the panel never opened,
      `chmod 644` and double-tap Shift → the capture lands. A capture-only
      user has no other way back
- [ ] Delete the notes file entirely and relaunch → the empty state shows the
      capture hint, NOT "Notes unavailable" — a fresh install must not look
      like a broken one
- [ ] Same again but leave the panel open the whole time: `chmod 644`, then
      press Return in the composer → recovers without hiding the panel first
- [ ] With the file unreadable, type in the composer and press Return → the
      text stays in the field *and* the composer keeps focus, so Return can
      be pressed again once the file is repaired
- [ ] After that refusal, the caret sits at the *end* of the kept draft with
      nothing selected: `swift tools/axdump.swift --grep panel.composer`
      reads `sel=(N,0)`, N being the draft's *UTF-16* length — type plain
      ASCII and it is the character count. Anything else fails: `(0,N)` is
      the original bug, `(0,0)` on a non-empty draft is a caret at the
      start, the `sel=«…»` forms mean the range could not be read, and no
      `sel=` at all means axdump's role gate did not recognise the composer
      — a tooling gap, not a caret bug. Then type one character: it appends
      and the draft is intact, which is the symptom the fix exists for and
      the only check that survives the whole instrument chain failing. Dump
      before typing: the reported range is what the app last set, and it
      does not reliably follow your own edits — a dump taken afterwards can
      still read the pre-typing figure. The collapse hangs off the refusal
      rather than its cause, so the reason does not matter here
- [ ] The same, with the search field left holding the *same* text as the
      draft: search for a phrase, get no match, then **click** into the
      composer and type that phrase. Not Cmd+N — that clears the query and
      silently turns this back into the ordinary case. Dump with
      `--grep panel.` and read both fields: `panel.composer` is `sel=(N,0)`
      and the search field is untouched. One shared field editor serves
      both, and identical text defeats the draft check, so focus is the only
      thing keeping the collapse on the right field. The log cannot catch a
      miss here — it would report `collapsed: (N,0)` for the *search* field,
      and identical text makes that range indistinguishable from a pass — so
      the dump is the only witness
- [ ] Refuse a draft, dismiss with Esc, summon again → the draft is still
      there. Clear the search field first, or Esc clears the filter instead
      of hiding. This does not test the hidden-panel lookup — the collapse
      finishes within 60ms of Return, far quicker than a key can follow it,
      so that branch is not reachable by hand
- [ ] The same refusal with a pasted draft long enough to scroll the
      five-line composer — 20 numbered lines of a few words each. The last
      line is on screen with the caret after it, no scrolling needed.
      Whether it is *visible* is eye-only — a range says nothing about what
      is on screen, and `value=` truncates at 60 characters — but dump it
      anyway and keep the `sel=` figure for the log item below
- [ ] None of the above logged `refusal caret collapse failed`, and each one
      logged `refusal caret collapsed: (N,0)` matching the `sel=` its dump
      reported — Copy Diagnostics includes debug entries, so the successes
      are readable there too, not just the failures. Redo one refusal immediately before
      reading: the window is the last ten minutes of *this* process, so a
      slow pass through the items above or any relaunch leaves an empty
      report that would pass by construction. Not `mise run logs` — a live
      tail with no backfill shows nothing whatever the app recorded
- [ ] Re-save an unreadable (non-UTF8) notes file as UTF-8 in an editor while
      the app runs → the panel recovers on its own via the watcher, with no
      summon needed; this is the repair the watcher can see
- [ ] `chmod 000` the notes file with the app still running (a mode change
      fires no watcher event), then type a note and press Return → it is
      *refused*, not accepted: the banner appears without a relaunch, a toast
      names the permission repair, the draft stays in the field, and the file's
      bytes are untouched. The composer's own Return is what notices the
      break — no save has failed yet, so nothing else knows. `chmod 644` and
      press Return again → saving resumes, still without a relaunch, and the
      draft that was held in the field lands
- [ ] The same break, but capture instead of the composer → the capture is
      refused with the same permission wording on the HUD. Unlike the composer
      there is no draft to hold, so the text is gone; reporting "Captured"
      there is the failure this refusal exists to prevent
- [ ] The same runtime break, recovered by capture alone: `chmod 000` with the
      app running, capture once (refused), `chmod 644`, capture again → it
      lands. Distinct from the launch-time capture-only item above, and the
      case that actually regressed: a runtime break leaves the document real,
      so a retry keyed on the placeholder flag does nothing and the user is
      refused until they relaunch
- [ ] OPPORTUNISTIC — cannot be forced by hand, so an unticked box here is
      not a defect. Editing the notes file outside the app opens a handoff
      window of a few milliseconds between storage adopting the new content
      and the store receiving it; a capture landing inside it is refused.
      Measured 2026-08-06: 51 captures against a file rewritten every
      40–120ms never once hit it. The refusal itself is covered by
      `CaptureCoordinatorTests` and `ListStoreTests`, and the HUD render path
      is the same one the unreadable cases above exercise — so the untested
      remainder is only "is the window reachable in the wild". If you do see
      it, it must read "Your notes just changed on disk — capture again" with
      the circular-arrow symbol, never "can't read your notes file": the file
      is fine and the window closes by itself
- [ ] Quit immediately after adding an item → item survived (flush on quit)
- [ ] An item with a blank line in the middle (captured multi-paragraph
      prompt) survives an external editor that strips trailing whitespace

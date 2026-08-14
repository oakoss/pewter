import os
import PewterCore
import SwiftUI

struct PanelRootView: View {
    /// The shared launcher-command table; non-optional so a wiring gap is a
    /// compile error, not a menu of silent no-ops.
    let commands: AppCommands

    @Environment(ListStore.self) private var store
    @Environment(PanelUIState.self) private var uiState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var draft = ""
    @State private var selection = SelectionModel()
    @State private var expansion = NoteExpansion()
    /// One-shot: after a collapse shrinks the content, the acted-on row can
    /// end up off-screen; scrolling back to it keeps the user's place.
    @State private var collapseScrollTarget: UUID?
    @State private var editingID: UUID?
    /// The text of an edit the store refused, held here so re-opening the
    /// editor cannot reseed itself from the document and quietly discard it.
    /// Keyed by id so a refusal on one row can't repopulate another.
    @State private var pendingEdit: (id: UUID, text: String)?
    @State private var showsShortcutGuide = false
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case search, quickAdd, editor, list
    }

    private var visibleSections: [MarkdownDocument.Section] {
        store.sections(matching: uiState.query)
    }

    private var visibleItems: [Item] {
        visibleSections.flatMap(\.items)
    }

    private var visibleOrder: [UUID] {
        visibleItems.map(\.id)
    }

    private var selectedItems: [Item] {
        visibleItems.filter { selection.isSelected($0.id) }
    }

    /// The selection every action reads: the visible projection's IDs, never
    /// the raw selected set — a stale selection (filter change, external
    /// edit) must not act on rows that aren't on screen. Pruning keeps the
    /// model tidy; this keeps the actions correct.
    private var selectedIDs: Set<UUID> {
        Set(selectedItems.map(\.id))
    }

    var body: some View {
        // One grouping walk per render; the list and the selection pruning
        // below derive from it.
        let sections = visibleSections
        VStack(spacing: 0) {
            if let storageError = store.storageBanner {
                errorBanner(storageError)
            }
            if uiState.showsPermissionBanner {
                permissionBanner
            }
            searchField
            Divider()
            itemList(sections)
            Divider()
            quickAddField
        }
        .overlay(alignment: .bottom) {
            if let toast = uiState.toast {
                toastCapsule(toast)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: uiState.toast)
        // Hidden, not modal-fenced: the guide sits in an overlay, so the
        // panel content stays in the accessibility tree beneath it and
        // VoiceOver could wander behind the guide. Applied before the
        // overlay so the guide itself stays exposed.
        .accessibilityHidden(showsShortcutGuide)
        .overlay {
            if showsShortcutGuide {
                ShortcutGuideView(captureHint: uiState.captureHint) {
                    showsShortcutGuide = false
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showsShortcutGuide)
        .frame(minWidth: 320, idealWidth: 360, minHeight: 360, idealHeight: 480)
        .background(.ultraThinMaterial)
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            // Every list shortcut is swallowed (.handled, not .ignored)
            // while the guide covers the list — .ignored would let the key
            // fall through to the scroll view or list behind the overlay.
            // The guide never coexists with a focused text field (the ⌘/
            // gate below), so swallowing can't eat field input. ⌘W, Esc,
            // and ⌘/ stay live.
            guard !showsShortcutGuide else { return .handled }
            return moveSelection(
                press.key == .upArrow ? -1 : 1,
                extending: press.modifiers.contains(.shift)
            )
        }
        .onKeyPress(.space) { showsShortcutGuide ? .handled : toggleSelected() }
        .onKeyPress(.return) { showsShortcutGuide ? .handled : editSelected() }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in
            showsShortcutGuide ? .handled : deleteSelected()
        }
        .onKeyPress(keys: ["c", "C"], phases: .down) { press in
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command) else { return .ignored }
            return press.modifiers.contains(.shift) ? copyList() : copySelected()
        }
        .onKeyPress(keys: ["a", "A"], phases: .down) { press in
            // The focus guard keeps Cmd+A in a text field meaning
            // "select the text", regardless of who consumes the key first.
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command),
                  focus == .list || focus == nil,
                  !visibleItems.isEmpty else { return .ignored }
            selection.selectAll(order: visibleOrder)
            return .handled
        }
        .onKeyPress(keys: ["z", "Z"], phases: .down) { press in
            // Cmd+Z undoes, Shift-Cmd-Z redoes; other modified combos
            // (Cmd-Opt-Z) stay unclaimed. Same focus rule as Cmd+A: in a
            // text field the key keeps its field meaning.
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.option, .control]),
                  focus == .list || focus == nil else { return .ignored }
            return press.modifiers.contains(.shift) ? redoDelete() : undoDelete()
        }
        .onKeyPress(keys: ["m", "M"], phases: .down) { press in
            // Same focus rule as Cmd+A: in a text field the key keeps its
            // field meaning.
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command), press.modifiers.contains(.shift),
                  press.modifiers.isDisjoint(with: [.option, .control]),
                  focus == .list || focus == nil else { return .ignored }
            return mergeSelected()
        }
        .onKeyPress(keys: ["e", "E"], phases: .down) { press in
            // Same focus rule as Cmd+A: in a text field Cmd+E keeps its
            // field meaning (use selection for find).
            guard !showsShortcutGuide else { return .handled }
            let ids = selectedIDs
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.shift, .option, .control]),
                  focus == .list || focus == nil,
                  !ids.isEmpty else { return .ignored }
            toggleExpansion(ids)
            return .handled
        }
        .onKeyPress(keys: ["f", "F"], phases: .down) { press in
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.shift, .option, .control]) else { return .ignored }
            focus = .search
            return .handled
        }
        .onKeyPress(keys: ["n", "N"], phases: .down) { press in
            // No focus guard: jumping to the composer from anywhere —
            // including mid-edit — is the point of the shortcut. The filter
            // clears too, or the "searched, didn't find it, now add it"
            // gesture would file the new note invisibly behind the query.
            guard !showsShortcutGuide else { return .handled }
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.shift, .option, .control]) else { return .ignored }
            focus = .quickAdd
            uiState.query = ""
            return .handled
        }
        .onKeyPress(keys: ["/", "?"], phases: .down) { press in
            // ⌘/ (and ⇧⌘/, which can arrive as ⌘?) toggles the guide, but
            // only from the list: a focused text field would keep receiving
            // plain typing behind the overlay, so the guide is never allowed
            // to cover one.
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.option, .control]),
                  focus == .list || focus == nil else { return .ignored }
            showsShortcutGuide.toggle()
            return .handled
        }
        .onKeyPress(keys: ["w", "W"], phases: .down) { press in
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.shift, .option, .control]) else { return .ignored }
            // Cancel an in-progress edit explicitly — the discard must not
            // depend on resign-key timing, and the panel survives hidden.
            // Focus moves off the removed editor for the same reason, and
            // the guide comes down too or the next summon reopens covered.
            editingID = nil
            showsShortcutGuide = false
            if focus == .editor {
                focus = .list
            }
            uiState.onDismissPanel?()
            return .handled
        }
        .onKeyPress(.escape) {
            // The ladder itself lives (and is tested) in PanelCommands;
            // .hidePanel falls through to the panel's cancelOperation.
            switch PanelCommands.escapeAction(
                guideShowing: showsShortcutGuide,
                selectionIsMultiple: selectedIDs.count > 1,
                filterActive: !uiState.query.isEmpty
            ) {
            case .closeGuide:
                showsShortcutGuide = false
                return .handled
            case .clearSelection:
                selection.clear()
                return .handled
            case .clearFilter:
                uiState.query = ""
                return .handled
            case .hidePanel:
                return .ignored
            }
        }
        .onChange(of: sections.flatMap(\.items).map(\.id)) { _, newOrder in
            selection.prune(order: newOrder)
        }
        .onChange(of: focus) { oldFocus, newFocus in
            // Clicking into another field mid-edit would otherwise strand a
            // stale editor row with uncommitted text and dead arrow keys —
            // `editingID` and `.editor` focus must never diverge.
            if newFocus != .editor, editingID != nil {
                // `pendingEdit` deliberately outlives this. Submit resigns
                // first responder, so a refusal's re-assert can land either
                // side of this handler — clearing here would destroy the text
                // `reopenEditor` had saved, in the ordering where the bounce
                // arrives last. It is keyed by id and `beginEdit` clears it,
                // so a stale one can never seed a different edit.
                editingID = nil
            }
            // Moving into the composer means done with the list; a parked
            // selection would let list shortcuts act at a distance later.
            // Guarded to real moves from another field: submit and makeKey
            // both bounce focus through nil back to .quickAdd, and that
            // restoration must not wipe the just-added note's selection.
            if newFocus == .quickAdd, oldFocus != nil {
                selection.clear()
            }
        }
        .onAppear { focus = .quickAdd }
    }

    private var searchField: some View {
        @Bindable var uiState = uiState
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $uiState.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search notes")
                .accessibilityIdentifier(PanelAccessibilityID.searchField)
                .focused($focus, equals: .search)
            panelMenu
        }
        .padding(10)
    }

    /// Renders the same command table as the status item's menu — its
    /// right-click is the only other mouse path to these.
    private var panelMenu: some View {
        Menu {
            ForEach(Array(AppMenu.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider()
                }
                ForEach(group) { command in
                    Button(command.title) { commands.run(command.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .pointingHandCursor()
        .accessibilityLabel("More actions")
        .accessibilityIdentifier(PanelAccessibilityID.menuButton)
    }

    private func itemList(_ sections: [MarkdownDocument.Section]) -> some View {
        // Hoisted: computing this per row would walk the document once per
        // selected row on every render.
        let selectionMarksDone = !store.allDone(ids: selectedIDs)
        // During a search, a returned empty section IS the match (its heading
        // matched), so "No matches" must not render beneath it.
        let showsEmptyState = uiState.query.isEmpty
            ? sections.allSatisfy(\.items.isEmpty)
            : sections.isEmpty
        return ScrollViewReader { proxy in
            ScrollView {
                // Focusable so list-level shortcuts (Space, Return, Delete,
                // Cmd+C) have a focus state distinct from the text fields.
                //
                // Eager, not LazyVStack: lazy content extents go stale when
                // an off-screen-sized row shrinks (collapsing an expanded
                // note), stranding the scroll offset past the content on a
                // blank viewport. Exact extents let the scroll view clamp.
                VStack(spacing: 4) {
                    ForEach(sections) { section in
                        if let heading = section.heading {
                            sectionHeader(heading)
                        }
                        ForEach(section.items) { item in
                            let isRowSelected = selection.isSelected(item.id)
                            ItemRow(
                                item: item,
                                isSelected: isRowSelected,
                                isHighlighted: item.id == uiState.highlightedItemID,
                                isEditing: item.id == editingID,
                                pendingEditText: pendingEdit?.id == item.id ? pendingEdit?.text : nil,
                                isExpanded: expansion.isExpanded(item.id),
                                editorFocus: $focus,
                                actions: ItemRowActions(
                                    toggle: { applied { store.toggleDone(ids: [item.id]) } },
                                    // Row-level like the checkbox: the chevron
                                    // toggles its own row even inside a
                                    // multi-selection; Cmd+E is the selection
                                    // path.
                                    toggleExpand: { toggleExpansion([item.id]) },
                                    select: { select(item) },
                                    beginEdit: { beginEdit(item) },
                                    commitEdit: { text in commitEdit(id: item.id, text: text) },
                                    cancelEdit: {
                                        pendingEdit = nil
                                        editingID = nil
                                        focus = .list
                                    },
                                    copy: { copy([item]) },
                                    delete: { delete(ids: [item.id]) }
                                ),
                                menu: ItemRowMenu(
                                    marksDone: isRowSelected ? selectionMarksDone : !item.done,
                                    canMerge: selectedIDs.count > 1 && isRowSelected,
                                    copy: { copy(targets(for: item)) },
                                    copyAsList: { copyAsList(targets(for: item)) },
                                    toggleDone: { toggleDone(targets(for: item)) },
                                    merge: { _ = mergeSelected() },
                                    delete: { delete(ids: Set(targets(for: item).map(\.id))) }
                                )
                            )
                            .id(item.id)
                            // The item's id, not its position: a filter, a
                            // sort or an external edit moves rows, and an
                            // index would silently retarget a different note.
                            .accessibilityIdentifier(PanelAccessibilityID.noteRow(item.id))
                        }
                    }
                    if showsEmptyState {
                        emptyState
                    }
                }
                .padding(8)
            }
            .focusable()
            // The row selection highlight communicates focus; suppress the
            // system focus ring around the whole scroll area.
            .focusEffectDisabled()
            .focused($focus, equals: .list)
            // Contain, then label: without an explicit container element the
            // label can propagate onto the rows and mask their own text.
            .accessibilityElement(children: .contain)
            // VoiceOver announces the container by name instead of a bare
            // "scroll area".
            .accessibilityLabel("Notes")
            .accessibilityIdentifier(PanelAccessibilityID.noteList)
            // contentShape makes the empty area below the rows hit-testable;
            // the gesture fires only for clicks no row consumed.
            .contentShape(Rectangle())
            .onTapGesture {
                selection.clear()
                focus = .list
            }
            .onChange(of: uiState.revealToken) {
                // The token, not the id: revealing the same note twice must
                // scroll both times, and the id alone wouldn't change.
                guard let target = uiState.revealTargetID else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target) }
            }
            .onChange(of: collapseScrollTarget) { _, target in
                guard let target else { return }
                collapseScrollTarget = nil
                // Minimal-move default on purpose: the eager stack already
                // clamps the offset, so this only rescues a collapsed row
                // that ended up off-screen — and no-ops (no viewport yank)
                // when the row is still visible, e.g. collapsing notes that
                // were never clamped.
                withAnimation(reduceMotion ? nil : .default) {
                    proxy.scrollTo(target)
                }
            }
        }
    }

    /// Uppercased so headers read as group labels distinct from note text;
    /// the file keeps whatever casing the author wrote.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .accessibilityAddTraits(.isHeader)
    }

    /// Two materials as close together as `.regularMaterial` on the panel's
    /// `.ultraThinMaterial` barely separate, leaving the toast reading as
    /// floating text; the thicker fill, the edge and the shadow are what make
    /// it a surface. Severity rides the leading symbol rather than the fill —
    /// the banner above owns persistent red for "saving is off", and a red
    /// toast would compete with it while meaning something transient.
    private func toastCapsule(_ toast: PanelUIState.Toast) -> some View {
        HStack(spacing: 6) {
            Image(systemName: toast.severity.symbolName)
                .foregroundStyle(toast.severity.tint)
                // Decorative, same as the empty state's: it restates the
                // severity the message already carries, and left visible it
                // becomes a stop announcing "warning" and nothing else.
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
        .padding(.bottom, 48)
        .transition(.opacity)
        // The symbol duplicates what the message says; combining reads them
        // as one outcome instead of stopping on an unlabelled "warning".
        .accessibilityElement(children: .combine)
        // After `combine`, not before: applied earlier the identifier lands on
        // a child the combined element replaces, and no query finds it.
        .accessibilityIdentifier(PanelAccessibilityID.toast)
    }

    /// The button is the difference between naming a repair and asking the
    /// user to go find a file they have never been told the location of.
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                // On the message, not the enclosing stack: an identifier on a
                // bare HStack propagates to every descendant, so the icon and
                // the text would both answer to it and a query would match
                // three elements. The same propagation the list's label
                // comment describes. Containing the stack instead would fix
                // that too, but it changes what VoiceOver navigates, and this
                // does not.
                .accessibilityIdentifier(PanelAccessibilityID.storageBanner)
            Spacer()
            Button("Reveal") {
                commands.revealNotesFile()
            }
            .controlSize(.small)
            .pointingHandCursor()
            .accessibilityLabel("Reveal notes file in Finder")
            .accessibilityIdentifier(PanelAccessibilityID.storageBannerReveal)
        }
        .padding(10)
        .background(.red.opacity(0.12))
    }

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("Capture is off — grant Accessibility access")
                .font(.callout)
                // On the message for the same reason as the storage banner.
                .accessibilityIdentifier(PanelAccessibilityID.permissionBanner)
            Spacer()
            Button("Enable…") {
                uiState.onRequestPermission?()
            }
            .controlSize(.small)
            .pointingHandCursor()
            .accessibilityIdentifier(PanelAccessibilityID.permissionBannerEnable)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: emptyStateContent.symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
                // The symbol only restates the message. Left visible to
                // VoiceOver it becomes a stop that announces "warning" and
                // nothing else, which is where the state's meaning is lost.
                .accessibilityHidden(true)
            Text(emptyStateContent.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        // Redundant while the symbol is the only other child, and kept so a
        // second line added later is announced with the message, not after it.
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(PanelAccessibilityID.emptyState)
    }

    /// A placeholder document must not read as an empty one — "capture
    /// something" invites work that would be discarded. Terse on purpose:
    /// the banner above owns the explanation and the remedy, and two
    /// paragraphs saying the same thing read as two problems.
    private var emptyStateContent: (symbol: String, message: String) {
        if store.documentIsPlaceholder {
            ("exclamationmark.triangle", "Notes unavailable")
        } else if uiState.query.isEmpty {
            ("sparkles", uiState.captureHint)
        } else {
            ("magnifyingglass", "No matches")
        }
    }

    private var quickAddField: some View {
        TextField(quickAddPrompt.title, text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .accessibilityLabel("New note")
            .accessibilityIdentifier(PanelAccessibilityID.composer)
            // The label displaces the placeholder in the announcement; the
            // hint restores what the field accepts.
            .accessibilityHint(quickAddPrompt.hint)
            .lineLimit(1 ... 5)
            .padding(10)
            .focused($focus, equals: .quickAdd)
            .onSubmit {
                // Submitting resigns first responder; every exit restores it
                // so Return can be pressed again without clicking back in.
                defer { focus = .quickAdd }
                store.retryUnavailableStorage()
                // The banner is not enough on its own: for the first note
                // after a runtime break it isn't up yet, and it never shows an
                // in-flight adoption at all. The draft survives a refusal, for
                // the same reason the field stays enabled rather than
                // disabled — a disabled field can't be focused, so VoiceOver
                // could never reach the reason.
                switch store.add(text: draft) {
                case let .applied(added):
                    draft = ""
                    // Same rule as capture: a filter that hides the new
                    // note would make the add read as a failure.
                    uiState.query = ""
                    selection.select(added.id)
                    uiState.reveal(added.id)
                case .unchanged:
                    break
                case let .refused(reason):
                    uiState.showToast(reason.refusalMessage, severity: .refusal)
                    // TextSelection would collapse this in SwiftUI directly,
                    // but needs macOS 15.
                    collapseRefusedDraftSelection()
                }
            }
    }

    /// Why the caret could not be left collapsed at the end of the draft.
    /// Content-free by construction: these reach the log, which Copy
    /// Diagnostics renders verbatim, so no case may carry the draft or the
    /// editor's text.
    private enum ComposerCollapseFailure: String, Error {
        case noPanel
        case notATextView
        case notAFieldEditor
        case notFocused
        case draftMismatch
        /// Only from the closing report; the lookup never returns it.
        case reselected
    }

    /// Moves the caret to the end of the kept draft after a refusal: collapse
    /// on each of three runloop hops, then report what the user was left with.
    ///
    /// The hops span real time — 23–56ms end to end across drafts of 6 to 722
    /// characters — so they do give SwiftUI's focus restore room to land, and
    /// it landed inside them every time. They are still a bet on that window,
    /// which is why the outcome is logged rather than assumed: if
    /// `refusal caret collapse failed: reselected` ever appears in the field,
    /// the restore is landing later than these hops and the answer is to
    /// observe `NSTextView.didChangeSelectionNotification`, not to add a
    /// fourth hop.
    ///
    /// It relies on submit having resigned first responder (see the composer's
    /// `onSubmit`): that is what stops the closing read from passing against a
    /// caret the restore has not touched yet.
    private func collapseRefusedDraftSelection(attemptsLeft: Int = 3) {
        DispatchQueue.main.async {
            collapseComposerSelection()
            DispatchQueue.main.async {
                guard attemptsLeft > 1 else {
                    reportCollapseOutcome()
                    return
                }
                collapseRefusedDraftSelection(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    /// Every failure is an error: the whole sequence spans tens of
    /// milliseconds (23–56ms measured), far faster than any keystroke, so
    /// surviving it means first responder never came back rather than that
    /// the user moved on.
    ///
    /// The range goes with it. An accessibility dump can read the caret too,
    /// but only while the app is running and the panel is up; the log is what
    /// survives to a bug report. Two integers carry no note content.
    private func reportCollapseOutcome() {
        switch composerEditor() {
        case let .failure(reason):
            Logger.panel.error(
                "refusal caret collapse failed: \(reason.rawValue, privacy: .public)"
            )
        case let .success(editor):
            let selection = editor.selectedRange
            let range = "(\(selection.location),\(selection.length))"
            guard selection.length == 0,
                  selection.location == (editor.string as NSString).length
            else {
                Logger.panel.error(
                    """
                    refusal caret collapse failed: \
                    \(ComposerCollapseFailure.reselected.rawValue, privacy: .public) \
                    at \(range, privacy: .public)
                    """
                )
                return
            }
            Logger.panel.debug("refusal caret collapsed: \(range, privacy: .public)")
        }
    }

    private func collapseComposerSelection() {
        guard case let .success(editor) = composerEditor() else { return }
        let end = (editor.string as NSString).length
        editor.selectedRange = NSRange(location: end, length: 0)
        editor.scrollRangeToVisible(editor.selectedRange)
    }

    /// The composer's field editor, or why it could not be reached.
    ///
    /// The panel is found by type rather than `keyWindow`, which is nil
    /// whenever this non-activating panel is not key. `isFieldEditor` rules
    /// out a standalone text view but not the sibling fields — one shared
    /// field editor serves search, the row editor and the composer alike — so
    /// the focus state is what discriminates, with the draft match as a
    /// staleness check. The backing control's accessibility identifier looks
    /// like a stronger anchor and is not: it is only reachable when focus
    /// already says the composer owns the editor.
    private func composerEditor() -> Result<NSTextView, ComposerCollapseFailure> {
        guard let panel = NSApp.windows.first(where: { $0 is FloatingPanel }) else {
            return .failure(.noPanel)
        }
        guard let editor = panel.firstResponder as? NSTextView else {
            return .failure(.notATextView)
        }
        guard editor.isFieldEditor else {
            return .failure(.notAFieldEditor)
        }
        guard focus == .quickAdd else {
            return .failure(.notFocused)
        }
        guard editor.string == draft else {
            return .failure(.draftMismatch)
        }
        return .success(editor)
    }

    /// Placeholder text and hint move together: a field that still invites a
    /// note it would refuse is the mismatch this exists to prevent.
    private var quickAddPrompt: (title: String, hint: String) {
        if store.documentIsPlaceholder {
            ("Notes unavailable", "Unavailable until your notes file can be read")
        } else {
            ("Add a note or a prompt…", "Add a note or a prompt")
        }
    }

    // MARK: - Actions

    /// What a row-level action applies to: the whole selection when the row
    /// is part of it, the row alone otherwise.
    private func targets(for item: Item) -> [Item] {
        selection.isSelected(item.id) ? selectedItems : [item]
    }

    private func select(_ item: Item) {
        // Explicit, mirroring the empty-area path — a row click must arm the
        // list shortcuts without relying on focusable()'s implicit focus.
        focus = .list
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            selection.toggle(item.id)
        } else if modifiers.contains(.shift) {
            selection.extend(to: item.id, order: visibleOrder)
        } else {
            selection.select(item.id)
        }
    }

    private func moveSelection(_ delta: Int, extending: Bool) -> KeyPress.Result {
        guard !visibleItems.isEmpty, editingID == nil, focus != .editor else { return .ignored }
        // First arrow press pulls focus out of the text fields so the
        // list-level shortcuts below become live.
        focus = .list
        selection.step(delta, order: visibleOrder, extending: extending)
        return .handled
    }

    /// Deliberately not animated: the text view re-clamps its content the
    /// instant the toggle lands, so an animated row frame lags behind it,
    /// flashing a gap between the text and the disclosure control.
    private func toggleExpansion(_ ids: Set<UUID>) {
        if expansion.toggle(ids) {
            collapseScrollTarget = visibleOrder.first(where: ids.contains)
        }
    }

    private func toggleSelected() -> KeyPress.Result {
        let ids = selectedIDs
        guard focus == .list, !ids.isEmpty else { return .ignored }
        applied { store.toggleDone(ids: ids) }
        return .handled
    }

    private func editSelected() -> KeyPress.Result {
        let items = selectedItems
        guard focus == .list, items.count == 1, let item = items.first else { return .ignored }
        beginEdit(item)
        return .handled
    }

    /// What became of a mutation once the panel had its say. Distinct from
    /// `MutationOutcome` by one arm: the store never sees `documentReplaced`,
    /// because the retry that caused it happens out here.
    private enum Disposition {
        case applied
        case unchanged
        /// The store declined; the document is untouched and a toast is up.
        case refused
        /// A retry adopted content from disk before the mutation ran, so the
        /// notes it was aimed at may no longer exist. Nothing was attempted.
        case documentReplaced

        /// Whether the user was told. Anything true here was handled, and a
        /// shortcut reporting `.ignored` over it lets the key fall through the
        /// responder chain and beep across the toast that just explained
        /// itself.
        var wasReported: Bool {
            self == .refused || self == .documentReplaced
        }
    }

    /// The product of a mutation, or nil when it did not happen — and a
    /// refusal gets the same toast the composer shows, so no path can drop a
    /// change the user watched themselves make without saying why.
    ///
    /// Reconciles with disk first, in the same order the composer and capture
    /// do, which is why the mutation arrives as a closure rather than an
    /// already-evaluated value. Both directions need it: a break that fired no
    /// watcher event would otherwise let the first change through and report it
    /// saved, and a permission-only repair fires no event either, so without
    /// this every control would keep refusing a file the user has already
    /// fixed.
    ///
    /// `nil` covers "nothing to do", "refused" and "the document was
    /// replaced" alike, because the callers that need to tell them apart —
    /// the editor and the keyboard paths — switch on the disposition instead.
    @discardableResult
    private func applied<Value>(_ mutate: () -> MutationOutcome<Value>) -> Value? {
        outcome(of: mutate).value
    }

    /// The product, plus what became of the attempt — which `applied` throws
    /// away and the keyboard and editor paths need.
    ///
    /// `whenReplaced` is the message for an adoption, because the default
    /// ("try again") is only good advice where trying again can work. Undo and
    /// redo pass their own: an adoption clears the history, so their retry is
    /// a guaranteed no-op.
    private func outcome<Value>(
        of mutate: () -> MutationOutcome<Value>,
        whenReplaced replacedMessage: String = Unavailability.adoptionInFlight.refusalMessage
    ) -> (value: Value?, disposition: Disposition) {
        // A retry that adopts replaces the list wholesale. An add can ride
        // that out — it appends to whatever is current — but a mutation aimed
        // at notes the user picked would then act on a list they never saw, so
        // it stops here and says what happened, rather than reaching for ids
        // that no longer exist and reporting "nothing happened".
        if store.retryUnavailableStorage() == .documentReplaced {
            uiState.showToast(replacedMessage, severity: .refusal)
            return (nil, .documentReplaced)
        }
        switch mutate() {
        case let .applied(value):
            return (value, .applied)
        case .unchanged:
            return (nil, .unchanged)
        case let .refused(reason):
            uiState.showToast(reason.refusalMessage, severity: .refusal)
            return (nil, .refused)
        }
    }

    /// Toast for an adoption that landed on undo or redo. "Try again" would be
    /// a lie: adopting clears both stacks, so the retry it asks for finds an
    /// empty history and does nothing at all.
    private static let historyClearedMessage = "Your notes changed on disk — undo history was cleared"

    private func mergeSelected() -> KeyPress.Result {
        let ids = selectedIDs
        guard ids.count > 1 else { return .ignored }
        let result = outcome(of: { store.merge(ids: ids) })
        guard let merged = result.value else {
            if result.disposition == .unchanged {
                // Two or more selected rows always come from the document, so
                // the store had sources and `.unchanged` means its insertion
                // seam broke. That seam asserts, which is a no-op in release —
                // without this the user's Cmd+M would answer with a beep.
                uiState.showToast("Couldn't merge those notes", severity: .refusal)
                return .handled
            }
            return result.disposition.wasReported ? .handled : .ignored
        }
        selection.select(merged.id)
        uiState.reveal(merged.id)
        return .handled
    }

    private func deleteSelected() -> KeyPress.Result {
        let ids = selectedIDs
        guard focus == .list, !ids.isEmpty else { return .ignored }
        delete(ids: ids)
        return .handled
    }

    private func delete(ids: Set<UUID>) {
        var order: [UUID] = []
        // Read inside the closure, so it is taken after `applied` reconciles
        // and before the store mutates: an adoption found by that reconcile
        // replaces the list, and a survivor rule computed against the old one
        // would advance the selection onto a note that is no longer there.
        guard applied({
            order = visibleOrder
            return store.delete(ids: ids)
        }) != nil else { return }
        selection.removeAndAdvance(ids: ids, order: order)
    }

    private func undoDelete() -> KeyPress.Result {
        let undone = outcome(of: { store.undoDelete() }, whenReplaced: Self.historyClearedMessage)
        guard let restored = undone.value else { return undone.disposition.wasReported ? .handled : .ignored }
        // Selecting and flashing the restored notes is the only feedback —
        // there's no undo toast — so both must survive an active filter
        // hiding them (replace prunes; scrollTo of a hidden id is a no-op).
        selection.replace(with: Set(restored.map(\.id)), order: visibleOrder)
        focus = .list
        if let first = restored.first {
            uiState.reveal(first.id)
        }
        return .handled
    }

    private func redoDelete() -> KeyPress.Result {
        let redone = outcome(of: { store.redo() }, whenReplaced: Self.historyClearedMessage)
        guard let result = redone.value else { return redone.disposition.wasReported ? .handled : .ignored }
        if let product = result.mergedProduct {
            // A merge redo re-creates its product — select and reveal it,
            // same feedback shape as undo's restored notes.
            selection.replace(with: [product.id], order: visibleOrder)
            focus = .list
            uiState.reveal(product.id)
        } else {
            // A delete redo only removes; drop the vanished ids so the
            // selection can't point at notes that no longer exist.
            selection.prune(order: visibleOrder)
        }
        return .handled
    }

    private func copySelected() -> KeyPress.Result {
        let items = selectedItems
        // Guard the materialized rows, not the ID set — a stale selection
        // must not wipe the clipboard with an empty write.
        guard focus == .list, !items.isEmpty else { return .ignored }
        copy(items)
        return .handled
    }

    private func copyList() -> KeyPress.Result {
        // Never write an empty list — it would wipe the user's clipboard
        // for nothing.
        let items = PanelCommands.listCopyTargets(selected: selectedItems, visible: visibleItems)
        guard !items.isEmpty else { return .ignored }
        copyAsList(items)
        return .handled
    }

    // Scope-taking effects shared by the keyboard and context-menu paths.

    private func copy(_ items: [Item]) {
        Pasteboard.write(ItemFormatter.itemsText(items))
    }

    private func copyAsList(_ items: [Item]) {
        Pasteboard.write(ItemFormatter.listText(items, style: PanelSettings.listCopyStyle))
    }

    private func toggleDone(_ items: [Item]) {
        applied { store.toggleDone(ids: Set(items.map(\.id))) }
    }

    private func beginEdit(_ item: Item) {
        // A fresh edit starts from the document, never from a refusal the
        // user has since walked away from.
        pendingEdit = nil
        editingID = item.id
        selection.select(item.id)
        focus = .editor
    }

    private func commitEdit(id: UUID, text: String) {
        let result = outcome(of: { store.updateText(id: id, text: text) })
        switch result.disposition {
        case .refused:
            // The editor comes back holding what the user typed, the same way
            // the composer keeps its draft. All three parts are re-asserted,
            // not focus alone: submit resigns first responder, and
            // `onChange(of: focus)` clears `editingID` the moment focus leaves
            // `.editor`, so the row may already be gone — and `pendingEdit` is
            // what stops the rebuilt editor reseeding itself from the
            // document. This still depends on submit's resign landing before
            // this call — the composer's own draft-collapse code measures that
            // restore at 23–56ms across three runloop hops — so it is verified
            // by hand rather than proven here; see the editor items in
            // docs/manual-testing.md.
            reopenEditor(id: id, keeping: text)
        case .documentReplaced:
            // The adopted document may not contain this note at all — a
            // hand-rewrite that drops the id metadata mints a new one — so
            // re-opening could point at a row that no longer exists. Land the
            // text somewhere it survives either way.
            if store.items.contains(where: { $0.id == id }) {
                // The adopted note may no longer match the active filter — a
                // rewrite that changes its text is exactly how this path is
                // reached — and an editor on a row the filter hides is one the
                // user can neither see nor escape.
                uiState.query = ""
                reopenEditor(id: id, keeping: text)
            } else {
                rescueOrphanedEdit(text)
            }
        case .applied, .unchanged:
            pendingEdit = nil
            editingID = nil
            focus = .list
        }
    }

    private func reopenEditor(id: UUID, keeping text: String) {
        pendingEdit = (id, text)
        editingID = id
        focus = .editor
    }

    /// Moves an edit into the composer when the note it belonged to is gone,
    /// rather than closing the editor over it. The text is the one thing here
    /// that cannot be recovered from disk.
    ///
    /// Re-toasts over the adoption message `outcome(of:)` already posted: that
    /// one says "try again", which is only good advice where the note still
    /// exists. Posted here rather than passed in, because which of the two is
    /// true is not known until the note has been looked for.
    private func rescueOrphanedEdit(_ text: String) {
        pendingEdit = nil
        editingID = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            uiState.showToast(Self.orphanedEditMessage, severity: .refusal)
            focus = .list
            return
        }
        // Blank line, matching how a merge joins notes: `add` never splits on
        // newlines, so a half-typed draft and the rescued edit become one note
        // either way — a paragraph break at least makes the seam visible.
        let appended = !draft.isEmpty
        draft = draft.isEmpty ? text : draft + "\n\n" + text
        uiState.query = ""
        focus = .quickAdd
        uiState.showToast(
            appended ? Self.orphanedEditAppendedMessage : Self.orphanedEditMessage,
            severity: .refusal
        )
    }

    /// The edited note is gone from the adopted document, so the text has been
    /// put where the user can still send it. Named surfaces, not "try again":
    /// there is nothing left to retry the edit against.
    private static let orphanedEditMessage = "That note is gone — your edit moved to the new-note field"
    private static let orphanedEditAppendedMessage = "That note is gone — your edit was added to your draft"
}

/// Tint lives here rather than beside the symbol in Core, which has no
/// SwiftUI dependency. Red is deliberately absent: the storage banner owns it
/// for "saving is off", and a toast wearing the same colour would read as that
/// same persistent problem.
private extension ToastSeverity {
    var tint: Color {
        switch self {
        case .confirmation: .secondary
        case .warning: .yellow
        case .refusal: .orange
        }
    }
}

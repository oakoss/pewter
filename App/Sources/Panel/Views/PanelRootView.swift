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

    var body: some View {
        // One grouping walk per render; the list and the selection pruning
        // below derive from it.
        let sections = visibleSections
        VStack(spacing: 0) {
            if let storageError = uiState.storageError {
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
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 48)
                    .transition(.opacity)
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
            guard press.modifiers.contains(.command),
                  press.modifiers.isDisjoint(with: [.shift, .option, .control]),
                  focus == .list || focus == nil,
                  !selection.isEmpty else { return .ignored }
            toggleExpansion(selection.selected)
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
            // Ladder: close the guide, then drop a multi-selection, then the
            // filter; otherwise fall through to the panel's cancelOperation
            // (hides it). A single selection doesn't count — quick-add
            // selects what it added, and capture-then-Esc must still hide
            // the panel in one press.
            if showsShortcutGuide {
                showsShortcutGuide = false
                return .handled
            }
            if selection.isMultiple {
                selection.clear()
                return .handled
            }
            guard !uiState.query.isEmpty else { return .ignored }
            uiState.query = ""
            return .handled
        }
        .onChange(of: sections.flatMap(\.items).map(\.id)) { _, newOrder in
            selection.prune(order: newOrder)
        }
        .onChange(of: focus) { oldFocus, newFocus in
            // Clicking into another field mid-edit would otherwise strand a
            // stale editor row with uncommitted text and dead arrow keys —
            // `editingID` and `.editor` focus must never diverge.
            if newFocus != .editor, editingID != nil {
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
    }

    private func itemList(_ sections: [MarkdownDocument.Section]) -> some View {
        // Hoisted: computing this per row would walk the document once per
        // selected row on every render.
        let selectionMarksDone = !store.allDone(ids: selection.selected)
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
                                isExpanded: expansion.isExpanded(item.id),
                                menuMarksDone: isRowSelected ? selectionMarksDone : !item.done,
                                editorFocus: $focus,
                                onToggle: { store.toggleDone(ids: [item.id]) },
                                // Row-level like the checkbox: the chevron
                                // toggles its own row even inside a
                                // multi-selection; Cmd+E is the selection path.
                                onToggleExpand: { toggleExpansion([item.id]) },
                                onSelect: { select(item) },
                                onBeginEdit: { beginEdit(item) },
                                onCommitEdit: { text in commitEdit(id: item.id, text: text) },
                                onCancelEdit: {
                                    editingID = nil
                                    focus = .list
                                },
                                onCopy: { copy([item]) },
                                onMenuCopy: { copy(targets(for: item)) },
                                onMenuCopyList: { copyAsList(targets(for: item)) },
                                onMenuToggle: { toggleDone(targets(for: item)) },
                                canMerge: selection.isMultiple && isRowSelected,
                                onMenuMerge: { _ = mergeSelected() },
                                onDelete: { delete(ids: [item.id]) },
                                onMenuDelete: { delete(ids: Set(targets(for: item).map(\.id))) }
                            )
                            .id(item.id)
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
            // contentShape makes the empty area below the rows hit-testable;
            // the gesture fires only for clicks no row consumed.
            .contentShape(Rectangle())
            .onTapGesture {
                selection.clear()
                focus = .list
            }
            .onChange(of: store.items.count) {
                // An explicit request (undo restore, merge) wins over the
                // tail-append heuristic — those notes can land mid-list.
                if let target = uiState.takeScrollTarget() {
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target) }
                } else if let last = store.items.last, uiState.query.isEmpty {
                    withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(last.id) }
                }
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
            Spacer()
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
            Spacer()
            Button("Enable…") {
                uiState.onRequestPermission?()
            }
            .controlSize(.small)
            .pointingHandCursor()
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: uiState.query.isEmpty ? "sparkles" : "magnifyingglass")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(uiState.query.isEmpty ? uiState.captureHint : "No matches")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
    }

    private var quickAddField: some View {
        TextField("Add a note or a prompt…", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .accessibilityLabel("New note")
            // The label displaces the placeholder in the announcement; the
            // hint restores what the field accepts.
            .accessibilityHint("Add a note or a prompt")
            .lineLimit(1 ... 5)
            .padding(10)
            .focused($focus, equals: .quickAdd)
            .onSubmit {
                if let added = store.add(text: draft) {
                    draft = ""
                    selection.select(added.id)
                }
                focus = .quickAdd
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
        guard focus == .list, !selection.isEmpty else { return .ignored }
        store.toggleDone(ids: selection.selected)
        return .handled
    }

    private func editSelected() -> KeyPress.Result {
        guard focus == .list, let id = selection.single,
              let item = visibleItems.first(where: { $0.id == id }) else { return .ignored }
        beginEdit(item)
        return .handled
    }

    private func mergeSelected() -> KeyPress.Result {
        guard selection.isMultiple,
              let merged = store.merge(ids: selection.selected) else { return .ignored }
        selection.select(merged.id)
        uiState.highlight(merged.id)
        // Explicit request wins over the tail-append heuristic — the merged
        // note lands mid-list, same as an undo restore.
        uiState.requestScroll(to: merged.id)
        return .handled
    }

    private func deleteSelected() -> KeyPress.Result {
        guard focus == .list, !selection.isEmpty else { return .ignored }
        delete(ids: selection.selected)
        return .handled
    }

    private func delete(ids: Set<UUID>) {
        // Reselecting a neighbor keeps arrow keys anchored where the user
        // was working — but only when the deletion touched the selection;
        // menu-deleting an unrelated row must not hijack it.
        let touchesSelection = !ids.isDisjoint(with: selection.selected)
        let next = touchesSelection ? SelectionModel.survivor(afterRemoving: ids, order: visibleOrder) : nil
        store.delete(ids: ids)
        guard touchesSelection else { return }
        if let next {
            selection.select(next)
        } else {
            selection.clear()
        }
    }

    private func undoDelete() -> KeyPress.Result {
        let restored = store.undoDelete()
        guard !restored.isEmpty else { return .ignored }
        // Selecting and flashing the restored notes is the only feedback —
        // there's no undo toast — so both must survive an active filter
        // hiding them (replace prunes; scrollTo of a hidden id is a no-op).
        selection.replace(with: Set(restored.map(\.id)), order: visibleOrder)
        focus = .list
        if let first = restored.first {
            uiState.highlight(first.id)
            uiState.requestScroll(to: first.id)
        }
        return .handled
    }

    private func redoDelete() -> KeyPress.Result {
        guard let result = store.redo() else { return .ignored }
        if let product = result.mergedProduct {
            // A merge redo re-creates its product — select and reveal it,
            // same feedback shape as undo's restored notes.
            selection.replace(with: [product.id], order: visibleOrder)
            focus = .list
            uiState.highlight(product.id)
            uiState.requestScroll(to: product.id)
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
        // A multi-selection narrows the list copy to it; otherwise the whole
        // visible list. Never write an empty list — it would wipe the user's
        // clipboard for nothing.
        let items = selection.isMultiple ? selectedItems : visibleItems
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
        store.toggleDone(ids: Set(items.map(\.id)))
    }

    private func beginEdit(_ item: Item) {
        editingID = item.id
        selection.select(item.id)
        focus = .editor
    }

    private func commitEdit(id: UUID, text: String) {
        store.updateText(id: id, text: text)
        editingID = nil
        focus = .list
    }
}

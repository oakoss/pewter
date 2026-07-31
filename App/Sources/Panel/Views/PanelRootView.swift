import PewterCore
import SwiftUI

struct PanelRootView: View {
    @Environment(ListStore.self) private var store
    @Environment(PanelUIState.self) private var uiState

    @State private var draft = ""
    @State private var selection = SelectionModel()
    @State private var editingID: UUID?
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case search, quickAdd, editor, list
    }

    private var visibleItems: [Item] {
        store.filtered(query: uiState.query)
    }

    private var visibleOrder: [UUID] {
        visibleItems.map(\.id)
    }

    private var selectedItems: [Item] {
        visibleItems.filter { selection.isSelected($0.id) }
    }

    var body: some View {
        // One filter walk per render; everything below derives from it.
        let items = visibleItems
        VStack(spacing: 0) {
            if let storageError = uiState.storageError {
                errorBanner(storageError)
            }
            if uiState.showsPermissionBanner {
                permissionBanner
            }
            searchField
            Divider()
            itemList(items)
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
        .frame(minWidth: 320, idealWidth: 360, minHeight: 360, idealHeight: 480)
        .background(.ultraThinMaterial)
        .onKeyPress(keys: [.upArrow, .downArrow], phases: .down) { press in
            moveSelection(
                press.key == .upArrow ? -1 : 1,
                extending: press.modifiers.contains(.shift)
            )
        }
        .onKeyPress(.space) { toggleSelected() }
        .onKeyPress(.return) { editSelected() }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in deleteSelected() }
        .onKeyPress(keys: ["c", "C"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return press.modifiers.contains(.shift) ? copyList() : copySelected()
        }
        .onKeyPress(keys: ["a", "A"], phases: .down) { press in
            // The focus guard keeps Cmd+A in a text field meaning
            // "select the text", regardless of who consumes the key first.
            guard press.modifiers.contains(.command),
                  focus == .list || focus == nil,
                  !visibleItems.isEmpty else { return .ignored }
            selection.selectAll(order: visibleOrder)
            return .handled
        }
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            focus = .search
            return .handled
        }
        .onKeyPress(.escape) {
            // Ladder: drop a multi-selection, then the filter; otherwise fall
            // through to the panel's cancelOperation (hides it). A single
            // selection doesn't count — quick-add selects what it added, and
            // capture-then-Esc must still hide the panel in one press.
            if selection.isMultiple {
                selection.clear()
                return .handled
            }
            guard !uiState.query.isEmpty else { return .ignored }
            uiState.query = ""
            return .handled
        }
        .onChange(of: items.map(\.id)) { _, newOrder in
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
                .focused($focus, equals: .search)
        }
        .padding(10)
    }

    private func itemList(_ items: [Item]) -> some View {
        // Hoisted: computing this per row would walk the document once per
        // selected row on every render.
        let selectionMarksDone = !store.allDone(ids: selection.selected)
        return ScrollViewReader { proxy in
            ScrollView {
                // Focusable so list-level shortcuts (Space, Return, Delete,
                // Cmd+C) have a focus state distinct from the text fields.
                LazyVStack(spacing: 4) {
                    ForEach(items) { item in
                        ItemRow(
                            item: item,
                            isSelected: selection.isSelected(item.id),
                            isHighlighted: item.id == uiState.highlightedItemID,
                            isEditing: item.id == editingID,
                            menuMarksDone: selection.isSelected(item.id) ? selectionMarksDone : !item.done,
                            editorFocus: $focus,
                            onToggle: { store.toggleDone(ids: [item.id]) },
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
                            onDelete: { delete(ids: Set(targets(for: item).map(\.id))) }
                        )
                        .id(item.id)
                    }
                    if items.isEmpty {
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
            // contentShape makes the empty area below the rows hit-testable;
            // the gesture fires only for clicks no row consumed.
            .contentShape(Rectangle())
            .onTapGesture {
                selection.clear()
                focus = .list
            }
            .onChange(of: store.items.count) {
                if let last = store.items.last, uiState.query.isEmpty {
                    withAnimation { proxy.scrollTo(last.id) }
                }
            }
        }
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

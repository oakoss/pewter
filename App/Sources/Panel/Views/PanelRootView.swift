import PewterCore
import SwiftUI

struct PanelRootView: View {
    @Environment(ListStore.self) private var store
    @Environment(PanelUIState.self) private var uiState

    @State private var draft = ""
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @FocusState private var focus: Field?

    enum Field: Hashable {
        case search, quickAdd, editor, list
    }

    private var visibleItems: [Item] {
        store.filtered(query: uiState.query)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let storageError = uiState.storageError {
                errorBanner(storageError)
            }
            if uiState.showsPermissionBanner {
                permissionBanner
            }
            searchField
            Divider()
            itemList
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
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.space) { toggleSelected() }
        .onKeyPress(.return) { editSelected() }
        .onKeyPress(keys: [.delete, .deleteForward], phases: .down) { _ in deleteSelected() }
        .onKeyPress(keys: ["c", "C"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            return press.modifiers.contains(.shift) ? copyVisibleList() : copySelected()
        }
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            focus = .search
            return .handled
        }
        .onKeyPress(.escape) {
            // Clear an active filter from any focus; with no filter, fall
            // through to the panel's cancelOperation (hides it).
            guard !uiState.query.isEmpty else { return .ignored }
            uiState.query = ""
            return .handled
        }
        .onChange(of: focus) { _, newFocus in
            // Clicking into another field mid-edit would otherwise strand a
            // stale editor row with uncommitted text and dead arrow keys —
            // `editingID` and `.editor` focus must never diverge.
            if newFocus != .editor, editingID != nil {
                editingID = nil
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

    private var itemList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Focusable so list-level shortcuts (Space, Return, Delete,
                // Cmd+C) have a focus state distinct from the text fields.
                LazyVStack(spacing: 4) {
                    ForEach(visibleItems) { item in
                        ItemRow(
                            item: item,
                            isSelected: item.id == selectedID,
                            isHighlighted: item.id == uiState.highlightedItemID,
                            isEditing: item.id == editingID,
                            editorFocus: $focus,
                            onToggle: { store.toggleDone(id: item.id) },
                            onSelect: { selectedID = item.id },
                            onBeginEdit: { beginEdit(item) },
                            onCommitEdit: { text in commitEdit(id: item.id, text: text) },
                            onCancelEdit: {
                                editingID = nil
                                focus = .list
                            },
                            onCopy: { copy(item) },
                            onCopyList: { _ = copyVisibleList() },
                            onDelete: { delete(id: item.id) }
                        )
                        .id(item.id)
                    }
                    if visibleItems.isEmpty {
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
                    selectedID = added.id
                }
                focus = .quickAdd
            }
    }

    // MARK: - Actions

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let items = visibleItems
        guard !items.isEmpty, editingID == nil, focus != .editor else { return .ignored }
        // First arrow press pulls focus out of the text fields so the
        // list-level shortcuts below become live.
        focus = .list
        let currentIndex = items.firstIndex { $0.id == selectedID }
        let next: Int = if let currentIndex {
            min(max(currentIndex + delta, 0), items.count - 1)
        } else {
            delta > 0 ? 0 : items.count - 1
        }
        selectedID = items[next].id
        return .handled
    }

    private func toggleSelected() -> KeyPress.Result {
        guard focus == .list, let id = selectedID else { return .ignored }
        store.toggleDone(id: id)
        return .handled
    }

    private func editSelected() -> KeyPress.Result {
        guard focus == .list, let item = visibleItems.first(where: { $0.id == selectedID }) else { return .ignored }
        beginEdit(item)
        return .handled
    }

    private func deleteSelected() -> KeyPress.Result {
        guard focus == .list, let id = selectedID else { return .ignored }
        delete(id: id)
        return .handled
    }

    private func delete(id: UUID) {
        store.delete(id: id)
        // A dangling selection would make the next arrow press jump to the
        // list edge instead of a neighbor.
        if selectedID == id {
            selectedID = nil
        }
    }

    private func copySelected() -> KeyPress.Result {
        guard focus == .list, let item = visibleItems.first(where: { $0.id == selectedID }) else { return .ignored }
        copy(item)
        return .handled
    }

    private func copyVisibleList() -> KeyPress.Result {
        // Writing an empty list would wipe the user's clipboard for nothing.
        guard !visibleItems.isEmpty else { return .ignored }
        Pasteboard.write(ItemFormatter.listText(visibleItems))
        return .handled
    }

    private func copy(_ item: Item) {
        Pasteboard.write(ItemFormatter.itemText(item))
    }

    private func beginEdit(_ item: Item) {
        editingID = item.id
        selectedID = item.id
        focus = .editor
    }

    private func commitEdit(id: UUID, text: String) {
        store.updateText(id: id, text: text)
        editingID = nil
        focus = .list
    }
}

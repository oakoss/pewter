import Foundation

/// Multi-selection over an ordered list of item IDs: a selected set plus the
/// anchor (where a range starts) and lead (where the cursor is). Range and
/// stepping operations take the current visible order, so filtering never
/// leaves the model pointing at rows that aren't on screen.
public struct SelectionModel: Equatable, Sendable {
    public private(set) var selected: Set<UUID> = []
    public private(set) var anchor: UUID?
    public private(set) var lead: UUID?

    public init() {}

    public var isEmpty: Bool {
        selected.isEmpty
    }

    public var count: Int {
        selected.count
    }

    /// The selected ID when exactly one item is selected.
    public var single: UUID? {
        selected.count == 1 ? selected.first : nil
    }

    /// True for a deliberately built multi-selection — the state Esc clears
    /// and list copies narrow to.
    public var isMultiple: Bool {
        selected.count > 1
    }

    public func isSelected(_ id: UUID) -> Bool {
        selected.contains(id)
    }

    /// Plain click: selection collapses to the clicked item.
    public mutating func select(_ id: UUID) {
        selected = [id]
        anchor = id
        lead = id
    }

    /// Cmd-click: toggles membership without touching the rest.
    public mutating func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
            if anchor == id {
                anchor = selected.contains(lead ?? id) ? lead : selected.first
            }
            if lead == id {
                lead = anchor
            }
            if selected.isEmpty {
                anchor = nil
                lead = nil
            }
        } else {
            selected.insert(id)
            anchor = id
            lead = id
        }
    }

    /// Shift-click or shift-arrow target: selects the contiguous range from
    /// the anchor to `id` in visible order, replacing the previous selection.
    public mutating func extend(to id: UUID, order: [UUID]) {
        guard let targetIndex = order.firstIndex(of: id) else { return }
        guard let anchor, let anchorIndex = order.firstIndex(of: anchor) else {
            select(id)
            return
        }
        let range = min(anchorIndex, targetIndex) ... max(anchorIndex, targetIndex)
        selected = Set(order[range])
        lead = id
    }

    /// Arrow key: steps the lead by `delta`, collapsing to a single selection,
    /// or extending the range from the anchor when `extending`.
    @discardableResult
    public mutating func step(_ delta: Int, order: [UUID], extending: Bool) -> UUID? {
        guard !order.isEmpty else { return nil }
        let target: UUID = if let lead, let leadIndex = order.firstIndex(of: lead) {
            order[min(max(leadIndex + delta, 0), order.count - 1)]
        } else {
            delta > 0 ? order[0] : order[order.count - 1]
        }
        if extending {
            extend(to: target, order: order)
        } else {
            select(target)
        }
        return target
    }

    /// Replaces the selection with `ids`, dropping any that aren't visible.
    public mutating func replace(with ids: Set<UUID>, order: [UUID]) {
        selected = ids
        anchor = nil
        lead = nil
        prune(order: order)
    }

    public mutating func selectAll(order: [UUID]) {
        guard !order.isEmpty else { return }
        selected = Set(order)
        anchor = order.first
        lead = order.last
    }

    public mutating func clear() {
        selected = []
        anchor = nil
        lead = nil
    }

    /// Drops IDs that are no longer visible (filter change, external edit).
    public mutating func prune(order: [UUID]) {
        selected.formIntersection(order)
        if let current = anchor, !selected.contains(current) {
            anchor = nil
        }
        if let current = lead, !selected.contains(current) {
            lead = nil
        }
        // Repair from visible order, not Set iteration order — the next
        // range operation must extend from a predictable row.
        if anchor == nil {
            anchor = lead ?? order.first(where: { selected.contains($0) })
        }
        if lead == nil {
            lead = anchor
        }
    }

    /// The item to select after the given IDs are removed: the first survivor
    /// after the removed block, else the last one before it. Uses the
    /// pre-removal order.
    public static func survivor(afterRemoving removed: Set<UUID>, order: [UUID]) -> UUID? {
        guard let lastRemoved = order.lastIndex(where: { removed.contains($0) }) else { return nil }
        if let after = order[(lastRemoved + 1)...].first(where: { !removed.contains($0) }) {
            return after
        }
        return order[..<lastRemoved].last { !removed.contains($0) }
    }
}

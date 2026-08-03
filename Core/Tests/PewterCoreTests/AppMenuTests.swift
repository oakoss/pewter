@testable import PewterCore
import Testing

struct AppMenuTests {
    @Test func everyCommandAppearsExactlyOnce() {
        let ids = AppMenu.groups.flatMap(\.self).map(\.id)
        #expect(ids.count == MenuCommand.ID.allCases.count)
        #expect(Set(ids) == Set(MenuCommand.ID.allCases))
    }

    @Test func groupingAndOrderMatchTheShippedMenu() {
        // Order is part of the contract: reveal-first keeps the status-item
        // menu from opening scrolled under the macOS 26 menu-bar band, and
        // docs/manual-testing.md gates on this exact sequence.
        #expect(AppMenu.groups.map { $0.map(\.id) } == [
            [.revealNotesFile],
            [.settings, .permissions, .copyDiagnostics],
            [.quit],
        ])
    }

    @Test func titlesAndKeyEquivalentsMatchTheShippedMenu() {
        let commands = Dictionary(
            uniqueKeysWithValues: AppMenu.groups.flatMap(\.self).map { ($0.id, $0) }
        )
        #expect(commands[.revealNotesFile]?.title == "Reveal Notes File in Finder")
        #expect(commands[.settings]?.title == "Settings…")
        #expect(commands[.permissions]?.title == "Permissions…")
        #expect(commands[.copyDiagnostics]?.title == "Copy Diagnostics")
        #expect(commands[.quit]?.title == "Quit Pewter")

        #expect(commands[.settings]?.keyEquivalent == ",")
        #expect(commands[.quit]?.keyEquivalent == "q")
        #expect(commands[.revealNotesFile]?.keyEquivalent == "")
        #expect(commands[.permissions]?.keyEquivalent == "")
        #expect(commands[.copyDiagnostics]?.keyEquivalent == "")

        // NSMenuItem accepts a single character, and duplicates would
        // collide while the menu is open.
        let nonEmpty = commands.values.map(\.keyEquivalent).filter { !$0.isEmpty }
        #expect(nonEmpty.allSatisfy { $0.count == 1 })
        #expect(Set(nonEmpty).count == nonEmpty.count)
    }
}

#!/usr/bin/env swift

// Dumps a running app's accessibility tree: role, identifier, label, value,
// caret/selection range, and selection state, indented by depth.
//
// This is the diagnostic that localized three VoiceOver bugs which behaviour
// alone could not — roleless elements, labels propagating onto children, and a
// selected row losing its label. Reading the tree shows the structure
// VoiceOver walks, rather than what the SwiftUI source implies.
//
// Usage:
//   swift tools/axdump.swift [bundle-id] [--grep substring]
//
// Defaults to com.oakoss.Pewter. The panel must be open — it is a separate
// window and vanishes from the tree when hidden.
//
// Requires Accessibility trust for the process that RUNS this (your terminal,
// not Pewter), and an unsandboxed run. Without it every query returns
// kAXErrorAPIDisabled and the dump is empty.

import AppKit
import ApplicationServices
import Foundation

let arguments = CommandLine.arguments
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("""
    \(message)

    usage: swift tools/axdump.swift [bundle-id] [--grep substring]

    """.utf8))
    exit(2)
}

// Consumed by position, not by value: matching on value accepts a repeated
// token because the duplicate is already in the consumed set, so
// `axdump com.oakoss.Pewter com.oakoss.Pewter` silently dumps the first and
// drops the second rather than saying the command made no sense.
var next = 1
var bundleID = "com.oakoss.Pewter"
if next < arguments.count, !arguments[next].hasPrefix("--") {
    bundleID = arguments[next]
    next += 1
}

var filter: String?
if next < arguments.count {
    guard arguments[next] == "--grep" else {
        fail("Unrecognized argument \(arguments[next].debugDescription).")
    }
    // A missing or flag-shaped value used to leave the filter nil, which
    // dumps the whole tree at exit 0 — a silent success that reads exactly
    // like "your filter matched everything".
    guard next + 1 < arguments.count, !arguments[next + 1].hasPrefix("--") else {
        fail("--grep needs a value.")
    }
    filter = arguments[next + 1]
    next += 2
}

if next < arguments.count {
    fail("Unrecognized argument \(arguments[next].debugDescription).")
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("""
    Not trusted for Accessibility.

    Grant the app running this — your terminal, not Pewter — access in
    System Settings > Privacy & Security > Accessibility, then re-run.

    """.utf8))
    exit(2)
}

guard let app = NSWorkspace.shared.runningApplications
    .first(where: { $0.bundleIdentifier == bundleID })
else {
    FileHandle.standardError.write(Data("No running app with bundle id \(bundleID)\n".utf8))
    exit(1)
}

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    if let text = value as? String { return text.isEmpty ? nil : text }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

/// The selected *range*, not the selected text: a collapsed caret selects no
/// text at all, so text alone cannot tell "nothing is selected" apart from
/// "this element has no selection to report". The location carries the other
/// half — where the caret actually sits.
///
/// Never silent: the caller asks only about roles that should carry a range,
/// so every failure here is an anomaly and absence would be read as "nothing
/// is selected" — signing off a caret assertion this never actually made.
func selectedRange(_ element: AXUIElement) -> String {
    var value: CFTypeRef?
    switch AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) {
    case .success: break
    case .attributeUnsupported: return "«unsupported»"
    case let status: return "«unreadable: \(status.rawValue)»"
    }
    guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return "«not an AXValue»" }
    // The type id above is what makes this cast safe; AXValue is a CF type,
    // so a conditional cast here would not do the checking for us.
    let axValue = value as! AXValue
    var range = CFRange()
    guard AXValueGetValue(axValue, .cfRange, &range) else {
        return "«not a range: type \(AXValueGetType(axValue).rawValue)»"
    }
    return "(\(range.location),\(range.length))"
}

/// Roles whose selection is worth printing. Everything else — menus, groups,
/// the menu bar — answers the query with (0,0), which on every line buries the
/// one a caret assertion is read from.
let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole]

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement]
    else { return [] }
    return list
}

/// One line per element. The identifier is printed first and unabbreviated:
/// it is the handle automation queries by, and the whole reason to read this.
func describe(_ element: AXUIElement) -> String {
    var parts: [String] = []
    let role = string(element, kAXRoleAttribute as String)
    parts.append(role ?? "«no role»")
    if let id = string(element, kAXIdentifierAttribute as String) {
        parts.append("id=\(id)")
    }
    if let label = string(element, kAXDescriptionAttribute as String)
        ?? string(element, kAXTitleAttribute as String)
    {
        parts.append("label=\(label.prefix(60).debugDescription)")
    }
    if let value = string(element, kAXValueAttribute as String) {
        parts.append("value=\(value.prefix(60).debugDescription)")
    }
    // Keyed on role, not on having a value: an empty field would otherwise
    // report no selection at all, which is the silence this prints to avoid.
    if let role, textRoles.contains(role) {
        parts.append("sel=\(selectedRange(element))")
    }
    if string(element, kAXSelectedAttribute as String) == "1" {
        parts.append("SELECTED")
    }
    return parts.joined(separator: "  ")
}

var matches = 0

func walk(_ element: AXUIElement, depth: Int) {
    let line = describe(element)
    if let filter {
        if line.localizedCaseInsensitiveContains(filter) {
            matches += 1
            print(String(repeating: "  ", count: depth) + line)
        }
    } else {
        print(String(repeating: "  ", count: depth) + line)
    }
    // Depth cap: a runaway hierarchy (or a cycle a buggy element exposes)
    // would otherwise print until the terminal gives up.
    let kids = children(element)
    guard depth < 40 else {
        // Marked rather than silent — the whole value of this dump is
        // trusting the structure, and a truncated branch must not read as a
        // leaf. Only when there is something to truncate: a real leaf at the
        // cap would otherwise be labelled as hiding children it never had.
        // Suppressed under `--grep`, where an unmatched branch prints nothing
        // and a lone marker would contradict the "no matches" exit.
        if !kids.isEmpty, filter == nil {
            print(String(repeating: "  ", count: depth + 1) + "… (depth cap)")
        }
        return
    }
    for child in kids {
        walk(child, depth: depth + 1)
    }
}

walk(AXUIElementCreateApplication(app.processIdentifier), depth: 0)

if let filter, matches == 0 {
    FileHandle.standardError.write(Data("No elements matched \(filter.debugDescription)\n".utf8))
    exit(1)
}

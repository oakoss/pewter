import Foundation

/// Generic HTML lexing shared by `HTMLMarkdown`'s parser: entity decoding,
/// attribute scanning, inline-style values, whitespace collapsing. Pure
/// string routines, split out so they are tested directly rather than only
/// through whole-document conversions.
enum HTMLLexer {
    private static let namedEntities: [Substring: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "\u{2018}",
        "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "times": "×", "laquo": "«", "raquo": "»", "deg": "°",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            rest = rest[ampersand...].dropFirst()
            guard let semicolon = rest.prefix(10).firstIndex(of: ";") else {
                result += "&"
                continue
            }
            let entity = rest[..<semicolon]
            if let replacement = namedEntities[entity] {
                result += replacement
                rest = rest[rest.index(after: semicolon)...]
            } else if entity.hasPrefix("#"),
                      let scalar = numericScalar(entity.dropFirst())
            {
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result += "&"
            }
        }
        result += rest
        return result
    }

    private static func numericScalar(_ digits: Substring) -> Unicode.Scalar? {
        let value: UInt32? = digits.hasPrefix("x") || digits.hasPrefix("X")
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits)
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        // C0 controls other than tab/newline have no place in a notes
        // file — "&#0;" must not inject a NUL.
        if value < 0x20, value != 0x09, value != 0x0A, value != 0x0D {
            return nil
        }
        return scalar
    }

    /// Positional left-to-right scan — substring-searching for the name
    /// would match a "name=" that sits inside another attribute's quoted
    /// value.
    static func attribute(_ name: String, in attributes: String) -> String? {
        let name = name.lowercased()
        var rest = Substring(attributes)
        while true {
            rest = rest.drop(while: { $0.isWhitespace || $0 == "/" })
            guard let first = rest.first, first != ">" else { return nil }
            let attributeName = rest.prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":"
            }
            guard !attributeName.isEmpty else { return nil }
            rest = rest.dropFirst(attributeName.count).drop(while: \.isWhitespace)

            var value: Substring = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    rest = rest.dropFirst()
                    value = rest.prefix { $0 != quote }
                    rest = rest.dropFirst(value.count).dropFirst()
                } else {
                    value = rest.prefix { !$0.isWhitespace && $0 != ">" }
                    rest = rest.dropFirst(value.count)
                }
            }
            if attributeName.lowercased() == name {
                return decodeEntities(String(value))
            }
        }
    }

    static func styleValue(_ property: String, in style: String) -> String? {
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == property else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func collapseWhitespace(_ text: String) -> String {
        guard text.contains(where: \.isWhitespace) else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace {
                    result.append(" ")
                }
                pendingSpace = false
                result.append(character)
            }
        }
        if pendingSpace {
            result.append(" ")
        }
        return result
    }
}

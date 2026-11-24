import Foundation

// MARK: - Ordered JSON
//
// A JSON document that keeps member order and the spelling of every scalar.
// The Claude Code settings configurator writes into `~/.claude/settings.json`,
// which also holds keys that are nobody else's business: a write must change
// the managed keys and reproduce every other byte. Foundation's JSONDecoder
// and JSONSerialization cannot promise that (unordered, re-spelled, reformatted).

/// A member of a JSON object, with its key, in document order.
struct JSONMember: Sendable, Equatable {
    var key: String
    var value: JSONNode
    init(_ key: String, _ value: JSONNode) {
        self.key = key
        self.value = value
    }
}

/// A JSON string: its value, and the spelling it was read with.
struct JSONString: Sendable, Equatable {
    var value: String
    /// The lexeme as written, e.g. `"café"`; nil for a string created in code.
    var raw: String?
    init(_ value: String, raw: String? = nil) {
        self.value = value
        self.raw = raw
    }

    /// Re-emits the original spelling. A new string is escaped the way a JSON writer escapes it.
    var lexeme: String { raw ?? JSONString.escape(value) }

    static func == (lhs: JSONString, rhs: JSONString) -> Bool { lhs.value == rhs.value }

    /// Escapes `"`, `\` and control characters; every other character is emitted as is.
    static func escape(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// A JSON value. A number is its lexeme as written, so `1.0` and `1e5` stay that way.
indirect enum JSONNode: Sendable, Equatable {
    case object(members: [JSONMember])
    case array([JSONNode])
    case string(JSONString)
    case number(String)
    case bool(Bool)
    case null
}

/// How a document is laid out. Detected from the text when parsing, so an edit
/// is written in the file's own style.
struct JSONStyle: Sendable, Equatable {
    /// One level of indentation; empty means the document is written on one line.
    var indent: String
    /// Between a key and its value: `": "` or `":"`.
    var separator: String
    /// Between members of a one-line document: `","` or `", "`.
    var itemSeparator: String
    var newline: String
    var trailingNewline: Bool

    /// How Claude Code writes `settings.json`: two spaces, no trailing newline.
    static let claudeCode = JSONStyle(indent: "  ", separator: ": ", itemSeparator: ",",
                                      newline: "\n", trailingNewline: false)
}

// MARK: - Errors

struct JSONPosition: Sendable, Equatable {
    let line: Int
    let column: Int
}

enum JSONParseError: Error, CustomStringConvertible, Equatable {
    case unexpectedCharacter(UInt8, at: JSONPosition)
    case unexpectedEnd(at: JSONPosition)
    case unterminatedString(at: JSONPosition)
    case controlCharacter(at: JSONPosition)
    case duplicateKey(String, at: JSONPosition)
    case invalidEscape(at: JSONPosition)
    case invalidUTF8

    var description: String {
        func place(_ p: JSONPosition) -> String { "line \(p.line), column \(p.column)" }
        switch self {
        case .unexpectedCharacter(let byte, let p):
            let shown = (0x20...0x7E).contains(byte) ? String(UnicodeScalar(byte)) : String(format: "0x%02X", byte)
            return "\(place(p)): unexpected character \(shown)"
        case .unexpectedEnd(let p): return "\(place(p)): unexpected end of input"
        case .unterminatedString(let p): return "\(place(p)): unterminated string"
        case .controlCharacter(let p): return "\(place(p)): control character in a string"
        case .duplicateKey(let key, let p): return "\(place(p)): duplicate key \"\(key)\""
        case .invalidEscape(let p): return "\(place(p)): invalid escape sequence in a string"
        case .invalidUTF8: return "the file is not valid UTF-8"
        }
    }
}

// MARK: - Document

/// A parsed JSON document: its values and the style to write them back in.
struct JSONText: Sendable, Equatable {
    var root: JSONNode
    let style: JSONStyle

    init(root: JSONNode, style: JSONStyle) {
        self.root = root
        self.style = style
    }

    /// Strict JSON: duplicates, control characters in strings, trailing text and a BOM are rejected.
    init(parsing text: String) throws {
        var parser = JSONParser(text)
        let parsed = try parser.parseDocument()
        root = parsed.root
        style = parsed.style
    }

    init(parsing data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONParseError.invalidUTF8
        }
        try self.init(parsing: text)
    }

    /// An empty object, to be written the way Claude Code writes the file.
    static func empty() -> JSONText {
        JSONText(root: .object(members: []), style: .claudeCode)
    }

    /// The whole document, with the values as they are now and the style they were read in.
    var serialized: String {
        var out = ""
        JSONSerializer.write(root, style: style, depth: 0, into: &out)
        if style.trailingNewline { out += style.newline }
        return out
    }

    var data: Data { Data(serialized.utf8) }
}

// MARK: - Node access

extension JSONNode {
    /// A string created in code: nothing to preserve.
    static func string(_ value: String) -> JSONNode { .string(JSONString(value)) }

    var objectMembers: [JSONMember]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var arrayElements: [JSONNode]? {
        if case .array(let elements) = self { return elements }
        return nil
    }

    var stringValue: String? {
        if case .string(let string) = self { return string.value }
        return nil
    }

    /// A string's value, or a number as written.
    var text: String? {
        switch self {
        case .string(let string): return string.value
        case .number(let lexeme): return lexeme
        default: return nil
        }
    }

    /// The value of an integer written without a fraction or exponent; nil otherwise.
    var intValue: Int? {
        if case .number(let lexeme) = self { return Int(lexeme) }
        return nil
    }

    func value(at path: [String]) -> JSONNode? {
        var node = self
        for key in path {
            guard let next = node.objectMembers?.first(where: { $0.key == key })?.value else { return nil }
            node = next
        }
        return node
    }

    /// Sets a value at a path, creating the objects on the way. A new key goes
    /// at the end of its object; an existing one keeps its place.
    mutating func set(_ node: JSONNode, at path: [String]) {
        guard let key = path.first else { return }
        if path.count == 1 {
            setMember(key, node)
            return
        }
        var child = self.objectMembers?.first(where: { $0.key == key })?.value ?? .object(members: [])
        if child.objectMembers == nil { child = .object(members: []) }
        child.set(node, at: Array(path.dropFirst()))
        setMember(key, child)
    }

    private mutating func setMember(_ key: String, _ value: JSONNode) {
        guard case .object(var members) = self else { return }
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append(JSONMember(key, value))
        }
        self = .object(members: members)
    }

    /// Removes the value at a path. An object left empty by the removal goes
    /// too, up to and not including the root.
    mutating func remove(at path: [String]) {
        _ = removing(at: path)
    }

    /// Returns true when the receiver is an object that is now empty.
    private mutating func removing(at path: [String]) -> Bool {
        guard let key = path.first, case .object(var members) = self else { return false }
        if path.count == 1 {
            members.removeAll { $0.key == key }
        } else if let index = members.firstIndex(where: { $0.key == key }) {
            var child = members[index].value
            if child.removing(at: Array(path.dropFirst())) {
                members.removeAll { $0.key == key }
            } else {
                members[index].value = child
            }
        }
        self = .object(members: members)
        return members.isEmpty
    }

    /// Renames a key of the object at a path, in place. Does nothing when the
    /// old key is absent or the new one is taken.
    mutating func renameMember(ofObjectAt path: [String], from oldKey: String, to newKey: String) {
        var object = self
        for key in path {
            guard let next = object.objectMembers?.first(where: { $0.key == key })?.value else { return }
            object = next
        }
        guard case .object(var members) = object,
              let index = members.firstIndex(where: { $0.key == oldKey }),
              !members.contains(where: { $0.key == newKey })
        else { return }
        members[index].key = newKey
        let renamed = JSONNode.object(members: members)
        if path.isEmpty {
            self = renamed
        } else {
            set(renamed, at: path)
        }
    }
}

// MARK: - Parser

/// Recursive descent over the UTF-8 bytes. Records the document's style while
/// it reads: the indentation before the first member, the spacing after the
/// first colon and the first comma, the line ending, a trailing newline.
private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var sawNewline = false
    private var sawCR = false
    private var sawMember = false
    private var firstMemberIndent = ""
    // An empty document shows no spacing to read; new members get Claude Code's.
    private var separator = JSONStyle.claudeCode.separator
    private var itemSeparator = JSONStyle.claudeCode.itemSeparator

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    mutating func parseDocument() throws -> (root: JSONNode, style: JSONStyle) {
        skipWhitespace()
        let root = try parseValue(depth: 0)
        let trailing = skipWhitespace()
        guard index == bytes.count else { throw unexpected(bytes[index]) }
        var style = JSONStyle.claudeCode
        if sawNewline {
            style.indent = firstMemberIndent.isEmpty ? "  " : firstMemberIndent
        } else if sawMember {
            style.indent = ""
        }
        style.separator = separator
        style.itemSeparator = itemSeparator
        style.newline = sawCR ? "\r\n" : "\n"
        style.trailingNewline = trailing.hasSuffix("\n")
        return (root, style)
    }

    // MARK: Values

    private mutating func parseValue(depth: Int) throws -> JSONNode {
        guard index < bytes.count else { throw unexpectedEnd() }
        switch bytes[index] {
        case 0x7B: return try parseObject(depth: depth)
        case 0x5B: return try parseArray(depth: depth)
        case 0x22: return .string(try parseString())
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6E: try literal("null"); return .null
        case 0x2D, 0x30...0x39: return .number(try parseNumber())
        default: throw unexpected(bytes[index])
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONNode {
        index += 1
        let leading = skipWhitespace()
        if depth == 0 { firstMemberIndent = text(afterLastNewlineIn: leading) }
        if peek() == 0x7D {
            index += 1
            return .object(members: [])
        }
        var members: [JSONMember] = []
        var keys = Set<String>()
        while true {
            guard let byte = peek() else { throw unexpectedEnd() }
            guard byte == 0x22 else { throw unexpected(byte) }
            let keyStart = index
            let key = try parseString()
            if !keys.insert(key.value).inserted { throw JSONParseError.duplicateKey(key.value, at: position(keyStart)) }
            skipWhitespace()
            guard let colon = peek() else { throw unexpectedEnd() }
            guard colon == 0x3A else { throw unexpected(colon) }
            index += 1
            let afterColon = skipWhitespace()
            if !sawMember { separator = afterColon.contains(" ") ? ": " : ":" }
            let value = try parseValue(depth: depth + 1)
            members.append(JSONMember(key.value, value))
            let wasFirst = !sawMember
            sawMember = true
            skipWhitespace()
            guard let next = peek() else { throw unexpectedEnd() }
            if next == 0x2C {
                index += 1
                let afterComma = skipWhitespace()
                if wasFirst { itemSeparator = afterComma == " " ? ", " : "," }
                continue
            }
            if next == 0x7D {
                index += 1
                return .object(members: members)
            }
            throw unexpected(next)
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONNode {
        index += 1
        skipWhitespace()
        var elements: [JSONNode] = []
        if peek() == 0x5D {
            index += 1
            return .array(elements)
        }
        while true {
            elements.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard let next = peek() else { throw unexpectedEnd() }
            if next == 0x2C {
                index += 1
                skipWhitespace()
                continue
            }
            if next == 0x5D {
                index += 1
                return .array(elements)
            }
            throw unexpected(next)
        }
    }

    /// A quoted string. The lexeme is kept for writing; the value is decoded
    /// only when it contains an escape.
    private mutating func parseString() throws -> JSONString {
        let start = index
        index += 1
        var hasEscape = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 { break }
            if byte < 0x20 { throw JSONParseError.controlCharacter(at: position(index)) }
            if byte == 0x5C {
                hasEscape = true
                index += 2
                continue
            }
            index += 1
        }
        guard index < bytes.count else { throw JSONParseError.unterminatedString(at: position(start)) }
        index += 1
        let raw = String(decoding: bytes[start..<index], as: UTF8.self)
        let content = String(raw.dropFirst().dropLast())
        guard hasEscape else { return JSONString(content, raw: raw) }
        do {
            return JSONString(try Self.unescape(content), raw: raw)
        } catch {
            // The only failure inside is a bad escape; it is reported at the string.
            throw JSONParseError.invalidEscape(at: position(start))
        }
    }

    private struct InvalidEscape: Error {}

    /// Value of a hexadecimal digit, or nil.
    private static func hexDigit(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar {
        case "0"..."9": return Int(scalar.value - 48)
        case "A"..."F": return Int(scalar.value - 55)
        case "a"..."f": return Int(scalar.value - 87)
        default: return nil
        }
    }

    private static func unescape(_ content: String) throws -> String {
        var out = ""
        let scalars = Array(content.unicodeScalars)
        var i = 0
        func hexUnit() -> Int? {
            guard i + 4 <= scalars.count else { return nil }
            var unit = 0
            for s in scalars[i..<i + 4] {
                guard let digit = Self.hexDigit(s) else { return nil }
                unit = unit * 16 + digit
            }
            i += 4
            return unit
        }
        func invalid() -> InvalidEscape { InvalidEscape() }
        while i < scalars.count {
            let scalar = scalars[i]
            i += 1
            guard scalar == "\\" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard i < scalars.count else { throw invalid() }
            let escape = scalars[i]
            i += 1
            switch escape {
            case "\"": out += "\""
            case "\\": out += "\\"
            case "/": out += "/"
            case "b": out.unicodeScalars.append("\u{08}")
            case "f": out.unicodeScalars.append("\u{0C}")
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "u":
                guard let unit = hexUnit() else { throw invalid() }
                if (0xD800...0xDBFF).contains(unit) {
                    // A high surrogate must be followed by `\u` and a low surrogate.
                    guard i + 2 <= scalars.count, scalars[i] == "\\", scalars[i + 1] == "u" else { throw invalid() }
                    i += 2
                    guard let low = hexUnit(), (0xDC00...0xDFFF).contains(low) else { throw invalid() }
                    let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                    out.unicodeScalars.append(Unicode.Scalar(combined)!)
                } else if (0xDC00...0xDFFF).contains(unit) {
                    throw invalid()
                } else {
                    out.unicodeScalars.append(Unicode.Scalar(unit)!)
                }
            default:
                throw invalid()
            }
        }
        return out
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        if peek() == 0x2D { index += 1 }
        guard let first = peek() else { throw unexpectedEnd() }
        if first == 0x30 {
            index += 1
        } else if (0x31...0x39).contains(first) {
            skipDigits()
        } else {
            throw unexpected(first)
        }
        if peek() == 0x2E {
            index += 1
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw peek().map { unexpected($0) } ?? unexpectedEnd()
            }
            skipDigits()
        }
        if let marker = peek(), marker == 0x65 || marker == 0x45 {
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
            guard let digit = peek(), (0x30...0x39).contains(digit) else {
                throw peek().map { unexpected($0) } ?? unexpectedEnd()
            }
            skipDigits()
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private mutating func literal(_ word: String) throws {
        for expected in word.utf8 {
            guard let byte = peek() else { throw unexpectedEnd() }
            guard byte == expected else { throw unexpected(byte) }
            index += 1
        }
    }

    // MARK: Helpers

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipDigits() {
        while let byte = peek(), (0x30...0x39).contains(byte) { index += 1 }
    }

    /// Skips spaces, tabs, carriage returns and line feeds; returns what it skipped.
    @discardableResult
    private mutating func skipWhitespace() -> String {
        let start = index
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            if byte == 0x0A { sawNewline = true }
            if byte == 0x0D { sawCR = true }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }

    private func text(afterLastNewlineIn whitespace: String) -> String {
        guard let lineStart = whitespace.lastIndex(of: "\n") else { return "" }
        return String(whitespace[whitespace.index(after: lineStart)...])
    }

    private func position(_ offset: Int) -> JSONPosition {
        var line = 1
        var lineStart = 0
        for i in 0..<min(offset, bytes.count) where bytes[i] == 0x0A {
            line += 1
            lineStart = i + 1
        }
        return JSONPosition(line: line, column: offset - lineStart + 1)
    }

    private func unexpected(_ byte: UInt8) -> JSONParseError {
        .unexpectedCharacter(byte, at: position(index))
    }

    private func unexpectedEnd() -> JSONParseError {
        .unexpectedEnd(at: position(index))
    }
}

// MARK: - Serializer

/// Writes a document the way a JSON writer would: one member per line inside
/// its indentation, empty containers as `{}` and `[]`, or everything on one
/// line when the style's indent is empty.
private enum JSONSerializer {
    static func write(_ node: JSONNode, style: JSONStyle, depth: Int, into out: inout String) {
        let multiline = !style.indent.isEmpty
        switch node {
        case .object(let members) where members.isEmpty:
            out += "{}"
        case .object(let members):
            out += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { out += style.itemSeparator }
                if multiline { out += style.newline + String(repeating: style.indent, count: depth + 1) }
                out += member.key.lexeme + style.separator
                write(member.value, style: style, depth: depth + 1, into: &out)
            }
            if multiline { out += style.newline + String(repeating: style.indent, count: depth) }
            out += "}"
        case .array(let elements) where elements.isEmpty:
            out += "[]"
        case .array(let elements):
            out += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { out += style.itemSeparator }
                if multiline { out += style.newline + String(repeating: style.indent, count: depth + 1) }
                write(element, style: style, depth: depth + 1, into: &out)
            }
            if multiline { out += style.newline + String(repeating: style.indent, count: depth) }
            out += "]"
        case .string(let string):
            out += string.lexeme
        case .number(let lexeme):
            out += lexeme
        case .bool(let value):
            out += value ? "true" : "false"
        case .null:
            out += "null"
        }
    }
}

private extension String {
    var lexeme: String { JSONString(self).lexeme }
}

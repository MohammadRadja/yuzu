import Foundation

/// Deliberately bounded YAML subset with JSON-compatible scalars. Unsupported
/// YAML features fail explicitly instead of silently changing their meaning.
enum YAMLDocument {
    private struct Line { let indent: Int; let value: String }
    private struct Parser {
        var lines: [Line]
        var index = 0
        mutating func block(_ indent: Int, depth: Int = 0) throws -> Any {
            guard depth < 64, index < lines.count else { throw failure() }
            let sequence = lines[index].value == "-" || lines[index].value.hasPrefix("- ")
            var array: [Any] = [], object: [String: Any] = [:]
            while index < lines.count && lines[index].indent == indent {
                let line = lines[index].value
                index += 1
                if sequence {
                    guard line == "-" || line.hasPrefix("- ") else { throw failure() }
                    let rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                    if rest.isEmpty {
                        array.append(try nested(indent, depth: depth))
                    } else if splitMapping(rest) != nil {
                        lines.insert(Line(indent: indent + 2, value: rest), at: index)
                        array.append(try block(indent + 2, depth: depth + 1))
                    } else {
                        array.append(try scalar(rest))
                    }
                } else if let (key, value) = splitMapping(line) {
                    guard let name = try scalar(key) as? String, object[name] == nil else { throw failure() }
                    object[name] = value.isEmpty ? try nested(indent, depth: depth) : try scalar(value)
                } else {
                    guard object.isEmpty else { throw failure() }
                    return try scalar(line)
                }
            }
            return sequence ? array : object
        }
        mutating func nested(_ indent: Int, depth: Int) throws -> Any {
            if index < lines.count && lines[index].indent > indent { return try block(lines[index].indent, depth: depth + 1) }
            return NSNull()
        }
    }
    private static func failure() -> YuzuError {
        .invalidInput(
            "Unsupported YAML. Use block mappings/sequences, JSON flow values, and single-line scalars. Anchors, tags, complex keys, multiline scalars, and multiple documents are not supported."
        )
    }
    private static func splitMapping(_ line: String) -> (String, String)? {
        var quote: Character?, escaped = false
        let chars = Array(line)
        for index in chars.indices {
            let char = chars[index]
            if escaped { escaped = false; continue }
            if char == "\\" && quote == "\"" { escaped = true; continue }
            if let active = quote { if char == active { quote = nil }; continue }
            if (char == "\"" || char == "'") && (index == 0 || chars[index - 1].isWhitespace || "[{,:".contains(chars[index - 1])) { quote = char; continue }
            if char == ":" && (index + 1 == chars.count || chars[index + 1].isWhitespace) {
                return (String(chars[..<index]).trimmingCharacters(in: .whitespaces), String(chars[(index + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }
    private static func scalar(_ raw: String) throws -> Any {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !["&", "*", "!", "|", ">", "?", "%"].contains(String(value.prefix(1))) else { throw failure() }
        if value.hasPrefix("'") {
            guard value.hasSuffix("'"), value.count >= 2 else { throw failure() }
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let json = try? JSONSerialization.jsonObject(with: Data(value.utf8), options: [.fragmentsAllowed]) { return json }
        if value.hasPrefix("\"") || value.hasPrefix("[") || value.hasPrefix("{") { throw failure() }
        if value == "~" || value.lowercased() == "null" { return NSNull() }
        if value.lowercased() == "true" { return true }
        if value.lowercased() == "false" { return false }
        // Reject non-JSON numeric spellings rather than silently converting YAML
        // numbers (hex, octal, leading zeros, infinities) into JSON strings.
        if value.range(of: "^[+-]?(?:[0-9]|\\.[0-9])", options: .regularExpression) != nil || [".nan", ".inf", "+.inf", "-.inf"].contains(value.lowercased()) {
            throw YuzuError.invalidInput("Use JSON number syntax in YAML, or quote this scalar explicitly: \(value).")
        }
        return value
    }
    static func read(_ text: String) throws -> Any {
        guard text.utf8.count <= 8_388_608 else { throw failure() }
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) { return json }
        var lines: [Line] = []
        for raw in text.components(separatedBy: .newlines) {
            guard !raw.contains("\t") else { throw failure() }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed == "---" && lines.isEmpty { continue }
            guard trimmed != "---", trimmed != "..." else { throw failure() }
            var quote: Character?, escaped = false, content = ""
            for char in trimmed {
                if char == "#" && quote == nil && (content.isEmpty || content.last?.isWhitespace == true) { break }
                let previous = content.last
                content.append(char)
                if escaped { escaped = false; continue }
                if char == "\\" && quote == "\"" { escaped = true; continue }
                if let active = quote {
                    if char == active { quote = nil }
                } else if (char == "\"" || char == "'") && (previous == nil || previous?.isWhitespace == true || previous.map({ "[{,:".contains($0) }) == true)
                {
                    quote = char
                }
            }
            guard quote == nil else { throw failure() }
            lines.append(Line(indent: raw.prefix(while: { $0 == " " }).count, value: content.trimmingCharacters(in: .whitespaces)))
            guard lines.count <= 10_000 else { throw failure() }
        }
        guard let first = lines.first else { return NSNull() }
        var parser = Parser(lines: lines)
        let result = try parser.block(first.indent)
        guard parser.index == parser.lines.count else { throw failure() }
        return result
    }
    static func write(_ value: Any, indent: Int = 0) throws -> String {
        guard indent < 128 else { throw failure() }
        let pad = String(repeating: " ", count: indent)
        if let object = value as? [String: Any], !object.isEmpty {
            return try object.keys.sorted().map { key in
                let escaped = String(decoding: try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]), as: UTF8.self)
                return pad + escaped + ":\n" + (try write(object[key] ?? NSNull(), indent: indent + 2))
            }.joined(separator: "\n")
        }
        if let array = value as? [Any], !array.isEmpty {
            return try array.map { pad + "-\n" + (try write($0, indent: indent + 2)) }.joined(separator: "\n")
        }
        return pad + String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
    }
}

enum XMLJSON {
    private static func escape(_ value: String) throws -> String {
        guard
            value.unicodeScalars.allSatisfy({ scalar in
                [9, 10, 13].contains(scalar.value) || (scalar.value >= 0x20 && scalar.value <= 0xfffd) || scalar.value >= 0x10000
            })
        else { throw YuzuError.invalidInput("This value contains control characters XML 1.0 cannot represent. Use JSON or YAML to preserve the data.") }
        return DocumentPackage.escape(value).replacingOccurrences(of: "\r", with: "&#13;")
    }
    private static func attribute(_ value: String) throws -> String {
        try escape(value).replacingOccurrences(of: "\n", with: "&#10;").replacingOccurrences(of: "\t", with: "&#9;")
    }
    static func read(_ text: String) throws -> Any {
        guard text.utf8.count <= 8_388_608 else { throw YuzuError.invalidInput("XML exceeds the 8 MiB limit.") }
        _ = try DocumentXML.parse(text)
        let document = try XMLDocument(xmlString: text, options: [.nodeLoadExternalEntitiesNever])
        guard let root = document.rootElement() else { throw YuzuError.invalidInput("XML has no root element.") }
        if root.name == "yuzu-json", root.attribute(forName: "version")?.stringValue == "1",
            let node = root.children?.first(where: { $0.kind == .element }) as? XMLElement
        {
            return try decode(node)
        }
        func element(_ node: XMLElement) -> [String: Any] {
            var attrs: [String: String] = [:]
            for attribute in node.attributes ?? [] { if let name = attribute.name { attrs[name] = attribute.stringValue ?? "" } }
            for namespace in node.namespaces ?? [] {
                attrs[namespace.name?.isEmpty == false ? "xmlns:" + (namespace.name ?? "") : "xmlns"] = namespace.stringValue ?? ""
            }
            let children: [Any] = (node.children ?? []).compactMap { child in
                if let child = child as? XMLElement { return element(child) }
                return child.kind == .text ? child.stringValue : nil
            }
            return ["name": node.name ?? "node", "attributes": attrs, "children": children]
        }
        return ["$xml": element(root)]
    }
    private static func decode(_ node: XMLElement, depth: Int = 0) throws -> Any {
        guard depth < 64 else { throw YuzuError.invalidInput("XML nesting limit exceeded.") }
        let children = (node.children ?? []).compactMap { $0 as? XMLElement }
        switch node.name {
        case "object":
            var object: [String: Any] = [:]
            for member in children {
                guard member.name == "member", let name = member.attribute(forName: "name")?.stringValue,
                    object[name] == nil, let value = member.children?.first(where: { $0.kind == .element }) as? XMLElement
                else { throw YuzuError.invalidInput("Invalid JSON XML mapping.") }
                object[name] = try decode(value, depth: depth + 1)
            }
            return object
        case "array": return try children.map { try decode($0, depth: depth + 1) }
        case "string": return node.stringValue ?? ""
        case "null": return NSNull()
        case "boolean", "number": return try JSONSerialization.jsonObject(with: Data((node.stringValue ?? "").utf8), options: [.fragmentsAllowed])
        default: throw YuzuError.invalidInput("Invalid JSON XML value type.")
        }
    }
    static func write(_ value: Any) throws -> String {
        // Only consume the exact node schema emitted by read(). A normal JSON
        // object may also contain "$xml"; treating every such key as a mapping
        // would silently discard its siblings or additional node properties.
        func isNodeMapping(_ object: [String: Any], depth: Int = 0) -> Bool {
            guard depth < 64, Set(object.keys) == ["name", "attributes", "children"],
                object["name"] is String, object["attributes"] is [String: String], let children = object["children"] as? [Any]
            else { return false }
            return children.allSatisfy { child in
                if child is String { return true }
                guard let node = child as? [String: Any] else { return false }
                return isNodeMapping(node, depth: depth + 1)
            }
        }
        func encode(_ value: Any, depth: Int) throws -> String {
            guard depth < 64 else { throw YuzuError.invalidInput("JSON nesting limit exceeded.") }
            if let object = value as? [String: Any] {
                return "<object>"
                    + (try object.keys.sorted().map {
                        "<member name=\"\(try attribute($0))\">" + (try encode(object[$0] ?? NSNull(), depth: depth + 1)) + "</member>"
                    }.joined()) + "</object>"
            }
            if let array = value as? [Any] { return "<array>" + (try array.map { try encode($0, depth: depth + 1) }.joined()) + "</array>" }
            if value is NSNull { return "<null/>" }
            if let string = value as? String { return "<string>\(try escape(string))</string>" }
            let scalar = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
            let type = scalar == "true" || scalar == "false" ? "boolean" : "number"
            return "<\(type)>\(scalar)</\(type)>"
        }
        func node(_ object: [String: Any], depth: Int = 0) throws -> String {
            guard depth < 64, let name = object["name"] as? String,
                name.range(of: "^[\\p{L}_][\\p{L}\\p{N}\\p{M}_.:-]*$", options: .regularExpression) != nil,
                let children = object["children"] as? [Any], let attrs = object["attributes"] as? [String: String]
            else { throw YuzuError.invalidInput("Invalid XML node mapping.") }
            var attributes = ""
            for key in attrs.keys.sorted() {
                guard key.range(of: "^[\\p{L}_][\\p{L}\\p{N}\\p{M}_.:-]*$", options: .regularExpression) != nil else {
                    throw YuzuError.invalidInput("Invalid XML attribute name.")
                }
                attributes += " \(key)=\"\(try attribute(attrs[key] ?? ""))\""
            }
            let content = try children.map { child -> String in
                if let text = child as? String { return try escape(text) }
                guard let object = child as? [String: Any] else { throw YuzuError.invalidInput("Invalid XML child.") }
                return try node(object, depth: depth + 1)
            }.joined()
            return "<\(name)\(attributes)>\(content)</\(name)>"
        }
        let xml: String
        if let object = value as? [String: Any], object.count == 1, let mapping = object["$xml"] as? [String: Any], isNodeMapping(mapping) {
            xml = try node(mapping)
        } else {
            xml = "<yuzu-json version=\"1\">" + (try encode(value, depth: 0)) + "</yuzu-json>"
        }
        _ = try DocumentXML.parse(xml)
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + xml
    }
}

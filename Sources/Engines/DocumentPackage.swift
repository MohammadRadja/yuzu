import Foundation

enum DocumentPackage {
    static func escape(_ text: String) -> String {
        let valid = String(
            String.UnicodeScalarView(
                text.unicodeScalars.filter {
                    $0.value == 9 || $0.value == 10 || $0.value == 13 || (0x20...0xD7FF).contains($0.value) || (0xE000...0xFFFD).contains($0.value)
                        || (0x10000...0x10FFFF).contains($0.value)
                }))
        return DocxWriter.escape(valid)
    }

    static func write(_ files: [String: Data], to destination: URL, mimetype: String? = nil) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw YuzuError.invalidInput("The destination already exists. Choose a new output name.") }
        let staging = fm.temporaryDirectory.appendingPathComponent("yuzu-package-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for (name, data) in files {
            try Task.checkCancellation()
            try validateEntry(name)
            let file = staging.appendingPathComponent(name)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        }
        if let mimetype {
            try mimetype.write(to: staging.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
            let first = try await Shell.run("/usr/bin/zip", ["-0", "-X", "-q", destination.path, "mimetype"], currentDirectory: staging)
            guard first.succeeded else { throw YuzuError.toolFailed("zip", first.stderr) }
        }
        try Task.checkCancellation()
        let result = try await Shell.run("/usr/bin/zip", ["-X", "-q", destination.path] + files.keys.sorted(), currentDirectory: staging)
        try Task.checkCancellation()
        guard result.succeeded else { throw YuzuError.toolFailed("zip", result.stderr) }
    }

    static func data(_ xml: String) -> Data { Data(xml.utf8) }

    static func validateEntry(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
            !name.unicodeScalars.contains(where: { $0.value < 0x20 }),
            !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else {
            throw YuzuError.invalidInput("The document contains an unsafe package path.")
        }
    }
}

/// Read individual ZIP members to a bounded pipe, never extract untrusted paths.
struct DocumentArchive {
    let source: URL
    let entries: Set<String>

    static func open(_ source: URL) async throws -> DocumentArchive {
        let listing = try await Shell.run("/usr/bin/unzip", ["-Z1", source.path], outputLimit: 2 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard listing.succeeded, !listing.outputTruncated else { throw YuzuError.unreadable(source) }
        let names = listing.stdout.split(separator: "\n").map(String.init)
        guard names.count <= 10_000, Set(names).count == names.count else {
            throw YuzuError.invalidInput("This document has too many or duplicate package entries.")
        }
        for name in names {
            try DocumentPackage.validateEntry(name.hasSuffix("/") ? String(name.dropLast()) : name)
            guard !name.contains("*"), !name.contains("?"), !name.contains("["), !name.contains("]") else {
                throw YuzuError.invalidInput("The document contains an ambiguous package path.")
            }
        }
        return DocumentArchive(source: source, entries: Set(names))
    }

    func text(_ name: String) async throws -> String {
        try DocumentPackage.validateEntry(name)
        guard entries.contains(name) else { throw YuzuError.invalidInput("The document is missing \(name).") }
        let result = try await Shell.run("/usr/bin/unzip", ["-p", source.path, name], outputLimit: 8 * 1_024 * 1_024)
        try Task.checkCancellation()
        guard result.succeeded, !result.outputTruncated else {
            throw YuzuError.invalidInput("A document section is unreadable or exceeds the 8 MB text limit.")
        }
        return result.stdout
    }
}

final class DocumentXML: NSObject, XMLParserDelegate {
    struct Element {
        let name: String
        let attributes: [String: String]
    }
    private(set) var elements: [Element] = []
    private(set) var text = ""
    private var hiddenDepth = 0
    private var depth = 0

    static func parse(_ xml: String) throws -> DocumentXML {
        guard !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else {
            throw YuzuError.invalidInput("Document XML with a DTD or entity declaration is not supported.")
        }
        let delegate = DocumentXML()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw YuzuError.invalidInput("The document contains invalid or overly nested XML.") }
        return delegate
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth > 128 || elements.count >= 100_000 { parser.abortParsing(); return }
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        elements.append(Element(name: name, attributes: attributes))
        if name == "head" || name == "script" || name == "style" || hiddenDepth > 0 { hiddenDepth += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if hiddenDepth == 0 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if hiddenDepth > 0 { hiddenDepth -= 1 } else if ["p", "div", "br", "h1", "h2", "h3", "li", "tr"].contains(name) { text += "\n" }
        depth -= 1
    }
}

enum EPUBDocument {
    static func read(_ source: URL) async throws -> String {
        let archive = try await DocumentArchive.open(source)
        let container = try DocumentXML.parse(try await archive.text("META-INF/container.xml"))
        guard let rootfile = container.elements.first(where: { $0.name == "rootfile" })?.attributes["full-path"] else {
            throw YuzuError.invalidInput("The EPUB has no package document.")
        }
        let package = try DocumentXML.parse(try await archive.text(rootfile))
        var manifest: [String: String] = [:]
        for item in package.elements where item.name == "item" && item.attributes["media-type"] == "application/xhtml+xml" {
            if let id = item.attributes["id"], let href = item.attributes["href"] { manifest[id] = href }
        }
        let directory = (rootfile as NSString).deletingLastPathComponent
        var chapters: [String] = []
        var totalBytes = 0
        for item in package.elements where item.name == "itemref" {
            try Task.checkCancellation()
            guard let id = item.attributes["idref"], let href = manifest[id],
                let decoded = href.removingPercentEncoding, !decoded.contains("#"), !decoded.contains("?")
            else {
                throw YuzuError.invalidInput("The EPUB has an unsupported or missing reading-order section.")
            }
            let name = directory.isEmpty ? decoded : directory + "/" + decoded
            let chapter = try DocumentXML.parse(try await archive.text(name)).text
            totalBytes += chapter.utf8.count
            guard totalBytes <= 32 * 1_024 * 1_024 else { throw YuzuError.invalidInput("The EPUB exceeds the 32 MB text limit.") }
            chapters.append(chapter)
        }
        let text = chapters.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw YuzuError.invalidInput("The EPUB has no readable text. Image-only or encrypted books are not supported.") }
        return text
    }

    static func write(_ text: String, title: String, to destination: URL) async throws {
        let id = UUID().uuidString
        let title = DocumentPackage.escape(title)
        let body = text.components(separatedBy: "\n").map { "<p>\(DocumentPackage.escape($0))</p>" }.joined()
        let files = [
            "META-INF/container.xml": """
            <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """,
            "EPUB/package.opf": """
            <?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">urn:uuid:\(id)</dc:identifier><dc:title>\(title)</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()))</meta></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="chapter"/></spine></package>
            """,
            "EPUB/chapter.xhtml": """
            <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head><body>\(body)</body></html>
            """,
            "EPUB/nav.xhtml": """
            <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(title)</a></li></ol></nav></body></html>
            """,
        ]
        try await DocumentPackage.write(files.mapValues(DocumentPackage.data), to: destination, mimetype: "application/epub+zip")
    }
}

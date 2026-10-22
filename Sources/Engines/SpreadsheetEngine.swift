import Foundation

enum DelimitedText {
    static func parse(_ text: String, separator: Character) throws -> [[String]] {
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var fieldUnits = 0
        var quoted = false
        var afterQuote = false
        var atFieldStart = true
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            try Task.checkCancellation()
            if quoted {
                if character == "\"" { quoted = false; afterQuote = true } else { field.append(character); fieldUnits += character.utf16.count }
                guard fieldUnits <= 32_767 else { throw YuzuError.invalidInput("A spreadsheet cell exceeds 32767 characters.") }
                continue
            }
            if afterQuote, character == "\"" {
                field.append("\""); fieldUnits += 1; quoted = true; afterQuote = false
                continue
            }
            if character == separator {
                row.append(field); field = ""; fieldUnits = 0; atFieldStart = true; afterQuote = false
            } else if character == "\n" || character == "\r" || character == "\r\n" {
                row.append(field); rows.append(row); row = []; field = ""; fieldUnits = 0; atFieldStart = true; afterQuote = false
            } else if character == "\"", atFieldStart {
                quoted = true; atFieldStart = false
            } else {
                guard !afterQuote else { throw YuzuError.invalidInput("The spreadsheet has characters after a closing quote.") }
                guard character != "\"" else { throw YuzuError.invalidInput("A spreadsheet field has an unexpected quote.") }
                field.append(character); fieldUnits += character.utf16.count; atFieldStart = false
            }
            guard rows.count <= 1_048_576, row.count < 16_384, fieldUnits <= 32_767 else {
                throw YuzuError.invalidInput("This spreadsheet exceeds the supported row, column, or cell size.")
            }
        }
        guard !quoted else { throw YuzuError.invalidInput("The spreadsheet has an unclosed quoted field.") }
        if !field.isEmpty || !row.isEmpty || afterQuote { row.append(field); rows.append(row) }
        try SpreadsheetWriter.validate(rows)
        return rows
    }

    static func serialize(_ rows: [[String]], separator: Character) -> String {
        rows.map { row in
            row.map { field in
                if field.contains(separator) || field.contains("\"") || field.contains("\n") || field.contains("\r") {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: String(separator))
        }.joined(separator: "\r\n") + (rows.isEmpty ? "" : "\r\n")
    }
}

struct SpreadsheetEngine: ConversionEngine {
    func supports(from: FileFormat, to: FileFormat) -> Bool {
        [.csv, .tsv].contains(from) && ConversionMatrix.targets(for: from).contains(to)
    }

    func convert(_ request: ConversionRequest) async throws {
        guard supports(from: request.sourceFormat, to: request.target) else { throw YuzuError.unsupportedConversion(request.sourceFormat, request.target) }
        try Task.checkCancellation()
        let size = try request.source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 32 * 1_024 * 1_024 else { throw YuzuError.invalidInput("The spreadsheet exceeds the 32 MB text limit.") }
        let rows = try DelimitedText.parse(TextFile.read(request.source), separator: request.sourceFormat == .csv ? "," : "\t")
        try Task.checkCancellation()
        switch request.target {
        case .csv, .tsv:
            try DelimitedText.serialize(rows, separator: request.target == .csv ? "," : "\t").write(to: request.destination, atomically: true, encoding: .utf8)
        case .xlsx: try await SpreadsheetWriter.writeXLSX([rows], to: request.destination)
        case .ods: try await SpreadsheetWriter.writeODS(rows, to: request.destination)
        case .pdf: try TextRenderer.writePDF(rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"), to: request.destination)
        default: throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
        }
        try Task.checkCancellation()
        request.progress(1)
    }
}

enum SpreadsheetWriter {
    static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        while number > 0 {
            number -= 1
            name = String(alphabet[number % 26]) + name
            number /= 26
        }
        return name
    }

    static func validate(_ rows: [[String]]) throws {
        guard rows.count <= 1_048_576, rows.allSatisfy({ $0.count <= 16_384 && $0.allSatisfy { $0.utf16.count <= 32_767 } }) else {
            throw YuzuError.invalidInput("This spreadsheet exceeds the supported row, column, or cell size.")
        }
    }

    static func writeXLSX(_ sheets: [[[String]]], to destination: URL) async throws {
        guard !sheets.isEmpty, sheets.count <= 1_024 else { throw YuzuError.invalidInput("Choose between 1 and 1024 spreadsheet pages.") }
        let ns = "http://schemas.openxmlformats.org"
        var files: [String: Data] = [:]
        var sheetNodes = ""
        var relationships = ""
        var overrides = ""
        for (index, rows) in sheets.enumerated() {
            try Task.checkCancellation()
            try validate(rows)
            let number = index + 1
            sheetNodes += "<sheet name=\"Page \(number)\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            relationships +=
                "<Relationship Id=\"rId\(number)\" Type=\"\(ns)/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"
            overrides +=
                "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            var content = ""
            for (rowIndex, row) in rows.enumerated() {
                try Task.checkCancellation()
                var cells = ""
                for (column, value) in row.enumerated() {
                    // Inline strings preserve leading zeros and never execute formulas.
                    let literal = value.replacingOccurrences(of: "_x(?=[0-9A-Fa-f]{4}_)", with: "_x005F_x", options: .regularExpression)
                    cells +=
                        "<c r=\"\(columnName(column))\(rowIndex + 1)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(DocumentPackage.escape(literal))</t></is></c>"
                }
                content += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
            }
            files["xl/worksheets/sheet\(number).xml"] = DocumentPackage.data(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"\(ns)/spreadsheetml/2006/main\"><sheetData>\(content)</sheetData></worksheet>")
        }
        files["[Content_Types].xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><Types xmlns=\"\(ns)/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>\(overrides)</Types>"
        )
        files["_rels/.rels"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><Relationships xmlns=\"\(ns)/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(ns)/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>"
        )
        files["xl/workbook.xml"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><workbook xmlns=\"\(ns)/spreadsheetml/2006/main\" xmlns:r=\"\(ns)/officeDocument/2006/relationships\"><sheets>\(sheetNodes)</sheets></workbook>"
        )
        files["xl/_rels/workbook.xml.rels"] = DocumentPackage.data(
            "<?xml version=\"1.0\"?><Relationships xmlns=\"\(ns)/package/2006/relationships\">\(relationships)</Relationships>")
        try await DocumentPackage.write(files, to: destination)
    }

    static func writeODS(_ rows: [[String]], to destination: URL) async throws {
        try validate(rows)
        var content = ""
        for row in rows {
            try Task.checkCancellation()
            content +=
                "<table:table-row>"
                + row.map { value in
                    let text = DocumentPackage.escape(value)
                        .replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .replacingOccurrences(of: " ", with: "<text:s/>")
                        .replacingOccurrences(of: "\t", with: "<text:tab/>")
                        .replacingOccurrences(of: "\n", with: "<text:line-break/>")
                    return "<table:table-cell office:value-type=\"string\"><text:p>\(text)</text:p></table:table-cell>"
                }.joined() + "</table:table-row>"
        }
        let files = [
            "content.xml": """
            <?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet 1">\(content)</table:table></office:spreadsheet></office:body></office:document-content>
            """,
            "META-INF/manifest.xml": """
            <?xml version="1.0" encoding="UTF-8"?><manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
            """,
        ]
        try await DocumentPackage.write(files.mapValues(DocumentPackage.data), to: destination, mimetype: "application/vnd.oasis.opendocument.spreadsheet")
    }
}

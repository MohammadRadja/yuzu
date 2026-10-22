import Foundation

/// An optional local backend for formats that need a full office layout engine.
struct OfficeEngine: ConversionEngine {
    static var executable: String? {
        Shell.which(
            "soffice",
            extra: [
                "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/LibreOffice.app/Contents/MacOS/soffice").path,
            ])
    }

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        let officeInputs: Set<FileFormat> = [.ppt, .pptx, .xls, .xlsx, .ods, .pages, .docx, .rtf]
        return officeInputs.contains(from) && ConversionMatrix.targets(for: from).contains(to)
    }

    func convert(_ request: ConversionRequest) async throws {
        guard supports(from: request.sourceFormat, to: request.target) else {
            throw YuzuError.unsupportedConversion(request.sourceFormat, request.target)
        }
        guard let executable = Self.executable else {
            throw YuzuError.invalidInput(
                "\(request.sourceFormat.displayName) conversion needs LibreOffice. Install LibreOffice in Applications, then try again.")
        }
        try Task.checkCancellation()
        guard request.source.isFileURL, FileManager.default.isReadableFile(atPath: request.source.path) else {
            throw YuzuError.unreadable(request.source)
        }
        try Self.validateSource(request.source, format: request.sourceFormat)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("yuzu-office-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let profile = staging.appendingPathComponent("profile")
        try Self.prepareProfile(profile)
        let input = staging.appendingPathComponent("input.\(request.sourceFormat.fileExtension)")
        try fm.copyItem(at: request.source, to: input)
        let target: FileFormat = [.jpg, .png].contains(request.target) ? .pdf : ([.md, .html].contains(request.target) ? .txt : request.target)
        let output = staging.appendingPathComponent("output")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let result = try await Shell.run(
            executable,
            [
                "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--nologo", "--nodefault", "--norestore", "--nofirststartwizard",
                "--convert-to", Self.filter(from: request.sourceFormat, to: target), "--outdir", output.path, input.path,
            ], outputLimit: 64 * 1_024)
        try Task.checkCancellation()
        let converted = output.appendingPathComponent("input.\(target.fileExtension)")
        guard result.succeeded, !result.outputTruncated, fm.isReadableFile(atPath: converted.path),
            ((try? converted.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        else {
            throw YuzuError.invalidInput(
                "LibreOffice could not convert this \(request.sourceFormat.displayName) file. It may be damaged, password-protected, or use an unsupported version. Try exporting it as PDF from its original app."
            )
        }
        request.progress(0.75)
        if [.md, .html].contains(request.target) {
            // Export text as literal Markdown; do not claim to reconstruct headings.
            let text = try TextFile.read(converted)
            try DocumentText.write(text, as: request.target, to: request.destination)
        } else if [.jpg, .png].contains(request.target) {
            try await DocumentEngine().convert(
                ConversionRequest(
                    source: converted, sourceFormat: .pdf, target: request.target, destination: request.destination,
                    progress: { request.progress(0.75 + $0 * 0.25) }))
        } else {
            try fm.moveItem(at: converted, to: request.destination)
        }
        try Task.checkCancellation()
        request.progress(1)
    }

    static func filter(from source: FileFormat, to target: FileFormat) -> String {
        switch target {
        case .pdf:
            let filter = source.category == .presentation ? "impress_pdf_Export" : (source.category == .spreadsheet ? "calc_pdf_Export" : "writer_pdf_Export")
            return "pdf:\(filter)"
        case .docx: return "docx:Office Open XML Text"
        case .xlsx: return "xlsx:Calc Office Open XML"
        case .ods: return "ods:calc8"
        case .csv: return "csv:Text - txt - csv (StarCalc):44,34,76,1,,0,false,true,false,false,false,0,false,false"
        case .tsv: return "tsv:Text - txt - csv (StarCalc):9,34,76,1,,0,false,true,false,false,false,0,false,false"
        case .epub: return "epub:EPUB"
        case .html: return "html:HTML (StarWriter)"
        case .txt: return "txt:Text (encoded):UTF8"
        case .md: return "md:Text (encoded):UTF8"
        default: return target.fileExtension
        }
    }

    static func validateSource(_ source: URL, format: FileFormat) throws {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isPackageKey, .isDirectoryKey])
        if format == .pages, values.isDirectory == true, values.isPackage == true { return }
        guard values.isRegularFile == true else { throw YuzuError.unreadable(source) }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 8) ?? Data()
        let valid: Bool
        switch format {
        case .pptx, .xlsx, .ods, .docx, .pages: valid = header.starts(with: [0x50, 0x4B, 0x03, 0x04])
        case .ppt, .xls: valid = header == Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        case .rtf: valid = header.starts(with: Data("{\\rtf".utf8))
        default: valid = false
        }
        guard valid else { throw YuzuError.invalidInput("This file is not a valid \(format.displayName) document. Check its original format and try again.") }
    }

    static func prepareProfile(_ profile: URL) throws {
        let user = profile.appendingPathComponent("user")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let settings = """
            <?xml version="1.0" encoding="UTF-8"?>
            <oor:items xmlns:oor="http://openoffice.org/2001/registry">
            <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
            <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop><prop oor:name="Field" oor:op="fuse"><value>false</value></prop><prop oor:name="Chart" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
            <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Common/Save/Document"><prop oor:name="WarnAlienFormat" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Update/Update"><prop oor:name="Enabled" oor:op="fuse"><value>false</value></prop></item>
            <item oor:path="/org.openoffice.Office.Common/OnlineUpdate"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>
            </oor:items>
            """
        try settings.write(to: user.appendingPathComponent("registrymodifications.xcu"), atomically: true, encoding: .utf8)
    }
}

enum DocumentText {
    static func markdown(_ text: String) -> String {
        // Escape Markdown punctuation so extracted PDF text is represented literally.
        var result = text
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "+", "-", "!", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }

    static func write(_ text: String, as format: FileFormat, to destination: URL) throws {
        let output: String
        switch format {
        case .md: output = markdown(text)
        case .html:
            output =
                "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Converted document</title></head><body><pre>\(DocumentPackage.escape(text))</pre></body></html>"
        default: output = text
        }
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }
}

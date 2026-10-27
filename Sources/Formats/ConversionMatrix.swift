import Foundation

enum ConversionMatrix {
    static func targets(for source: FileFormat) -> [FileFormat] {
        let list: [FileFormat]
        switch source {
        case .jpg, .png:
            list = FileFormat.imageTargets + [.docx]
        case .webp, .heic, .tiff, .svg, .avif, .bmp, .ico, .icns:
            list = FileFormat.imageTargets
        case .mp3, .m4a, .wav, .flac, .ogg, .opus, .aiff, .wma:
            list = FileFormat.audio
        case .mp4, .mov, .mkv, .webm, .avi, .wmv:
            list = FileFormat.video + [.gif, .mp3, .webp]
        case .gif:
            list = FileFormat.video + [.webp]
        case .pdf:
            list = [.docx, .pptx, .xlsx, .jpg, .png, .epub, .txt, .md, .svg]
        case .txt:
            list = [.pdf, .jpg, .png, .srt, .vtt, .docx, .md, .epub, .html]
        case .docx, .pages, .md, .epub, .rtf, .rtfd:
            list = FileFormat.documentTargets
        case .ppt, .pptx:
            list = [.pdf, .jpg, .png]
        case .xls, .xlsx, .ods, .csv, .tsv:
            list = FileFormat.spreadsheetTargets
        case .html:
            list = [.pdf, .docx, .txt]  // Offline text extraction; no browser resource loading.
        case .textClipping: list = [.txt, .md, .pdf]
        case .json: list = [.yaml, .xml]
        case .yaml, .xml: list = [.json]
        case .srt, .vtt:
            list = FileFormat.subtitles + [.txt]
        case .zip, .tar, .gz, .rar:
            list = [.zip, .tar, .gz]
        }
        return list.filter { $0 != source }
    }

    static func targets(for sources: [FileFormat]) -> [FileFormat] {
        guard let first = sources.first else { return [] }
        var common = targets(for: first)
        for source in sources.dropFirst() {
            let next = Set(targets(for: source))
            common = common.filter { next.contains($0) }
        }
        return common
    }

    static var totalConversions: Int {
        FileFormat.allCases.reduce(0) { $0 + targets(for: $1).count }
    }

    static func outputURL(for source: URL, target: FileFormat, in directory: URL, existing: Set<String> = []) -> URL {
        let base = strippedBaseName(source.lastPathComponent)
        var candidate = "\(base).\(target.fileExtension)"
        var counter = 2
        let fm = FileManager.default
        while existing.contains(candidate) || fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(counter).\(target.fileExtension)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func uniqueURL(directory: URL, baseName: String, suffix: String, ext: String) -> URL {
        let fm = FileManager.default
        var candidate = suffix.isEmpty ? "\(baseName).\(ext)" : "\(baseName) \(suffix).\(ext)"
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = suffix.isEmpty ? "\(baseName) \(counter).\(ext)" : "\(baseName) \(suffix) \(counter).\(ext)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func uniqueDirectory(directory: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = name
        var counter = 2
        while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = "\(name) \(counter)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }

    static func strippedBaseName(_ fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower.hasSuffix(".tar.gz") { return String(fileName.dropLast(7)) }
        if lower.hasSuffix(".tgz") { return String(fileName.dropLast(4)) }
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return fileName }
        return String(fileName[..<dot])
    }
}

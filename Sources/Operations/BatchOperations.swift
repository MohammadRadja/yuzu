import Foundation

struct FileChange: Identifiable, Hashable {
    let source: URL
    let destination: URL
    var id: URL { source }
}

struct RenameOptions: Equatable {
    var prefix = ""
    var suffix = ""
    var search = ""
    var replacement = ""
    var pattern = "{name}"
    var number = false
    var start = 1
    var digits = 3

    func name(for url: URL, index: Int) throws -> String {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = isFolder || url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        if !search.isEmpty { base = base.replacingOccurrences(of: search, with: replacement) }
        guard start >= 0, start <= Int.max - index, (1...12).contains(digits) else { throw YuzuError.invalidInput("Choose valid numbering values.") }
        let sequence = String(start + index)
        let padded = String(repeating: "0", count: max(0, digits - sequence.count)) + sequence
        var result = pattern.replacingOccurrences(of: "{name}", with: base).replacingOccurrences(of: "{n}", with: padded)
        if number && !pattern.contains("{n}") { result += " " + padded }
        result = prefix + result + suffix + ext
        guard !result.isEmpty, result != ".", result != "..", !result.contains("/"), !result.contains(":"),
            !result.contains("\0"), result.utf8.count <= 255
        else { throw YuzuError.invalidInput("A preview name is invalid or too long. Remove slashes, colons, or unsupported characters.") }
        return result
    }
}

enum BatchOperations {
    static func renamePlan(_ urls: [URL], options: RenameOptions) throws -> [FileChange] {
        let plan = try FileSelection(urls: urls).urls.enumerated().map { index, url in
            FileChange(source: url, destination: url.deletingLastPathComponent().appendingPathComponent(try options.name(for: url, index: index)))
        }
        try validate(plan)
        return plan
    }

    static func organizePlan(_ urls: [URL], byDate: Bool) throws -> [FileChange] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM"
        let plan = try FileSelection(urls: urls).urls.map { url -> FileChange in
            let values = try url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
            let group: String
            if byDate {
                group = formatter.string(from: values.creationDate ?? Date(timeIntervalSince1970: 0))
            } else if values.isDirectory == true {
                group = "Folders"
            } else {
                group = FileFormat.detect(url)?.category.title ?? "Other"
            }
            return FileChange(
                source: url, destination: url.deletingLastPathComponent().appendingPathComponent(group).appendingPathComponent(url.lastPathComponent))
        }
        try validate(plan)
        return plan
    }

    static func validate(_ plan: [FileChange]) throws {
        guard !plan.isEmpty else { throw YuzuError.invalidInput("Select files to preview this operation.") }
        let sources = Set(plan.map { $0.source.standardizedFileURL })
        var destinations = Set<String>()
        for change in plan {
            guard change.source.isFileURL, change.destination.isFileURL,
                FileManager.default.fileExists(atPath: change.source.path),
                !change.destination.resolvingSymlinksInPath().path.hasPrefix(change.source.resolvingSymlinksInPath().path + "/")
            else { throw YuzuError.invalidInput("A source is missing or a destination is inside its source.") }
            let key = change.destination.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
            guard destinations.insert(key).inserted else { throw YuzuError.invalidInput("Conflicting preview name: \(change.destination.lastPathComponent).") }
            if FileManager.default.fileExists(atPath: change.destination.path), !sources.contains(change.destination.standardizedFileURL) {
                throw FileActionError.collision(change.destination.lastPathComponent)
            }
            guard !plan.contains(where: { $0.source != change.source && change.source.path.hasPrefix($0.source.path + "/") }) else {
                throw YuzuError.invalidInput("Select a folder or its contents, rather than both together.")
            }
        }
    }

    static func apply(_ plan: [FileChange], progress: @escaping (Double) -> Void) async throws -> [URL] {
        try validate(plan)  // Revalidate after the user reviewed the preview.
        let changes = plan.filter { $0.source != $0.destination }
        let temporary = changes.map { $0.source.deletingLastPathComponent().appendingPathComponent(".yuzu-rename-\(UUID().uuidString)") }
        var staged = Set<Int>()
        var finalized = Set<Int>()
        var created: [URL] = []
        let fm = FileManager.default
        do {
            for (index, change) in changes.enumerated() {
                try Task.checkCancellation()
                let parent = change.destination.deletingLastPathComponent()
                if !fm.fileExists(atPath: parent.path) { try fm.createDirectory(at: parent, withIntermediateDirectories: false); created.append(parent) }
                try fm.moveItem(at: change.source, to: temporary[index])
                staged.insert(index)
                progress(0.5 * Double(index + 1) / Double(changes.count))
            }
            for (index, change) in changes.enumerated() {
                try Task.checkCancellation()
                try fm.moveItem(at: temporary[index], to: change.destination)
                finalized.insert(index)
                progress(0.5 + 0.5 * Double(index + 1) / Double(changes.count))
            }
            return plan.map(\.destination)
        } catch {
            var failures: [String] = []
            for index in finalized {
                do { try fm.moveItem(at: changes[index].destination, to: temporary[index]) } catch { failures.append(changes[index].destination.path) }
            }
            for index in staged {
                do { try fm.moveItem(at: temporary[index], to: changes[index].source) } catch { failures.append(temporary[index].path) }
            }
            for folder in created.reversed() where (try? fm.contentsOfDirectory(atPath: folder.path).isEmpty) == true { try? fm.removeItem(at: folder) }
            if !failures.isEmpty { throw YuzuError.invalidInput("Operation stopped. These items need manual recovery:\n" + failures.joined(separator: "\n")) }
            throw error
        }
    }
}

struct OptimizationResult: Identifiable {
    let source: URL
    let output: URL?
    let before: Int64
    let after: Int64
    let error: String?
    var id: URL { source }
}

enum BatchOptimizer {
    static func run(
        _ urls: [URL], preset: CompressionPreset, directory: OutputLocation,
        progress: @escaping (Double) -> Void, onResult: (OptimizationResult) async -> Void = { _ in }
    ) async throws -> [OptimizationResult] {
        var results: [OptimizationResult] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let format = Compressor.outputFormat(for: url)
            let output = ConversionMatrix.uniqueURL(
                directory: directory.directory(for: url), baseName: ConversionMatrix.strippedBaseName(url.lastPathComponent), suffix: "optimized",
                ext: format.fileExtension)
            let before = FileSizeFormatter.size(of: url)
            do {
                try await Compressor.compress(url, preset: preset, resizeLongEdge: 0, targetBytes: nil, to: output) { fraction in
                    progress((Double(index) + fraction) / Double(urls.count))
                }
                results.append(OptimizationResult(source: url, output: output, before: before, after: FileSizeFormatter.size(of: output), error: nil))
            } catch is CancellationError { throw CancellationError() } catch {
                results.append(OptimizationResult(source: url, output: nil, before: before, after: 0, error: error.localizedDescription))
            }
            if let latest = results.last { await onResult(latest) }
            progress(Double(index + 1) / Double(urls.count))
        }
        return results
    }
}

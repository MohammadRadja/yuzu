import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
    var outputTruncated = false

    var succeeded: Bool { status == 0 }
}

final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var truncated = false

    func set(stdout data: Data) { lock.withLock { stdout = data } }
    func set(stderr data: Data) { lock.withLock { stderr = data } }

    func read(_ handle: FileHandle, standardError: Bool, limit: Int?, process: ProcessBox) {
        var data = Data()
        var overflow = false
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let limit, chunk.count > limit - data.count {
                data.append(chunk.prefix(max(0, limit - data.count)))
                overflow = true
                process.terminate()
            } else if !overflow {
                data.append(chunk)
            }
        }
        lock.withLock {
            if standardError { stderr = data } else { stdout = data }
            truncated = truncated || overflow
        }
    }

    func result(status: Int32) -> ShellResult {
        lock.withLock {
            ShellResult(
                status: status, stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self), outputTruncated: truncated)
        }
    }
}

final class ProcessBox: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false

    func run() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            try process.run()
        }
    }

    func terminate() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil, outputLimit: Int? = nil) async throws -> ShellResult {
        let box = ProcessBox()
        try Task.checkCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = box.process
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                let output = PipeBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    output.read(outPipe.fileHandleForReading, standardError: false, limit: outputLimit, process: box)
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    output.read(errPipe.fileHandleForReading, standardError: true, limit: outputLimit, process: box)
                    group.leave()
                }
                process.terminationHandler = { proc in
                    group.wait()
                    continuation.resume(returning: output.result(status: proc.terminationStatus))
                }
                do {
                    try box.run()
                } catch {
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return result
    }

    static func which(_ name: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        var candidates = extra
        candidates += [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(fm.homeDirectoryForCurrentUser.path)/.local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            candidates.insert(bundled, at: 0)
        }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent(name).path {
            candidates.insert(resource, at: 1)
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }
}

import Combine
import SwiftUI

enum TaskID: String, CaseIterable, Hashable {
    case batchRename, smartOrganize, batchOptimize
    case workflow, duplicateFinder, fileShelf
    var title: String {
        switch self {
        case .batchRename: return "Batch Rename"
        case .smartOrganize: return "Smart Organize"
        case .batchOptimize: return "Batch Optimize"
        case .workflow: return "Workflow Builder"
        case .duplicateFinder: return "Duplicate Finder"
        case .fileShelf: return "File Shelf"
        }
    }
    var symbol: String {
        switch self {
        case .batchRename: return "character.cursor.ibeam"
        case .smartOrganize: return "folder.badge.gearshape"
        case .batchOptimize: return "arrow.down.right.and.arrow.up.left"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .duplicateFinder: return "doc.on.doc"
        case .fileShelf: return "tray.2"
        }
    }
}

@MainActor
struct TaskPanel: View {
    let task: TaskID
    let files: [URL]
    @State private var options = RenameOptions()
    @State private var byDate = false
    @State private var preset = CompressionPreset.balanced
    @State private var confirm = false
    @State private var running = false
    @State private var finished = false
    @State private var error: String?
    @State private var job: Job?
    @State private var overallProgress = 0.0
    @State private var results: [OptimizationResult] = []
    @State private var completedPlan: [FileChange]?

    private var plan: Result<[FileChange], Error> {
        if let completedPlan { return .success(completedPlan) }
        return Result {
            task == .batchRename ? try BatchOperations.renamePlan(files, options: options) : try BatchOperations.organizePlan(files, byDate: byDate)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(files.count) selected items").font(.headline)
            if task == .batchRename {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Prefix"); TextField("Prefix", text: $options.prefix).accessibilityIdentifier("rename.prefix")
                        Text("Suffix"); TextField("Suffix", text: $options.suffix).accessibilityIdentifier("rename.suffix")
                    }
                    GridRow {
                        Text("Replace"); TextField("Find", text: $options.search).accessibilityIdentifier("rename.search")
                        Text("With"); TextField("Replacement", text: $options.replacement).accessibilityIdentifier("rename.replacement")
                    }
                    GridRow {
                        Text("Pattern"); TextField("{name} and {n}", text: $options.pattern).gridCellColumns(3).accessibilityIdentifier("rename.pattern")
                    }
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Append numbering", isOn: $options.number)
                    Stepper("Start: \(options.start)", value: $options.start, in: 0...999999)
                    Stepper("Digits: \(options.digits)", value: $options.digits, in: 1...8)
                }
                FormHint("{name} uses the original name after replacement; {n} inserts the padded number. Extensions are preserved.")
            } else if task == .smartOrganize {
                Picker("Group by", selection: $byDate) {
                    Text("File Type").tag(false); Text("Creation Month").tag(true)
                }.pickerStyle(.segmented)
                FormHint("Folders are created beside each source. Review the destination paths before moving.")
            } else {
                Picker("Preset", selection: $preset) { ForEach(CompressionPreset.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                FormHint("Runs compression for each file, keeps originals, and reports sizes and individual failures below. Cancel keeps completed copies.")
            }
            if task == .batchOptimize {
                if running {
                    Text("Total: \(Int(overallProgress * 100))% · \(results.count)/\(files.count) files completed").monospacedDigit()
                    ProgressView(value: overallProgress)
                    if results.count < files.count {
                        Text("Processing: \(files[results.count].lastPathComponent)").lineLimit(2)
                        ProgressView(value: min(1, max(0, overallProgress * Double(files.count) - Double(results.count))))
                            .accessibilityLabel("Current file progress")
                    }
                }
                List {
                    if results.isEmpty { ForEach(files, id: \.self) { Text($0.lastPathComponent) } }
                    ForEach(results) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.source.lastPathComponent).font(.headline)
                            if let failure = result.error {
                                Text(failure).foregroundStyle(.red)
                            } else {
                                Text("\(FileSizeFormatter.string(result.before)) → \(FileSizeFormatter.string(result.after))").monospacedDigit()
                                if let output = result.output { Button("Reveal output") { NSWorkspace.shared.activateFileViewerSelecting([output]) } }
                            }
                        }
                    }
                }
            } else {
                switch plan {
                case .success(let changes):
                    List(changes) { change in
                        HStack {
                            Text(change.source.lastPathComponent).lineLimit(2)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(task == .smartOrganize ? change.destination.path : change.destination.lastPathComponent).lineLimit(3)
                        }.textSelection(.enabled)
                    }
                case .failure(let failure):
                    Text(failure.localizedDescription).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if finished { Text("Completed. Review the outputs in Finder or the report above.").foregroundStyle(.secondary) }
            HStack {
                if running { ProgressView().controlSize(.small); Text("\(Int(overallProgress * 100))%") }
                Spacer()
                if running { Button("Cancel") { if let job { JobRunner.shared.cancel(job) } }.accessibilityIdentifier("task.cancel") }
                Button(task == .batchOptimize ? "Optimize copies" : "Apply preview…") { confirm = true }
                    .accessibilityIdentifier("task.apply")
                    .buttonStyle(.borderedProminent)
                    .disabled(running || finished || (task != .batchOptimize && (try? plan.get()) == nil))
            }
        }
        .padding(24)
        .confirmationDialog("Apply \(task.title) to \(files.count) items?", isPresented: $confirm) {
            Button("Apply") { run() }.accessibilityIdentifier("task.confirm")
        } message: {
            Text(
                task == .batchOptimize
                    ? "New copies will be created. Originals stay unchanged."
                    : "The previewed source names or locations will change. Existing files will not be replaced.")
        }
        .onReceive(job?.$status.eraseToAnyPublisher() ?? Just(Job.Status.waiting).eraseToAnyPublisher()) { status in
            if status.isFinished { running = false }
        }
        .onReceive(job?.$progress.eraseToAnyPublisher() ?? Just(0.0).eraseToAnyPublisher()) { value in
            overallProgress = value.isFinite ? min(1, max(0, value)) : 0
        }
    }

    private func run() {
        let reviewedPlan = try? plan.get()
        let preset = preset
        let location = AppSettings.shared.outputLocation
        let workJob = Job(title: task.title, detail: "\(files.count) items", symbol: task.symbol)
        job = workJob
        overallProgress = 0
        running = true
        error = nil
        JobRunner.shared.enqueue(workJob) { progress in
            do {
                let outputs: [URL]
                if task == .batchOptimize {
                    let report = try await BatchOptimizer.run(files, preset: preset, directory: location, progress: progress) { result in
                        await MainActor.run { results.append(result) }
                    }
                    await MainActor.run { results = report }
                    outputs = report.compactMap(\.output)
                } else {
                    guard let changes = reviewedPlan else { throw YuzuError.invalidInput("Refresh the preview before applying changes.") }
                    outputs = try await BatchOperations.apply(changes, progress: progress)
                    await MainActor.run { completedPlan = changes }
                }
                await MainActor.run {
                    running = false; finished = true
                }
                return outputs
            } catch {
                await MainActor.run {
                    running = false; self.error = error.localizedDescription
                }
                throw error
            }
        }
    }
}

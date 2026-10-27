import SwiftUI

@MainActor
struct WorkflowPanel: View {
    let files: [URL]
    @State private var steps = [WorkflowStep(kind: .resize), WorkflowStep(kind: .optimize)]
    @State private var error: String?
    @State private var confirm = false
    @AppStorage("YuzuSavedWorkflowV1") private var saved = Data()

    private var validation: String? {
        do {
            for file in files {
                guard let format = FileFormat.detect(file) else { throw YuzuError.unreadable(file) }
                _ = try WorkflowEngine.validate(steps, source: format)
            }
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHint("Steps run in order on private intermediate copies. Only completed final outputs are published; originals remain unchanged.")
            List {
                ForEach(Array(steps.indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("\(index + 1)").monospacedDigit()
                            Picker("Operation", selection: $steps[index].kind) { ForEach(WorkflowStep.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                .accessibilityIdentifier("workflow.kind.\(index)")
                            Button {
                                if index > 0 { steps.swapAt(index, index - 1) }
                            } label: {
                                Image(systemName: "arrow.up")
                            }.disabled(index == 0).accessibilityIdentifier("workflow.up.\(index)").accessibilityLabel("Move step \(index + 1) up")
                            Button {
                                steps.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }.disabled(steps.count == 1).accessibilityIdentifier("workflow.remove.\(index)").accessibilityLabel("Remove step \(index + 1)")
                        }
                        switch steps[index].kind {
                        case .convert:
                            Picker("Target", selection: $steps[index].target) {
                                ForEach(FileFormat.allCases.filter { $0.category != .archive }) { Text($0.displayName).tag($0.rawValue) }
                            }
                            .accessibilityIdentifier("workflow.target.\(index)")
                        case .resize: NumberField(title: "Longest edge", value: $steps[index].longEdge, suffix: "px")
                        case .optimize:
                            Picker("Preset", selection: $steps[index].preset) { ForEach(CompressionPreset.allCases) { Text($0.title).tag($0.rawValue) } }
                        case .ocr: Text("Apple Vision → UTF-8 TXT").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
            }
            if let validation { Text(validation).foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Add step") { steps.append(WorkflowStep()) }.disabled(steps.count >= 16).accessibilityIdentifier("workflow.add")
                Button("Save workflow") { if let data = try? JSONEncoder().encode(steps) { saved = data } }.accessibilityIdentifier("workflow.save")
                Button("Load saved") {
                    do { steps = try JSONDecoder().decode([WorkflowStep].self, from: saved) } catch { self.error = "Saved workflow could not be read." }
                }.disabled(saved.isEmpty).accessibilityIdentifier("workflow.load")
                Spacer()
                Button("Run workflow…") { confirm = true }.buttonStyle(.borderedProminent).disabled(validation != nil).accessibilityIdentifier("workflow.run")
            }
        }.padding(24)
            .confirmationDialog("Run this workflow on \(files.count) files?", isPresented: $confirm) {
                Button("Run") { run() }.accessibilityIdentifier("workflow.confirm")
            }
    }
    private func run() {
        let steps = steps
        for file in files {
            do {
                guard let source = FileFormat.detect(file) else { throw YuzuError.unreadable(file) }
                let target = try WorkflowEngine.validate(steps, source: source)
                let output = ConversionMatrix.uniqueURL(
                    directory: AppSettings.shared.outputLocation.directory(for: file), baseName: ConversionMatrix.strippedBaseName(file.lastPathComponent),
                    suffix: "workflow", ext: target.fileExtension)
                JobRunner.shared.run(title: "Running workflow", detail: file.lastPathComponent, symbol: "point.3.connected.trianglepath.dotted") { progress in
                    try await WorkflowEngine.run(file, steps: steps, to: output, progress: progress)
                    return [output]
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
struct DuplicateFinderView: View {
    let files: [URL]
    @State private var groups: [DuplicateGroup] = []
    @State private var running = false
    @State private var fraction = 0.0
    @State private var error: String?
    @State private var scan: Task<Void, Never>?
    @State private var scanned = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHint(
                "Compares regular files by size and streaming SHA-256. Review the results in Finder; no files are deleted automatically. Links are skipped.")
            if running { ProgressView(value: fraction) }
            if scanned && groups.isEmpty && error == nil { Text("No identical files found.") }
            List(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.urls.count) identical files · \(FileSizeFormatter.string(group.size)) each").font(.headline)
                    ForEach(group.urls, id: \.self) { url in
                        HStack {
                            Text(url.path).textSelection(.enabled); Spacer();
                            Button("Reveal") { ValidationRuntime.reveal([url]) }
                                .accessibilityIdentifier("duplicate.reveal." + url.path)
                        }
                    }
                }.padding(.vertical, 8)
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                if running { Button("Cancel scan") { scan?.cancel() } }
                Button(scanned ? "Scan again" : "Find duplicates") { start() }.disabled(running)
            }
        }.padding(24)
            .onDisappear { scan?.cancel() }
    }
    private func start() {
        running = true; error = nil; groups = []; fraction = 0
        scan = Task {
            do {
                groups = try await DuplicateFinder.find(files) { value in Task { @MainActor in fraction = value } }
                scanned = true
            } catch { self.error = error.localizedDescription }
            running = false
        }
    }
}

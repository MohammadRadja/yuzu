import Combine
import SwiftUI

/// Tracks only this panel's jobs, independently of retained failures in the HUD.
@MainActor
final class ArchiveSubmission: ObservableObject {
    enum Status: Equatable {
        case idle, running, succeeded, cancelled, failed(String)
    }
    @Published private(set) var status = Status.idle
    private var statuses: [UUID: Job.Status] = [:]
    private var subscriptions: [AnyCancellable] = []

    func track(_ jobs: [Job]) {
        subscriptions.removeAll()
        statuses = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.status) })
        updateStatus()
        for job in jobs {
            let id = job.id
            subscriptions.append(
                job.$status.sink { [weak self] value in
                    self?.statuses[id] = value
                    self?.updateStatus()
                })
        }
    }

    private func updateStatus() {
        guard !statuses.isEmpty else { status = .idle; return }
        guard statuses.values.allSatisfy(\.isFinished) else { status = .running; return }
        let errors = statuses.values.compactMap { value -> String? in
            if case .failed(let message) = value { return message }; return nil
        }.sorted()
        if !errors.isEmpty {
            status = .failed(errors.joined(separator: "\n"))
        } else if statuses.values.contains(.cancelled) {
            status = .cancelled
        } else {
            status = .succeeded
        }
    }
}

@MainActor
struct ArchiveActionView: View {
    let files: [URL]
    let creating: Bool
    @State private var advanced = false
    @State private var encrypted = false
    @State private var password = ""
    @State private var entries: [ArchiveEntryInfo] = []
    @State private var selection = Set<String>()
    @State private var loading = false
    @State private var error: String?
    @StateObject private var submission = ArchiveSubmission()
    @Environment(\.closeFeatureWindow) private var closeWindow
    @State private var inspection: Task<Void, Never>?
    @State private var exportPassword = ""
    @State private var protectExport = false

    private var submitted: Bool { submission.status == .running }

    init(files: [URL], creating: Bool, showAdvanced: Bool = false) {
        self.files = files; self.creating = creating
        _advanced = State(initialValue: showAdvanced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creating ? "Create a ZIP from \(files.count) selected items" : "Extract \(files.count) archive(s)").font(.headline)
            FormHint("Outputs use new names beside the originals or in your configured output folder. Existing files are never replaced.")
            DisclosureGroup("Advanced · Archive Manager", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 12) {
                    if creating {
                        if EncryptedZIP.isSupported {
                            Toggle("Protect with AES-256 ZIP encryption", isOn: $encrypted)
                            if encrypted {
                                SecureField("New ZIP password", text: $password).accessibilityIdentifier("archive.password")
                                FormHint(
                                    "Keep this password. File contents are encrypted; entry names remain visible. Finder may require another archive app for AES ZIPs."
                                )
                            }
                        } else {
                            FormHint("This system archive backend does not support creating AES-encrypted ZIPs.")
                        }
                    } else {
                        SecureField("Password (if encrypted)", text: $password).accessibilityIdentifier("archive.password")
                        if files.count == 1 {
                            Button(loading ? "Inspecting…" : "Inspect archive entries") { inspect() }.disabled(loading)
                            FormHint(
                                "Select entries below to extract only those items. Folder selection includes its descendants. Every entry is still validated for safety."
                            )
                            if !entries.isEmpty {
                                if EncryptedZIP.isSupported {
                                    Toggle("Protect exported ZIP copy", isOn: $protectExport)
                                    if protectExport {
                                        SecureField("New password for exported copy", text: $exportPassword).accessibilityIdentifier("archive.exportPassword")
                                    }
                                }
                                Button("Export selected entries as ZIP") { repack() }
                                    .disabled(selection.isEmpty || submitted || protectExport && exportPassword.isEmpty)
                            }
                        } else {
                            FormHint("Entry selection is available for one archive at a time. The password applies to every selected archive.")
                        }
                    }
                }.padding(.top, 12)
            }
            if entries.isEmpty {
                List(files, id: \.self) { Text($0.lastPathComponent) }
            } else {
                List(entries, selection: $selection) { entry in
                    HStack {
                        Label(entry.path, systemImage: entry.isDirectory ? "folder" : "doc")
                        Spacer()
                        Text(FileSizeFormatter.string(entry.size)).foregroundStyle(.secondary)
                    }.tag(entry.path).accessibilityIdentifier("archive.row." + entry.path)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if loading { ProgressView().controlSize(.small); Button("Cancel inspection") { inspection?.cancel() } }
                Spacer()
                if !creating && !entries.isEmpty { Button("Extract selected") { run(selected: selection) }.disabled(selection.isEmpty || submitted) }
                Button(creating ? "Create ZIP" : "Extract all") { run(selected: nil) }
                    .buttonStyle(.borderedProminent).disabled(submitted || (creating && encrypted && password.isEmpty))
            }
            if submitted { FormHint("Progress and cancellation are available in the job window. This panel closes when the operation succeeds.") }
        }.padding(24)
            .onDisappear { inspection?.cancel() }
            .onChange(of: submission.status) { _, status in
                switch status {
                case .succeeded: closeWindow()
                case .failed(let message): error = message
                case .cancelled: error = "Archive operation cancelled. Completed outputs have been kept. You can try again."
                case .idle, .running: break
                }
            }
    }
    private func inspect() {
        guard let first = files.first else { return }
        let password = password
        error = nil; loading = true; entries = []
        inspection = Task {
            do { entries = try await FileOperations.inspectArchive(first, password: password.isEmpty ? nil : password) } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }
    private func run(selected: Set<String>?) {
        guard let first = files.first else { return }
        error = nil
        let password = password, encrypt = encrypted
        if creating {
            let base = files.count == 1 ? ConversionMatrix.strippedBaseName(first.lastPathComponent) : "Archive"
            let output = ConversionMatrix.uniqueURL(directory: AppSettings.shared.outputLocation.directory(for: first), baseName: base, suffix: "", ext: "zip")
            let job = JobRunner.shared.run(title: encrypt ? "Creating encrypted ZIP" : "Creating ZIP", detail: "\(files.count) items", symbol: "archivebox") {
                progress in
                if encrypt {
                    try await EncryptedZIP.create(files, to: output, password: password, progress: progress)
                } else {
                    try await FileOperations.createZIP(files, to: output, progress: progress)
                }
                return [output]
            }
            submission.track([job])
        } else {
            let jobs = files.map { archive in
                let output = ConversionMatrix.uniqueDirectory(
                    directory: AppSettings.shared.outputLocation.directory(for: archive), name: ConversionMatrix.strippedBaseName(archive.lastPathComponent))
                return JobRunner.shared.run(title: "Extracting archive", detail: archive.lastPathComponent, symbol: "tray.and.arrow.down") { progress in
                    try await FileOperations.extract(archive, to: output, selected: selected, password: password.isEmpty ? nil : password, progress: progress)
                    return [output]
                }
            }
            submission.track(jobs)
        }
    }

    private func repack() {
        guard let first = files.first else { return }
        error = nil
        let selected = selection, current = password, new = protectExport ? exportPassword : nil
        let output = ConversionMatrix.uniqueURL(
            directory: AppSettings.shared.outputLocation.directory(for: first), baseName: ConversionMatrix.strippedBaseName(first.lastPathComponent),
            suffix: "exported", ext: "zip")
        let job = JobRunner.shared.run(title: "Exporting archive selection", detail: first.lastPathComponent, symbol: "archivebox") { progress in
            try await ArchiveRepack.export(
                first, selected: selected, currentPassword: current.isEmpty ? nil : current, newPassword: new, to: output, progress: progress)
            return [output]
        }
        submission.track([job])
    }
}

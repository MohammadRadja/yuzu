import SwiftUI

@MainActor
struct AdvancedToolView: View {
    private struct PreviewKey: Equatable { let options: WatermarkOptions; let page: Int }
    let session: ToolSession
    @State private var factor = 2.0
    @State private var page = 1
    @State private var options = WatermarkOptions(text: "", position: .bottomRight, width: 0.25, opacity: 1)
    @State private var preview: CGImage?
    @State private var comparison: FileComparisonResult?
    @State private var error: String?

    var body: some View {
        FormShell(
            session: session, saveTitle: session.tool == .fileComparison ? "Close" : "Save copy",
            saveEnabled: session.tool != .pdfSign || (options.image != nil && preview != nil && error == nil), onSave: run
        ) {
            Text(session.primary.lastPathComponent).font(.headline)
            if session.tool == .upscaleImage {
                Picker("Scale", selection: $factor) {
                    Text("2×").tag(2.0); Text("4×").tag(4.0)
                }.pickerStyle(.segmented)
                FormHint(
                    "Lanczos interpolation increases pixel dimensions. This is not AI super-resolution and does not reconstruct missing detail. Output is PNG.")
            } else if session.tool == .removeBackground {
                FormHint(
                    "Apple Vision identifies the foreground locally. Exports a transparent PNG, with a longest edge of at most 8192 pixels. Results depend on the subject and background."
                )
            } else if session.tool == .pdfSign {
                FormHint(
                    "Adds a visual signature image to a selected page. This is not a cryptographic digital signature and does not verify identity. Existing PDF signatures may be invalidated; keep the original."
                )
                Button(options.image?.lastPathComponent ?? "Choose signature image…") {
                    NativeFilePicker.choose(title: "Choose Signature Image", types: [.image]) { urls in if let image = urls.first { options.image = image } }
                }
                NumberField(title: "Page", value: $page)
                Picker("Position", selection: $options.position) { ForEach(WatermarkOptions.Position.allCases) { Text($0.rawValue).tag($0) } }
                LabeledSlider(title: "Width", value: $options.width, range: 0.05...0.8)
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 300)
                        .accessibilityHidden(false).accessibilityLabel("Visual signature preview")
                        .accessibilityIdentifier("signature.preview")
                }
            } else if let comparison {
                Text(comparison.identical ? "Files have identical SHA-256 content hashes." : "File contents differ.").font(.headline)
                if let inserted = comparison.insertions, let removed = comparison.removals { Text("\(inserted) inserted lines · \(removed) removed lines") }
                if let first = comparison.firstText, let second = comparison.secondText {
                    HStack(alignment: .top, spacing: 16) {
                        ScrollView { Text(first).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        ScrollView { Text(second).font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    }.frame(minHeight: 320)
                } else {
                    FormHint(
                        "Binary or large files are compared by streaming SHA-256. Text display is limited to 1 MiB per file; line diff is limited to 10,000 combined lines."
                    )
                }
            } else if session.tool == .fileComparison {
                ProgressView("Comparing files…")
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task {
            if session.tool == .fileComparison, session.files.count == 2 {
                do { comparison = try await FileComparison.compare(session.files[0], session.files[1]) } catch { self.error = error.localizedDescription }
            }
        }
        .task(id: PreviewKey(options: options, page: page)) {
            guard session.tool == .pdfSign, options.image != nil else { return }
            error = nil; preview = nil
            do { preview = try await VisualPDFSignature.preview(session.primary, page: page, options: options) } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func run() {
        if session.tool == .fileComparison { ToolWindowManager.shared.close(session); return }
        let source = session.primary, factor = factor, options = options, page = page
        let output = session.outputURL(
            suffix: session.tool == .pdfSign ? "visually signed" : session.tool.rawValue, ext: session.tool == .pdfSign ? "pdf" : "png")
        session.run(title: session.tool.progressTitle, detail: source.lastPathComponent) { progress in
            switch session.tool {
            case .removeBackground: try await AdvancedImageOps.removeBackground(source, to: output)
            case .upscaleImage: try await AdvancedImageOps.upscale(source, factor: factor, to: output)
            case .pdfSign: try await VisualPDFSignature.export(source, to: output, page: page, options: options)
            default: throw YuzuError.invalidInput("Choose a supported tool.")
            }
            progress(1)
            return [output]
        }
    }
}

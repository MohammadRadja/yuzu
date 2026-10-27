import SwiftUI

@MainActor
struct ProductivityToolView: View {
    let session: ToolSession
    @State private var watermark = WatermarkOptions()
    @State private var imageWatermark = false
    @State private var preview: CGImage?
    @State private var error: String?
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var protect = true
    @State private var authorized = false

    private var enabled: Bool {
        switch session.tool {
        case .watermark: return preview != nil && error == nil && (!imageWatermark || watermark.image != nil)
        case .pdfPassword: return authorized && (!protect || !newPassword.isEmpty)
        default: return true
        }
    }

    var body: some View {
        FormShell(session: session, saveTitle: session.tool == .ocr ? "Export TXT" : "Save copy", saveEnabled: enabled, onSave: run) {
            Text(session.primary.lastPathComponent).font(.headline).textSelection(.enabled)
            if session.tool == .watermark {
                if let preview {
                    Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 320)
                        .accessibilityLabel("Watermark preview of the first page or image")
                } else if error == nil {
                    ProgressView("Rendering preview…")
                }
                Toggle("Use an image watermark", isOn: $imageWatermark)
                    .onChange(of: imageWatermark) { _, enabled in if !enabled { watermark.image = nil } }
                if imageWatermark {
                    Button(watermark.image?.lastPathComponent ?? "Choose watermark image…") { chooseImage() }
                } else {
                    TextField("Watermark text", text: $watermark.text).textFieldStyle(.roundedBorder).accessibilityIdentifier("watermark.text")
                }
                Picker("Position", selection: $watermark.position) {
                    ForEach(WatermarkOptions.Position.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("watermark.position").accessibilityLabel("Watermark position")
                LabeledSlider(title: "Width", value: $watermark.width, range: 0.05...0.9, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Opacity", value: $watermark.opacity, range: 0.05...1, format: { "\(Int($0 * 100))%" })
                LabeledSlider(title: "Rotation", value: $watermark.rotation, range: -180...180, format: { "\(Int($0))°" })
                FormHint("PDF preview shows the first page. Export applies the watermark to every page. Images export as PNG.")
            } else if session.tool == .pdfPassword {
                SecureField("Current password (if encrypted)", text: $currentPassword).accessibilityIdentifier("pdf.currentPassword")
                Toggle("Protect the exported copy", isOn: $protect).accessibilityIdentifier("pdf.protect")
                if protect { SecureField("New password", text: $newPassword).accessibilityIdentifier("pdf.newPassword") }
                Toggle("I am authorized to change this document's protection", isOn: $authorized).accessibilityIdentifier("pdf.authorized")
                FormHint(
                    "Uses PDFKit encryption. A correct current password is required for encrypted input. Passwords are not stored. Document-level forms, outlines, and existing signatures may not survive page copying; keep your original."
                )
            } else {
                Label("Apple Vision · local text recognition", systemImage: "text.viewfinder")
                FormHint(
                    "Recognizes images and scanned PDF pages, then exports UTF-8 text. PDF pages are processed one at a time. Layout, tables, and handwriting fidelity vary; review the exported text."
                )
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task(id: watermark) {
            guard session.tool == .watermark else { return }
            preview = nil
            error = nil
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                let rendered = try await WatermarkOps.preview(session.primary, options: watermark)
                try Task.checkCancellation()
                preview = rendered
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }

    private func chooseImage() {
        NativeFilePicker.choose(title: "Choose Watermark Image", types: [.image]) { urls in if let image = urls.first { watermark.image = image } }
    }

    private func run() {
        let source = session.primary
        let options = watermark
        let old = currentPassword, new = newPassword, protect = protect, authorized = authorized
        let target: FileFormat = session.tool == .ocr ? .txt : (session.tool == .watermark && session.primaryFormat != .pdf ? .png : .pdf)
        let destination = session.outputURL(
            suffix: session.tool == .ocr ? "OCR" : (session.tool == .watermark ? "watermarked" : "protected"), ext: target.fileExtension)
        session.run(title: session.tool.progressTitle, detail: source.lastPathComponent) { progress in
            switch session.tool {
            case .watermark: try await WatermarkOps.export(source, to: destination, options: options, progress: progress)
            case .pdfPassword:
                try await PDFPasswordOps.export(source, to: destination, currentPassword: old, newPassword: protect ? new : nil, authorized: authorized)
            case .ocr: try await OCROps.export(source, to: destination, progress: progress)
            default: throw YuzuError.invalidInput("Choose a supported tool.")
            }
            return [destination]
        }
    }
}

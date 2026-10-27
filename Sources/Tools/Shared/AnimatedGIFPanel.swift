import SwiftUI

@MainActor
struct AnimatedGIFPanel: View {
    @State var files: [URL]
    @State private var delay = 0.2
    @State private var submitted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHint("Frames follow the order below. Use the arrows to reorder. Images fit the first frame's canvas, up to 1024 pixels on its longest edge.")
            List(Array(files.enumerated()), id: \.element) { index, url in
                HStack {
                    Text("\(index + 1). \(url.lastPathComponent)")
                    Spacer()
                    Button {
                        files.swapAt(index, index - 1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }.disabled(index == 0).accessibilityLabel("Move frame up")
                        .accessibilityIdentifier("gif.up.\(index)")
                }
            }
            LabeledSlider(title: "Seconds per frame", value: $delay, range: 0.02...2)
            HStack {
                Spacer()
                Button("Create GIF") {
                    guard let first = files.first else { return }
                    let urls = files, delay = delay
                    let output = ConversionMatrix.uniqueURL(
                        directory: AppSettings.shared.outputLocation.directory(for: first), baseName: "Animation", suffix: "", ext: "gif")
                    submitted = true
                    JobRunner.shared.run(title: "Creating GIF", detail: "\(urls.count) frames", symbol: "photo.stack") { progress in
                        try await AnimatedGIFWriter.write(urls, to: output, delay: delay, progress: progress)
                        return [output]
                    }
                }.buttonStyle(.borderedProminent).disabled(submitted)
            }
            if submitted { Text("Progress and cancellation are available in the job window.").foregroundStyle(.secondary) }
        }.padding(24)
    }
}

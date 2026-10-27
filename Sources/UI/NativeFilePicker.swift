import AppKit
import UniformTypeIdentifiers

@MainActor
enum NativeFilePicker {
    static func choose(
        title: String, directories: Bool = false, multiple: Bool = false, types: [UTType]? = nil,
        showHiddenFiles: Bool = false, prompt: String = "Choose",
        completion: @escaping ([URL]) -> Void
    ) {
        if ValidationRuntime.ownedGUI {
            // The integration harness supplies the OS dialog result. Application
            // controls, bindings, operations and output validation still run.
            completion(ValidationRuntime.fileSelections.isEmpty ? [] : ValidationRuntime.fileSelections.removeFirst())
            return
        }
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.showsHiddenFiles = showHiddenFiles
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories || multiple
        panel.allowsMultipleSelection = multiple
        if let types { panel.allowedContentTypes = types }
        panel.begin { response in completion(response == .OK ? panel.urls : []) }
    }
}

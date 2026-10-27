import AppKit
import Combine
import SwiftUI

struct ShelfReference: Identifiable, Codable {
    let id: UUID
    var bookmark: Data
    var lastPath: String

    mutating func resolve() -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
            url.isFileURL, FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        if stale, let updated = try? url.bookmarkData(options: .minimalBookmark) { bookmark = updated }
        lastPath = url.path
        return url
    }
}

@MainActor
final class FileShelfStore: ObservableObject {
    static let shared = FileShelfStore(defaults: ValidationRuntime.isolatedDefaults ?? .standard)
    @Published private(set) var items: [ShelfReference]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        items = defaults.data(forKey: "YuzuFileShelfV1").flatMap { try? JSONDecoder().decode([ShelfReference].self, from: $0) } ?? []
    }
    func add(_ urls: [URL]) throws {
        for url in FileSelection(urls: urls).urls {
            guard FileManager.default.fileExists(atPath: url.path) else { throw YuzuError.unreadable(url) }
            if items.contains(where: {
                var ref = $0; return ref.resolve()?.standardizedFileURL == url.standardizedFileURL
            }) {
                continue
            }
            guard items.count < 1000 else { throw YuzuError.invalidInput("The shelf holds up to 1,000 references. Remove an item first.") }
            items.append(ShelfReference(id: UUID(), bookmark: try url.bookmarkData(options: .minimalBookmark), lastPath: url.path))
        }
        save()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func refresh() {
        var refreshed = items
        for index in refreshed.indices { _ = refreshed[index].resolve() }
        items = refreshed
        save()
    }
    private func save() { if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: "YuzuFileShelfV1") } }
}

@MainActor
struct FileShelfView: View {
    let files: [URL]
    let use: ([URL], RadialMode) -> Void
    @ObservedObject private var shelf: FileShelfStore
    @State private var selected = Set<UUID>()
    @State private var mode = RadialMode.conversion
    @State private var error: String?
    @Environment(\.scenePhase) private var scenePhase

    init(files: [URL], shelf: FileShelfStore? = nil, use: @escaping ([URL], RadialMode) -> Void) {
        self.files = files
        self.shelf = shelf ?? .shared
        self.use = use
    }

    private var resolved: [(ShelfReference, URL?)] {
        shelf.items.map {
            var ref = $0; return (ref, ref.resolve())
        }
    }
    private var urls: [URL] { resolved.filter { selected.contains($0.0.id) }.compactMap(\.1) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FormHint("Temporary references to your files. Removing a reference does not delete its file. Missing items remain visible for review.")
            List(selection: $selected) {
                ForEach(resolved, id: \.0.id) { ref, url in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url?.lastPathComponent ?? (ref.lastPath as NSString).lastPathComponent).font(.headline)
                        Text(url?.path ?? "Missing · \(ref.lastPath)").font(.callout).foregroundStyle(url == nil ? .red : .secondary).textSelection(.enabled)
                    }.tag(ref.id).accessibilityIdentifier("shelf.row." + ref.id.uuidString)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Add files…") { choose() }.accessibilityIdentifier("shelf.add")
                Button("Refresh") { shelf.refresh() }.accessibilityIdentifier("shelf.refresh")
                Button("Remove reference") {
                    for id in selected { shelf.remove(id) }; selected = []
                }.disabled(selected.isEmpty).accessibilityIdentifier("shelf.remove")
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(RadialMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.frame(width: 160).accessibilityLabel("Shelf mode")
                Button("Use selection") { use(urls, mode) }
                    .disabled(urls.isEmpty).accessibilityIdentifier("shelf.use")
            }
        }.padding(24)
            .onAppear { do { try shelf.add(files); shelf.refresh() } catch { self.error = error.localizedDescription } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { shelf.refresh() } }
    }
    private func choose() {
        NativeFilePicker.choose(title: "Add to File Shelf", directories: true, multiple: true) { urls in
            do { try shelf.add(urls) } catch { self.error = error.localizedDescription }
        }
    }
}

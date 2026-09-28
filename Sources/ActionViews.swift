import SwiftUI

/// Everything the laptop knows about one file or folder.
struct DetailsView: View {
    let path: String
    let entry: Entry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stat: FileStat?
    @State private var error: String?
    @State private var size: FolderSize?
    @State private var sizeError: String?

    var body: some View {
        List {
            if let stat {
                ForEach(Array(stat.rows.enumerated()), id: \.offset) { item in
                    LabeledContent(item.element.0, value: item.element.1)
                        .accessibilityElement(children: .combine)
                }
                if stat.folder {
                    LabeledContent("Size", value: size?.spoken ?? sizeError ?? "Measuring")
                        .accessibilityElement(children: .combine)
                }
            } else if let error {
                Text(error)
            } else {
                Text("Loading")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            let client = model.client
            do {
                stat = try await client.stat(path)
            } catch is CancellationError {
                return
            } catch {
                model.noteFailure(error)
                self.error = ConnectError.message(for: error)
                Announce.say(self.error ?? "")
                return
            }
            if stat?.folder == true {
                do {
                    size = try await model.sizes.fetch(path, client: client)
                } catch {
                    sizeError = ConnectError.sizeMessage(for: error, name: entry.name)
                }
            }
        }
    }
}

/// Browse to a folder to copy or move into.
struct DestinationPicker: View {
    let request: PickRequest
    let onPick: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [FolderRoute]

    init(request: PickRequest, start: String, onPick: @escaping (String) -> Void) {
        self.request = request
        self.onPick = onPick
        _path = State(initialValue: RemotePath.ancestors(start).map { FolderRoute(path: $0, title: RemotePath.lastComponent($0)) })
    }

    private var title: String {
        let what = request.paths.count == 1 ? RemotePath.lastComponent(request.paths[0]) : "\(request.paths.count) items"
        return request.move ? "Move \(what)" : "Copy \(what)"
    }

    var body: some View {
        NavigationStack(path: $path) {
            PickDrivesList(cancel: { dismiss() })
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: FolderRoute.self) { route in
                    PickFolderList(route: route, request: request, cancel: { dismiss() }) { destination in
                        dismiss()
                        onPick(destination)
                    }
                }
        }
        .accessibilityAction(.magicTap) { model.player.togglePlayPause() }
    }

    /// Can't put a folder inside itself, and moving to where it already is does nothing.
    static func allowed(_ destination: String, _ request: PickRequest) -> Bool {
        for p in request.paths {
            if RemotePath.isInside(destination, p) { return false }
            if request.move, let parent = RemotePath.parent(p), parent.lowercased() == destination.lowercased() { return false }
        }
        return true
    }
}

private struct PickDrivesList: View {
    let cancel: () -> Void
    @Environment(AppModel.self) private var model
    @State private var drives: Load<[Drive]> = .loading

    var body: some View {
        StateList(state: drives, retry: load) { list in
            ForEach(list, id: \.name) { d in
                NavigationLink(value: FolderRoute(path: d.name, title: Labels.driveTitle(d))) {
                    RowContent(symbol: Labels.driveSymbol(d), title: Labels.driveTitle(d), detail: nil)
                }
                .accessibilityLabel(Labels.drive(d))
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
        }
        .task {
            if drives.value == nil { await load() }
        }
    }

    private func load() async {
        do {
            drives = .loaded(try await model.client.drives())
        } catch is CancellationError {
        } catch {
            if let saved = ListingCache.load([Drive].self, for: ListingCache.drivesKey) {
                drives = .cached(saved, ConnectError.message(for: error))
            } else {
                drives = .failed(ConnectError.message(for: error))
            }
        }
    }
}

private struct PickFolderList: View {
    let route: FolderRoute
    let request: PickRequest
    let cancel: () -> Void
    let pick: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var state: Load<[Entry]> = .loading

    var body: some View {
        StateList(state: state, retry: load) { entries in
            let folders = entries.filter(\.folder)
            if folders.isEmpty {
                Text("No folders here")
            }
            ForEach(folders) { e in
                let p = RemotePath.join(route.path, e.name)
                NavigationLink(value: FolderRoute(path: p, title: e.name)) {
                    RowContent(symbol: "folder", title: e.name, detail: nil)
                }
                .accessibilityLabel(e.name)
            }
        }
        .navigationTitle(route.title)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                HStack {
                    Button("Cancel", action: cancel)
                    Spacer()
                    Button(request.move ? "Move here" : "Copy here") { pick(route.path) }
                        .disabled(!DestinationPicker.allowed(route.path, request) || !state.isLive)
                        .bold()
                }
            }
        }
        .task {
            if state.value == nil { await load() }
        }
    }

    private func load() async {
        guard let result = await fetchListing(model, route.path) else { return }
        state = result
    }
}

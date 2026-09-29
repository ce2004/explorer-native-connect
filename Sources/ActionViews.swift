import SwiftUI

/// Everything the laptop knows about one file or folder, in sections. Every row is one VoiceOver element
/// ("Sample rate, 44.1 kHz"); chapters play from where they start.
struct DetailsView: View {
    let path: String
    let entry: Entry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var stat: RichStat?
    @State private var error: String?
    @State private var size: FolderSize?
    @State private var sizeError: String?
    @State private var hashing = false

    private var sections: [DetailSection] {
        guard let stat else { return [] }
        var list = DetailsBuilder.sections(stat, path: path)
        if stat.isFolder, let i = list.firstIndex(where: { $0.title == "File" }) {
            list[i].rows.append(DetailRow("Size", size?.spoken ?? sizeError ?? "Measuring"))
        }
        return list
    }

    var body: some View {
        List {
            if let stat {
                Section {
                    Button("Copy all details") { copyAll() }
                    if DetailsBuilder.canHash(stat, apiVersion: model.apiVersion) {
                        Button(hashing ? "Computing SHA-256" : "Compute SHA-256") { computeHash() }
                            .disabled(hashing)
                    }
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                            DetailRowView(row: row)
                        }
                    } header: {
                        Text(section.title).accessibilityAddTraits(.isHeader)
                    }
                }
                if !stat.chapters.isEmpty {
                    Section {
                        ForEach(Array(stat.chapters.enumerated()), id: \.offset) { i, chapter in
                            chapterRow(chapter, index: i)
                        }
                    } header: {
                        Text("Chapters").accessibilityAddTraits(.isHeader)
                    }
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
        .task { await load() }
    }

    @ViewBuilder
    private func chapterRow(_ chapter: Chapter, index: Int) -> some View {
        let label = DetailsBuilder.chapterLabel(chapter, index: index)
        let title = chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title
        if model.isAudio(entry.name) {
            Button {
                play(chapter, title: title)
            } label: {
                LabeledContent(title, value: Format.time(chapter.startSeconds))
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(label)
            .accessibilityHint("Plays from here.")
        } else {
            LabeledContent(title, value: Format.time(chapter.startSeconds))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        }
    }

    private func load() async {
        let client = model.client
        do {
            stat = try await client.stat(path)
            model.noteSuccess()
        } catch is CancellationError {
            return
        } catch {
            model.noteFailure(error)
            self.error = ConnectError.message(for: error)
            Announce.say(self.error ?? "")
            return
        }
        if stat?.isFolder == true {
            do {
                size = try await model.sizes.fetch(path, client: client)
            } catch {
                sizeError = ConnectError.sizeMessage(for: error, name: entry.name)
            }
        }
    }

    private func copyAll() {
        guard let stat else { return }
        UIPasteboard.general.string = DetailsBuilder.plainText(title: entry.name, sections: sections, chapters: stat.chapters)
        Announce.say("Copied all details.")
    }

    private func computeHash() {
        hashing = true
        Announce.say("Computing SHA-256.")
        let client = model.client
        Task {
            defer { hashing = false }
            do {
                let hashed = try await client.stat(path, hash: true)
                stat = hashed
                Announce.say(hashed.sha256 == nil ? "The laptop couldn't compute the SHA-256." : "SHA-256 computed. It's in the File section.")
            } catch {
                model.noteFailure(error)
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    private func play(_ chapter: Chapter, title: String) {
        let track = Player.Track(name: entry.name, path: path, folder: RemotePath.lastComponent(RemotePath.parent(path) ?? path))
        model.player.play(tracks: [track], client: model.client, at: chapter.startSeconds)
        Announce.say("Playing from \(title).")
    }
}

/// One label and value, read as one element, with Copy in its menu and its actions.
struct DetailRowView: View {
    let row: DetailRow

    var body: some View {
        LabeledContent {
            Text(row.value)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Text(row.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityText)
        .accessibilityAction(named: "Copy value") { copy() }
        .contextMenu {
            Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    private func copy() {
        UIPasteboard.general.string = row.value
        Announce.say("Copied.")
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

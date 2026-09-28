import SwiftUI
import UniformTypeIdentifiers

/// Loads a folder, falling back to the saved copy when the laptop can't be reached. nil means cancelled.
@MainActor
func fetchListing(_ model: AppModel, _ path: String) async -> Load<[Entry]>? {
    let client = model.client
    do {
        let entries = try await model.watched { try await client.list(path) }
        model.noteSuccess()
        Task.detached(priority: .utility) { ListingCache.save(entries, for: path) }
        return .loaded(entries)
    } catch is CancellationError {
        return nil
    } catch {
        if Task.isCancelled { return nil }
        model.noteFailure(error)
        let message = ConnectError.message(for: error)
        if ConnectError.isConnectionProblem(error), let saved = ListingCache.load([Entry].self, for: path) {
            return .cached(saved, message)
        }
        return .failed(message)
    }
}

/// Says "Still loading" if a listing is slow (big Drive folders can take most of a minute).
@MainActor
func stillLoadingNotice() -> Task<Void, Never> {
    Task {
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { Announce.say("Still loading.") }
    }
}

struct DrivesView: View {
    @Environment(AppModel.self) private var model
    @State private var state: Load<[Drive]> = .loading
    @State private var loadedGeneration = -1
    @State private var showSettings = false
    @State private var showTransfers = false

    var body: some View {
        StateList(state: state, retry: load) { drives in
            if drives.isEmpty {
                Text("No drives")
            }
            ForEach(drives, id: \.name) { d in
                NavigationLink(value: FolderRoute(path: d.name, title: Labels.driveTitle(d), space: Labels.space(d).map(capitalizedFirst))) {
                    RowContent(symbol: Labels.driveSymbol(d), title: Labels.driveTitle(d), detail: Labels.space(d))
                }
                .accessibilityLabel(Labels.drive(d))
            }
        }
        .navigationTitle(model.computerName.isEmpty ? "Drives" : model.computerName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showTransfers = true
                } label: {
                    Label("Transfers", systemImage: "arrow.up.arrow.down.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
            }
            .environment(model)
        }
        .sheet(isPresented: $showTransfers) {
            TransfersView()
                .environment(model)
        }
        .task(id: model.generation) {
            if !state.isLive || loadedGeneration != model.generation { await load() }
        }
        .onChange(of: model.onlineEpoch) {
            if !state.isLive { Task { await load() } }
        }
    }

    private func load() async {
        let generation = model.generation
        if state.value == nil { state = .loading }
        let client = model.client
        do {
            let drives = try await model.watched { try await client.drives() }
            model.noteSuccess()
            state = .loaded(drives)
            loadedGeneration = generation
            ListingCache.save(drives, for: ListingCache.drivesKey)
        } catch is CancellationError {
        } catch {
            if Task.isCancelled { return }
            model.noteFailure(error)
            let message = ConnectError.message(for: error)
            if ConnectError.isConnectionProblem(error), let saved = ListingCache.load([Drive].self, for: ListingCache.drivesKey) {
                state = .cached(saved, message)
                Announce.say("Offline, showing saved list. \(message)")
            } else {
                state = .failed(message)
                Announce.say(message)
            }
        }
    }
}

func capitalizedFirst(_ s: String) -> String {
    guard let first = s.first else { return s }
    return first.uppercased() + s.dropFirst()
}

struct PickRequest: Identifiable {
    let id = UUID()
    let paths: [String]
    let move: Bool
}

struct FolderView: View {
    let route: FolderRoute
    @Environment(AppModel.self) private var model
    @State private var state: Load<[Entry]> = .loading
    @State private var shown: [Entry] = []
    @State private var opening: OpenFile?
    @State private var details: Entry?
    @State private var picking: PickRequest?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var renaming: Entry?
    @State private var newName = ""
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var deleting: [Entry] = []
    @State private var confirmingDelete = false
    @State private var importing = false
    @State private var pickingPhotos = false

    private var settings: Settings { model.settings }
    private var editable: Bool { model.canEdit && state.isLive }

    var body: some View {
        dialogs(sheets(base))
    }

    private var base: some View {
        StateList(state: state, retry: load) { _ in
            if let space = route.space {
                Text(space)
                    .foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Text("Empty folder")
            }
            ForEach(shown) { e in
                row(e)
            }
        }
        .navigationTitle(route.title)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting { selectionBar }
        }
        .task {
            if state.value == nil { await load() }
        }
        .onChange(of: model.onlineEpoch) {
            if !state.isLive { Task { await load() } }
        }
        .onChange(of: model.changeEpoch) {
            Task { await load() }
        }
        .onChange(of: settings.sort) { resort() }
        .onChange(of: settings.foldersFirst) { resort() }
    }

    private func sheets<V: View>(_ view: V) -> some View {
        view
        .sheet(item: $opening) { file in
            FileOpenView(file: file)
                .environment(model)
        }
        .sheet(item: $details) { e in
            NavigationStack {
                DetailsView(path: path(e), entry: e)
            }
            .environment(model)
        }
        .sheet(item: $picking) { request in
            DestinationPicker(request: request, start: route.path) { destination in
                selecting = false
                selected = []
                Task {
                    await model.jobs.startCopy(request.paths, to: destination, move: request.move, conflict: settings.conflict, client: model.client)
                }
            }
            .environment(model)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                model.transfers.upload(files: urls, to: route.path, conflict: settings.conflict)
            case .failure(let error):
                Announce.say(error.localizedDescription)
            }
        }
        .sheet(isPresented: $pickingPhotos) {
            PhotoPicker { staged in
                pickingPhotos = false
                if !staged.isEmpty {
                    model.transfers.upload(staged: staged, to: route.path, conflict: settings.conflict)
                }
            }
            .ignoresSafeArea()
        }
    }

    private func dialogs<V: View>(_ view: V) -> some View {
        view
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { e in
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Rename") { rename(e, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New folder", isPresented: $creatingFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { makeFolder(folderName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(deleting) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deleted items go to the Recycle Bin, or the Google Drive trash.")
        }
    }

    // MARK: Rows

    private func path(_ e: Entry) -> String { RemotePath.join(route.path, e.name) }

    @ViewBuilder
    private func row(_ e: Entry) -> some View {
        let folderSize = e.folder ? model.sizes.result(for: path(e)) : nil
        let label = Labels.entry(e, showExtensions: settings.showExtensions, folderSize: folderSize)
        let detail: String? = e.folder ? folderSize?.short : (e.sizeKnown ? Format.size(e.size) : nil)
        let content = RowContent(
            symbol: selecting ? (selected.contains(e.name) ? "checkmark.circle.fill" : "circle") : (e.folder ? "folder" : FileKind.symbol(for: e.name, audio: model.isAudio(e.name))),
            title: Labels.displayName(e, showExtensions: settings.showExtensions),
            detail: detail
        )
        Group {
            if selecting {
                Button {
                    toggle(e)
                } label: {
                    content
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(label)
                .accessibilityAddTraits(selected.contains(e.name) ? .isSelected : [])
            } else if e.folder {
                NavigationLink(value: FolderRoute(path: path(e), title: e.name)) {
                    content
                }
                .accessibilityLabel(label)
            } else {
                Button {
                    open(e)
                } label: {
                    content
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(label)
            }
        }
        .contextMenu {
            if !selecting { actions(e) }
        }
        .accessibilityActions {
            if !selecting { actions(e) }
        }
        .onAppear {
            if e.folder && settings.showFolderSizes && editable { model.sizes.want(path(e), client: model.client) }
        }
        .onDisappear {
            if e.folder { model.sizes.unwant(path(e)) }
        }
    }

    @ViewBuilder
    private func actions(_ e: Entry) -> some View {
        if state.isLive {
            if editable && e.folder {
                Button { getSize(e) } label: { Label("Get size", systemImage: "scalemass") }
            }
            if editable {
                Button { details = e } label: { Label("Details", systemImage: "info.circle") }
                Button { startRename(e) } label: { Label("Rename", systemImage: "pencil") }
                Button { picking = PickRequest(paths: [path(e)], move: false) } label: { Label("Copy to", systemImage: "doc.on.doc") }
                Button { picking = PickRequest(paths: [path(e)], move: true) } label: { Label("Move to", systemImage: "folder") }
            }
            if !e.folder {
                Button { saveToPhone([e]) } label: { Label("Save to iPhone", systemImage: "square.and.arrow.down") }
                Button { opening = OpenFile(path: path(e), name: e.name, size: e.size, share: true) } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            if editable {
                Button { startSelecting(e) } label: { Label("Select", systemImage: "checkmark.circle") }
                Button(role: .destructive) { askDelete([e]) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    // MARK: Toolbars

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selected.count == shown.count ? "Select none" : "Select all") {
                    selected = selected.count == shown.count ? [] : Set(shown.map(\.name))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    selecting = false
                    selected = []
                }
            }
        } else if editable {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { startNewFolder() } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    Button { importing = true } label: { Label("Send from Files", systemImage: "square.and.arrow.up.on.square") }
                    Button { pickingPhotos = true } label: { Label("Send from Photos", systemImage: "photo.on.rectangle") }
                    Button { startSelecting(nil) } label: { Label("Select", systemImage: "checkmark.circle") }
                } label: {
                    Label("Folder actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private var selectionBar: some View {
        let items = shown.filter { selected.contains($0.name) }
        return VStack(spacing: 0) {
            Divider()
            Text("\(items.count) selected")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
            HStack(spacing: 12) {
                Button("Save to iPhone") { saveToPhone(items) }
                Button("Copy to") { picking = PickRequest(paths: items.map(path), move: false) }
                Button("Move to") { picking = PickRequest(paths: items.map(path), move: true) }
                Button("Delete", role: .destructive) { askDelete(items) }
            }
            .disabled(items.isEmpty)
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var deleteTitle: String {
        deleting.count == 1 ? "Delete \(deleting[0].name)?" : "Delete \(deleting.count) items?"
    }

    // MARK: Actions

    private func open(_ e: Entry) {
        if model.isAudio(e.name) {
            let tracks = QueueBuilder.queue(from: shown, startingAt: e, wholeFolder: settings.playWholeFolder, isAudio: model.isAudio).map {
                Player.Track(name: $0.name, path: path($0), folder: route.title)
            }
            model.player.play(tracks: tracks, client: model.client)
        } else {
            opening = OpenFile(path: path(e), name: e.name, size: e.size)
        }
    }

    private func saveToPhone(_ items: [Entry]) {
        let files = items.filter { !$0.folder }
        if files.count < items.count { Announce.say("Folders can't be saved to the iPhone; saving the files.") }
        guard !files.isEmpty else { return }
        model.transfers.download(files.map { (path: path($0), name: $0.name, size: $0.size) })
        selecting = false
        selected = []
    }

    private func toggle(_ e: Entry) {
        if selected.contains(e.name) { selected.remove(e.name) } else { selected.insert(e.name) }
    }

    private func startSelecting(_ e: Entry?) {
        selecting = true
        selected = e.map { [$0.name] } ?? []
        Announce.say("Selecting. \(selected.count) selected.")
    }

    private func getSize(_ e: Entry) {
        let p = path(e)
        Announce.say("Measuring \(e.name).")
        Task {
            do {
                let size = try await model.sizes.fetch(p, client: model.client)
                Announce.say("\(e.name): \(size.spoken)")
            } catch {
                model.noteFailure(error)
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    private func startRename(_ e: Entry) {
        newName = e.name
        renaming = e
    }

    private func rename(_ e: Entry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != e.name else { return }
        let client = model.client
        let p = path(e)
        Task {
            do {
                _ = try await client.rename(p, to: trimmed)
                Announce.say("Renamed to \(trimmed).")
                model.sizes.forget(inside: route.path)
                await load()
            } catch {
                model.noteFailure(error)
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    private func startNewFolder() {
        folderName = ""
        creatingFolder = true
    }

    private func makeFolder(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = model.client
        let parent = route.path
        Task {
            do {
                _ = try await client.mkdir(in: parent, name: trimmed)
                Announce.say("Created \(trimmed).")
                await load()
            } catch {
                model.noteFailure(error)
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    private func askDelete(_ items: [Entry]) {
        guard !items.isEmpty else { return }
        if settings.confirmDelete {
            deleting = items
            confirmingDelete = true
        } else {
            delete(items)
        }
    }

    private func delete(_ items: [Entry]) {
        let paths = items.map(path)
        let client = model.client
        Task {
            do {
                let result = try await client.delete(paths)
                if result.failed.isEmpty {
                    Announce.say(result.deleted == 1 ? "Deleted." : "Deleted \(result.deleted) items.")
                } else {
                    Announce.say("Deleted \(result.deleted). \(Format.count(result.failed.count, "item", "items")) couldn't be deleted: \(result.failed[0].error)")
                }
                selecting = false
                selected = []
                model.sizes.forget(inside: route.path)
                await load()
            } catch {
                model.noteFailure(error)
                Announce.say(ConnectError.message(for: error))
            }
        }
    }

    private func resort() {
        shown = Sorter.sort(state.value ?? [], by: settings.sort, foldersFirst: settings.foldersFirst)
    }

    private func load() async {
        if state.value == nil { state = .loading }
        let notice = stillLoadingNotice()
        defer { notice.cancel() }
        guard let result = await fetchListing(model, route.path) else { return }
        notice.cancel()
        switch result {
        case .failed(let message):
            if let old = state.value, !state.isLive || model.isOffline {
                state = .cached(old, message)
                Announce.say("Offline, showing saved list. \(message)")
            } else {
                state = .failed(message)
                Announce.say(message)
            }
        case .cached(_, let message):
            state = result
            Announce.say("Offline, showing saved list. \(message)")
        default:
            state = result
        }
        resort()
        selected = selected.filter { name in shown.contains { $0.name == name } }
    }
}

/// Icon, name and size. The row it sits in supplies the VoiceOver label.
struct RowContent: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .contentShape(Rectangle())
    }
}

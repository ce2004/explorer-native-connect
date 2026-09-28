import SwiftUI

struct DrivesView: View {
    @Environment(AppModel.self) private var model
    @State private var state: Load<[Drive]> = .loading
    @State private var loadedGeneration = -1
    @State private var showSettings = false

    var body: some View {
        StateList(state: state, retry: load) { drives in
            if drives.isEmpty {
                Text("No drives")
            }
            ForEach(drives, id: \.name) { d in
                NavigationLink(value: FolderRoute(path: d.name, title: Labels.driveTitle(d))) {
                    RowContent(symbol: Labels.driveSymbol(d), title: Labels.drive(d), detail: nil)
                }
                .accessibilityLabel(Labels.drive(d))
            }
        }
        .navigationTitle(model.computerName.isEmpty ? "Drives" : model.computerName)
        .toolbar {
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
        .task(id: model.generation) {
            if !state.isLoaded || loadedGeneration != model.generation { await load() }
        }
    }

    private func load() async {
        let generation = model.generation
        if !state.isLoaded { state = .loading }
        do {
            let drives = try await model.client.drives()
            state = .loaded(drives)
            loadedGeneration = generation
        } catch is CancellationError {
        } catch {
            let message = ConnectError.message(for: error)
            state = .failed(message)
            Announce.say(message)
        }
    }
}

struct FolderView: View {
    let route: FolderRoute
    @Environment(AppModel.self) private var model
    @State private var state: Load<[Entry]> = .loading
    @State private var opening: OpenFile?

    var body: some View {
        StateList(state: state, retry: load) { entries in
            if entries.isEmpty {
                Text("Empty folder")
            }
            ForEach(entries) { e in
                row(e, in: entries)
            }
        }
        .navigationTitle(route.title)
        .sheet(item: $opening) { file in
            FileOpenView(file: file)
                .environment(model)
        }
        .task {
            if !state.isLoaded { await load() }
        }
    }

    @ViewBuilder
    private func row(_ e: Entry, in entries: [Entry]) -> some View {
        let content = RowContent(
            symbol: e.folder ? "folder" : FileKind.symbol(for: e.name),
            title: e.name,
            detail: e.folder ? nil : Format.size(e.size)
        )
        if e.folder {
            NavigationLink(value: FolderRoute(path: RemotePath.join(route.path, e.name), title: e.name)) {
                content
            }
            .accessibilityLabel(Labels.entry(e))
        } else {
            Button {
                open(e, in: entries)
            } label: {
                content
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(Labels.entry(e))
        }
    }

    private func open(_ e: Entry, in entries: [Entry]) {
        if FileKind.isAudio(e.name) {
            let tracks = QueueBuilder.queue(from: entries, startingAt: e).map {
                Player.Track(name: $0.name, path: RemotePath.join(route.path, $0.name), folder: route.title)
            }
            model.player.play(tracks: tracks, client: model.client)
        } else {
            opening = OpenFile(path: RemotePath.join(route.path, e.name), name: e.name, size: e.size)
        }
    }

    private func load() async {
        if !state.isLoaded { state = .loading }
        do {
            state = .loaded(try await model.client.list(route.path))
        } catch is CancellationError {
        } catch {
            let message = ConnectError.message(for: error)
            state = .failed(message)
            Announce.say(message)
        }
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

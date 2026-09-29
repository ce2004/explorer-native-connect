import SwiftUI
import UniformTypeIdentifiers

/// The Clipboard tab.
struct ClipboardTab: View {
    var body: some View {
        NavigationStack {
            ClipboardView()
        }
        .modifier(PlayerBars())
    }
}

struct ClipboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var text = ""
    @State private var importing = false
    @State private var pickingPhotos = false
    @State private var opening: OpenFile?
    @State private var confirmingClear = false
    @FocusState private var typing: Bool

    private var clip: ClipboardModel { model.clipboard }

    var body: some View {
        List {
            Section {
                current
            } header: {
                Text("On the PC").accessibilityAddTraits(.isHeader)
            }

            Section {
                PasteButton(supportedContentTypes: [.plainText, .text, .image, .fileURL, .item]) { providers in
                    Task { @MainActor in clip.paste(providers, transfers: model.transfers) }
                }
                TextField("Text to send", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($typing)
                    .accessibilityIdentifier("text to send")
                Button("Send text") {
                    let sending = text
                    Task {
                        if await clip.send(text: sending) { text = "" }
                    }
                }
                .disabled(text.isEmpty)
                Button("Send files from Files") { importing = true }
                Button("Send from Photos") { pickingPhotos = true }
            } header: {
                Text("Send to the PC").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Files go onto the PC clipboard, so Control V pastes them on the laptop.")
            }

            Section {
                if clip.history.isEmpty {
                    Text(clip.historyLoaded ? "No history yet." : "Loading")
                }
                ForEach(clip.history) { item in
                    historyRow(item)
                }
                if !clip.history.isEmpty {
                    Button("Clear history", role: .destructive) { confirmingClear = true }
                }
            } header: {
                Text("History").accessibilityAddTraits(.isHeader)
            }
        }
        .navigationTitle("Clipboard")
        .refreshable { await clip.refresh() }
        .onAppear {
            clip.setAppActive(scenePhase == .active)
            clip.setVisible(true)
            Task { await clip.loadHistory() }
        }
        .onDisappear { clip.setVisible(false) }
        .onChange(of: scenePhase) { _, phase in
            clip.setAppActive(phase == .active)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.transfers.sendToClipboard(files: urls) }
        }
        .sheet(isPresented: $pickingPhotos) {
            PhotoPicker { staged in
                pickingPhotos = false
                model.transfers.sendToClipboard(staged: staged)
            }
            .ignoresSafeArea()
        }
        .sheet(item: $opening) { file in
            FileOpenView(file: file)
                .environment(model)
        }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) { Task { await clip.clearHistory() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: What's on the PC clipboard

    @ViewBuilder
    private var current: some View {
        if let state = clip.state {
            switch state.kind {
            case "text":
                let full = state.text ?? ""
                Text(full.count > 4000 ? String(full.prefix(4000)) + "… (\(full.count - 4000) more characters)" : full)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("pc clipboard text")
                Button("Copy to iPhone") { clip.copyToPhone(text: full) }
            case "files":
                let paths = state.files ?? []
                ForEach(paths, id: \.self) { path in
                    fileRow(path, all: paths)
                }
                if paths.count > 1 {
                    Button("Save all to iPhone") { save(paths) }
                }
            case "image":
                if let image = clip.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .accessibilityLabel("Image on the PC clipboard, \(Int(image.size.width)) by \(Int(image.size.height))")
                    Button("Copy to iPhone") { clip.copyImageToPhone() }
                    Button("Save to Photos") { clip.saveImageToPhotos() }
                } else {
                    Text("An image. Loading the preview.")
                }
            default:
                Text("The PC clipboard is empty.")
            }
        } else if let problem = clip.problem {
            Text(problem)
            Button("Try again") { Task { await clip.refresh() } }
        } else {
            Text("Loading")
        }
    }

    private func entry(_ path: String) -> Entry {
        Entry(name: RemotePath.lastComponent(path), folder: false, size: -1, modified: nil)
    }

    @ViewBuilder
    private func fileRow(_ path: String, all: [String]) -> some View {
        let e = entry(path)
        Button {
            open(path, all: all)
        } label: {
            RowContent(symbol: FileKind.symbol(for: e.name, audio: model.isAudio(e.name)),
                       title: Labels.displayName(e, showExtensions: model.settings.showExtensions), detail: nil)
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(Labels.entry(e, showExtensions: model.settings.showExtensions))
        .contextMenu { fileActions(path) }
        .accessibilityActions { fileActions(path) }
    }

    @ViewBuilder
    private func fileActions(_ path: String) -> some View {
        Button { save([path]) } label: { Label("Save to iPhone", systemImage: "square.and.arrow.down") }
        Button { opening = OpenFile(path: path, name: RemotePath.lastComponent(path), size: -1, share: true) } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func open(_ path: String, all: [String]) {
        let name = RemotePath.lastComponent(path)
        if model.isAudio(name) {
            let entries = all.map(entry)
            let queue = QueueBuilder.queue(from: entries, startingAt: entry(path), wholeFolder: model.settings.playWholeFolder, isAudio: model.isAudio)
            let byName = Dictionary(all.map { (RemotePath.lastComponent($0), $0) }, uniquingKeysWith: { a, _ in a })
            let tracks = queue.map { Player.Track(name: $0.name, path: byName[$0.name] ?? path, folder: "PC clipboard") }
            model.player.play(tracks: tracks, client: model.client)
        } else {
            opening = OpenFile(path: path, name: name, size: -1)
        }
    }

    private func save(_ paths: [String]) {
        model.transfers.download(paths.map { (path: $0, name: RemotePath.lastComponent($0), size: Int64(-1)) })
    }

    // MARK: History

    @ViewBuilder
    private func historyRow(_ item: ClipboardItem) -> some View {
        let summary = ClipText.summary(kind: item.kind, text: item.text, files: item.files)
        let when = item.time.map { $0.formatted(.relative(presentation: .named)) }
        Button {
            clip.copyToPhone(item)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .lineLimit(2)
                if let when {
                    Text(when)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(when.map { "\(summary), \($0)" } ?? summary)
        .accessibilityAction(named: "Send to PC again") { Task { await clip.sendAgain(item) } }
        .contextMenu {
            Button { clip.copyToPhone(item) } label: { Label("Copy to iPhone", systemImage: "doc.on.doc") }
            Button { Task { await clip.sendAgain(item) } } label: { Label("Send to PC again", systemImage: "arrow.up.doc") }
        }
    }
}

/// The copy and transfer line and the now-playing bar, under every tab.
struct PlayerBars: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showNowPlaying = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    ActivityBar()
                    if model.player.current != nil {
                        NowPlayingBar { showNowPlaying = true }
                    }
                }
            }
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
                    .environment(model)
            }
    }
}

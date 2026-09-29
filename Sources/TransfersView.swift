import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Everything moving between the phone and the laptop, plus copies and moves running on the laptop.
struct TransfersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var previewing: URL?
    @State private var sharing: URL?
    @State private var exporting: URL?

    var body: some View {
        NavigationStack {
            List {
                if model.jobs.jobs.isEmpty && model.transfers.records.isEmpty {
                    Text("Nothing is transferring.")
                }
                if !model.jobs.jobs.isEmpty {
                    Section {
                        ForEach(model.jobs.jobs) { job in
                            HStack {
                                Text(job.spoken)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if job.finished {
                                    Button("Dismiss") { model.jobs.dismiss(job.id) }
                                } else {
                                    Button("Cancel") { model.jobs.cancel(job.id) }
                                }
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("On the laptop")
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                if !model.transfers.records.isEmpty {
                    Section {
                        ForEach(Array(model.transfers.records.reversed())) { r in
                            row(r)
                        }
                    } header: {
                        Text("Between phone and laptop")
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if model.transfers.records.contains(where: \.isFinished) {
                        Button("Clear finished") { model.transfers.clearFinished() }
                    }
                }
            }
            .sheet(item: Binding(get: { previewing.map(IdentifiedURL.init) }, set: { previewing = $0?.url })) { item in
                NavigationStack {
                    QuickLookView(url: item.url)
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle(item.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { previewing = nil }
                            }
                            ToolbarItem(placement: .primaryAction) {
                                ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            }
                        }
                }
            }
            .sheet(item: Binding(get: { sharing.map(IdentifiedURL.init) }, set: { sharing = $0?.url })) { item in
                ActivityView(items: [item.url])
            }
            .sheet(item: Binding(get: { exporting.map(IdentifiedURL.init) }, set: { exporting = $0?.url })) { item in
                ExportPicker(url: item.url) { exporting = nil }
                    .ignoresSafeArea()
            }
        }
        .accessibilityAction(.magicTap) { model.player.togglePlayPause() }
    }

    @ViewBuilder
    private func row(_ r: TransferRecord) -> some View {
        let text = TransferText.describe(r, rate: model.transfers.rate(r.id))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: r.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if r.isActive || r.state == .paused, r.size > 0 {
                ProgressView(value: min(1, Double(r.done) / Double(r.size)))
                    .accessibilityHidden(true)
            }
            HStack(spacing: 20) {
                switch r.state {
                case .running, .finishing, .sendingToDrive:
                    if r.state == .running { Button("Pause") { model.transfers.pause(r.id) } }
                    Button("Cancel", role: .destructive) { model.transfers.cancel(r.id) }
                case .paused, .waiting, .failed:
                    Button("Resume") { model.transfers.resume(r.id) }
                    Button("Cancel", role: .destructive) { model.transfers.cancel(r.id) }
                case .done:
                    if let url = model.transfers.savedURL(r) {
                        Button("Open") { previewing = url }
                        Button("Share") { sharing = url }
                        Button("Save to Files") { exporting = url }
                    }
                    Button("Remove") { model.transfers.remove(r.id) }
                case .cancelled:
                    Button("Remove") { model.transfers.remove(r.id) }
                }
            }
            .buttonStyle(TapTargetButtonStyle())
            .font(.subheadline)
        }
        .padding(.vertical, 4)
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: URL { url }
}

/// "Save to Files": the system's export picker, copying so the file stays in Explorer Connect too.
struct ExportPicker: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            Announce.say("Saved.")
            done()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            done()
        }
    }
}

/// Photos and videos from the library, as their original files, copied into the app so the transfer can resume.
struct PhotoPicker: UIViewControllerRepresentable {
    let onDone: ([(name: String, stagedName: String)]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        config.selection = .ordered
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onDone: ([(name: String, stagedName: String)]) -> Void
        init(onDone: @escaping ([(name: String, stagedName: String)]) -> Void) { self.onDone = onDone }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                onDone([])
                return
            }
            let count = results.count
            MainActor.assumeIsolated {
                Announce.say(count == 1 ? "Preparing 1 item." : "Preparing \(count) items.")
            }
            let group = DispatchGroup()
            let box = StagedBox()
            let folder = TransferCenter.stagingFolder
            for (i, result) in results.enumerated() {
                let provider = result.itemProvider
                let types = provider.registeredTypeIdentifiers
                let preferred = types.first { id in
                    guard let t = UTType(id) else { return false }
                    return t.conforms(to: .image) || t.conforms(to: .movie) || t.conforms(to: .audiovisualContent)
                } ?? types.first
                guard let type = preferred else { continue }
                let suggested = provider.suggestedName
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                    defer { group.leave() }
                    guard let url else { return }
                    var name = url.lastPathComponent
                    if let suggested, !suggested.isEmpty {
                        let ext = url.pathExtension.isEmpty ? (UTType(type)?.preferredFilenameExtension ?? "") : url.pathExtension
                        name = ext.isEmpty ? suggested : "\(suggested).\(ext)"
                    }
                    let stagedName = UUID().uuidString + "-" + name
                    guard (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(stagedName))) != nil else { return }
                    box.add((i, name, stagedName))
                }
            }
            group.notify(queue: .main) { [onDone] in
                MainActor.assumeIsolated {
                let ordered = box.items.sorted { $0.0 < $1.0 }.map { (name: $0.1, stagedName: $0.2) }
                if ordered.count < results.count {
                    Announce.say("\(results.count - ordered.count) couldn't be read.")
                }
                onDone(ordered)
                }
            }
        }
    }
}

private final class StagedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [(Int, String, String)] = []

    func add(_ item: (Int, String, String)) {
        lock.lock()
        list.append(item)
        lock.unlock()
    }

    var items: [(Int, String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }
}

/// A borderless button with at least a 44 point square hit area, the size
/// Apple's accessibility audit asks for. `.borderless` sizes to its text.
struct TapTargetButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? Color.red : Color.accentColor)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

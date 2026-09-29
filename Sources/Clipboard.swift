import Observation
import Photos
import UIKit
import UniformTypeIdentifiers

/// The PC clipboard: what it holds, live while the Clipboard tab is showing, and its history.
@MainActor
@Observable
final class ClipboardModel {
    private(set) var state: ClipboardState?
    private(set) var image: UIImage?
    private(set) var history: [ClipboardItem] = []
    private(set) var problem: String?
    private(set) var historyLoaded = false

    @ObservationIgnored var clientProvider: (@MainActor () -> ConnectClient)?
    @ObservationIgnored var onConnectionProblem: (@MainActor (Error) -> Void)?
    @ObservationIgnored var onSuccess: (@MainActor () -> Void)?
    @ObservationIgnored var announceChanges = true
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// Changes we made ourselves aren't announced back.
    @ObservationIgnored private var ownChanges: Set<Int64> = []
    /// A server with a history (every server with a clipboard so far) records what the phone sends itself, so the
    /// phone keeps no echo of its own; this is only for one that doesn't.
    @ObservationIgnored var serverKeepsHistory = true
    @ObservationIgnored private var localEchoes: [ClipboardItem] = []
    @ObservationIgnored private var serverHistory: [ClipboardItem] = []
    @ObservationIgnored private var tabVisible = false
    @ObservationIgnored private var appActive = true

    /// The Clipboard tab came into view or went away.
    func setVisible(_ visible: Bool) {
        tabVisible = visible
        updateWatching()
    }

    /// The app came to the front, or went to the background (the screen went off).
    func setAppActive(_ active: Bool) {
        appActive = active
        updateWatching()
    }

    /// The long poll runs only while the tab is showing and the app is in front, so the radio sleeps otherwise.
    private func updateWatching() {
        if tabVisible && appActive { startWatching() } else { stopWatching() }
    }

    var isWatching: Bool { watcher != nil }

    private func startWatching() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in await self?.watch() }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    private func watch() async {
        var delay: Double = 2
        var first = true
        while !Task.isCancelled {
            guard let client = clientProvider?() else { return }
            do {
                let next: ClipboardState
                if first || state == nil {
                    next = try await client.clipboard()
                } else {
                    next = try await client.clipboardWait(since: state?.seq ?? 0)
                }
                if Task.isCancelled { return }
                delay = 2
                problem = nil
                onSuccess?()
                await apply(next, announce: !first)
                first = false
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                problem = ConnectError.message(for: error)
                onConnectionProblem?(error)
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
            }
        }
    }

    private func apply(_ next: ClipboardState, announce: Bool) async {
        let changed = next.seq != state?.seq
        state = next
        guard changed else { return }
        if next.kind == "image", let client = clientProvider?() {
            image = (try? await client.clipboardImage()).flatMap(UIImage.init(data:))
        } else {
            image = nil
        }
        if announce && announceChanges && !ownChanges.contains(next.seq), let text = ClipText.announcement(next) {
            Announce.say(text)
        }
        if historyLoaded { await loadHistory() }
    }

    func refresh() async {
        guard let client = clientProvider?() else { return }
        do {
            await apply(try await client.clipboard(), announce: false)
            problem = nil
            await loadHistory()
        } catch {
            problem = ConnectError.message(for: error)
            onConnectionProblem?(error)
        }
    }

    func loadHistory() async {
        guard let client = clientProvider?() else { return }
        if let items = try? await client.clipboardHistory() {
            serverHistory = items
            rebuildHistory()
            historyLoaded = true
        }
    }

    private func rebuildHistory() {
        let merged = ClipHistory.merge(server: serverHistory, local: localEchoes, serverKeepsHistory: serverKeepsHistory)
        if merged != history { history = merged }
    }

    // MARK: PC to phone

    func copyToPhone(text: String) {
        UIPasteboard.general.string = text
        Announce.say("Copied to iPhone.")
    }

    func copyImageToPhone() {
        guard let image else { return }
        UIPasteboard.general.image = image
        Announce.say("Image copied to iPhone.")
    }

    func saveImageToPhotos() {
        guard let image else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in Announce.say("Explorer Connect isn't allowed to add to Photos. You can allow it in Settings.") }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { ok, _ in
                Task { @MainActor in Announce.say(ok ? "Saved to Photos." : "Couldn't save to Photos.") }
            }
        }
    }

    /// A history row: text goes onto the iPhone clipboard; files as their paths.
    func copyToPhone(_ item: ClipboardItem) {
        switch item.kind {
        case "text": copyToPhone(text: item.text ?? "")
        case "files":
            UIPasteboard.general.string = (item.files ?? []).joined(separator: "\n")
            Announce.say("File paths copied to iPhone.")
        default:
            Announce.say("Only text and files from the history can be copied.")
        }
    }

    // MARK: Phone to PC

    func send(text: String) async -> Bool {
        guard let client = clientProvider?(), !text.isEmpty else { return false }
        do {
            let seq = try await client.setClipboard(text: text)
            ownChanges.insert(seq)
            if !serverKeepsHistory {
                localEchoes.insert(ClipboardItem(seq: seq, kind: "text", text: text, time: Date()), at: 0)
                localEchoes = Array(localEchoes.prefix(50))
                rebuildHistory()
            }
            Announce.say("Sent to the PC clipboard.")
            if historyLoaded && !isWatching { await loadHistory() }
            return true
        } catch {
            onConnectionProblem?(error)
            Announce.say(ConnectError.message(for: error))
            return false
        }
    }

    func send(image data: Data, contentType: String) async {
        guard let client = clientProvider?() else { return }
        do {
            try await client.setClipboard(image: data, contentType: contentType)
            Announce.say("Image sent to the PC clipboard.")
        } catch {
            onConnectionProblem?(error)
            Announce.say(ConnectError.message(for: error))
        }
    }

    /// History row's custom action.
    func sendAgain(_ item: ClipboardItem) async {
        guard let client = clientProvider?() else { return }
        do {
            switch item.kind {
            case "text":
                let seq = try await client.setClipboard(text: item.text ?? "")
                ownChanges.insert(seq)
            case "files":
                try await client.copyOnPC(item.files ?? [])
            default:
                Announce.say("Images in the history can't be sent again.")
                return
            }
            Announce.say("Back on the PC clipboard.")
        } catch {
            onConnectionProblem?(error)
            Announce.say(ConnectError.message(for: error))
        }
    }

    func clearHistory() async {
        guard let client = clientProvider?() else { return }
        do {
            try await client.clearClipboardHistory()
            serverHistory = []
            localEchoes = []
            history = []
            Announce.say("History cleared.")
        } catch {
            Announce.say(ConnectError.message(for: error))
        }
    }

    /// What the Paste button hands over: text, an image, or files (sent through Transfers).
    func paste(_ providers: [NSItemProvider], transfers: TransferCenter) {
        guard let provider = providers.first else { return }
        if provider.canLoadObject(ofClass: String.self) && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                guard let text else { return }
                Task { @MainActor in _ = await self?.send(text: text) }
            }
            return
        }
        if let imageType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }),
           providers.count == 1, !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: imageType) { [weak self] data, _ in
                guard let data else { return }
                let type = UTType(imageType)?.preferredMIMEType ?? "image/png"
                Task { @MainActor in await self?.send(image: data, contentType: type) }
            }
            return
        }
        // Files: copy each into the app, then send them as one batch.
        let folder = TransferCenter.stagingFolder
        let group = DispatchGroup()
        let box = PastedBox()
        for (i, p) in providers.enumerated() {
            guard let type = p.registeredTypeIdentifiers.first else { continue }
            let suggested = p.suggestedName
            group.enter()
            p.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                var name = url.lastPathComponent
                if let suggested, !suggested.isEmpty, !url.pathExtension.isEmpty, !suggested.hasSuffix("." + url.pathExtension) {
                    name = suggested + "." + url.pathExtension
                }
                let stagedName = UUID().uuidString + "-" + name
                if (try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(stagedName))) != nil {
                    box.add(i, name, stagedName)
                }
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let staged = box.sorted
                if staged.isEmpty {
                    Announce.say("Nothing on the iPhone clipboard could be sent.")
                } else {
                    transfers.sendToClipboard(staged: staged)
                }
            }
        }
    }
}

private final class PastedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, String, String)] = []

    func add(_ i: Int, _ name: String, _ staged: String) {
        lock.lock()
        items.append((i, name, staged))
        lock.unlock()
    }

    var sorted: [(name: String, stagedName: String)] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.0 < $1.0 }.map { (name: $0.1, stagedName: $0.2) }
    }
}

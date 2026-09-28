import AVFoundation
import MediaPlayer
import Observation
import UniformTypeIdentifiers

/// Streams audio files from the laptop. Keeps its own queue and gives AVQueuePlayer the current track plus
/// the next one, so the next track is already buffering when this one ends.
@MainActor
@Observable
final class Player {
    struct Track: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let path: String
        let folder: String
        var title: String { FileKind.baseName(name) }
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var tagTitle: String?
    private(set) var tagArtist: String?

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var title: String { tagTitle ?? current?.title ?? "" }
    var subtitle: String { tagArtist ?? current?.folder ?? "" }
    var hasNext: Bool { index + 1 < queue.count }

    @ObservationIgnored private let player = AVQueuePlayer()
    @ObservationIgnored private var client: ConnectClient?
    @ObservationIgnored private var itemIndex: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var interruptionObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .advance
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let playing = p.timeControlStatus != .paused
            Task { @MainActor in self?.setPlaying(playing) }
        })
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume) else { return }
            Task { @MainActor in self?.play() }
        }
        setUpRemoteCommands()
    }

    // MARK: - Controls

    func play(tracks: [Track], startAt: Int = 0, client: ConnectClient) {
        self.client = client
        queue = tracks
        load(startAt)
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard current != nil else { return }
        if player.currentItem == nil {
            load(index)
            return
        }
        activateSession()
        player.play()
    }

    func pause() {
        player.pause()
    }

    func next() {
        if hasNext { load(index + 1) }
    }

    func previous() {
        if position > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(index - 1)
        }
    }

    func jump(to i: Int) {
        load(i)
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        var t = max(0, seconds)
        if duration > 0 { t = min(t, max(0, duration - 1)) }
        position = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    // MARK: - Queue plumbing

    private func load(_ i: Int) {
        guard queue.indices.contains(i) else { return }
        activateSession()
        index = i
        resetTrackState()
        player.removeAllItems()
        itemIndex.removeAll()
        itemObservations.removeAll()
        guard let item = makeItem(i) else {
            failed(i)
            return
        }
        player.insert(item, after: nil)
        preloadNext()
        player.play()
        updateNowPlaying()
        loadTags(item.asset, trackID: queue[i].id)
    }

    private func resetTrackState() {
        position = 0
        duration = 0
        tagTitle = nil
        tagArtist = nil
    }

    private func makeItem(_ i: Int) -> AVPlayerItem? {
        guard let client, let url = client.fileURL(queue[i].path) else { return nil }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": client.headers]
        // The URL has no extension (/api/file?path=...), so say what the file is.
        if let mime = UTType(filenameExtension: FileKind.ext(queue[i].name))?.preferredMIMEType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        let id = ObjectIdentifier(item)
        itemIndex[id] = i
        itemObservations[id] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let failedID = ObjectIdentifier(item)
            Task { @MainActor in self?.itemFailed(failedID) }
        }
        return item
    }

    /// Keeps exactly one track queued behind the current one.
    private func preloadNext() {
        let items = player.items()
        guard items.count == 1, let currentIndex = itemIndex[ObjectIdentifier(items[0])] else { return }
        var j = currentIndex + 1
        while j < queue.count {
            if let item = makeItem(j) {
                player.insert(item, after: items[0])
                return
            }
            j += 1
        }
    }

    private func currentItemChanged() {
        guard let item = player.currentItem else {
            // Ran off the end of the queue; stay on the last track so Play starts it again.
            if !queue.isEmpty { position = 0; updateNowPlaying() }
            return
        }
        guard let i = itemIndex[ObjectIdentifier(item)], i != index else { return }
        index = i
        resetTrackState()
        // Forget items that are no longer in the player.
        let live = Set(player.items().map { ObjectIdentifier($0) })
        for id in itemIndex.keys where !live.contains(id) {
            itemIndex[id] = nil
            itemObservations[id] = nil
        }
        preloadNext()
        updateNowPlaying()
        loadTags(item.asset, trackID: queue[i].id)
    }

    private func itemFailed(_ id: ObjectIdentifier) {
        guard let i = itemIndex[id], queue.indices.contains(i) else { return }
        let isCurrent = player.currentItem.map { ObjectIdentifier($0) } == id
        if isCurrent {
            failed(i)
        } else if let item = player.items().first(where: { ObjectIdentifier($0) == id }) {
            // The preloaded track can't play: say so now and line up the one after it.
            Announce.say("Can't play \(queue[i].title).")
            player.remove(item)
            itemIndex[id] = nil
            itemObservations[id] = nil
            if let current = player.currentItem {
                var j = i + 1
                while j < queue.count {
                    if let next = makeItem(j) {
                        player.insert(next, after: current)
                        break
                    }
                    j += 1
                }
            }
        }
    }

    private func failed(_ i: Int) {
        Announce.say("Can't play \(queue[i].title).")
        if i + 1 < queue.count {
            load(i + 1)
        } else {
            player.removeAllItems()
            index = i
            resetTrackState()
            updateNowPlaying()
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlaying()
    }

    private func tick(_ seconds: Double) {
        if seconds.isFinite, player.currentItem != nil { position = max(0, seconds) }
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
    }

    private func loadTags(_ asset: AVAsset, trackID: UUID) {
        Task { [weak self] in
            guard let metadata = try? await asset.load(.commonMetadata) else { return }
            var title: String?
            var artist: String?
            for m in metadata {
                if m.commonKey == .commonKeyTitle { title = try? await m.load(.stringValue) }
                if m.commonKey == .commonKeyArtist { artist = try? await m.load(.stringValue) }
            }
            guard let self, self.current?.id == trackID else { return }
            if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { self.tagTitle = title }
            if let artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty { self.tagArtist = artist }
            self.updateNowPlaying()
        }
    }

    // MARK: - System integration

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        c.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: 15) }
            return .success
        }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -15) }
            return .success
        }
    }
}

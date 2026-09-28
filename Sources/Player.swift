import AVFoundation
import MediaPlayer
import Observation
import UniformTypeIdentifiers

/// Streams audio files from the laptop.
///
/// The active AVQueuePlayer holds the current track plus the next one, so the next track is already buffering when
/// this one ends. A track the user picks while something is playing loads in a second player and takes over only once
/// it has buffered playable audio ("Keep playing until the next track is ready").
/// If the laptop drops off, playback waits and picks up at the same spot when it comes back.
@MainActor
@Observable
final class Player {
    struct Track: Identifiable, Hashable, Codable {
        var id = UUID()
        let name: String
        let path: String
        let folder: String
        var title: String { FileKind.baseName(name) }

        private enum CodingKeys: String, CodingKey { case name, path, folder }

        init(name: String, path: String, folder: String) {
            self.name = name
            self.path = path
            self.folder = folder
        }
    }

    struct SavedState: Codable, Equatable {
        var tracks: [Track]
        var index: Int
        var position: Double
        var playing: Bool
    }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    /// The player is actually producing sound (or buffering to).
    private(set) var isPlaying = false
    /// What the user asked for; drives the Play/Pause button, including while reconnecting.
    private(set) var wantsPlay = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var tagTitle: String?
    private(set) var tagArtist: String?
    private(set) var reconnecting = false
    /// Title of a track loading in the background while the current one keeps playing.
    private(set) var loadingTitle: String?
    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffled = false
    private(set) var speed: Float = 1
    private(set) var sleepEnd: Date?
    private(set) var sleepAtTrackEnd = false

    var current: Track? { queue.indices.contains(index) ? queue[index] : nil }
    var title: String { tagTitle ?? current?.title ?? "" }
    var subtitle: String { tagArtist ?? current?.folder ?? "" }
    var hasNext: Bool { QueueBuilder.next(after: index, count: queue.count, repeatMode: repeatMode) != nil }
    var sleepTimerOn: Bool { sleepEnd != nil || sleepAtTrackEnd }

    // Set by AppModel from Settings.
    @ObservationIgnored var skipInterval: Double = 15 { didSet { updateSkipIntervals() } }
    @ObservationIgnored var keepPlayingUntilReady = true
    @ObservationIgnored var persistEnabled = true
    /// Which files go through /api/audio.
    @ObservationIgnored var formats = Formats.fallback
    /// Asks the laptop whether it's reachable (short timeout).
    @ObservationIgnored var probe: (@MainActor () async -> Bool)?
    @ObservationIgnored var onConnectionLost: (@MainActor () -> Void)?

    private final class Pending {
        let id = UUID()
        let tracks: [Track]
        let index: Int
        let start: Double
        let player: AVQueuePlayer
        let item: AVPlayerItem
        var observations: [NSKeyValueObservation] = []
        var positioned: Bool
        var committing = false

        init(tracks: [Track], index: Int, start: Double, player: AVQueuePlayer, item: AVPlayerItem) {
            self.tracks = tracks
            self.index = index
            self.start = start
            self.player = player
            self.item = item
            positioned = start <= 0
        }
    }

    @ObservationIgnored private var active = AVQueuePlayer()
    @ObservationIgnored private var client: ConnectClient?
    @ObservationIgnored private var itemIndex: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    @ObservationIgnored private var readyItems: Set<ObjectIdentifier> = []
    @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverOwner: AVPlayer?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: Pending?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var recovering = false
    @ObservationIgnored private var resumeAt: Double = 0
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var badInARow = 0
    @ObservationIgnored private var lastPlayingAt = Date.distantPast
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var originalQueue: [Track]?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var seekGeneration = 0
    @ObservationIgnored private var seeking = false

    static let savedKey = "playback"
    private static let repeatKey = "repeatMode"
    private static let speedKey = "playbackSpeed"

    init() {
        let d = UserDefaults.standard
        repeatMode = RepeatMode(rawValue: d.string(forKey: Self.repeatKey) ?? "") ?? .off
        let savedSpeed = d.float(forKey: Self.speedKey)
        speed = savedSpeed > 0 ? savedSpeed : 1
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        configure(active)
        attach(active)
        observeNotifications()
        setUpRemoteCommands()
    }

    // MARK: - Starting playback

    func play(tracks: [Track], startAt: Int = 0, client: ConnectClient) {
        self.client = client
        var list = tracks
        var start = startAt
        originalQueue = nil
        if shuffled && list.count > 1 {
            originalQueue = list
            list = QueueBuilder.shuffled(list, current: startAt)
            start = 0
        }
        begin(list, start, at: 0)
    }

    /// Puts back what was playing when the app last went away.
    func restore(_ state: SavedState, client: ConnectClient) {
        guard state.tracks.indices.contains(state.index) else { return }
        self.client = client
        queue = state.tracks
        loadActive(state.index, at: state.position, autoplay: state.playing)
    }

    static func loadSaved() -> SavedState? {
        guard let data = UserDefaults.standard.data(forKey: savedKey) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    func updateClient(_ client: ConnectClient) {
        self.client = client
    }

    /// Picks a track by the user. Keeps the current one playing until the new one is ready, if that's on.
    private func begin(_ tracks: [Track], _ i: Int, at start: Double) {
        guard tracks.indices.contains(i) else { return }
        retries = 0
        badInARow = 0
        if keepPlayingUntilReady && isPlaying && active.currentItem != nil && !recovering && !reconnecting {
            beginPending(tracks, i, at: start)
        } else {
            cancelPending()
            queue = tracks
            loadActive(i, at: start, autoplay: true)
        }
    }

    // MARK: - Controls

    func togglePlayPause() {
        if wantsPlay { pause() } else { play() }
    }

    func play() {
        guard current != nil else { return }
        if reconnecting {
            wantsPlay = true
            save()
            Task { [weak self] in
                if await self?.probe?() == true { self?.connectionRestored() }
            }
            return
        }
        if active.currentItem == nil {
            loadActive(index, at: position, autoplay: true)
            return
        }
        activateSession()
        wantsPlay = true
        if pendingSeek == nil { active.play() }
        updateNowPlaying()
        save()
    }

    func pause() {
        wantsPlay = false
        cancelPending()
        active.pause()
        updateNowPlaying()
        save()
    }

    func next() {
        let base = pending?.index ?? index
        let tracks = pending?.tracks ?? queue
        guard let n = QueueBuilder.next(after: base, count: tracks.count, repeatMode: repeatMode) else { return }
        begin(tracks, n, at: 0)
    }

    func previous() {
        if pending == nil && (position > 3 || QueueBuilder.previous(before: index, count: queue.count, repeatMode: repeatMode) == nil) {
            seek(to: 0)
            return
        }
        let base = pending?.index ?? index
        let tracks = pending?.tracks ?? queue
        guard let p = QueueBuilder.previous(before: base, count: tracks.count, repeatMode: repeatMode) else { return }
        begin(tracks, p, at: 0)
    }

    func jump(to i: Int) {
        begin(queue, i, at: 0)
    }

    func skip(by seconds: Double) {
        seek(to: position + seconds)
    }

    func skipForward() { skip(by: skipInterval) }
    func skipBackward() { skip(by: -skipInterval) }

    /// Instant, sample-accurate seek that keeps playing. A new seek replaces one still in flight.
    func seek(to seconds: Double) {
        var t = max(0, seconds)
        if duration > 0 { t = min(t, max(0, duration - 0.25)) }
        position = t
        if reconnecting {
            resumeAt = t
        } else if pendingSeek != nil {
            pendingSeek = t
        } else if let item = active.currentItem {
            item.cancelPendingSeeks()
            seekGeneration += 1
            let generation = seekGeneration
            seeking = true
            active.seek(to: CMTime(seconds: t, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.seekGeneration == generation else { return }
                    self.seeking = false
                }
            }
        }
        updateNowPlaying()
        saveSoon()
    }

    /// While a finger is on the position slider, the clock doesn't fight it.
    func setScrubbing(_ on: Bool) {
        scrubbing = on
        if !on { save() }
    }

    func setSpeed(_ s: Float) {
        speed = s
        UserDefaults.standard.set(s, forKey: Self.speedKey)
        active.defaultRate = s
        if active.rate > 0 { active.rate = s }
        pending?.player.defaultRate = s
        updateNowPlaying()
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.repeatKey)
        updateActionAtEnd()
        refreshPreload()
    }

    func setShuffle(_ on: Bool) {
        guard on != shuffled else { return }
        shuffled = on
        guard let cur = current else { return }
        if on {
            originalQueue = queue
            queue = QueueBuilder.shuffled(queue, current: index)
            index = 0
        } else if let original = originalQueue {
            queue = original
            index = original.firstIndex(where: { $0.id == cur.id }) ?? 0
            originalQueue = nil
        }
        refreshPreload()
        save()
    }

    /// nil turns the timer off.
    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        sleepEnd = nil
        sleepAtTrackEnd = false
        if let minutes {
            let end = Date().addingTimeInterval(Double(minutes) * 60)
            sleepEnd = end
            sleepTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
                guard !Task.isCancelled, let self else { return }
                self.sleepEnd = nil
                self.pause()
            }
        }
        updateActionAtEnd()
        refreshPreload()
    }

    func setSleepAtEndOfTrack() {
        setSleepTimer(minutes: nil)
        sleepAtTrackEnd = true
        updateActionAtEnd()
        refreshPreload()
    }

    /// Called by AppModel when the laptop answers again.
    func connectionRestored() {
        guard reconnecting else { return }
        reconnecting = false
        recovering = false
        Announce.say("Reconnected.")
        loadActive(index, at: resumeAt, autoplay: wantsPlay)
    }

    // MARK: - Active player

    private func configure(_ p: AVQueuePlayer) {
        p.actionAtItemEnd = (repeatMode == .one || sleepAtTrackEnd) ? .pause : .advance
        p.defaultRate = speed
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = 1
    }

    private func attach(_ p: AVQueuePlayer) {
        playerObservations = [
            p.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged() }
            },
            p.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.currentItemChanged() }
            },
        ]
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        timeObserverOwner = p
    }

    private func detach() {
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
        if let timeObserver, let owner = timeObserverOwner { owner.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeObserverOwner = nil
    }

    private func updateActionAtEnd() {
        active.actionAtItemEnd = (repeatMode == .one || sleepAtTrackEnd) ? .pause : .advance
    }

    private func clearActiveItems() {
        active.removeAllItems()
        itemIndex.removeAll()
        itemObservations.removeAll()
        readyItems.removeAll()
    }

    private func loadActive(_ i: Int, at start: Double, autoplay: Bool) {
        guard queue.indices.contains(i) else { return }
        recovering = false
        reconnecting = false
        index = i
        resetTrackState()
        position = max(0, start)
        clearActiveItems()
        guard let item = makeItem(queue[i]) else {
            badTrack(i, autoplay: autoplay)
            return
        }
        watchActive(item, index: i)
        active.insert(item, after: nil)
        preloadNext()
        wantsPlay = autoplay
        pendingSeek = start > 0.5 ? start : nil
        if autoplay {
            activateSession()
            if pendingSeek == nil { active.play() }
        } else {
            active.pause()
        }
        updateNowPlaying()
        loadTags(item.asset, trackID: queue[i].id)
        save()
    }

    private func resetTrackState() {
        position = 0
        duration = 0
        tagTitle = nil
        tagArtist = nil
        pendingSeek = nil
        seeking = false
    }

    private func makeItem(_ track: Track) -> AVPlayerItem? {
        guard let client else { return nil }
        let decode = formats.needsDecoding(track.name)
        guard let url = decode ? client.audioURL(track.path) : client.fileURL(track.path) else { return nil }
        var options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": client.headers]
        // The URL has no extension (/api/file?path=...), so say what the file is.
        // /api/audio is always WAV: the laptop decodes anything else (and the sound of videos) to it.
        if decode {
            options[AVURLAssetOverrideMIMETypeKey] = "audio/wav"
        } else if let mime = UTType(filenameExtension: FileKind.ext(track.name))?.preferredMIMEType {
            options[AVURLAssetOverrideMIMETypeKey] = mime
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.audioMix = nil
        return item
    }

    private func watchActive(_ item: AVPlayerItem, index i: Int) {
        let id = ObjectIdentifier(item)
        itemIndex[id] = i
        itemObservations[id] = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.activeItemStatus(id, status) }
        }
    }

    /// Keeps exactly one track queued behind the current one.
    private func preloadNext() {
        guard repeatMode != .one, !sleepAtTrackEnd else { return }
        let items = active.items()
        guard items.count == 1, let cur = itemIndex[ObjectIdentifier(items[0])],
              let n = QueueBuilder.next(after: cur, count: queue.count, repeatMode: repeatMode),
              let item = makeItem(queue[n]) else { return }
        watchActive(item, index: n)
        active.insert(item, after: items[0])
    }

    /// Drops the queued-up next track and lines up the right one (after repeat, shuffle or the sleep timer change).
    private func refreshPreload() {
        let items = active.items()
        guard let first = items.first else { return }
        for item in items.dropFirst() {
            active.remove(item)
            let id = ObjectIdentifier(item)
            itemIndex[id] = nil
            itemObservations[id] = nil
        }
        itemIndex[ObjectIdentifier(first)] = index
        preloadNext()
    }

    private func activeItemStatus(_ id: ObjectIdentifier, _ status: AVPlayerItem.Status) {
        guard itemIndex[id] != nil else { return }
        let isCurrent = active.currentItem.map { ObjectIdentifier($0) } == id
        switch status {
        case .readyToPlay:
            readyItems.insert(id)
            guard isCurrent else { return }
            badInARow = 0
            if let target = pendingSeek {
                pendingSeek = nil
                active.seek(to: CMTime(seconds: target, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.wantsPlay else { return }
                        self.active.play()
                    }
                }
            }
        case .failed:
            if isCurrent, let item = active.currentItem {
                currentFailed(item)
            } else if let item = active.items().first(where: { ObjectIdentifier($0) == id }) {
                // The queued-up next track failed; it gets another go when its turn comes.
                active.remove(item)
                itemIndex[id] = nil
                itemObservations[id] = nil
            }
        default:
            break
        }
    }

    private func statusChanged() {
        let playing = active.timeControlStatus != .paused
        if playing { lastPlayingAt = Date() }
        guard playing != isPlaying else { return }
        isPlaying = playing
        updateNowPlaying()
    }

    private func currentItemChanged() {
        guard !recovering, !reconnecting else { return }
        guard let item = active.currentItem else {
            // Ran off the end. If a track should follow (its preload failed), load it; otherwise stop here.
            let wasPlaying = wantsPlay && Date().timeIntervalSince(lastPlayingAt) < 3
            if wasPlaying, let n = QueueBuilder.next(after: index, count: queue.count, repeatMode: repeatMode) {
                loadActive(n, at: 0, autoplay: true)
            } else if !queue.isEmpty && pendingSeek == nil {
                wantsPlay = false
                position = 0
                updateNowPlaying()
                save()
            }
            return
        }
        guard let i = itemIndex[ObjectIdentifier(item)], i != index else { return }
        index = i
        retries = 0
        resetTrackState()
        let live = Set(active.items().map { ObjectIdentifier($0) })
        for id in itemIndex.keys where !live.contains(id) {
            itemIndex[id] = nil
            itemObservations[id] = nil
            readyItems.remove(id)
        }
        preloadNext()
        updateNowPlaying()
        loadTags(item.asset, trackID: queue[i].id)
        save()
    }

    private func didPlayToEnd(_ item: AVPlayerItem) {
        guard item === active.currentItem else { return }
        if sleepAtTrackEnd {
            sleepAtTrackEnd = false
            updateActionAtEnd()
            wantsPlay = false
            if let n = QueueBuilder.next(after: index, count: queue.count, repeatMode: repeatMode == .one ? .off : repeatMode) {
                loadActive(n, at: 0, autoplay: false)
            } else {
                active.pause()
                seek(to: 0)
            }
        } else if repeatMode == .one {
            active.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            active.play()
        }
    }

    // MARK: - Failures and reconnecting

    private func currentFailed(_ item: AVPlayerItem) {
        let id = ObjectIdentifier(item)
        guard !recovering, !reconnecting, let i = itemIndex[id] else { return }
        let hadPlayed = readyItems.contains(id)
        let spot = position
        let resume = wantsPlay || Date().timeIntervalSince(lastPlayingAt) < 3
        recovering = true
        clearActiveItems()
        Task { [weak self] in
            let reachable = await self?.probe?() ?? true
            guard let self, self.recovering, self.index == i else { return }
            if reachable && hadPlayed && self.retries < 2 {
                // It was playing fine, so this was a hiccup: pick up where it stopped.
                self.retries += 1
                self.loadActive(i, at: spot, autoplay: resume)
            } else if reachable {
                self.recovering = false
                self.badTrack(i, autoplay: resume)
            } else {
                self.resumeAt = spot
                self.wantsPlay = resume
                self.reconnecting = true
                self.updateNowPlaying()
                self.save()
                Announce.say("Lost the connection to the laptop. Playback will pick up when it's back.")
                self.onConnectionLost?()
            }
        }
    }

    /// The file itself won't play: say so and move on.
    private func badTrack(_ i: Int, autoplay: Bool) {
        Announce.say("Can't play \(queue[i].title).")
        badInARow += 1
        retries = 0
        let mode: RepeatMode = repeatMode == .one ? .off : repeatMode
        if badInARow < queue.count, let n = QueueBuilder.next(after: i, count: queue.count, repeatMode: mode), n != i {
            loadActive(n, at: 0, autoplay: autoplay)
        } else {
            clearActiveItems()
            index = i
            wantsPlay = false
            resetTrackState()
            updateNowPlaying()
            save()
        }
    }

    // MARK: - Pending track (keep playing until it's ready)

    private func beginPending(_ tracks: [Track], _ i: Int, at start: Double) {
        cancelPending()
        guard let item = makeItem(tracks[i]) else {
            Announce.say("Can't play \(tracks[i].title).")
            return
        }
        let p = AVQueuePlayer()
        configure(p)
        p.actionAtItemEnd = .pause
        p.insert(item, after: nil)
        let pend = Pending(tracks: tracks, index: i, start: start, player: p, item: item)
        let pid = pend.id
        pend.observations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.pendingChanged(pid) }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.pendingChanged(pid) }
            },
            p.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.pendingChanged(pid) }
            },
        ]
        pending = pend
        loadingTitle = tracks[i].title
    }

    private func cancelPending() {
        guard let pend = pending else { return }
        pend.observations.forEach { $0.invalidate() }
        pend.player.pause()
        pend.player.removeAllItems()
        pending = nil
        loadingTitle = nil
    }

    private func pendingChanged(_ pid: UUID) {
        guard let pend = pending, pend.id == pid, !pend.committing else { return }
        switch pend.item.status {
        case .failed:
            let name = pend.tracks[pend.index].title
            cancelPending()
            Announce.say("Can't play \(name).")
            return
        case .readyToPlay:
            break
        default:
            return
        }
        if !pend.positioned {
            pend.positioned = true
            pend.committing = true
            pend.player.seek(to: CMTime(seconds: pend.start, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    pend.committing = false
                    self?.pendingChanged(pid)
                }
            }
            return
        }
        if pend.player.status == .readyToPlay && pend.player.rate == 0 && !pend.item.isPlaybackLikelyToKeepUp {
            pend.committing = true
            pend.player.preroll(atRate: speed) { [weak self] finished in
                Task { @MainActor in
                    pend.committing = false
                    guard let self, self.pending?.id == pid else { return }
                    if finished || pend.item.isPlaybackLikelyToKeepUp { self.commitPending() }
                }
            }
            return
        }
        if pend.item.isPlaybackLikelyToKeepUp { commitPending() }
    }

    /// The new track has audio ready: hand over in one step.
    private func commitPending() {
        guard let pend = pending else { return }
        pend.observations.forEach { $0.invalidate() }
        pending = nil
        loadingTitle = nil

        let old = active
        detach()
        itemIndex.removeAll()
        itemObservations.removeAll()
        readyItems.removeAll()

        active = pend.player
        configure(active)
        attach(active)
        queue = pend.tracks
        index = pend.index
        recovering = false
        resetTrackState()
        position = pend.start
        watchActive(pend.item, index: pend.index)
        readyItems.insert(ObjectIdentifier(pend.item))
        wantsPlay = true
        activateSession()
        active.play()
        old.pause()
        old.removeAllItems()
        preloadNext()
        statusChanged()
        updateNowPlaying()
        loadTags(pend.item.asset, trackID: queue[index].id)
        save()
    }

    // MARK: - Clock and saving

    private func tick(_ seconds: Double) {
        if !scrubbing && !seeking && pendingSeek == nil && seconds.isFinite && active.currentItem != nil {
            position = max(0, seconds)
        }
        if let d = active.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        if isPlaying && Date().timeIntervalSince(lastSave) > 5 { save() }
    }

    private func saveSoon() {
        if Date().timeIntervalSince(lastSave) > 1 { save() }
    }

    func save() {
        guard persistEnabled else { return }
        lastSave = Date()
        guard !queue.isEmpty else {
            Self.clearSaved()
            return
        }
        let state = SavedState(tracks: queue, index: index, position: reconnecting ? resumeAt : position, playing: wantsPlay)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
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

    private func observeNotifications() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let opts = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let resume = AVAudioSession.InterruptionOptions(rawValue: opts).contains(.shouldResume)
            Task { @MainActor in
                guard let self else { return }
                if type == .began {
                    if self.wantsPlay { self.wantsPlay = false; self.save() }
                } else if resume {
                    self.play()
                }
            }
        })
        tokens.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            // Headphones came out: iOS pauses, so the button should say Play.
            Task { @MainActor in self?.pause() }
        })
        tokens.append(nc.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated { self?.didPlayToEnd(item) }
        })
        tokens.append(nc.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            guard let item = note.object as? AVPlayerItem else { return }
            MainActor.assumeIsolated {
                guard let self, item === self.active.currentItem else { return }
                self.currentFailed(item)
            }
        })
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(speed) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(speed),
            MPNowPlayingInfoPropertyPlaybackQueueIndex: index,
            MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !subtitle.isEmpty { info[MPMediaItemPropertyArtist] = subtitle }
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateSkipIntervals() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipInterval)]
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
        updateSkipIntervals()
        c.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        c.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
    }
}

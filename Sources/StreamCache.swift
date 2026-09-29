import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The playback cache on disk: each file is a folder of fixed-size blocks, each block filled from its start.
/// Blocks are small enough (1 MB) that the cache can be trimmed around a 10-hour WAV that's bigger than the cap.
/// Not thread-safe: StreamCache uses it from one serial queue (and the unit tests from one thread).
final class BlockStore {
    struct Meta: Codable, Equatable {
        var total: Int64?
        var contentType: String?
        var lastAccess: Date
    }

    let folder: URL
    let blockSize: Int64
    private(set) var totalBytes: Int64 = 0
    /// Bytes held per key, for every key on disk.
    private var sizes: [String: Int64] = [:]
    private var metas: [String: Meta] = [:]
    /// Cached length of each block, loaded when a key is first used.
    private var blockLengths: [String: [Int64: Int64]] = [:]
    private var writer: (key: String, block: Int64, handle: FileHandle)?
    private var lastMetaSave: [String: Date] = [:]

    init(folder: URL, blockSize: Int64 = 1 << 20) {
        self.folder = folder
        self.blockSize = blockSize
        scan()
    }

    private func dir(_ key: String) -> URL { folder.appendingPathComponent(key, isDirectory: true) }
    private func blockURL(_ key: String, _ i: Int64) -> URL { dir(key).appendingPathComponent("\(i).blk") }
    private func metaURL(_ key: String) -> URL { dir(key).appendingPathComponent("meta.json") }

    /// Works out what's on disk (at launch).
    private func scan() {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        totalBytes = 0
        sizes = [:]
        for d in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            let key = d.lastPathComponent
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
                try? fm.removeItem(at: d)
                continue
            }
            metas[key] = meta
            var bytes: Int64 = 0
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey])) ?? [] where f.pathExtension == "blk" {
                bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            sizes[key] = bytes
            totalBytes += bytes
        }
    }

    var keys: [String] { Array(sizes.keys) }

    func bytes(_ key: String) -> Int64 { sizes[key] ?? 0 }

    func meta(_ key: String) -> Meta? { metas[key] }

    /// Creates the key's folder if needed and records what's known about the file.
    func setMeta(_ key: String, total: Int64?, contentType: String?) {
        var m = metas[key] ?? Meta(total: nil, contentType: nil, lastAccess: Date())
        if let total { m.total = total }
        if let contentType { m.contentType = contentType }
        m.lastAccess = Date()
        metas[key] = m
        if sizes[key] == nil { sizes[key] = 0 }
        saveMeta(key)
    }

    func touch(_ key: String) {
        guard var m = metas[key] else { return }
        m.lastAccess = Date()
        metas[key] = m
        if Date().timeIntervalSince(lastMetaSave[key] ?? .distantPast) > 60 { saveMeta(key) }
    }

    private func saveMeta(_ key: String) {
        guard let m = metas[key], let data = try? JSONEncoder().encode(m) else { return }
        try? FileManager.default.createDirectory(at: dir(key), withIntermediateDirectories: true)
        try? data.write(to: metaURL(key), options: .atomic)
        lastMetaSave[key] = Date()
    }

    func lengths(_ key: String) -> [Int64: Int64] {
        if let l = blockLengths[key] { return l }
        var l: [Int64: Int64] = [:]
        for f in (try? FileManager.default.contentsOfDirectory(at: dir(key), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        where f.pathExtension == "blk" {
            guard let i = Int64(f.deletingPathExtension().lastPathComponent) else { continue }
            let n = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if n > 0 { l[i] = n }
        }
        blockLengths[key] = l
        return l
    }

    /// How long block `i` is when it's complete.
    func fullLength(_ i: Int64, total: Int64?) -> Int64 {
        guard let total else { return blockSize }
        return max(0, min(blockSize, total - i * blockSize))
    }

    /// Bytes held without a gap from `offset`, up to `limit`.
    func contiguous(_ key: String, from offset: Int64, limit: Int64) -> Int64 {
        let l = lengths(key)
        let total = metas[key]?.total
        var o = offset
        var got: Int64 = 0
        while got < limit {
            if let total, o >= total { break }
            let i = o / blockSize
            let len = l[i] ?? 0
            let end = i * blockSize + len
            guard end > o else { break }
            got += end - o
            o = end
            if len < fullLength(i, total: total) { break }
        }
        return min(got, limit)
    }

    func isCached(_ key: String, _ offset: Int64) -> Bool { contiguous(key, from: offset, limit: 1) > 0 }

    /// Everything from 0 to the end is held.
    func isComplete(_ key: String) -> Bool {
        guard let total = metas[key]?.total, total > 0 else { return false }
        return contiguous(key, from: 0, limit: total) >= total
    }

    /// Where a fetch for byte `need` has to start so every block stays filled from its start: `need` itself, or the
    /// end of what its block already holds (at most one block earlier). nil when `need` is held or past the end.
    func fetchStart(_ key: String, need: Int64) -> Int64? {
        if let total = metas[key]?.total, need >= total { return nil }
        let i = need / blockSize
        let blockEnd = i * blockSize + (lengths(key)[i] ?? 0)
        if need < blockEnd {
            let n = contiguous(key, from: need, limit: .max / 2)
            let start = need + n
            if let total = metas[key]?.total, start >= total { return nil }
            return fetchStart(key, need: start)
        }
        return blockEnd
    }

    /// Where a fetch starting at `start` stops: `maxLength` later, at the end of the file, or at the next block
    /// that already holds something.
    func fetchEnd(_ key: String, start: Int64, maxLength: Int64) -> Int64 {
        var end = start + maxLength
        if let total = metas[key]?.total { end = min(end, total) }
        let l = lengths(key)
        var i = start / blockSize + 1
        while i * blockSize < end {
            if (l[i] ?? 0) > 0 {
                end = i * blockSize
                break
            }
            i += 1
        }
        return end
    }

    /// Appends bytes that arrived for `offset`. Returns false if they don't follow on from what's held (the fetch is
    /// out of step and should start again).
    @discardableResult
    func write(_ key: String, at offset: Int64, _ data: Data) -> Bool {
        var l = lengths(key)
        var o = offset
        var index = data.startIndex
        defer { blockLengths[key] = l }
        while index < data.endIndex {
            let i = o / blockSize
            let len = l[i] ?? 0
            guard i * blockSize + len == o else { return false }
            let n = Int(min(blockSize - len, Int64(data.endIndex - index)))
            guard n > 0 else { return false }
            guard let handle = writeHandle(key, i) else { return false }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data[index..<(index + n)])
            } catch {
                closeWriter()
                return false
            }
            l[i] = len + Int64(n)
            sizes[key, default: 0] += Int64(n)
            totalBytes += Int64(n)
            o += Int64(n)
            index += n
        }
        return true
    }

    private func writeHandle(_ key: String, _ i: Int64) -> FileHandle? {
        if let w = writer, w.key == key, w.block == i { return w.handle }
        closeWriter()
        let url = blockURL(key, i)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: dir(key), withIntermediateDirectories: true)
            guard fm.createFile(atPath: url.path, contents: nil) else { return nil }
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        writer = (key, i, h)
        return h
    }

    func closeWriter() {
        try? writer?.handle.close()
        writer = nil
    }

    /// Up to `count` held bytes from `offset` (fewer at a gap).
    func read(_ key: String, at offset: Int64, count: Int64) -> Data? {
        let n = contiguous(key, from: offset, limit: count)
        guard n > 0 else { return nil }
        var out = Data(capacity: Int(n))
        var o = offset
        while Int64(out.count) < n {
            let i = o / blockSize
            let inBlock = o - i * blockSize
            let want = min(n - Int64(out.count), blockSize - inBlock)
            guard let h = try? FileHandle(forReadingFrom: blockURL(key, i)) else { return out.isEmpty ? nil : out }
            defer { try? h.close() }
            do {
                try h.seek(toOffset: UInt64(inBlock))
                guard let d = try h.read(upToCount: Int(want)), !d.isEmpty else { return out.isEmpty ? nil : out }
                out.append(d)
                o += Int64(d.count)
            } catch {
                return out.isEmpty ? nil : out
            }
        }
        return out
    }

    private func removeBlock(_ key: String, _ i: Int64) {
        var l = lengths(key)
        guard let n = l[i] else { return }
        if let w = writer, w.key == key, w.block == i { closeWriter() }
        try? FileManager.default.removeItem(at: blockURL(key, i))
        l[i] = nil
        blockLengths[key] = l
        sizes[key, default: 0] -= n
        totalBytes -= n
    }

    /// Forgets one file entirely.
    func remove(_ key: String) {
        if writer?.key == key { closeWriter() }
        try? FileManager.default.removeItem(at: dir(key))
        totalBytes -= sizes[key] ?? 0
        sizes[key] = nil
        metas[key] = nil
        blockLengths[key] = nil
    }

    /// Drops the blocks but keeps what's known about the file (it's still playing).
    func emptyBlocks(_ key: String) {
        for i in lengths(key).keys { removeBlock(key, i) }
    }

    func clear() {
        closeWriter()
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        totalBytes = 0
        sizes = [:]
        let kept = metas
        metas = [:]
        blockLengths = [:]
        // Files that are open keep their size and type, so playback carries on seamlessly.
        for (key, m) in kept where openKeys.contains(key) {
            setMeta(key, total: m.total, contentType: m.contentType)
        }
    }

    /// Keys the caller is using right now; clear() keeps their metadata.
    var openKeys: Set<String> = []

    /// Brings the cache under `capacity`: least recently used files that aren't in use go first, then, for files in
    /// use, blocks far behind where they're being read (keeping `keepBehind`), then blocks far ahead of it.
    func evict(capacity: Int64, inUse: [String: Int64], keepBehind: Int64, keepAhead: Int64) {
        guard capacity > 0, totalBytes > capacity else { return }
        let idle = sizes.keys.filter { inUse[$0] == nil }.sorted {
            (metas[$0]?.lastAccess ?? .distantPast) < (metas[$1]?.lastAccess ?? .distantPast)
        }
        for key in idle where totalBytes > capacity {
            remove(key)
        }
        guard totalBytes > capacity else { return }
        for (key, head) in inUse where totalBytes > capacity {
            let headBlock = head / blockSize
            let behind = lengths(key).keys.filter { ($0 + 1) * blockSize <= head - keepBehind }.sorted()
            for i in behind where totalBytes > capacity { removeBlock(key, i) }
            let ahead = lengths(key).keys.filter { $0 * blockSize >= head + keepAhead && $0 > headBlock }.sorted(by: >)
            for i in ahead where totalBytes > capacity { removeBlock(key, i) }
        }
    }
}

/// Plays files from the laptop through a disk cache, so the radio works in bursts and then sleeps.
///
/// AVPlayer asks for bytes through an AVAssetResourceLoaderDelegate. Bytes on disk are handed over at once (seeking
/// inside them is instant); missing bytes are fetched first, at full speed, in large Range requests. The playing file
/// is read ahead in bursts: when less than `lowWater` is held past where the player is reading, one fetch runs at full
/// speed until `highWater` is held, and then nothing touches the network until it drops low again. The next track
/// gets a smaller head start once the playing one is topped up.
///
/// Everything runs on one serial queue, never the main thread.
final class StreamCache: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = StreamCache(folder: StreamCache.defaultFolder)
    static let scheme = "encache"
    static let limitKey = "cacheLimit"
    static let defaultLimit: Int64 = 2 * 1024 * 1024 * 1024

    static var defaultFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Playback", isDirectory: true)
    }

    let queue = DispatchQueue(label: "stream-cache", qos: .userInitiated)
    private let store: BlockStore
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        c.httpMaximumConnectionsPerHost = 4
        let q = OperationQueue()
        q.underlyingQueue = queue
        q.maxConcurrentOperationCount = 1
        return URLSession(configuration: c, delegate: self, delegateQueue: q)
    }()

    // Burst sizes.
    var lowWater: Int64 = 24 * 1024 * 1024
    var highWater: Int64 = 256 * 1024 * 1024
    var nextTrackWater: Int64 = 24 * 1024 * 1024
    var maxFetch: Int64 = 32 * 1024 * 1024

    private final class Source {
        let key: String
        let remote: URL
        let headers: [String: String]
        let contentType: String
        var requests: [AVAssetResourceLoadingRequest] = []
        /// Where the player last asked to read.
        var head: Int64 = 0
        var burst = false
        var fetch: Fetch?
        /// The last time the laptop couldn't give bytes; reading ahead waits a while after that.
        var lastFailure: Date?

        init(key: String, remote: URL, headers: [String: String], contentType: String) {
            self.key = key
            self.remote = remote
            self.headers = headers
            self.contentType = contentType
        }
    }

    private final class Fetch {
        let task: URLSessionDataTask
        let start: Int64
        let end: Int64
        /// Next byte to arrive.
        var position: Int64
        /// Bytes to drop before `start` (a server that ignored Range).
        var skip: Int64 = 0
        var responded = false

        init(task: URLSessionDataTask, start: Int64, end: Int64) {
            self.task = task
            self.start = start
            self.end = end
            position = start
        }
    }

    private var sources: [String: Source] = [:]
    private var fetches: [Int: String] = [:]
    /// Keys of the playing file first, then the next one.
    private var priority: [String] = []
    private let capacityLock = NSLock()
    private var capacityValue: Int64

    init(folder: URL, blockSize: Int64 = 1 << 20) {
        store = BlockStore(folder: folder, blockSize: blockSize)
        let saved = UserDefaults.standard.object(forKey: Self.limitKey) as? NSNumber
        capacityValue = saved?.int64Value ?? Self.defaultLimit
        super.init()
    }

    private var _capacity: Int64 {
        capacityLock.lock()
        defer { capacityLock.unlock() }
        return capacityValue
    }

    // MARK: - Public (any thread)

    /// 0 turns the cache off: files stream straight from the laptop as before.
    var capacity: Int64 {
        get { _capacity }
        set {
            capacityLock.lock()
            capacityValue = newValue
            capacityLock.unlock()
            queue.async { self.evict() }
        }
    }

    var enabled: Bool { capacity > 0 }

    /// The key a laptop URL is cached under (no pairing code in it; that travels in a header).
    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.lowercased().utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// An asset that reads `remote` through the cache.
    func asset(for remote: URL, headers: [String: String], contentType: String) -> AVURLAsset {
        let key = Self.key(for: remote)
        queue.async {
            if self.sources[key] == nil {
                self.sources[key] = Source(key: key, remote: remote, headers: headers, contentType: contentType)
            }
            self.store.setMeta(key, total: nil, contentType: contentType)
        }
        let asset = AVURLAsset(url: URL(string: "\(Self.scheme)://cache/\(key)")!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    /// Which files to keep topped up: the playing one, then the next.
    func setPriority(_ remotes: [URL]) {
        let keys = remotes.map(Self.key(for:))
        queue.async {
            guard keys != self.priority else { return }
            self.priority = keys
            self.store.openKeys = Set(keys).union(self.sources.keys)
            for s in self.sources.values { self.service(s) }
        }
    }

    func clear() {
        queue.async {
            for s in self.sources.values { self.cancelFetch(s) }
            self.store.openKeys = Set(self.sources.keys)
            self.store.clear()
            for s in self.sources.values {
                s.burst = false
                self.service(s)
            }
        }
    }

    func usedBytes() async -> Int64 {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.store.totalBytes) } }
    }

    /// (bytes held, file length if known) for tests and the settings screen.
    func cached(_ remote: URL) async -> (Int64, Int64?) {
        let key = Self.key(for: remote)
        return await withCheckedContinuation { c in
            queue.async { c.resume(returning: (self.store.bytes(key), self.store.meta(key)?.total)) }
        }
    }

    /// The held bytes of a file from the start, for tests.
    func cachedData(_ remote: URL) async -> Data? {
        let key = Self.key(for: remote)
        return await withCheckedContinuation { c in
            queue.async {
                guard let total = self.store.meta(key)?.total else { return c.resume(returning: nil) }
                c.resume(returning: self.store.read(key, at: 0, count: total))
            }
        }
    }

    /// Whether a fetch is running for this file (tests use it to see the radio go quiet).
    func isFetching(_ remote: URL) async -> Bool {
        let key = Self.key(for: remote)
        return await withCheckedContinuation { c in queue.async { c.resume(returning: self.sources[key]?.fetch != nil) } }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme,
              let s = sources[url.lastPathComponent] else { return false }
        s.requests.append(loadingRequest)
        if let d = loadingRequest.dataRequest { s.head = d.requestedOffset }
        store.touch(s.key)
        service(s)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        for s in sources.values where s.requests.contains(where: { $0 === loadingRequest }) {
            s.requests.removeAll { $0 === loadingRequest }
            service(s)
        }
    }

    // MARK: - Serving and deciding what to fetch

    private func isPriority(_ s: Source) -> Bool { priority.contains(s.key) }

    private func service(_ s: Source) {
        serve(s)
        schedule(s)
    }

    /// Hands every waiting request what's on disk.
    private func serve(_ s: Source) {
        let total = store.meta(s.key)?.total
        var more = false
        for r in s.requests {
            if r.isCancelled || r.isFinished {
                continue
            }
            guard let total else { continue }
            if let info = r.contentInformationRequest {
                info.contentType = s.contentType
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            guard let d = r.dataRequest else {
                r.finishLoading()
                continue
            }
            let end = d.requestsAllDataToEndOfResource ? total : min(total, d.requestedOffset + Int64(d.requestedLength))
            var served: Int64 = 0
            while d.currentOffset < end && served < 8 * 1024 * 1024 && !r.isCancelled {
                let want = min(end - d.currentOffset, 1024 * 1024)
                guard let data = store.read(s.key, at: d.currentOffset, count: want) else { break }
                d.respond(with: data)
                served += Int64(data.count)
            }
            if d.currentOffset >= end {
                r.finishLoading()
            } else if served >= 8 * 1024 * 1024 {
                more = true
            }
        }
        s.requests.removeAll { $0.isFinished || $0.isCancelled }
        if more { queue.async { [weak self] in self?.serve(s) } }
    }

    /// The byte each waiting request needs next.
    private func needs(_ s: Source) -> [Int64] {
        let total = store.meta(s.key)?.total
        return s.requests.compactMap { r in
            guard let d = r.dataRequest else { return total == nil ? 0 : nil }
            if let total, d.currentOffset >= total { return nil }
            return d.currentOffset
        }
    }

    private func schedule(_ s: Source) {
        let total = store.meta(s.key)?.total
        // 1. A request is waiting on bytes that aren't here: fetch them first (a seek outside what's held).
        let waiting = needs(s).filter { total == nil || !store.isCached(s.key, $0) }
        if let need = waiting.min() {
            s.head = need
            if let f = s.fetch, f.position <= need, need < f.position + 2 * 1024 * 1024, need < f.end { return }
            cancelFetch(s)
            guard let start = store.fetchStart(s.key, need: need) else { return }
            startFetch(s, from: start, maxLength: maxFetch)
            return
        }
        guard s.fetch == nil else {
            // Nobody wants this file any more: stop spending the radio on it.
            if !isPriority(s) && s.requests.isEmpty { cancelFetch(s) }
            return
        }
        // 2. Read ahead in bursts, for the playing file and then the next one.
        guard let rank = priority.firstIndex(of: s.key), _capacity > 0 else { return }
        if let failed = s.lastFailure, Date().timeIntervalSince(failed) < 30 { return }
        if rank > 0 {
            // The next track waits until the playing one is topped up.
            if let first = sources[priority[0]], first.fetch != nil || first.burst { return }
        }
        let high = min(rank == 0 ? highWater : nextTrackWater, max(_capacity / 3, 4 * 1024 * 1024))
        guard let total else {
            // Nothing known about it yet (the next track, before AVPlayer has looked at it): its first bytes tell us.
            s.burst = true
            startFetch(s, from: store.fetchStart(s.key, need: 0) ?? 0, maxLength: min(maxFetch, high))
            return
        }
        let head = rank == 0 ? s.head : 0
        let ahead = store.contiguous(s.key, from: head, limit: high)
        if ahead >= high || head + ahead >= total {
            if s.burst {
                s.burst = false
                for other in sources.values where other !== s { schedule(other) }
            }
            return
        }
        if !s.burst && ahead >= min(lowWater, high / 2) { return }
        s.burst = true
        guard let start = store.fetchStart(s.key, need: head + ahead) else { return }
        startFetch(s, from: start, maxLength: min(maxFetch, high - ahead + store.blockSize))
    }

    private func startFetch(_ s: Source, from start: Int64, maxLength: Int64) {
        let end = store.fetchEnd(s.key, start: start, maxLength: maxLength)
        guard end > start else { return }
        var request = URLRequest(url: s.remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        for (k, v) in s.headers { request.setValue(v, forHTTPHeaderField: k) }
        request.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        s.fetch = Fetch(task: task, start: start, end: end)
        fetches[task.taskIdentifier] = s.key
        task.resume()
    }

    private func cancelFetch(_ s: Source) {
        guard let f = s.fetch else { return }
        s.fetch = nil
        fetches[f.task.taskIdentifier] = nil
        f.task.cancel()
        store.closeWriter()
    }

    private func source(for task: URLSessionTask) -> Source? {
        guard let key = fetches[task.taskIdentifier], let s = sources[key], s.fetch?.task === task else { return nil }
        return s
    }

    /// The laptop couldn't give the bytes: requests waiting on them fail, so the player's own recovery takes over.
    private func fail(_ s: Source, _ error: Error) {
        let total = store.meta(s.key)?.total
        for r in s.requests where !r.isFinished && !r.isCancelled {
            let waitingOnNetwork: Bool
            if let d = r.dataRequest {
                waitingOnNetwork = total == nil || !store.isCached(s.key, d.currentOffset)
            } else {
                waitingOnNetwork = total == nil
            }
            if waitingOnNetwork { r.finishLoading(with: error) }
        }
        s.requests.removeAll { $0.isFinished || $0.isCancelled }
        s.burst = false
        s.lastFailure = Date()
    }

    private func evict() {
        var inUse: [String: Int64] = [:]
        for s in sources.values where isPriority(s) || !s.requests.isEmpty { inUse[s.key] = s.head }
        store.evict(capacity: _capacity, inUse: inUse, keepBehind: 8 * 1024 * 1024, keepAhead: highWater)
        for key in sources.keys where store.meta(key) == nil && inUse[key] == nil {
            sources[key] = nil
        }
    }

    // MARK: - URLSessionDataDelegate (on the cache queue)

    /// Reads the status and length of a fetch's response (from its first bytes, or at its end if it had none).
    /// Returns false when the laptop said no; the requests waiting on it have been failed.
    private func handleResponse(_ s: Source, _ f: Fetch, _ response: URLResponse?) -> Bool {
        f.responded = true
        guard let http = response as? HTTPURLResponse else { return true }
        if let problem = ConnectError.from(status: http.statusCode) {
            cancelFetch(s)
            fail(s, NSError(domain: "ExplorerConnect", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: problem.errorDescription ?? ""]))
            return false
        }
        var total: Int64?
        if http.statusCode == 206, let range = http.value(forHTTPHeaderField: "Content-Range"),
           let slash = range.lastIndex(of: "/"), let t = Int64(range[range.index(after: slash)...]) {
            total = t
        } else if http.statusCode == 200 {
            if http.expectedContentLength > 0 { total = http.expectedContentLength }
            f.position = 0
            f.skip = f.start
        }
        if let total {
            if let known = store.meta(s.key)?.total, known != total {
                // The file changed on the laptop: what's held is stale.
                store.emptyBlocks(s.key)
            }
            store.setMeta(s.key, total: total, contentType: s.contentType)
        }
        s.lastFailure = nil
        serve(s)
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let s = source(for: dataTask), let f = s.fetch else { return }
        if !f.responded {
            guard handleResponse(s, f, dataTask.response) else { return }
            guard s.fetch === f else { return }
        }
        var chunk = data
        if f.skip > 0 {
            let drop = Int(min(f.skip, Int64(chunk.count)))
            chunk = chunk.subdata(in: chunk.startIndex + drop..<chunk.endIndex)
            f.skip -= Int64(drop)
            f.position += Int64(drop)
            if chunk.isEmpty { return }
        }
        if !store.write(s.key, at: f.position, chunk) {
            // Out of step (a block was trimmed under it): start again from what's really held.
            cancelFetch(s)
            schedule(s)
            return
        }
        f.position += Int64(chunk.count)
        serve(s)
        if !s.requests.isEmpty {
            // A seek may have moved the reader somewhere this fetch won't reach soon.
            let waiting = needs(s).filter { !store.isCached(s.key, $0) }
            if let need = waiting.min(), !(f.position <= need && need < f.position + 2 * 1024 * 1024) { schedule(s) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let s = source(for: task), let f = s.fetch else { return }
        if error == nil && !f.responded {
            guard handleResponse(s, f, task.response) else { return }
        }
        fetches[task.taskIdentifier] = nil
        s.fetch = nil
        store.closeWriter()
        if let error, (error as? URLError)?.code != .cancelled {
            fail(s, error)
            return
        }
        finishedFetch(s)
    }

    private func finishedFetch(_ s: Source) {
        if store.totalBytes > _capacity { evict() }
        service(s)
        if s.fetch == nil {
            for other in sources.values where other !== s { schedule(other) }
        }
    }

    // MARK: - Content types

    /// The type AVFoundation needs for a file name: /api/audio is always WAV.
    static func contentType(name: String, decoded: Bool) -> String {
        if decoded { return UTType.wav.identifier }
        switch FileKind.ext(name) {
        case "m4a", "m4b", "alac": return "com.apple.m4a-audio"
        case "aac": return "public.aac-audio"
        case "mp3": return UTType.mp3.identifier
        case "wav": return UTType.wav.identifier
        case "aif", "aiff", "aifc": return UTType.aiff.identifier
        case "caf": return "com.apple.coreaudio-format"
        case "flac": return "org.xiph.flac"
        default:
            let t = UTType(filenameExtension: FileKind.ext(name))
            return t?.identifier ?? UTType.audio.identifier
        }
    }
}

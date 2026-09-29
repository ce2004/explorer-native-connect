# Battery

What Explorer Connect does so a 10-hour audiobook doesn't drain the phone.

## Nothing polls in the background

- **Clipboard.** The long poll on `/api/clipboard/wait` runs only while the Clipboard tab is showing and the app is in front. Switching tabs, locking the screen or leaving the app stops it at once. Before, it could restart while another tab was showing.
- **Reconnecting.** The retry loop that looks for the laptop, and the network-change check, stop when the app goes to the background. The one exception is playback that lost the laptop and wants to carry on. Everything else retries when the app comes back to the front (`AppActivity.waitUntilActive`).
- **Transfers and jobs.** The retry timer for a transfer waiting on the laptop, and the progress polling for Drive uploads and copies or moves on the laptop, wait for the app to come back. The work itself carries on (on the laptop, and through the background URLSession).
- **Progress.** Upload and download progress reaches the main thread at most four times a second, and every five seconds in the background. Spoken progress ("40 percent") is only announced while the app is in front.
- **Clock.** The player's time observer runs four times a second while the app is in front. In the background it's replaced by one that ticks every 15 seconds, which is just enough to save the spot. Now Playing works out the elapsed time itself from the rate.

## Streaming in bursts (`Sources/StreamCache.swift`)

Playback goes through an `AVAssetResourceLoaderDelegate` backed by a disk cache in `Caches/Playback`:

- AVPlayer's requests are answered from disk when the bytes are there, so seeking inside them is instant. When a seek lands outside them, that range is fetched first, and any fetch elsewhere is cancelled.
- The playing file is read ahead in bursts. When less than 24 MB is held past where the player is reading, one Range request runs at full speed until 256 MB is held (or the whole file). Then nothing touches the network until the buffer drops below 24 MB again. For a 128 kbps audiobook that's hours between bursts. For the 24-bit WAV from `/api/audio`, it's about 15 minutes.
- Once the playing file is topped up, the next track gets a 24 MB head start.
- The cache is 1 MB blocks per file, so it can be trimmed. When it's over the cap, the least recently used files go first. After that, for files in use, blocks well behind or well ahead of the reader go. That keeps a WAV bigger than the whole cap playable.
- The cap is 2 GB by default. Settings > Playback cache has Off, 500 MB, 1 GB, 2 GB, 5 GB and 10 GB, plus Clear cache. Off streams straight from the laptop as before.
- Keep playing until ready and `/api/audio` WAVs work unchanged: the loading track reads through the same cache. If the laptop fails, the requests waiting on the network fail, and the player's own reconnect takes over. A fully cached track keeps playing with the laptop gone.
- All cache work (disk reads and writes, answering AVPlayer, the URLSession callbacks) runs on one serial queue, never the main thread.

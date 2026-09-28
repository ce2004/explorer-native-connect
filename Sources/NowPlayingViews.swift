import SwiftUI

/// Sits under every browse screen while something is loaded.
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    var body: some View {
        let player = model.player
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title)
                            .lineLimit(1)
                        if !player.subtitle.isEmpty {
                            Text(player.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Now playing, \(player.title)")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .disabled(!player.hasNext)
                .accessibilityLabel("Next")
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let player = model.player
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.title)
                            .font(.title3.bold())
                        if !player.subtitle.isEmpty {
                            Text(player.subtitle)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    PositionView(player: player)

                    HStack {
                        Spacer()
                        Button {
                            player.previous()
                        } label: {
                            Image(systemName: "backward.fill").font(.title).frame(width: 60, height: 60)
                        }
                        .accessibilityLabel("Previous")
                        Spacer()
                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.largeTitle).frame(width: 60, height: 60)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Spacer()
                        Button {
                            player.next()
                        } label: {
                            Image(systemName: "forward.fill").font(.title).frame(width: 60, height: 60)
                        }
                        .disabled(!player.hasNext)
                        .accessibilityLabel("Next")
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                }

                Section {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { i, track in
                        Button {
                            player.jump(to: i)
                        } label: {
                            HStack {
                                Text(track.title)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if i == player.index {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel(track.title)
                        .accessibilityAddTraits(i == player.index ? .isSelected : [])
                    }
                } header: {
                    Text("Queue")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityAction(.magicTap) { player.togglePlayPause() }
    }
}

/// One adjustable element: swipe up or down to move 15 seconds.
struct PositionView: View {
    let player: Player

    var body: some View {
        VStack(spacing: 4) {
            ProgressView(value: player.duration > 0 ? min(player.position / player.duration, 1) : 0)
            HStack {
                Text(Format.time(player.position))
                Spacer()
                Text(player.duration > 0 ? Format.time(player.duration) : "")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: 15)
            case .decrement: player.skip(by: -15)
            @unknown default: break
            }
        }
    }

    private var valueText: String {
        let now = Format.spokenTime(player.position)
        return player.duration > 0 ? "\(now) of \(Format.spokenTime(player.duration))" : now
    }
}

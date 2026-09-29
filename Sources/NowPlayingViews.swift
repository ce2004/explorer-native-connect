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
                        if let status = statusLine(player) {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel(barLabel(player))

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.wantsPlay ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.wantsPlay ? "Pause" : "Play")

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

    private func statusLine(_ p: Player) -> String? {
        if p.reconnecting { return "Waiting for the laptop" }
        if let loading = p.loadingTitle { return "Loading \(loading)" }
        return p.subtitle.isEmpty ? nil : p.subtitle
    }

    private func barLabel(_ p: Player) -> String {
        var text = "Now playing, \(p.title)"
        if p.reconnecting { text += ", waiting for the laptop" }
        if let loading = p.loadingTitle { text += ", loading \(loading)" }
        return text
    }
}

/// Copies, moves and transfers in one line above the now-playing bar; opens the Transfers screen.
struct ActivityBar: View {
    @Environment(AppModel.self) private var model
    @State private var showTransfers = false

    var body: some View {
        let jobs = model.jobs.jobs
        let active = model.transfers.active
        // The sheet hangs off a view that's always there, so Transfers stays open when the last transfer stops.
        VStack(spacing: 0) {
            if !jobs.isEmpty || !active.isEmpty {
                Divider()
                Button {
                    showTransfers = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .accessibilityHidden(true)
                        Text(summary(jobs, active))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(.primary)
                .accessibilityLabel("Transfers, \(summary(jobs, active))")
                .accessibilityAction(named: "Stop all transfers") { model.stopAllTransfers() }
                .padding(.horizontal)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showTransfers) {
            TransfersView()
                .environment(model)
        }
    }

    private func summary(_ jobs: [JobCenter.Job], _ active: [TransferRecord]) -> String {
        if active.isEmpty, let job = jobs.first {
            return jobs.count == 1 ? job.spoken : "\(jobs.count) jobs on the laptop"
        }
        if active.count == 1, jobs.isEmpty, let r = active.first {
            return TransferText.describe(r, rate: model.transfers.rate(r.id))
        }
        let size = active.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let done = active.reduce(Int64(0)) { $0 + $1.done }
        var text = Format.count(active.count + jobs.count, "transfer", "transfers")
        if size > 0 { text += ", \(TransferMath.percent(done, size)) percent" }
        return text
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
                        if player.reconnecting {
                            Text("Waiting for the laptop")
                                .foregroundStyle(.secondary)
                        } else if let loading = player.loadingTitle {
                            Text("Loading \(loading)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)

                    PositionView(player: player, step: Double(model.settings.skipInterval))

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
                            Image(systemName: player.wantsPlay ? "pause.fill" : "play.fill").font(.largeTitle).frame(width: 60, height: 60)
                        }
                        .accessibilityLabel(player.wantsPlay ? "Pause" : "Play")
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
                    Picker("Speed", selection: Binding(get: { player.speed }, set: { player.setSpeed($0) })) {
                        ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { s in
                            Text(speedText(s)).tag(s)
                        }
                    }
                    Picker("Repeat", selection: Binding(get: { player.repeatMode }, set: { player.setRepeat($0) })) {
                        ForEach(RepeatMode.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Shuffle", isOn: Binding(get: { player.shuffled }, set: { player.setShuffle($0) }))
                    Menu {
                        Button("Off") { player.setSleepTimer(minutes: nil) }
                        ForEach([15, 30, 45, 60], id: \.self) { m in
                            Button("\(m) minutes") { player.setSleepTimer(minutes: m) }
                        }
                        Button("End of this track") { player.setSleepAtEndOfTrack() }
                    } label: {
                        LabeledContent("Sleep timer", value: sleepText(player))
                    }
                    .accessibilityLabel("Sleep timer")
                    .accessibilityValue(sleepText(player))
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

    private func speedText(_ s: Float) -> String {
        s == 1 ? "Normal" : String(format: "%g times", s)
    }

    private func sleepText(_ p: Player) -> String {
        if p.sleepAtTrackEnd { return "End of this track" }
        guard let end = p.sleepEnd else { return "Off" }
        let minutes = max(1, Int((end.timeIntervalSinceNow / 60).rounded(.up)))
        return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
    }
}

/// One adjustable element for VoiceOver (swipe up or down jumps by the skip interval, instantly, while playing),
/// and a slider to drag for everyone else, which scrubs audibly as it moves.
struct PositionView: View {
    let player: Player
    let step: Double
    @State private var dragValue: Double?

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { dragValue ?? player.position },
                    set: { value in
                        dragValue = value
                        player.seek(to: value)
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    player.setScrubbing(editing)
                    if !editing { dragValue = nil }
                }
            )
            .disabled(player.duration <= 0)
            HStack {
                Text(Format.time(dragValue ?? player.position))
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
            case .increment: player.skip(by: step)
            case .decrement: player.skip(by: -step)
            @unknown default: break
            }
        }
    }

    private var valueText: String {
        let now = Format.spokenTime(player.position)
        return player.duration > 0 ? "\(now) of \(Format.spokenTime(player.duration))" : now
    }
}

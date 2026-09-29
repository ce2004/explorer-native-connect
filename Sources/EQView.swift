import SwiftUI

/// The equalizer: on or off, ten bands, and Reset all. Reached from Settings and from Now Playing.
struct EQView: View {
    @Environment(AppModel.self) private var model
    @State private var typingBand: Int?
    @State private var typed = ""

    var body: some View {
        let eq = model.equalizer
        Form {
            Section {
                Toggle("Equalizer", isOn: Binding(get: { eq.enabled }, set: { eq.setEnabled($0) }))
            } footer: {
                Text("Boosting a band turns the overall level down by the same amount, so nothing clips.")
            }
            Section {
                ForEach(0..<EQEngine.bandCount, id: \.self) { band in
                    EQBandRow(band: band, typingBand: $typingBand, typed: $typed)
                }
                Button("Reset all") {
                    eq.resetAll()
                    Announce.say("All bands at 0 decibels.")
                }
            } header: {
                Text("Bands").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Swipe up or down on a band to change it by 1 decibel.")
            }
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .alert(typingBand.map { Equalizer.bandName($0) } ?? "",
               isPresented: Binding(get: { typingBand != nil }, set: { if !$0 { typingBand = nil } })) {
            TextField("Decibels", text: $typed)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("decibels")
            Button("Set") { applyTyped() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From minus 12 to plus 12 decibels.")
        }
    }

    private func applyTyped() {
        guard let band = typingBand else { return }
        let text = typed.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "\u{2212}", with: "-")
        guard let value = Int(text) else {
            Announce.say("That isn't a number.")
            return
        }
        model.equalizer.setGain(band, value)
        Announce.say("\(Equalizer.bandName(band)), \(Equalizer.gainText(model.equalizer.gains[band])).")
    }
}

/// One band: a slider to drag, and for VoiceOver one adjustable element ("125 hertz, plus 3 decibels") that moves
/// 1 dB per swipe, with Reset band and Type a value as actions.
private struct EQBandRow: View {
    let band: Int
    @Binding var typingBand: Int?
    @Binding var typed: String
    @Environment(AppModel.self) private var model

    var body: some View {
        let eq = model.equalizer
        let gain = eq.gains[band]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Equalizer.bandShortName(band))
                Spacer()
                Text(Equalizer.gainShortText(gain))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { Double(gain) }, set: { eq.setGain(band, Int($0.rounded())) }),
                   in: Double(Equalizer.range.lowerBound)...Double(Equalizer.range.upperBound), step: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Equalizer.bandName(band))
        .accessibilityValue(Equalizer.gainText(gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: eq.adjust(band, by: 1)
            case .decrement: eq.adjust(band, by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Reset band") { eq.setGain(band, 0) }
        .accessibilityAction(named: "Type a value") { startTyping() }
        .contextMenu {
            Button { eq.setGain(band, 0) } label: { Label("Reset band", systemImage: "arrow.counterclockwise") }
            Button { startTyping() } label: { Label("Type a value", systemImage: "keyboard") }
        }
    }

    private func startTyping() {
        typed = String(model.equalizer.gains[band])
        typingBand = band
    }
}

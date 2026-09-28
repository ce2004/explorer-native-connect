import SwiftUI

struct SettingsView: View {
    var firstRun = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var code = ""
    @State private var status: String?
    @State private var connecting = false

    var body: some View {
        Form {
            Section {
                TextField("Computer", text: $host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("computer")
                TextField("Pairing code", text: $code)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("code")
                Button(connecting ? "Connecting" : "Connect") {
                    Task { await connect() }
                }
                .disabled(connecting)
                if let status {
                    Text(status)
                }
            } footer: {
                if firstRun {
                    Text("Use the pairing code shown in Explorer Native on the laptop.")
                }
            }

            if !firstRun {
                Section {
                    Button(model.updater.checking ? "Checking for updates" : "Check for updates") {
                        Task {
                            await model.updater.check()
                            if let result = model.updater.lastResult { Announce.say(result) }
                        }
                    }
                    .disabled(model.updater.checking)
                    if let available = model.updater.available {
                        Button("Install version \(available.version)") {
                            Task { _ = await model.updater.install() }
                        }
                    }
                    if let result = model.updater.lastResult {
                        Text(result)
                    }
                } footer: {
                    Text("Version \(model.updater.currentVersion)")
                }
            }
        }
        .navigationTitle(firstRun ? "Explorer Connect" : "Settings")
        .toolbar {
            if !firstRun {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            host = model.host == ConnectClient.demoHost ? "" : model.host
            code = model.code
        }
    }

    private func connect() async {
        let client = ConnectClient(host: host, code: code)
        guard client.code.count == 8 else {
            report("The pairing code is 8 digits.")
            return
        }
        connecting = true
        status = nil
        defer { connecting = false }
        do {
            let info = try await client.info()
            host = client.host
            code = client.code
            model.connected(client, info: info)
            report(info.name.isEmpty ? "Connected." : "Connected to \(info.name).")
        } catch {
            report(ConnectError.message(for: error))
        }
    }

    private func report(_ text: String) {
        status = text
        Announce.say(text)
    }
}

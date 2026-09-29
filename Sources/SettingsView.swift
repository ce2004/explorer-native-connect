import SwiftUI

struct SettingsView: View {
    var firstRun = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var code = ""
    @State private var status: String?
    @State private var connecting = false
    @State private var cacheUsed: Int64?

    var body: some View {
        @Bindable var settings = model.settings
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
                Button(connecting ? "Connecting" : (firstRun ? "Connect" : "Test connection")) {
                    Task { await connect() }
                }
                .disabled(connecting)
                if let status {
                    Text(status)
                }
                if !firstRun && model.configured && model.apiVersion < 2 {
                    Text("Explorer Native on the laptop is an older version. Renaming, copying and the other file actions appear once it's updated.")
                }
            } header: {
                if !firstRun { Text("Connection").accessibilityAddTraits(.isHeader) }
            } footer: {
                if firstRun {
                    Text("Use the pairing code shown in Explorer Native on the laptop.")
                }
            }

            if !firstRun {
                Section {
                    Picker("Sort by", selection: $settings.sort) {
                        ForEach(SortOrder.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Folders first", isOn: $settings.foldersFirst)
                    Toggle("Show file extensions", isOn: $settings.showExtensions)
                    Toggle("Show folder sizes", isOn: $settings.showFolderSizes)
                } header: {
                    Text("Browsing").accessibilityAddTraits(.isHeader)
                }

                Section {
                    Toggle("Play the rest of the folder", isOn: $settings.playWholeFolder)
                    Picker("Skip", selection: $settings.skipInterval) {
                        ForEach(Settings.skipChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                    }
                    Toggle("Keep playing until the next track is ready", isOn: $settings.keepPlayingUntilReady)
                    Toggle("Continue playing when the app reopens", isOn: $settings.resumePlayback)
                } header: {
                    Text("Playback").accessibilityAddTraits(.isHeader)
                }

                Section {
                    Picker("Cache size", selection: $settings.cacheLimit) {
                        ForEach(Settings.cacheChoices, id: \.self) { Text(Settings.cacheTitle($0)).tag($0) }
                    }
                    if let cacheUsed {
                        Text("Using \(Format.size(cacheUsed))")
                    }
                    Button("Clear cache") {
                        StreamCache.shared.clear()
                        cacheUsed = 0
                        Announce.say("Cache cleared.")
                    }
                } header: {
                    Text("Playback cache").accessibilityAddTraits(.isHeader)
                } footer: {
                    Text("Playing files are saved ahead on the iPhone in bursts, so the phone's radio can rest and seeking is instant. The oldest files are removed when the cache is full.")
                }

                Section {
                    Picker("When a name is taken", selection: $settings.conflict) {
                        ForEach(Conflict.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Confirm before deleting", isOn: $settings.confirmDelete)
                    Toggle("Announce transfer progress", isOn: $settings.announceTransfers)
                } header: {
                    Text("Files").accessibilityAddTraits(.isHeader)
                }

                if model.apiVersion >= 3 {
                    Section {
                        Toggle("Announce PC clipboard changes", isOn: $settings.announceClipboard)
                    } header: {
                        Text("Clipboard").accessibilityAddTraits(.isHeader)
                    }
                }

                Section {
                    Button(model.updater.checking ? "Checking for updates" : "Check for updates") {
                        Task {
                            await model.updater.check()
                            if let result = model.updater.lastResult { Announce.say(result) }
                        }
                    }
                    .disabled(model.updater.checking)
                    if let result = model.updater.lastResult {
                        Text(result)
                    }
                    if let signed = model.updater.signedText {
                        Text(signed)
                    }
                } header: {
                    Text("Updates").accessibilityAddTraits(.isHeader)
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
            host = model.host
            code = model.code
        }
        .task {
            cacheUsed = await StreamCache.shared.usedBytes()
        }
        .onChange(of: settings.cacheLimit) {
            model.applySettings()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                cacheUsed = await StreamCache.shared.usedBytes()
            }
        }
        .onChange(of: settings.skipInterval) { model.applySettings() }
        .onChange(of: settings.keepPlayingUntilReady) { model.applySettings() }
        .onChange(of: settings.resumePlayback) { model.applySettings() }
        .onChange(of: settings.announceTransfers) { model.applySettings() }
        .onChange(of: settings.announceClipboard) { model.applySettings() }
        .onChange(of: settings.showFolderSizes) { if !settings.showFolderSizes { model.sizes.clear() } }
    }

    private func connect() async {
        let client = ConnectClient(host: host, code: code, port: model.client.port)
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
            var text = info.name.isEmpty ? "Connected." : "Connected to \(info.name)."
            if !firstRun {
                // About five round trips, timed; /api/info stands in on a server without /api/ping.
                if let ping = try? await client.measurePing(useInfo: info.apiVersion < 4) {
                    text = ping.report(name: info.name)
                }
            }
            if info.apiVersion < 2 {
                text += " Explorer Native on the laptop is an older version, so only browsing and playing work until it's updated."
            }
            report(text)
        } catch {
            report(ConnectError.message(for: error))
        }
    }

    private func report(_ text: String) {
        status = text
        Announce.say(text)
    }
}

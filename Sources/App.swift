import SwiftUI

@main
struct ExplorerConnectApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        AppModel.prepareLaunch()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.configured {
                if model.apiVersion >= 3 {
                    TabView {
                        BrowserView()
                            .tabItem { Label("Files", systemImage: "folder") }
                        ClipboardTab()
                            .tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }
                    }
                } else {
                    BrowserView()
                }
            } else {
                NavigationStack {
                    SettingsView(firstRun: true)
                }
            }
        }
        .accessibilityAction(.magicTap) { model.player.togglePlayPause() }
        .task {
            // Once per launch, after VoiceOver has settled on the first screen.
            guard let warning = model.updater.expiryWarning else { return }
            try? await Task.sleep(for: .seconds(2))
            Announce.say(warning)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.transfers.appCameToFront()
                model.appBecameActive()
            case .background:
                model.player.save()
                model.transfers.appWentToBackground()
            default: break
            }
        }
    }
}

struct FolderRoute: Hashable {
    let path: String
    let title: String
    /// "1.2 TB free of 5 TB" for a drive's root.
    var space: String?
}

struct BrowserView: View {
    var body: some View {
        NavigationStack {
            DrivesView()
                .navigationDestination(for: FolderRoute.self) { FolderView(route: $0) }
        }
        .modifier(PlayerBars())
    }
}

enum Load<Value> {
    case loading
    case loaded(Value)
    /// Saved from an earlier visit, shown read-only while the laptop can't be reached.
    case cached(Value, String)
    case failed(String)

    var value: Value? {
        switch self {
        case .loaded(let v), .cached(let v, _): return v
        default: return nil
        }
    }

    var isLive: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// A list that shows "Loading", an error with Try again, a saved copy with an offline note, or its rows.
struct StateList<Value, Rows: View>: View {
    let state: Load<Value>
    let retry: () async -> Void
    @ViewBuilder let rows: (Value) -> Rows

    var body: some View {
        List {
            switch state {
            case .loading:
                HStack(spacing: 12) {
                    ProgressView()
                        .accessibilityHidden(true)
                    Text("Loading")
                }
            case .failed(let message):
                Text(message)
                Button("Try again") { Task { await retry() } }
            case .cached(let value, let why):
                Section {
                    Text("Offline, showing saved list. \(why)")
                    Button("Try again") { Task { await retry() } }
                }
                Section {
                    rows(value)
                }
            case .loaded(let value):
                rows(value)
            }
        }
        .refreshable { await retry() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Downloads to the phone finished while the app was suspended: iOS relaunches us to hear about them.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadEngine.shared.backgroundCompletion = completionHandler
        _ = DownloadEngine.shared.session
    }
}

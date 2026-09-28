import SwiftUI

@main
struct ExplorerConnectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.configured {
                BrowserView()
            } else {
                NavigationStack {
                    SettingsView(firstRun: true)
                }
            }
        }
        .accessibilityAction(.magicTap) { model.player.togglePlayPause() }
    }
}

struct FolderRoute: Hashable {
    let path: String
    let title: String
}

struct BrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var showNowPlaying = false

    var body: some View {
        NavigationStack {
            DrivesView()
                .navigationDestination(for: FolderRoute.self) { FolderView(route: $0) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.player.current != nil {
                NowPlayingBar { showNowPlaying = true }
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
                .environment(model)
        }
    }
}

enum Load<Value> {
    case loading
    case loaded(Value)
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

/// A list that shows "Loading", an error with Try again, or its rows.
struct StateList<Value, Rows: View>: View {
    let state: Load<Value>
    let retry: () async -> Void
    @ViewBuilder let rows: (Value) -> Rows

    var body: some View {
        List {
            switch state {
            case .loading:
                Text("Loading")
            case .failed(let message):
                Text(message)
                Button("Try again") { Task { await retry() } }
            case .loaded(let value):
                rows(value)
            }
        }
        .refreshable { await retry() }
    }
}

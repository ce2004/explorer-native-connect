import QuickLook
import SwiftUI

struct OpenFile: Identifiable {
    let id = UUID()
    let path: String
    let name: String
    let size: Int64
}

/// Downloads a file, then shows it with Quick Look. Share saves it to Files or sends it elsewhere.
struct FileOpenView: View {
    let file: OpenFile
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var downloader = Downloader()

    private var doneURL: URL? {
        if case .done(let url) = downloader.phase { return url }
        return nil
    }

    var body: some View {
        NavigationStack {
            Group {
                switch downloader.phase {
                case .downloading:
                    VStack(spacing: 16) {
                        ProgressView(value: downloader.fraction)
                            .accessibilityHidden(true)
                        Text(downloader.progressText)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxHeight: .infinity)
                case .done(let url):
                    QuickLookView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                case .failed(let message):
                    Text(message)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxHeight: .infinity)
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(downloader.phase == .downloading ? "Cancel" : "Done") {
                        downloader.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if let url = doneURL {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .onAppear {
            downloader.start(path: file.path, name: file.name, size: file.size, client: model.client)
        }
        .onDisappear {
            downloader.cancel()
        }
        .accessibilityAction(.magicTap) { model.player.togglePlayPause() }
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            controller.reloadData()
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

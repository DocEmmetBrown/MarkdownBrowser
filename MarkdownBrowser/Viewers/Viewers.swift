import AVKit
import Quartz
import SwiftUI
import os

struct ImageViewer: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                GeometryReader { proxy in
                    let size = fittedSize(image.size, in: proxy.size)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                }
            } else if failed {
                QuickLookViewer(url: url)
            } else {
                ProgressView()
            }
        }
        .task(id: url) {
            image = nil
            failed = false
            do {
                let loaded = try await NativePreviewModel.boundedImage(url)
                guard !Task.isCancelled else { return }
                image = loaded
            } catch is CancellationError {
                return
            } catch {
                // Over a preview bound, zero-sized or undecodable: Quick Look renders it out of process.
                guard !Task.isCancelled else { return }
                failed = true
                Logger(subsystem: "MarkdownBrowser", category: "Viewers")
                    .notice("Image viewer fell back to Quick Look: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Shrinks to fit the window, but never enlarges past the image's natural size.
    private func fittedSize(_ size: CGSize, in container: CGSize) -> CGSize {
        let padding: CGFloat = 32
        guard size.width > 0, size.height > 0 else { return size }
        let scale = min(1, (container.width - padding) / size.width, (container.height - padding) / size.height)
        return CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
    }
}

struct VideoViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = Self.player(for: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = Self.player(for: url)
        }
    }

    static func player(for url: URL) -> AVPlayer {
        AVPlayer(playerItem: AVPlayerItem(asset: NativePreviewModel.restrictedAsset(url)))
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}

struct QuickLookViewer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

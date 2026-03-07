import SwiftUI
import AVKit

struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsTimecodes = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// Displays animated GIFs and static images using NSImageView.
/// macOS animates multi-frame GIFs natively when `animates = true`.
struct ImagePreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = NSImage(contentsOf: url)
    }
}

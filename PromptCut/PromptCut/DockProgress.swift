import AppKit

/// Draws a native-looking progress bar on the app's dock icon.
enum DockProgress {

    private static var progressView: DockProgressView?

    @MainActor
    static func update(_ value: Double) {
        let dockTile = NSApp.dockTile

        if progressView == nil {
            let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: dockTile.size.width, height: dockTile.size.height))
            progressView = view
            dockTile.contentView = view
        }

        progressView?.progress = value
        dockTile.display()
    }

    @MainActor
    static func clear() {
        progressView = nil
        let dockTile = NSApp.dockTile
        dockTile.contentView = nil
        dockTile.display()
    }
}

/// Custom NSView that draws the app icon with a progress bar overlay at the bottom.
private class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        // Draw the app icon as background
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: bounds)
        }

        guard progress > 0 && progress < 1 else { return }

        let barHeight: CGFloat = 12
        let barInset: CGFloat = 8
        let barY: CGFloat = 8
        let barRect = NSRect(
            x: barInset,
            y: barY,
            width: bounds.width - barInset * 2,
            height: barHeight
        )

        // Track background
        let trackPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.black.withAlphaComponent(0.6).setFill()
        trackPath.fill()

        // Progress fill
        let fillRect = NSRect(
            x: barRect.minX + 1.5,
            y: barRect.minY + 1.5,
            width: (barRect.width - 3) * CGFloat(progress),
            height: barRect.height - 3
        )
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: (barHeight - 3) / 2, yRadius: (barHeight - 3) / 2)
        NSColor.white.setFill()
        fillPath.fill()
    }
}

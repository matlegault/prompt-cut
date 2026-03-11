import Foundation
import PostHog

/// Lightweight analytics wrapper that captures **only metadata** — never filenames,
/// raw command text, or anything that could identify the user's content.
enum Analytics {

    // MARK: - Setup

    static func setup() {
        let config = PostHogConfig(apiKey: "phc_7jL9KpZG7JDUfK1I6iZKNWPMof9jPDCfrWjE7GPjo51")
        // config.host = "https://us.i.posthog.com"  // or eu.i.posthog.com
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        PostHogSDK.shared.setup(config)
    }

    // MARK: - Events

    static func trackAppLaunched() {
        PostHogSDK.shared.capture("app_launched")
    }

    /// Tracks that a video was loaded. Only captures format & numeric metadata.
    static func trackVideoLoaded(
        fileExtension: String,
        fileSizeBytes: Int64?,
        durationSeconds: Double?,
        resolution: CGSize?,
        fps: Double?
    ) {
        var props: [String: Any] = [
            "file_format": fileExtension.lowercased()
        ]
        if let size = fileSizeBytes { props["file_size_bytes"] = size }
        if let dur = durationSeconds { props["duration_seconds"] = round(dur * 10) / 10 }
        if let res = resolution {
            props["width"] = Int(res.width)
            props["height"] = Int(res.height)
        }
        if let fps { props["fps"] = round(fps) }
        PostHogSDK.shared.capture("video_loaded", properties: props)
    }

    /// Tracks command execution. Captures the **command category** (e.g. "trim", "convert"),
    /// never the raw user input.
    static func trackCommandExecuted(
        commandType: String,
        success: Bool,
        processingTimeSeconds: Double?
    ) {
        var props: [String: Any] = [
            "command_type": commandType,
            "success": success
        ]
        if let time = processingTimeSeconds {
            props["processing_time_seconds"] = round(time * 10) / 10
        }
        PostHogSDK.shared.capture("command_executed", properties: props)
    }

    /// Tracks that a file was saved. Only captures output format and size.
    static func trackFileSaved(outputFormat: String, fileSizeBytes: Int64?) {
        var props: [String: Any] = [
            "output_format": outputFormat.lowercased()
        ]
        if let size = fileSizeBytes { props["file_size_bytes"] = size }
        PostHogSDK.shared.capture("file_saved", properties: props)
    }

    static func trackUndo() {
        PostHogSDK.shared.capture("undo")
    }

    static func trackRedo() {
        PostHogSDK.shared.capture("redo")
    }

    static func trackDiscard() {
        PostHogSDK.shared.capture("discard_changes")
    }

    static func trackStartOver() {
        PostHogSDK.shared.capture("start_over")
    }

    static func trackMergeExecuted(clipCount: Int, success: Bool, processingTimeSeconds: Double?) {
        var props: [String: Any] = [
            "clip_count": clipCount,
            "success": success
        ]
        if let time = processingTimeSeconds {
            props["processing_time_seconds"] = round(time * 10) / 10
        }
        PostHogSDK.shared.capture("merge_executed", properties: props)
    }

    static func trackClipAdded(clipCount: Int) {
        PostHogSDK.shared.capture("clip_added", properties: [
            "total_clips": clipCount
        ])
    }

    static func trackError(type: String) {
        PostHogSDK.shared.capture("error_occurred", properties: [
            "error_type": type
        ])
    }

    static func trackCheatSheetOpened() {
        PostHogSDK.shared.capture("cheat_sheet_opened")
    }

    static func trackCancelProcessing() {
        PostHogSDK.shared.capture("processing_cancelled")
    }

    // MARK: - Helpers

    /// Extracts the command category from raw user input without storing the input.
    /// Returns a safe label like "trim", "convert", "compress", etc.
    static func commandCategory(from rawCommand: String) -> String {
        let t = rawCommand.trimmingCharacters(in: .whitespaces).lowercased()

        if t.hasPrefix("trim") || t.hasPrefix("cut")          { return "trim" }
        if t.contains("gif")                                    { return "convert_gif" }
        if t.hasPrefix("convert")                               { return "convert" }
        if t.hasPrefix("compress")                              { return "compress" }
        if t.hasPrefix("extract audio")                         { return "extract_audio" }
        if t.hasPrefix("resize") || t.hasPrefix("scale")       { return "resize" }
        if t.hasPrefix("speed up")                              { return "speed_up" }
        if t.hasPrefix("slow")                                  { return "slow_down" }
        if t.hasPrefix("reverse")                               { return "reverse" }
        if t.hasPrefix("mute") || t.hasPrefix("remove audio")  { return "mute" }
        if t.hasPrefix("thumbnail") || t.hasPrefix("frame") || t.hasPrefix("screenshot") { return "thumbnail" }
        if t.hasPrefix("rotate")                                { return "rotate" }
        if t.hasPrefix("crop")                                  { return "crop" }
        if t.hasPrefix("fps") || t.hasPrefix("framerate")      { return "fps" }
        if t.hasPrefix("loop")                                  { return "loop" }
        if t.hasPrefix("stabilize") || t.hasPrefix("stabilise") { return "stabilize" }
        if t.hasPrefix("denoise") || t.hasPrefix("reduce noise") { return "denoise" }
        if t.hasPrefix("grayscale") || t.hasPrefix("greyscale") || t.hasPrefix("black") { return "grayscale" }
        if t.hasPrefix("flip")                                  { return "flip" }

        return "unknown"
    }
}

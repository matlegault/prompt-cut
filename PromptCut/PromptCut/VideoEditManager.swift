import Foundation
import AVKit
import Combine
import SwiftUI

// MARK: - Clip model for merge timeline

struct VideoClip: Identifiable {
    let id = UUID()
    var url: URL
    var filename: String
    var duration: Double
    var thumbnail: NSImage?
}

@MainActor
class VideoEditManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isProcessing = false {
        didSet { if !isProcessing { DockProgress.clear() } }
    }
    @Published var progress: Double = 0 {  // 0…1 during processing
        didSet { DockProgress.update(progress) }
    }
    @Published var statusMessage = "Load a video to get started"
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var hasUnsavedChanges = false
    @Published var isVideoLoaded = false
    @Published var loadedFilename: String = "PromptCut"
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var previewImageURL: URL? = nil  // GIF / image output
    @Published var isAudioOnly: Bool = false     // audio-only output
    @Published var videoSize: CGSize? = nil
    @Published var videoFPS: Double? = nil
    @Published var lastLog: String? = nil       // full ffmpeg output from last command
    @Published var fileInfo: String? = nil        // e.g. "1920×1080 · 30fps · 12.4 MB"

    // MARK: - Merge state
    @Published var clips: [VideoClip] = []
    var isMergeMode: Bool { clips.count > 1 }

    private var history: [URL] = []
    private var redoStack: [URL] = []
    private var currentURL: URL? { history.last }
    private var sourceBitrateKbps: Int?  // video stream bitrate of the loaded file

    /// The file that should be offered for saving — GIF/image uses previewImageURL, otherwise the video.
    var currentOutputURL: URL? { previewImageURL ?? currentURL }

    private let tempDir: URL
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var loadSizeTask: Task<Void, Never>?
    private var runningProcess: Process?
    private var itemStatusObserver: NSKeyValueObservation?

    init() {
        let base = FileManager.default.temporaryDirectory
        // Clean up any leftover temp dirs from previous sessions
        if let contents = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
            for url in contents where url.lastPathComponent.hasPrefix("PromptCut-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        tempDir = base.appendingPathComponent("PromptCut-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Load

    func loadVideo(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        history = []
        redoStack = []
        isPlaying = false
        currentTime = 0
        duration = 0
        previewImageURL = nil
        isAudioOnly = false
        videoSize = nil
        videoFPS = nil
        sourceBitrateKbps = nil

        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let initial = tempDir.appendingPathComponent("v0.\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: initial)
            history = [initial]
            replacePlayer(url: initial)
            loadVideoSize(from: initial)
            loadVideoBitrate(from: initial)
            isVideoLoaded = true
            hasUnsavedChanges = false
            loadedFilename = url.lastPathComponent

            resetClipsToCurrentVideo()
            updateState()
            statusMessage = "Ready — type a command to start"

            // Analytics: track video load with metadata only
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: initial.path)[.size] as? Int64) ?? nil
            Analytics.trackVideoLoaded(
                fileExtension: ext,
                fileSizeBytes: fileSize,
                durationSeconds: nil,  // duration loads async
                resolution: videoSize,
                fps: videoFPS
            )
        } catch {
            player?.pause()
            player = nil
            isVideoLoaded = false
            previewImageURL = nil
            isAudioOnly = false
            statusMessage = "Failed to load: \(error.localizedDescription)"
            Analytics.trackError(type: "load_failed")
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: - Apply command

    func applyCommand(_ rawCommand: String) async {
        guard let current = currentURL else { return }

        let trimmed = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isProcessing = true
        wasCancelled = false
        progress = 0
        statusMessage = "Processing…"
        let commandCategory = Analytics.commandCategory(from: trimmed)
        let commandStart = CFAbsoluteTimeGetCurrent()

        do {
            let cmd = try CommandParser.parse(trimmed, inputPath: current.path, sourceBitrateKbps: sourceBitrateKbps, durationSeconds: duration)

            guard let ffmpegPath = findFFmpeg() else {
                statusMessage = "ffmpeg not found. Run: brew install ffmpeg  (or add the binary to the app bundle)"
                isProcessing = false
                return
            }

            let totalDuration = duration  // captured for progress calc
            let (output, exitCode) = await runProcess(ffmpegPath, args: cmd.args, in: tempDir) { [weak self] timeSeconds in
                guard let self, totalDuration > 0 else { return }
                let pct = min(timeSeconds / totalDuration, 1.0)
                Task { @MainActor in self.progress = pct }
            }

            lastLog = output

            if exitCode == 0 {
                let produced = URL(fileURLWithPath: cmd.outputPath)
                let ext = produced.pathExtension.lowercased()
                let nextIndex = history.count
                let stateURL = tempDir.appendingPathComponent("v\(nextIndex).\(ext)")

                if produced.path != stateURL.path {
                    try FileManager.default.moveItem(at: produced, to: stateURL)
                }
                redoStack = []
                history.append(stateURL)
                updatePlayerState(for: stateURL)
                hasUnsavedChanges = true
                statusMessage = "Done!"
                let elapsed = CFAbsoluteTimeGetCurrent() - commandStart
                Analytics.trackCommandExecuted(commandType: commandCategory, success: true, processingTimeSeconds: elapsed)
            } else if wasCancelled {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: cmd.outputPath))
                statusMessage = "Cancelled"
                Analytics.trackCancelProcessing()
            } else {
                statusMessage = "Error: \(extractError(output))"
                Analytics.trackCommandExecuted(commandType: commandCategory, success: false, processingTimeSeconds: nil)
            }
        } catch {
            lastLog = nil
            statusMessage = error.localizedDescription ?? "Unknown error"
            Analytics.trackError(type: "parse_failed")
        }

        isProcessing = false
        updateState()
    }

    // MARK: - History

    func undo() {
        guard history.count > 1 else { return }
        redoStack.append(history.removeLast())
        updatePlayerState(for: history.last!)
        hasUnsavedChanges = history.count > 1
        resetClipsToCurrentVideo()
        updateState()
        statusMessage = "Undone"
        Analytics.trackUndo()
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        let next = redoStack.removeLast()
        history.append(next)
        updatePlayerState(for: next)
        hasUnsavedChanges = true
        resetClipsToCurrentVideo()
        updateState()
        statusMessage = "Redone"
        Analytics.trackRedo()
    }

    private var wasCancelled = false

    func cancelProcessing() {
        guard isProcessing, let process = runningProcess, process.isRunning else { return }
        wasCancelled = true
        process.terminate()
    }

    func startOver() {
        let toDelete = history + redoStack
        for url in toDelete { try? FileManager.default.removeItem(at: url) }
        history = []
        redoStack = []
        clips = []
        player?.pause()
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        rateObserver?.invalidate(); rateObserver = nil
        itemStatusObserver?.invalidate(); itemStatusObserver = nil
        player = nil
        isVideoLoaded = false
        isPlaying = false
        currentTime = 0
        duration = 0
        previewImageURL = nil
        isAudioOnly = false
        videoSize = nil
        videoFPS = nil
        fileInfo = nil
        lastLog = nil
        loadedFilename = "PromptCut"
        hasUnsavedChanges = false
        canUndo = false
        canRedo = false
        statusMessage = "Load a video to get started"
        Analytics.trackStartOver()
    }

    func discardChanges() {
        guard let first = history.first else { return }
        let toDelete = Array(history.dropFirst()) + redoStack
        for url in toDelete { try? FileManager.default.removeItem(at: url) }
        history = [first]
        redoStack = []
        updatePlayerState(for: first)
        hasUnsavedChanges = false
        resetClipsToCurrentVideo()
        updateState()
        statusMessage = "Changes discarded"
        Analytics.trackDiscard()
    }

    func markSaved() {
        hasUnsavedChanges = false
        statusMessage = "Saved!"
    }

    func saveResult(from source: URL, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: source, to: url)
        hasUnsavedChanges = false
        statusMessage = "Saved!"

        let savedSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
        Analytics.trackFileSaved(outputFormat: url.pathExtension, fileSizeBytes: savedSize)
    }

    // MARK: - Merge / Timeline

    func addClip(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let clipFile = tempDir.appendingPathComponent("clip-\(UUID().uuidString).\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: clipFile)
        } catch {
            statusMessage = "Failed to add clip: \(error.localizedDescription)"
            return
        }

        let clip = VideoClip(url: clipFile, filename: url.lastPathComponent, duration: 0, thumbnail: nil)
        clips.append(clip)

        // Load duration + thumbnail async
        let clipID = clip.id
        Task {
            let asset = AVURLAsset(url: clipFile)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            let thumb = await Self.generateThumbnail(for: clipFile)
            if let idx = clips.firstIndex(where: { $0.id == clipID }) {
                clips[idx].duration = dur
                clips[idx].thumbnail = thumb
            }
        }

        statusMessage = "Added clip — \(clips.count) clips in timeline"
        Analytics.trackClipAdded(clipCount: clips.count)
    }

    func removeClip(id: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        let removed = clips.remove(at: idx)
        try? FileManager.default.removeItem(at: removed.url)

        if clips.isEmpty {
            // All clips removed — nothing to show
            statusMessage = "Load a video to get started"
        } else if clips.count == 1 {
            // Back to single-clip mode — reload it as the main video
            loadVideo(url: clips[0].url)
            statusMessage = "Back to single video mode"
        } else {
            statusMessage = "\(clips.count) clips in timeline"
        }
    }

    func reorderClips(from source: IndexSet, to destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }

    func previewClip(_ clip: VideoClip) {
        replacePlayer(url: clip.url)
        previewImageURL = nil
        isAudioOnly = false
        loadVideoSize(from: clip.url)
    }

    func executeMerge() async {
        guard clips.count > 1 else { return }

        guard let ffmpegPath = findFFmpeg() else {
            statusMessage = "ffmpeg not found. Run: brew install ffmpeg"
            return
        }

        isProcessing = true
        wasCancelled = false
        progress = 0
        statusMessage = "Merging \(clips.count) clips…"
        let mergeClipCount = clips.count
        let mergeStart = CFAbsoluteTimeGetCurrent()

        let outputFile = tempDir.appendingPathComponent("merged_output.mp4")
        try? FileManager.default.removeItem(at: outputFile)

        let totalDuration = clips.reduce(0.0) { $0 + $1.duration }
        let n = clips.count

        // Probe each clip for audio presence
        var hasAudio: [Bool] = []
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            hasAudio.append(!audioTracks.isEmpty)
        }

        // Determine target resolution from first clip (or fallback to 1280x720)
        let targetW: Int
        let targetH: Int
        if let size = videoSize {
            // Use even dimensions
            targetW = Int(size.width) / 2 * 2
            targetH = Int(size.height) / 2 * 2
        } else {
            targetW = 1280
            targetH = 720
        }

        // Build inputs — add an anullsrc input for generating silence
        var inputArgs = clips.flatMap { ["-i", $0.url.path] }
        // Extra input at index [n]: silent audio source
        let needsSilence = hasAudio.contains(false)
        if needsSilence {
            inputArgs += ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100"]
        }
        let silenceIdx = n  // index of the anullsrc input

        // Build filter graph
        var filterParts: [String] = []

        // Video: scale all to target resolution, normalize fps and pixel format
        for i in 0..<n {
            filterParts.append("[\(i):v:0]scale=\(targetW):\(targetH):force_original_aspect_ratio=decrease,pad=\(targetW):\(targetH):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=nv12[\(i)v]")
        }

        // Audio: use real audio or trimmed silence for each clip
        for i in 0..<n {
            if hasAudio[i] {
                filterParts.append("[\(i):a:0]aformat=sample_rates=44100:channel_layouts=stereo[\(i)a]")
            } else {
                // Trim silence to match clip duration
                let dur = String(format: "%.3f", clips[i].duration)
                filterParts.append("[\(silenceIdx)]atrim=0:\(dur),asetpts=PTS-STARTPTS[\(i)a]")
            }
        }

        // Concat
        let videoConcat = (0..<n).map { "[\($0)v]" }.joined()
        let audioConcat = (0..<n).map { "[\($0)a]" }.joined()
        filterParts.append("\(videoConcat)concat=n=\(n):v=1:a=0[outv]")
        filterParts.append("\(audioConcat)concat=n=\(n):v=0:a=1[outa]")

        let fullFilter = filterParts.joined(separator: ";")

        let args = ["-threads", "0"] + inputArgs +
            ["-filter_complex", fullFilter,
             "-map", "[outv]", "-map", "[outa]",
             "-c:v", "h264_videotoolbox", "-b:v", "\(sourceBitrateKbps ?? 8000)k",
             "-c:a", "aac", "-b:a", "192k",
             "-movflags", "+faststart",
             "-y", outputFile.path]

        let (output, exitCode) = await runProcess(ffmpegPath, args: args, in: tempDir) { [weak self] timeSeconds in
            guard let self, totalDuration > 0 else { return }
            let pct = min(timeSeconds / totalDuration, 1.0)
            Task { @MainActor in self.progress = pct }
        }

        lastLog = output

        if exitCode == 0 {
            finishMerge(outputFile: outputFile)
            let elapsed = CFAbsoluteTimeGetCurrent() - mergeStart
            Analytics.trackMergeExecuted(clipCount: mergeClipCount, success: true, processingTimeSeconds: elapsed)
        } else if wasCancelled {
            try? FileManager.default.removeItem(at: outputFile)
            statusMessage = "Cancelled"
            Analytics.trackCancelProcessing()
        } else {
            statusMessage = "Merge failed: \(extractError(output))"
            Analytics.trackMergeExecuted(clipCount: mergeClipCount, success: false, processingTimeSeconds: nil)
        }

        isProcessing = false
        updateState()
    }

    private func finishMerge(outputFile: URL) {
        let ext = outputFile.pathExtension
        let nextIndex = history.count
        let stateURL = tempDir.appendingPathComponent("v\(nextIndex).\(ext)")
        // Clean up redo stack files before moving, since merge invalidates redo history
        for redoURL in redoStack {
            try? FileManager.default.removeItem(at: redoURL)
        }
        redoStack = []

        do {
            if outputFile.path != stateURL.path {
                try? FileManager.default.removeItem(at: stateURL)
                try FileManager.default.moveItem(at: outputFile, to: stateURL)
            }
        } catch {
            statusMessage = "Failed to save merge result: \(error.localizedDescription)"
            return
        }
        history.append(stateURL)
        updatePlayerState(for: stateURL)
        hasUnsavedChanges = true

        // Back to single-video mode with the merged result as the sole clip
        resetClipsToCurrentVideo()
        statusMessage = "Merged!"
    }

    /// Resets the clips array to contain only the current video, so subsequent
    /// drops correctly enter merge mode again.
    private func resetClipsToCurrentVideo() {
        guard let url = currentURL else { clips = []; return }
        let clip = VideoClip(url: url, filename: loadedFilename, duration: 0, thumbnail: nil)
        clips = [clip]
        let clipID = clip.id
        Task {
            let asset = AVURLAsset(url: url)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            let thumb = await Self.generateThumbnail(for: url)
            if let idx = self.clips.firstIndex(where: { $0.id == clipID }) {
                self.clips[idx].duration = dur
                self.clips[idx].thumbnail = thumb
            }
        }
    }

    nonisolated static func generateThumbnail(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        let time = CMTime(seconds: 1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Private helpers

    private static let imageFormats: Set<String> = ["gif", "jpg", "jpeg", "png", "webp"]
    private static let audioFormats: Set<String> = ["mp3", "wav", "aac", "flac", "ogg", "m4a"]

    /// Routes a URL to the right preview mode: image viewer, audio player, or video player.
    private func updatePlayerState(for url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.imageFormats.contains(ext) {
            previewImageURL = url
            isAudioOnly = false
            videoFPS = nil
            if let img = NSImage(contentsOf: url) { videoSize = img.size }
            updateFileInfo(for: url)
        } else {
            replacePlayer(url: url)
            previewImageURL = nil
            isAudioOnly = Self.audioFormats.contains(ext)
            if !isAudioOnly {
                loadVideoSize(from: url)
            } else {
                videoSize = nil
                videoFPS = nil
                updateFileInfo(for: url)
            }
        }
    }

    private func loadVideoSize(from url: URL) {
        loadSizeTask?.cancel()
        loadSizeTask = Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  !Task.isCancelled else { return }
            let size = try? await track.load(.naturalSize)
            let transform = try? await track.load(.preferredTransform)
            let fps = try? await track.load(.nominalFrameRate)
            guard !Task.isCancelled, let size, let transform else { return }
            let transformed = size.applying(transform)
            videoSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
            if let fps, fps > 0 { videoFPS = Double(fps) }
            updateFileInfo(for: url)
        }
    }

    private func loadVideoBitrate(from url: URL) {
        Task {
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return }
            let estimatedRate = try? await track.load(.estimatedDataRate) // bits per second
            if let bps = estimatedRate, bps > 0 {
                sourceBitrateKbps = Int(bps / 1000)
            }
        }
    }

    private func replacePlayer(url: URL) {
        let item = AVPlayerItem(url: url)
        if let p = player {
            p.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)

            // Periodic time observer — added once per player instance
            timeObserver = player!.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 30),
                queue: .main
            ) { [weak self] time in
                guard let self else { return }
                let s = time.seconds
                if s.isFinite { self.currentTime = s }
            }

            // Rate observer — tracks play/pause state
            rateObserver = player!.observe(\.rate, options: .new) { [weak self] p, _ in
                DispatchQueue.main.async { self?.isPlaying = p.rate > 0 }
            }
        }

        // Duration + seek-to-start when item becomes ready
        itemStatusObserver?.invalidate()
        itemStatusObserver = item.observe(\.status, options: .new) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                let d = item.duration.seconds
                if d.isFinite && d > 0 { self?.duration = d }
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
                self?.itemStatusObserver?.invalidate()
                self?.itemStatusObserver = nil
            }
        }
    }

    private func updateState() {
        canUndo = history.count > 1
        canRedo = !redoStack.isEmpty
    }

    private func updateFileInfo(for url: URL) {
        var parts: [String] = []
        if let size = videoSize {
            parts.append("\(Int(size.width))×\(Int(size.height))")
        }
        if let fps = videoFPS {
            let rounded = fps.rounded()
            parts.append("\(Int(rounded))fps")
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attrs[.size] as? Int64 {
            parts.append(Self.formatBytes(bytes))
        }
        fileInfo = parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    private func findFFmpeg() -> String? {
        // 1. Bundled in app resources (add via Xcode target → Copy Bundle Resources)
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
            return bundled.path
        }
        // 2. Common system locations
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",   // Homebrew arm64
            "/usr/local/bin/ffmpeg",      // Homebrew x86 / manual install
            "/usr/bin/ffmpeg"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func runProcess(
        _ executable: String,
        args: [String],
        in directory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let process = Process()
                Task { @MainActor in self?.runningProcess = process }
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
                process.currentDirectoryURL = directory

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var collectedOutput = Data()

                // Stream stderr to parse FFmpeg progress lines
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    collectedOutput.append(chunk)

                    if let text = String(data: chunk, encoding: .utf8) {
                        // FFmpeg outputs lines like: frame=  123 fps= 30 ... time=00:01:23.45 ...
                        for line in text.components(separatedBy: "\r") {
                            if let range = line.range(of: "time=") {
                                let after = String(line[range.upperBound...])
                                let timeStr = after.prefix(while: { $0 != " " && $0 != "\n" })
                                if let seconds = Self.parseFFmpegTime(String(timeStr)) {
                                    onProgress?(seconds)
                                }
                            }
                        }
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = errPipe.fileHandleForReading.readDataToEndOfFile()
                    collectedOutput.append(remaining)
                    let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    collectedOutput.append(stdoutData)
                    let output = String(data: collectedOutput, encoding: .utf8) ?? ""
                    Task { @MainActor in self?.runningProcess = nil }
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    Task { @MainActor in self?.runningProcess = nil }
                    continuation.resume(returning: (error.localizedDescription, -1))
                }
            }
        }
    }

    /// Parses FFmpeg time strings like "00:01:23.45" or "01:23.45" into seconds.
    private static func parseFFmpegTime(_ str: String) -> Double? {
        let parts = str.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        if parts.count == 3,
           let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
            return h * 3600 + m * 60 + s
        } else if parts.count == 2,
                  let m = Double(parts[0]), let s = Double(parts[1]) {
            return m * 60 + s
        }
        return nil
    }

    private func extractError(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("frame=") && !$0.hasPrefix("Press") }
        return lines.last ?? output
    }
}

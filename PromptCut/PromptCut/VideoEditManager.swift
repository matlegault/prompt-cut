import Foundation
import AVKit
import Combine

@MainActor
class VideoEditManager: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isProcessing = false
    @Published var progress: Double = 0   // 0…1 during processing
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

    private var history: [URL] = []
    private var redoStack: [URL] = []
    private var currentURL: URL? { history.last }

    /// The file that should be offered for saving — GIF/image uses previewImageURL, otherwise the video.
    var currentOutputURL: URL? { previewImageURL ?? currentURL }

    private let tempDir: URL
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var loadSizeTask: Task<Void, Never>?

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

        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let initial = tempDir.appendingPathComponent("v0.\(ext)")
        do {
            try FileManager.default.copyItem(at: url, to: initial)
            history = [initial]
            replacePlayer(url: initial)
            loadVideoSize(from: initial)
            isVideoLoaded = true
            hasUnsavedChanges = false
            loadedFilename = url.lastPathComponent
            updateState()
            statusMessage = "Ready — type a command to start"
        } catch {
            statusMessage = "Failed to load: \(error.localizedDescription)"
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
        progress = 0
        statusMessage = "Processing…"

        do {
            let cmd = try CommandParser.parse(trimmed, inputPath: current.path)

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
            } else {
                statusMessage = "Error: \(extractError(output))"
            }
        } catch {
            statusMessage = error.localizedDescription ?? "Unknown error"
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
        updateState()
        statusMessage = "Undone"
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        let next = redoStack.removeLast()
        history.append(next)
        updatePlayerState(for: next)
        hasUnsavedChanges = true
        updateState()
        statusMessage = "Redone"
    }

    func discardChanges() {
        guard let first = history.first else { return }
        let toDelete = Array(history.dropFirst()) + redoStack
        for url in toDelete { try? FileManager.default.removeItem(at: url) }
        history = [first]
        redoStack = []
        updatePlayerState(for: first)
        hasUnsavedChanges = false
        updateState()
        statusMessage = "Changes discarded"
    }

    func markSaved() {
        hasUnsavedChanges = false
        statusMessage = "Saved!"
    }

    func saveResult(to url: URL) throws {
        guard let current = currentOutputURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.copyItem(at: current, to: url)
        hasUnsavedChanges = false
        statusMessage = "Saved!"
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
            if let img = NSImage(contentsOf: url) { videoSize = img.size }
        } else {
            replacePlayer(url: url)
            previewImageURL = nil
            isAudioOnly = Self.audioFormats.contains(ext)
            if !isAudioOnly { loadVideoSize(from: url) }
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
            guard !Task.isCancelled, let size, let transform else { return }
            let transformed = size.applying(transform)
            videoSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
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
        var token: NSKeyValueObservation?
        token = item.observe(\.status, options: .new) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            DispatchQueue.main.async {
                let d = item.duration.seconds
                if d.isFinite && d > 0 { self?.duration = d }
                self?.currentTime = 0
                self?.player?.seek(to: .zero)
            }
            token?.invalidate()
        }
    }

    private func updateState() {
        canUndo = history.count > 1
        canRedo = !redoStack.isEmpty
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
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
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
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
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

//
//  ContentView.swift
//  PromptCut
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers

// MARK: - Command templates for typeahead

private let commandTemplates: [String] = [
    "trim video from [start] to [end]",
    "cut video from [start] to [end]",
    "convert video to gif",
    "convert video to mp4",
    "convert video to mp3",
    "compress video to [size]mb",
    "resize video to 720p",
    "resize video to 1080p",
    "resize video to 480p",
    "resize video to [w]x[h]",
    "scale video to 720p",
    "speed up video by 2x",
    "speed up video by [n]x",
    "slow down video by 2x",
    "slow down video by [n]x",
    "reverse video",
    "mute video",
    "remove audio from video",
    "extract audio from video",
    "thumbnail video at [time]",
    "screenshot video at [time]",
    "rotate video by 90",
    "rotate video by 180",
    "rotate video by 270",
    "crop video to [w]x[h]",
    "fps video to [rate]",
    "loop video [n] times",
    "stabilize video",
    "denoise video",
    "grayscale video",
    "flip video horizontal",
    "flip video vertical",
]

struct ContentView: View {
    @StateObject private var editManager = VideoEditManager()
    @State private var commandText = ""
    @State private var showCheatSheet = false
    @State private var isTargeted = false
    @State private var hoveredSuggestion: String? = nil
    @State private var selectedSuggestionIndex: Int? = nil
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    private var exportContentType: UTType {
        switch editManager.currentOutputURL?.pathExtension.lowercased() {
        case "gif":         return UTType("com.compuserve.gif") ?? .data
        case "mp3":         return .mp3
        case "wav":         return .wav
        case "m4a", "aac":  return .mpeg4Audio
        case "jpg", "jpeg": return .jpeg
        case "png":         return .png
        default:            return .movie
        }
    }

    private var suggestions: [String] {
        let query = commandText.trimmingCharacters(in: .whitespaces).lowercased()
        guard query.count >= 2,
              !commandTemplates.contains(where: { $0.lowercased() == query }) else { return [] }
        let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return commandTemplates.filter { template in
            words.allSatisfy { template.lowercased().contains($0) }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Full-window video or drop zone ────────────────────────────
            Group {
                if let previewURL = editManager.previewImageURL {
                    ImagePreviewView(url: previewURL)
                        .background(Color.black)
                } else if let player = editManager.player {
                    VideoPlayerView(player: player)
                        .background(Color.black)
                    if editManager.isAudioOnly {
                        audioOnlyOverlay
                    }
                } else {
                    dropZone
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Processing overlay ────────────────────────────────────────
            if editManager.isProcessing {
                processingOverlay
            }

            // ── Floating glass bar (slides up when video is loaded) ───────
            if editManager.isVideoLoaded {
                floatingBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(duration: 0.3), value: editManager.isVideoLoaded)
            }

            // ── Suggestions panel (above the command row, always on top) ──
            if editManager.isVideoLoaded && !suggestions.isEmpty {
                suggestionsPanel
                    .padding(.leading, 32)
                    .padding(.bottom, 88)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ignoresSafeArea()
        .onDrop(of: [UTType.movie], isTargeted: $isTargeted) { providers in
            loadDroppedVideo(from: providers)
        }
        .navigationTitle(editManager.loadedFilename)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: openFile) {
                    Label("Open Video", systemImage: "folder.badge.plus")
                }
                .help("Open Video (⌘O)")
                .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button(action: editManager.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!editManager.canUndo)
                .help("Undo (⌘Z)")
                .keyboardShortcut("z", modifiers: .command)

                Button(action: editManager.redo) {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!editManager.canRedo)
                .help("Redo (⌘⇧Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift])

                Spacer()

                Button("Discard") {
                    editManager.discardChanges()
                }
                .disabled(!editManager.hasUnsavedChanges)
                .foregroundStyle(.red)
                .help("Discard all changes since last save")

                Button("Save…") {
                    saveFile()
                }
                .disabled(!editManager.hasUnsavedChanges)
                .buttonStyle(.borderedProminent)
                .help("Save edited video")
            }
        }
    }

    // MARK: - Sub-views

    private var dropZone: some View {
        ZStack {
            Color.black.opacity(0.01) // needed to receive drop events over the empty area

            VStack(spacing: 12) {
                Image(systemName: "film.stack")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("Drop a video here")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                Text("or")
                    .foregroundStyle(.secondary)
                Button("Choose File…") { openFile() }
                    .buttonStyle(.bordered)
            }

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 4])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
                )
                .padding()
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.4)
                Text("Processing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // Layout content for the floating bar — separated so the glass styling
    // can be applied via an availability check without duplicating the layout.
    private var audioOnlyOverlay: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Audio")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var floatingBarContent: some View {
        VStack(spacing: 0) {
            // ── Playback controls (hidden for image/GIF outputs) ──────────
            if editManager.previewImageURL == nil {
            HStack(spacing: 10) {
                Button(action: editManager.togglePlayback) {
                    Image(systemName: editManager.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubTime : editManager.currentTime },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(editManager.duration, 1),
                    onEditingChanged: { editing in
                        if editing { scrubTime = editManager.currentTime }
                        else { editManager.seek(to: scrubTime) }
                        isScrubbing = editing
                    }
                )
                .transaction { $0.animation = nil }

                Text("\(formatTime(editManager.currentTime)) / \(formatTime(editManager.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()
            } // end playback controls

            // ── Command input ─────────────────────────────────────────────
            HStack(spacing: 8) {
                commandEditor

                Button("Apply") { applyEdit() }
                    .disabled(!canApply)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // ── Status + cheat sheet ──────────────────────────────────────
            HStack {
                Text(editManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    showCheatSheet = true
                } label: {
                    Label("Cheat Sheet", systemImage: "questionmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Cheat Sheet")
                .sheet(isPresented: $showCheatSheet) {
                    CheatSheetView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private var suggestionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.prefix(6).enumerated()), id: \.offset) { idx, suggestion in
                let isSelected = selectedSuggestionIndex == idx || hoveredSuggestion == suggestion
                Button {
                    commandText = suggestion
                    selectedSuggestionIndex = nil
                    hoveredSuggestion = nil
                } label: {
                    Text(suggestion)
                        .font(.body)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered in hoveredSuggestion = isHovered ? suggestion : nil }

                if idx < min(suggestions.count, 6) - 1 {
                    Divider()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: -6)
    }

    @ViewBuilder
    private var floatingBar: some View {
        if #available(macOS 26.0, *) {
            floatingBarContent
                .glassEffect(in: RoundedRectangle(cornerRadius: 20))
        } else {
            floatingBarContent
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        }
    }

    private var commandEditor: some View {
        TextField("Type your edit in plain English…  e.g. trim video from 0:30 to 1:00", text: $commandText)
            .font(.body)
            .textFieldStyle(.roundedBorder)
            .onChange(of: commandText) { selectedSuggestionIndex = nil }
            .onSubmit {
                if let idx = selectedSuggestionIndex, idx < suggestions.prefix(6).count {
                    commandText = Array(suggestions.prefix(6))[idx]
                    selectedSuggestionIndex = nil
                } else {
                    applyEdit()
                }
            }
            .onKeyPress(.downArrow) { navigateSuggestion(by: 1); return .handled }
            .onKeyPress(.upArrow)   { navigateSuggestion(by: -1); return .handled }
            .onKeyPress(.escape)    { selectedSuggestionIndex = nil; return .handled }
    }

    // MARK: - Helpers

    private func navigateSuggestion(by delta: Int) {
        let count = min(suggestions.count, 6)
        guard count > 0 else { return }
        if let idx = selectedSuggestionIndex {
            selectedSuggestionIndex = (idx + delta + count) % count
        } else {
            selectedSuggestionIndex = delta > 0 ? 0 : count - 1
        }
    }

    private var canApply: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editManager.isVideoLoaded
            && !editManager.isProcessing
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let m = s / 60
        let sec = s % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    private func openFile() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .video]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.message = "Choose a video file to edit"
            let response = await panel.begin()
            guard response == .OK, let url = panel.url else { return }
            editManager.loadVideo(url: url)
        }
    }

    private func saveFile() {
        guard let outputURL = editManager.currentOutputURL else { return }
        Task { @MainActor in
            let panel = NSSavePanel()
            let baseName = URL(fileURLWithPath: editManager.loadedFilename).deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(baseName)-edited.\(outputURL.pathExtension)"
            panel.allowedContentTypes = [exportContentType]
            let response = await panel.begin()
            guard response == .OK, let dest = panel.url else { return }
            try? editManager.saveResult(to: dest)
        }
    }


    private func applyEdit() {
        let cmd = commandText
        commandText = ""
        Task { await editManager.applyCommand(cmd) }
    }

    private func loadDroppedVideo(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) else {
            return false
        }
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
            guard let url else { return }
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: dest)
            Task { @MainActor in editManager.loadVideo(url: dest) }
        }
        return true
    }
}

#Preview {
    ContentView()
}

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

    private var suggestions: [String] {
        let query = commandText.trimmingCharacters(in: .whitespaces).lowercased()
        // Hide suggestions once the user has typed an exact match (already selected one)
        guard query.count >= 2,
              !commandTemplates.contains(where: { $0.lowercased() == query }) else { return [] }
        let words = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return commandTemplates.filter { template in
            words.allSatisfy { template.lowercased().contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Video area ───────────────────────────────────────────────
            ZStack {
                if let player = editManager.player {
                    VideoPlayerView(player: player)
                        .background(Color.black)
                } else {
                    dropZone
                }

                if editManager.isProcessing {
                    processingOverlay
                }
            }
            .frame(minHeight: 320)
            .onDrop(of: [UTType.movie], isTargeted: $isTargeted) { providers in
                loadDroppedVideo(from: providers)
            }

            Divider()

            // ── Command area ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    commandEditor

                    Button("Apply") {
                        applyEdit()
                    }
                    .disabled(!canApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }

                HStack(spacing: 8) {
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
            }
            .padding(12)
        }
        .navigationTitle(editManager.loadedFilename)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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
            }

            ToolbarItemGroup(placement: .primaryAction) {
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

    private var commandEditor: some View {
        TextField("Type your edit in plain English…  e.g. trim video from 0:30 to 1:00", text: $commandText)
            .font(.body)
            .textFieldStyle(.roundedBorder)
            .onSubmit { applyEdit() }
            .overlay(alignment: .topLeading) {
                // Floating suggestions popup, anchored to the top-left of the text field
                // and offset upward so it floats above without shifting the layout.
                if !suggestions.isEmpty {
                    suggestionsPopup
                        .alignmentGuide(.top)    { d in d[.bottom] + 4 }
                        .alignmentGuide(.leading) { d in d[.leading] }
                }
            }
    }

    private var suggestionsPopup: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(6), id: \.self) { suggestion in
                Button {
                    commandText = suggestion
                    hoveredSuggestion = nil
                } label: {
                    Text(suggestion)
                        .font(.body)
                        .foregroundStyle(hoveredSuggestion == suggestion ? .white : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(hoveredSuggestion == suggestion ? Color.accentColor : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovered in hoveredSuggestion = isHovered ? suggestion : nil }

                if suggestion != suggestions.prefix(6).last {
                    Divider()
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(minWidth: 300)
        .fixedSize(horizontal: false, vertical: true)
        .offset(y: -CGFloat(min(suggestions.count, 6)) * 31 - 8)
    }

    // MARK: - Helpers

    private var canApply: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && editManager.isVideoLoaded
            && !editManager.isProcessing
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose a video file to edit"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        editManager.loadVideo(url: url)
    }

    private func saveFile() {
        guard let ext = editManager.player?.currentItem?.asset
            .tracks(withMediaType: .video).isEmpty == false ? "mp4" : nil ?? "mp4" as String? else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.movie]
        panel.nameFieldStringValue = "edited-video.\(ext)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? editManager.saveResult(to: url)
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
            // loadFileRepresentation gives a temp copy; copy it ourselves so it survives
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

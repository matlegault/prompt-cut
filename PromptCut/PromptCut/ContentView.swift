//
//  ContentView.swift
//  PromptCut
//

import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var editManager = VideoEditManager()
    @State private var commandText = ""
    @State private var showCheatSheet = false
    @State private var isTargeted = false

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
            VStack(alignment: .leading, spacing: 8) {
                commandEditor

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

                    Button("Apply Edit") {
                        applyEdit()
                    }
                    .disabled(!canApply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(12)
        }
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
        ZStack(alignment: .topLeading) {
            TextEditor(text: $commandText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            if commandText.isEmpty {
                Text("Type your edit in plain English…\ne.g.  trim video from 0:30 to 1:00")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .padding(.leading, 5)
                    .padding(.top, 5)
                    .allowsHitTesting(false)
            }
        }
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

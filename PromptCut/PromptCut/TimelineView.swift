import SwiftUI
import UniformTypeIdentifiers

struct TimelineView: View {
    @ObservedObject var editManager: VideoEditManager

    var body: some View {
        timelineContent
    }

    @ViewBuilder
    private var timelineContent: some View {
        if #available(macOS 26.0, *) {
            timelineBar
                .glassEffect(in: RoundedRectangle(cornerRadius: 16))
        } else {
            timelineBar
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        }
    }

    private var timelineBar: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(editManager.clips.count) clips")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(formatTotalDuration())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                Button("Merge") {
                    Task { await editManager.executeMerge() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editManager.clips.count < 2 || editManager.isProcessing)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(editManager.clips.enumerated()), id: \.element.id) { index, clip in
                        clipCard(clip, at: index)
                    }

                    addClipButton
                }
                .padding(.horizontal, 14)
            }
            .padding(.bottom, 10)
        }
    }

    private func clipCard(_ clip: VideoClip, at index: Int) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let thumb = clip.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 100, height: 56)
                        .clipped()
                        .cornerRadius(6)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 100, height: 56)
                        .overlay(
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                        )
                }

                Button {
                    editManager.removeClip(id: clip.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(3)
            }

            Text(clip.filename)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 100)

            // Reorder buttons
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editManager.clips.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(index == 0)
                .opacity(index == 0 ? 0.3 : 1)

                Text(formatDuration(clip.duration))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editManager.clips.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(index == editManager.clips.count - 1)
                .opacity(index == editManager.clips.count - 1 ? 0.3 : 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            editManager.previewClip(clip)
        }
    }

    private var addClipButton: some View {
        Button {
            openFilePicker()
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 100, height: 56)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    )

                Text("Add clip")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                Text(" ")
                    .font(.system(size: 9))
            }
        }
        .buttonStyle(.plain)
    }

    private func openFilePicker() {
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.movie, .video]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.message = "Choose video clips to add"
            let response = await panel.begin()
            guard response == .OK else { return }
            for url in panel.urls {
                editManager.addClip(url: url)
            }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        let m = s / 60
        let sec = s % 60
        if m >= 60 {
            return String(format: "%d:%02d:%02d", m / 60, m % 60, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    private func formatTotalDuration() -> String {
        let total = editManager.clips.reduce(0.0) { $0 + $1.duration }
        return "Total: \(formatDuration(total))"
    }
}

import SwiftUI

struct CheatCommand: Identifiable {
    let id = UUID()
    let category: String
    let syntax: String
    let example: String
}

private let commands: [CheatCommand] = [
    CheatCommand(category: "Trim",      syntax: "trim video from [start] to [end]",   example: "trim video from 0:30 to 1:00"),
    CheatCommand(category: "Convert",   syntax: "convert video to gif",               example: "convert video to gif"),
    CheatCommand(category: "Convert",   syntax: "convert video to [format]",          example: "convert video to mp4"),
    CheatCommand(category: "Convert",   syntax: "convert video to [audio]",           example: "convert video to mp3"),
    CheatCommand(category: "Compress",  syntax: "compress video to [size]mb",         example: "compress video to 10mb"),
    CheatCommand(category: "Resize",    syntax: "resize video to [N]p",               example: "resize video to 720p"),
    CheatCommand(category: "Resize",    syntax: "resize video to [W]x[H]",            example: "resize video to 1280x720"),
    CheatCommand(category: "Crop",      syntax: "crop video to [W]x[H]",              example: "crop video to 1280x720"),
    CheatCommand(category: "Speed",     syntax: "speed up video by [n]x",             example: "speed up video by 2x"),
    CheatCommand(category: "Speed",     syntax: "slow down video by [n]x",            example: "slow down video by 2x"),
    CheatCommand(category: "Reverse",   syntax: "reverse video",                      example: "reverse video"),
    CheatCommand(category: "Audio",     syntax: "extract audio from video",           example: "extract audio from video"),
    CheatCommand(category: "Audio",     syntax: "mute video",                         example: "mute video"),
    CheatCommand(category: "Rotate",    syntax: "rotate video [degrees]",             example: "rotate video 90"),
    CheatCommand(category: "Flip",      syntax: "flip video horizontal",              example: "flip video horizontal"),
    CheatCommand(category: "Flip",      syntax: "flip video vertical",                example: "flip video vertical"),
    CheatCommand(category: "Thumbnail", syntax: "thumbnail video at [time]",          example: "thumbnail video at 0:05"),
    CheatCommand(category: "FPS",       syntax: "fps video to [n]",                   example: "fps video to 30"),
    CheatCommand(category: "Loop",      syntax: "loop video [n] times",               example: "loop video 3 times"),
    CheatCommand(category: "Stabilize", syntax: "stabilize video",                    example: "stabilize video"),
    CheatCommand(category: "Denoise",   syntax: "denoise video",                      example: "denoise video"),
    CheatCommand(category: "Grayscale", syntax: "grayscale video",                    example: "grayscale video"),
]

struct CheatSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Command Cheat Sheet")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(commands) { cmd in
                        HStack(alignment: .top, spacing: 12) {
                            Text(cmd.category)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 64, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(cmd.syntax)
                                    .font(.system(.body, design: .monospaced))
                                Text(cmd.example)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)

                        Divider()
                            .padding(.leading, 88)
                    }
                }
                .padding(.vertical, 4)
            }

        }
        .frame(width: 400, height: 480)
    }
}

#Preview {
    CheatSheetView()
}

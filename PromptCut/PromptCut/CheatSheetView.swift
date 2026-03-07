import SwiftUI

struct CheatCommand: Identifiable {
    let id = UUID()
    let category: String
    let syntax: String
    let example: String
}

private let commands: [CheatCommand] = [
    CheatCommand(category: "Trim",    syntax: "trim video from [start] to [end]",    example: "trim video from 0:30 to 1:00"),
    CheatCommand(category: "Convert", syntax: "convert video to [format]",             example: "convert video to gif"),
    CheatCommand(category: "Compress",syntax: "compress video to [size]mb",           example: "compress video to 10mb"),
    CheatCommand(category: "Resize",  syntax: "resize video to [resolution]",         example: "resize video to 720p"),
    CheatCommand(category: "Speed",   syntax: "speed up video by [n]x",               example: "speed up video by 2x"),
    CheatCommand(category: "Speed",   syntax: "slow down video by [n]x",              example: "slow down video by 2x"),
    CheatCommand(category: "Reverse", syntax: "reverse video",                        example: "reverse video"),
    CheatCommand(category: "Audio",   syntax: "extract audio from video",             example: "extract audio from video"),
    CheatCommand(category: "Audio",   syntax: "mute video",                           example: "mute video"),
    CheatCommand(category: "Rotate",  syntax: "rotate video [degrees]",               example: "rotate video 90"),
    CheatCommand(category: "Flip",    syntax: "flip video horizontal",                example: "flip video horizontal"),
    CheatCommand(category: "Flip",    syntax: "flip video vertical",                  example: "flip video vertical"),
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

            Divider()

            Text("Use **video** as the placeholder for the current file.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
        .frame(width: 400, height: 480)
    }
}

#Preview {
    CheatSheetView()
}

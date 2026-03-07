import Foundation

// MARK: - Result types

struct FFmpegCommand {
    let args: [String]      // passed directly to the ffmpeg process
    let outputPath: String  // last element of args; extracted for convenience
}

enum ParseError: LocalizedError {
    case unrecognized(String)
    var errorDescription: String? {
        if case .unrecognized(let s) = self {
            return "Could not understand: \"\(s)\". Open the Cheat Sheet for syntax."
        }
        return nil
    }
}

// MARK: - Parser

/// Translates plain-English commands into ffmpeg arguments.
/// Mirrors the pattern set from ezff (https://www.npmjs.com/package/ezff).
/// The caller substitutes the "video" placeholder with the real file path before calling parse().
enum CommandParser {

    static func parse(_ raw: String, inputPath: String) throws -> FFmpegCommand {
        let t = raw.trimmingCharacters(in: .whitespaces)

        // ── convert to gif ───────────────────────────────────────────────────
        if t.matches(#"^gif\s+"#) || (t.contains("convert") && t.contains("gif")) {
            let out = outputPath(for: inputPath, ext: "gif")
            return cmd(["-i", inputPath,
                        "-vf", "fps=15,scale=480:-1:flags=lanczos",
                        "-loop", "0", "-y", out])
        }

        // ── convert to [audio format] ────────────────────────────────────────
        let audioFormats = ["mp3","wav","aac","flac","ogg","m4a"]
        if t.matches(#"^convert\s+.+\s+to\s+(\w+)$"#),
           let fmt = t.capture(#"to\s+(\w+)$"#),
           audioFormats.contains(fmt) {
            let out = outputPath(for: inputPath, ext: fmt)
            return cmd(["-i", inputPath, "-vn", "-y", out])
        }

        // ── convert to [video format] ────────────────────────────────────────
        if t.matches(#"^convert\s+.+\s+to\s+(\w+)$"#),
           let fmt = t.capture(#"to\s+(\w+)$"#) {
            let out = outputPath(for: inputPath, ext: fmt)
            return cmd(["-i", inputPath, "-y", out])
        }

        // ── compress to [N] mb/kb/gb ─────────────────────────────────────────
        if t.matches(#"^compress\s+.+\s+to\s+\d"#),
           let sizeStr = t.capture(#"to\s+(\d+(?:\.\d+)?)\s*(?:mb|kb|gb)?"#),
           let size = Double(sizeStr) {
            let unit = t.contains("gb") ? "gb" : t.contains("kb") ? "kb" : "mb"
            let crf: Int
            switch (unit, size) {
            case ("mb", _) where size <= 5:  crf = 32
            case ("mb", _) where size <= 10: crf = 28
            case ("mb", _) where size <= 20: crf = 24
            default:                         crf = 20
            }
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath,
                        "-c:v", "libx264", "-crf", "\(crf)",
                        "-preset", "medium",
                        "-c:a", "aac", "-b:a", "128k",
                        "-y", out])
        }

        // ── extract audio ────────────────────────────────────────────────────
        if t.matches(#"^extract\s+audio"#) {
            let out = outputPath(for: inputPath, ext: "mp3")
            return cmd(["-i", inputPath,
                        "-vn", "-acodec", "libmp3lame", "-q:a", "2",
                        "-y", out])
        }

        // ── scale to [N]p ────────────────────────────────────────────────────
        if t.matches(#"(?:resize|scale)\s+.+\s+to\s+\d+p"#),
           let h = t.capture(#"to\s+(\d+)p"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "scale=-2:\(h)", "-y", out])
        }

        // ── resize to WxH ────────────────────────────────────────────────────
        if t.matches(#"resize\s+.+\s+to\s+\d+x\d+"#),
           let w = t.capture(#"to\s+(\d+)x\d+"#),
           let h = t.capture(#"to\s+\d+x(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "scale=\(w):\(h)", "-y", out])
        }

        // ── trim / cut ───────────────────────────────────────────────────────
        // Timestamp pattern accepts: 0:30  1:00:00  30  30s  1m  1m30s  1.5s  90
        if t.matches(#"^(?:trim|cut)\s+"#),
           let start = t.capture(#"from\s+([\d:\.hms]+)"#),
           let end   = t.capture(#"to\s+([\d:\.hms]+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            // -ss before -i = input seeking: snaps to a keyframe so output starts clean (no black frames).
            // Use -t (duration) instead of -to because with input seeking -to is relative to output start.
            let startSec   = String(format: "%.3f", timeToSeconds(start))
            let duration   = String(format: "%.3f", timeToSeconds(end) - timeToSeconds(start))
            return cmd(["-ss", startSec, "-i", inputPath, "-t", duration, "-c", "copy", "-reset_timestamps", "1", "-y", out])
        }

        // ── speed up ─────────────────────────────────────────────────────────
        if t.matches(#"^speed\s+up"#),
           let fStr = t.capture(#"(?:by\s+)?(\d+(?:\.\d+)?)[x×]?"#, after: "up"),
           let factor = Double(fStr) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath,
                        "-vf", "setpts=PTS/\(factor)",
                        "-af", chainedAtempo(factor),
                        "-y", out])
        }

        // ── slow down ────────────────────────────────────────────────────────
        if t.matches(#"^(?:slow\s+down|slowdown)"#),
           let fStr = t.capture(#"(?:by|to)\s+(\d+(?:\.\d+)?)[x×]?"#),
           let factor = Double(fStr) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath,
                        "-vf", "setpts=PTS*\(factor)",
                        "-af", chainedAtempo(1.0 / factor),
                        "-y", out])
        }

        // ── reverse ──────────────────────────────────────────────────────────
        if t.matches(#"^reverse\s+"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "reverse", "-af", "areverse", "-y", out])
        }

        // ── mute / remove audio ───────────────────────────────────────────────
        if t.matches(#"^mute\s+"#) || t.matches(#"^remove\s+audio"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-c", "copy", "-an", "-y", out])
        }

        // ── thumbnail / frame / screenshot ───────────────────────────────────
        if t.matches(#"^(?:thumbnail|frame|screenshot)\s+"#),
           let time = t.capture(#"at\s+([\d:\.]+)"#) {
            let out = outputPath(for: inputPath, ext: "jpg")
            return cmd(["-i", inputPath, "-ss", time, "-vframes", "1", "-y", out])
        }

        // ── rotate ───────────────────────────────────────────────────────────
        if t.matches(#"^rotate\s+"#),
           let degStr = t.capture(#"(?:by\s+)?(\d+)"#, after: "rotate"),
           let deg = Int(degStr) {
            let filter: String
            switch ((deg % 360 + 360) % 360) {
            case 90:  filter = "transpose=1"
            case 180: filter = "transpose=1,transpose=1"
            case 270: filter = "transpose=2"
            default:  filter = "rotate=\(deg)*PI/180"
            }
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", filter, "-y", out])
        }

        // ── crop to WxH ──────────────────────────────────────────────────────
        if t.matches(#"^crop\s+.+\s+to\s+\d+x\d+"#),
           let w = t.capture(#"to\s+(\d+)x\d+"#),
           let h = t.capture(#"to\s+\d+x(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "crop=\(w):\(h)", "-y", out])
        }

        // ── fps ───────────────────────────────────────────────────────────────
        if t.matches(#"^(?:fps|framerate|change\s+fps)"#),
           let fps = t.capture(#"to\s+(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "fps=\(fps)", "-y", out])
        }

        // ── loop ─────────────────────────────────────────────────────────────
        if t.matches(#"^loop\s+"#),
           let nStr = t.capture(#"(\d+)\s*(?:times?)?"#, after: "loop"),
           let n = Int(nStr) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-stream_loop", "\(n - 1)", "-i", inputPath, "-c", "copy", "-y", out])
        }

        // ── stabilize ────────────────────────────────────────────────────────
        if t.matches(#"^(?:stabilize|stabilise)\s+"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "deshake", "-y", out])
        }

        // ── denoise ───────────────────────────────────────────────────────────
        if t.matches(#"^(?:denoise|reduce\s+noise)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "hqdn3d", "-y", out])
        }

        // ── grayscale / black and white ───────────────────────────────────────
        if t.matches(#"(?:grayscale|greyscale|black.and.white|\bbw\b)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "format=gray", "-y", out])
        }

        // ── flip ─────────────────────────────────────────────────────────────
        if t.matches(#"^flip\s+"#) {
            let isHorizontal = t.contains("horiz") || t.hasSuffix(" h")
            let filter = isHorizontal ? "hflip" : "vflip"
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", filter, "-y", out])
        }

        throw ParseError.unrecognized(raw)
    }

    // MARK: - Helpers

    private static func cmd(_ args: [String]) -> FFmpegCommand {
        FFmpegCommand(args: args, outputPath: args.last!)
    }

    private static func outputPath(for inputPath: String, ext: String) -> String {
        let url = URL(fileURLWithPath: inputPath)
        let dir = url.deletingLastPathComponent().path
        let base = url.deletingPathExtension().lastPathComponent
        let e = ext.hasPrefix(".") ? ext : ".\(ext)"
        return "\(dir)/\(base)_output\(e)"
    }

    /// Converts many timestamp formats to total seconds.
    /// Accepts: 0:30  1:00  1:30:00  30  90  30s  1m  1m30s  1h  1h30m15s  1.5s  500ms
    static func timeToSeconds(_ time: String) -> Double {
        let t = time.lowercased().trimmingCharacters(in: .whitespaces)

        // Colon format: [H:]M:S[.ms]
        if t.contains(":") {
            let parts = t.components(separatedBy: ":").compactMap { Double($0) }
            switch parts.count {
            case 2: return parts[0] * 60 + parts[1]
            case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
            default: return 0
            }
        }

        // Plain number → seconds
        if let s = Double(t) { return s }

        // Compound unit format: 1h30m15s, 1m30s, 30s, 500ms, 1h, etc.
        var total = 0.0
        // Order matters: "ms" before "m" and "s" to avoid partial matches
        let pattern = #"(\d+(?:\.\d+)?)(ms|h|m|s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let ns = t as NSString
        let matches = regex.matches(in: t, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            guard let vRange = Range(m.range(at: 1), in: t),
                  let uRange = Range(m.range(at: 2), in: t),
                  let value  = Double(t[vRange]) else { continue }
            switch t[uRange] {
            case "h":  total += value * 3600
            case "m":  total += value * 60
            case "s":  total += value
            case "ms": total += value / 1000
            default: break
            }
        }
        return total
    }

    /// Builds a chain of atempo filters valid for any speed factor.
    /// ffmpeg's atempo filter only accepts values in [0.5, 2.0], so we chain.
    private static func chainedAtempo(_ factor: Double) -> String {
        var remaining = factor
        var filters: [String] = []
        while remaining > 2.0 { filters.append("atempo=2.0"); remaining /= 2.0 }
        while remaining < 0.5 { filters.append("atempo=0.5"); remaining /= 0.5 }
        filters.append(String(format: "atempo=%.6g", remaining))
        return filters.joined(separator: ",")
    }
}

// MARK: - String regex helpers

private extension String {
    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Returns the first capture group of `pattern`.
    /// If `after` is provided, only searches the substring after that word.
    func capture(_ pattern: String, after keyword: String? = nil) -> String? {
        let haystack: String
        if let kw = keyword,
           let r = range(of: kw, options: .caseInsensitive),
           r.upperBound < endIndex {
            haystack = String(self[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            haystack = self
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: haystack) else { return nil }
        return String(haystack[range])
    }
}

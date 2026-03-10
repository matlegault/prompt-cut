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
/// The caller substitutes the "video" placeholder with the real file path before calling parse().
enum CommandParser {

    /// - Parameter sourceBitrateKbps: video stream bitrate in kbps (used to match quality on re-encode).
    /// - Parameter durationSeconds: total duration in seconds (used to calculate target bitrate for compression).
    static func parse(_ raw: String, inputPath: String, sourceBitrateKbps: Int? = nil, durationSeconds: Double? = nil) throws -> FFmpegCommand {
        let t = raw.trimmingCharacters(in: .whitespaces)

        // ── convert to gif / audio / video format ────────────────────────────
        if t.matches(#"^gif\s+"#) || (t.contains("convert") && t.contains("gif")) {
            let out = outputPath(for: inputPath, ext: "gif")
            let original = t.contains("original")
            let filters = original
                ? "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=sierra2_4a"
                : "fps=15,scale='min(480,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=sierra2_4a"
            return cmd(["-i", inputPath,
                        "-filter_complex", filters,
                        "-loop", "0", "-y", out], hwAccel: false)
        }

        if t.matches(#"^convert\s+.+\s+to\s+(\w+)"#),
           let fmt = t.capture(#"to\s+(\w+)"#) {
            let out = outputPath(for: inputPath, ext: fmt)
            if Self.audioFormats.contains(fmt) {
                return cmd(["-i", inputPath, "-vn", "-y", out])
            }
            return cmd(["-i", inputPath, "-y", out])
        }

        // ── compress to [N] mb/kb/gb ─────────────────────────────────────────
        if t.matches(#"^compress\s+.+\s+to\s+\d"#),
           let sizeStr = t.capture(#"to\s+(\d+(?:\.\d+)?)\s*(?:mb|kb|gb)?"#),
           let size = Double(sizeStr), size > 0 {
            let ext = URL(fileURLWithPath: inputPath).pathExtension
            let out = outputPath(for: inputPath, ext: ext)
            let unit = t.contains("gb") ? "gb" : t.contains("kb") ? "kb" : "mb"

            // GIF: dynamically compress by adjusting fps, resolution, and colors
            // based on the ratio of actual file size to target size.
            if ext.lowercased() == "gif" {
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int64) ?? 0
                let targetBytes: Int64
                switch unit {
                case "kb": targetBytes = Int64(size * 1024)
                case "gb": targetBytes = Int64(size * 1_073_741_824)
                default:   targetBytes = Int64(size * 1_048_576)
                }

                let ratio = fileSize > 0 ? Double(fileSize) / Double(targetBytes) : 2.0

                if ratio <= 1.0 {
                    // Already under target — just re-encode with full quality
                    let filters = "split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse=dither=sierra2_4a"
                    return cmd(["-i", inputPath,
                                "-filter_complex", filters,
                                "-loop", "0", "-y", out])
                }

                // Add a 25% safety margin so we land under the target
                let R = ratio * 1.25

                // GIF size ≈ k × fps × width × height × log2(colors)
                // Distribute reduction across 3 levers: fps, scale² (area), colors
                // Each lever gets an equal share: factor^(1/3) of the total reduction
                let fpsFactor   = 1.0 / pow(R, 1.0 / 3.0)
                let scaleFactor = 1.0 / pow(R, 1.0 / 6.0)  // sqrt of (1/R)^(1/3) since area is quadratic
                let colorFactor = 1.0 / pow(R, 1.0 / 3.0)

                let targetFps = max(5, min(30, Int(round(20.0 * fpsFactor))))
                let colors    = max(16, min(256, Int(round(256.0 * colorFactor))))

                var filters = "fps=\(targetFps)"
                if scaleFactor < 0.95 {
                    let pct = String(format: "%.2f", scaleFactor)
                    filters += ",scale='trunc(iw*\(pct)/2)*2':'trunc(ih*\(pct)/2)*2':flags=lanczos"
                }
                filters += ",split[s0][s1];[s0]palettegen=max_colors=\(colors)[p];[s1][p]paletteuse=dither=sierra2_4a"

                return cmd(["-i", inputPath,
                            "-filter_complex", filters,
                            "-loop", "0", "-y", out])
            }
            // Video: calculate bitrate from target size and duration
            let targetBytes: Double
            switch unit {
            case "kb": targetBytes = size * 1024
            case "gb": targetBytes = size * 1_073_741_824
            default:   targetBytes = size * 1_048_576
            }

            let audioBitrateKbps = 128.0
            let dur = durationSeconds ?? 0

            let bitrate: String
            if dur > 0 {
                // total bitrate = (targetBytes × 8) / duration, then subtract audio
                let totalBitrateKbps = (targetBytes * 8.0) / (dur * 1000.0)
                let videoBitrateKbps = max(100, totalBitrateKbps - audioBitrateKbps)
                if videoBitrateKbps >= 1000 {
                    bitrate = "\(Int(round(videoBitrateKbps / 1000.0)))M"
                } else {
                    bitrate = "\(Int(round(videoBitrateKbps)))k"
                }
            } else {
                // Fallback if duration is unknown — use source bitrate scaled by file size ratio
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int64).flatMap { Double($0) } ?? 0
                if fileSize > 0, let srcBr = sourceBitrateKbps {
                    let ratio = targetBytes / fileSize
                    let videoBitrateKbps = max(100, Double(srcBr) * ratio)
                    bitrate = videoBitrateKbps >= 1000 ? "\(Int(round(videoBitrateKbps / 1000.0)))M" : "\(Int(round(videoBitrateKbps)))k"
                } else {
                    bitrate = "2M"
                }
            }

            return cmd(["-i", inputPath,
                        "-c:v", "h264_videotoolbox", "-b:v", bitrate,
                        "-c:a", "aac", "-b:a", "\(Int(audioBitrateKbps))k",
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
            return cmd(["-i", inputPath, "-vf", "scale=-2:\(h)", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── resize to WxH ────────────────────────────────────────────────────
        if t.matches(#"(?:resize|scale)\s+.+\s+to\s+\d+x\d+"#),
           let w = t.capture(#"to\s+(\d+)x\d+"#),
           let h = t.capture(#"to\s+\d+x(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "scale=\(w):\(h)", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── trim / cut ───────────────────────────────────────────────────────
        // Timestamp pattern accepts: 0:30  1:00:00  30  30s  1m  1m30s  1.5s  90
        if t.matches(#"^(?:trim|cut)\s+"#),
           let start = t.capture(#"from\s+([\d:\.hms]+)"#),
           let end   = t.capture(#"to\s+([\d:\.hms]+)"#) {
            let startSeconds = timeToSeconds(start)
            let endSeconds   = timeToSeconds(end)
            guard endSeconds > startSeconds else {
                throw ParseError.unrecognized("End time must be after start time")
            }
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            // -ss before -i = input seeking: snaps to a keyframe so output starts clean (no black frames).
            // Use -t (duration) instead of -to because with input seeking -to is relative to output start.
            let startSec   = String(format: "%.3f", startSeconds)
            let duration   = String(format: "%.3f", endSeconds - startSeconds)
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
                        "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── slow down ────────────────────────────────────────────────────────
        if t.matches(#"^(?:slow\s+down|slowdown)"#),
           let fStr = t.capture(#"(?:by|to)\s+(\d+(?:\.\d+)?)[x×]?"#),
           let factor = Double(fStr) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath,
                        "-vf", "setpts=PTS*\(factor)",
                        "-af", chainedAtempo(1.0 / factor),
                        "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── reverse ──────────────────────────────────────────────────────────
        if t.matches(#"^reverse\s+"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "reverse", "-af", "areverse", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
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
            return cmd(["-i", inputPath, "-vf", filter, "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── crop to WxH ──────────────────────────────────────────────────────
        if t.matches(#"^crop\s+.+\s+to\s+\d+x\d+"#),
           let w = t.capture(#"to\s+(\d+)x\d+"#),
           let h = t.capture(#"to\s+\d+x(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "crop=\(w):\(h)", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── fps ───────────────────────────────────────────────────────────────
        if t.matches(#"^(?:fps|framerate|change\s+fps)"#),
           let fps = t.capture(#"to\s+(\d+)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "fps=\(fps)", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
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
            return cmd(["-i", inputPath, "-vf", "deshake", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── denoise ───────────────────────────────────────────────────────────
        if t.matches(#"^(?:denoise|reduce\s+noise)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "hqdn3d", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── grayscale / black and white ───────────────────────────────────────
        if t.matches(#"^(?:grayscale|greyscale|black.and.white|bw\b)"#) {
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", "format=gray", "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        // ── flip ─────────────────────────────────────────────────────────────
        if t.matches(#"^flip\s+"#) {
            let isHorizontal = t.contains("horiz") || t.hasSuffix(" h")
            let filter = isHorizontal ? "hflip" : "vflip"
            let out = outputPath(for: inputPath, ext: URL(fileURLWithPath: inputPath).pathExtension)
            return cmd(["-i", inputPath, "-vf", filter, "-y", out], hwAccel: true, bitrateKbps: sourceBitrateKbps)
        }

        throw ParseError.unrecognized(raw)
    }

    // MARK: - Helpers

    private static let audioFormats: Set<String> = ["mp3", "wav", "aac", "flac", "ogg", "m4a"]

    /// Wraps args with `-threads 0` and, when re-encoding video, hardware acceleration via VideoToolbox.
    /// Uses the source bitrate to preserve quality; falls back to 20 Mbps if unknown.
    private static let gifFormats: Set<String> = ["gif"]

    private static func cmd(_ args: [String], hwAccel: Bool = false, bitrateKbps: Int? = nil) -> FFmpegCommand {
        var final_args = ["-threads", "0"] + args
        let outputExt = URL(fileURLWithPath: final_args.last ?? "").pathExtension.lowercased()
        // VideoToolbox can't encode GIFs — skip hw accel for image outputs
        if hwAccel, !gifFormats.contains(outputExt), let yIdx = final_args.lastIndex(of: "-y") {
            // VideoToolbox requires nv12 pixel format — append it to any existing -vf chain
            if let vfIdx = final_args.firstIndex(of: "-vf"),
               vfIdx + 1 < final_args.count {
                final_args[vfIdx + 1] += ",format=nv12"
            } else {
                final_args.insert(contentsOf: ["-vf", "format=nv12"], at: yIdx)
            }
            let br = bitrateKbps.map { "\($0)k" } ?? "20M"
            final_args.insert(contentsOf: ["-c:v", "h264_videotoolbox", "-b:v", br], at: final_args.lastIndex(of: "-y")!)
        }
        return FFmpegCommand(args: final_args, outputPath: final_args.last!)
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

import Foundation

/// Outcome of a playlist resolve.
enum PlaylistResult {
    case playlist(title: String?, tracks: [Track])
    case failure(String)
}

/// Thin wrapper around the `yt-dlp` command-line tool. Two operations are used:
///   1. Resolve a playlist to flat metadata (title/artist/duration) as JSON.
///   2. Download a single track's audio as m4a.
enum YTDLP {
    /// Homebrew bin folders. An app started from Finder or `open` gets a PATH without them, and
    /// then yt-dlp cannot find ffmpeg for the m4a step.
    private static let toolDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The yt-dlp binary: `$YTDLP_PATH`, else the first Homebrew install found.
    static var binary: String {
        if let p = ProcessInfo.processInfo.environment["YTDLP_PATH"] { return p }
        return toolDirs.map { $0 + "/yt-dlp" }.first(where: FileManager.default.isExecutableFile(atPath:))
            ?? "/opt/homebrew/bin/yt-dlp"
    }

    static func isInstalled() -> Bool {
        FileManager.default.isExecutableFile(atPath: binary)
    }

    /// Append a timestamped record of every yt-dlp invocation to ~/Library/Logs/Platter/yt-dlp.log.
    static func log(_ line: String) {
        let fm = FileManager.default
        let dir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Platter", isDirectory: true)
        guard let dir else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("yt-dlp.log")
        let entry = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
        if let data = entry.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Run a command, returning (stdout, stderr, exitCode). Blocks the calling thread; use
    /// `runAsync` from async code.
    ///
    /// IMPORTANT: both pipes must be drained concurrently. Reading one to the end before the
    /// other deadlocks as soon as output exceeds the ~64 KB OS pipe buffer (a 111-track playlist
    /// dump is ~250 KB): yt-dlp blocks on a full pipe, and waitUntilExit blocks on yt-dlp.
    /// A watchdog also kills the process after `timeout` so a hung yt-dlp cannot freeze the UI.
    static func run(_ arguments: [String], workingDirectory: URL? = nil, timeout: TimeInterval = 300) -> (stdout: String, stderr: String, exit: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = arguments
        if let wd = workingDirectory { p.currentDirectoryURL = wd }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (toolDirs + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        do {
            try p.run()
        } catch {
            log("LAUNCH FAILED args=\(arguments.joined(separator: " ")) err=\(error.localizedDescription)")
            return ("", "could not launch yt-dlp: \(error.localizedDescription)", -1)
        }
        log("RUN args=\(arguments.joined(separator: " "))")

        // Watchdog: terminate a hung process so the UI is never stuck forever.
        let watchdog = DispatchWorkItem {
            if p.isRunning {
                p.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        // One blocking full-read per pipe, each on its own thread. readDataToEndOfFile
        // returns at EOF, so neither pipe can back up and stall the child. (The group
        // provides the happens-before edge that makes outData/errData visible after wait.)
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        watchdog.cancel()
        p.waitUntilExit()

        let stderr = String(data: errData, encoding: .utf8) ?? ""
        log("EXIT=\(p.terminationStatus) stderr=\(stderr.prefix(4000))")
        return (String(data: outData, encoding: .utf8) ?? "",
                stderr,
                p.terminationStatus)
    }

    /// `run` on a GCD thread, so a blocked yt-dlp never holds a Swift concurrency thread.
    static func runAsync(_ arguments: [String], timeout: TimeInterval = 300) async -> (stdout: String, stderr: String, exit: Int32) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: run(arguments, timeout: timeout))
            }
        }
    }

    /// Resolve a playlist URL to its title and flat track metadata.
    static func playlist(url: String) async -> PlaylistResult {
        let r = await runAsync(["--flat-playlist", "--dump-single-json", "--no-warnings", url], timeout: 120)
        guard r.exit == 0 else {
            return .failure(r.stderr.isEmpty ? "yt-dlp exited \(r.exit)" : r.stderr.trimmed)
        }
        let tracks = parseFlatJSON(r.stdout)
        guard !tracks.isEmpty else {
            return .failure("yt-dlp returned no tracks. Make sure the playlist is public.")
        }
        return .playlist(title: parsePlaylistTitle(r.stdout), tracks: tracks)
    }

    /// Download one video's audio as `<id>.m4a` into `directory`. The download runs in a
    /// private temp folder and moves in only when complete, so a failed or killed run never
    /// leaves a partial file where the library looks for audio. Returns the file name.
    static func download(id: String, into directory: URL) async throws -> String {
        let fm = FileManager.default
        let tmp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // A URL, never the bare id: a video id can start with "-" and would read as a flag.
        let r = await runAsync([
            "-f", "bestaudio[ext=m4a]/bestaudio/best",
            "-x", "--audio-format", "m4a",
            "--no-playlist", "--no-warnings",
            "-o", tmp.path + "/%(id)s.%(ext)s",
            "https://www.youtube.com/watch?v=\(id)",
        ])
        guard r.exit == 0 else {
            throw LibraryError(r.stderr.isEmpty ? "Download failed (yt-dlp exited \(r.exit))." : r.stderr.trimmed)
        }
        let name = "\(id).m4a"
        let src = tmp.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else {
            throw LibraryError("yt-dlp finished but wrote no m4a file. Is ffmpeg installed?")
        }
        let dst = directory.appendingPathComponent(name)
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: src, to: dst)
        return name
    }

    /// Parse the flat-playlist JSON. `--flat-playlist --dump-single-json` emits one object with
    /// an `entries` array. Also accepts a bare array or newline-delimited objects.
    static func parseFlatJSON(_ text: String) -> [Track] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = Data(trimmed.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Primary shape: a playlist object with an "entries" array.
        if trimmed.hasPrefix("{"), let pl = try? decoder.decode(PlaylistObject.self, from: data),
           let entries = pl.entries {
            return entries.map { toTrack($0) }
        }
        // Fallback: a bare array of entries.
        if trimmed.hasPrefix("["), let arr = try? decoder.decode([FlatEntry].self, from: data) {
            return arr.map { toTrack($0) }
        }
        // Fallback: newline-delimited entry objects.
        var tracks: [Track] = []
        for line in trimmed.split(whereSeparator: { $0 == "\n" }) {
            guard !line.isEmpty else { continue }
            if let e = try? decoder.decode(FlatEntry.self, from: Data(line.utf8)) {
                tracks.append(toTrack(e))
            }
        }
        return tracks
    }

    /// The playlist title from the top-level object, or `nil` for the other shapes.
    static func parsePlaylistTitle(_ text: String) -> String? {
        let data = Data(text.utf8)
        guard let pl = try? JSONDecoder().decode(PlaylistObject.self, from: data),
              let title = pl.title?.trimmed, !title.isEmpty else { return nil }
        return title
    }

    private static func toTrack(_ e: FlatEntry) -> Track {
        let title = (e.title ?? e.artist ?? e.id).trimmingCharacters(in: .whitespacesAndNewlines)
        return Track(id: e.id, title: title, artist: e.artist ?? "", duration: e.duration)
    }
}

/// Top-level playlist object emitted by `--dump-single-json` (has an "entries" array).
private struct PlaylistObject: Decodable {
    let title: String?
    let entries: [FlatEntry]?
}

/// Minimal flat-playlist entry shape. yt-dlp names the artist differently per extractor:
/// `channel`, `uploader`, or `creator`. We take the first one present.
private struct FlatEntry: Decodable {
    let id: String
    let title: String?
    let artist: String?
    let duration: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        artist = try (
            c.decodeIfPresent(String.self, forKey: .channel)
            ?? c.decodeIfPresent(String.self, forKey: .uploader)
            ?? c.decodeIfPresent(String.self, forKey: .creator)
        )
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, channel, uploader, creator, duration
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

import Foundation

/// Process-based wrapper around the vendored `rg` binary. Launches ripgrep
/// with `--json` output, streams stdout line-by-line, and turns it into
/// `[FileSearchHit]`. Honours `.gitignore` (rg's default), case-insensitive
/// match (`-i`), and includes ±1 line of context.
///
/// The binary ships under `Sources/BentoCore/Resources/rg` (Universal2,
/// resolved via `Bundle.module`). When the binary is absent (e.g. local
/// fresh-clone where `scripts/install-rg.sh` hasn't been run) `bundled()`
/// returns nil and callers should fall through to the Swift scanner.
public struct RipgrepFileSearch: Sendable {
    /// Absolute path to the executable launched by `Process`.
    public let binaryURL: URL

    /// Time budget for one search. Default is 500 ms (S-3 target for a
    /// 10-MB project). When the budget is exceeded, the rg process is
    /// terminated and whatever hits have been parsed so far are returned.
    public var timeLimit: TimeInterval

    public init(binaryURL: URL, timeLimit: TimeInterval = 0.5) {
        self.binaryURL = binaryURL
        self.timeLimit = timeLimit
    }

    /// Locate the bundled `rg`. Returns nil when the resource isn't
    /// present (callers should fall back to the Swift scanner).
    public static func bundled(timeLimit: TimeInterval = 0.5) -> RipgrepFileSearch? {
        guard let url = Bundle.module.url(forResource: "rg", withExtension: nil) else {
            return nil
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return RipgrepFileSearch(binaryURL: url, timeLimit: timeLimit)
    }

    /// Run rg against `root`, returning a flat list of `FileSearchHit`.
    /// Honours `.gitignore`. Cancels cleanly when the calling Task is
    /// cancelled or when `timeLimit` is exceeded.
    public func search(query: String, root: URL) throws -> [FileSearchHit] {
        guard !query.isEmpty else { return [] }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--json",
            "--no-heading",
            "--line-number",
            "--context", "1",
            "-i",
            "--", query, root.path
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        // Detach from any controlling tty so rg never tries to read from
        // stdin (it would otherwise block on an empty pipe).
        process.standardInput = FileHandle.nullDevice

        try process.run()

        let deadline = Date().addingTimeInterval(timeLimit)

        // Read stdout to EOF (or until deadline / cancellation), then
        // parse. rg flushes JSON-per-line; for a 500 ms budget it's
        // simpler — and fast enough — to drain to completion via a
        // background read rather than thread an AsyncSequence through.
        let collector = StreamCollector()
        let readingQueue = DispatchQueue(label: "bento.ripgrep.read")
        readingQueue.async {
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                collector.append(chunk)
            }
        }

        // Poll for completion / cancellation / timeout. 5 ms is a
        // reasonable granularity given the 500 ms budget.
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            if Date() >= deadline {
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()

        // Give the reader queue a brief window to finish draining the
        // pipe after the process exits. Sync barrier is sufficient: we
        // only need to be sure no more `append` calls land mid-parse.
        readingQueue.sync(flags: .barrier) {}

        let data = collector.snapshot()
        return parse(data, root: root)
    }

    // MARK: - JSON parsing

    /// Parse rg's `--json` stream into hits. Each line is a JSON object:
    ///   {"type":"begin","data":{"path":{"text":"…"}}}
    ///   {"type":"context","data":{"path":..., "lines":{"text":"…"}, "line_number":N}}
    ///   {"type":"match",  "data":{"path":..., "lines":{"text":"…"}, "line_number":N}}
    ///   {"type":"end",    "data":...}
    ///
    /// We pair each `match` with its immediately-preceding and immediately-
    /// following `context` lines from the same file.
    private func parse(_ data: Data, root: URL) -> [FileSearchHit] {
        guard !data.isEmpty else { return [] }
        var hits: [FileSearchHit] = []

        // Per-file pending state: the most recent context line and the
        // most recent match awaiting an "after" context.
        var pendingBefore: [String: String] = [:]      // path -> last context line text
        var awaitingAfter: [String: Int] = [:]         // path -> index into `hits` waiting for after

        // Walk lines; each line is one JSON record.
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            for i in 0..<bytes.count {
                if bytes[i] == 0x0A {  // newline
                    let slice = Data(bytes[start..<i])
                    start = i + 1
                    handleRecord(slice, root: root, hits: &hits, pendingBefore: &pendingBefore, awaitingAfter: &awaitingAfter)
                }
            }
            if start < bytes.count {
                let slice = Data(bytes[start..<bytes.count])
                handleRecord(slice, root: root, hits: &hits, pendingBefore: &pendingBefore, awaitingAfter: &awaitingAfter)
            }
        }

        return hits
    }

    private func handleRecord(
        _ data: Data,
        root: URL,
        hits: inout [FileSearchHit],
        pendingBefore: inout [String: String],
        awaitingAfter: inout [String: Int]
    ) {
        guard !data.isEmpty else { return }
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []) else { return }
        guard let obj = raw as? [String: Any] else { return }
        guard let type = obj["type"] as? String else { return }
        let payload = obj["data"] as? [String: Any] ?? [:]

        switch type {
        case "begin":
            if let path = pathString(payload["path"]) {
                pendingBefore[path] = nil
                awaitingAfter[path] = nil
            }
        case "context":
            guard let path = pathString(payload["path"]) else { return }
            guard let text = linesText(payload["lines"]) else { return }
            // If a previous match is waiting for an "after" line, fill it.
            if let pendingIndex = awaitingAfter[path] {
                hits[pendingIndex].contextAfter = stripTrailingNewline(text)
                awaitingAfter[path] = nil
            }
            // Remember this as a potential "before" for the next match.
            pendingBefore[path] = stripTrailingNewline(text)
        case "match":
            guard let path = pathString(payload["path"]) else { return }
            guard let text = linesText(payload["lines"]) else { return }
            let lineNumber = (payload["line_number"] as? Int) ?? 0
            // Resolve display path: prefer relative-to-root for tidy UI,
            // but keep absolute when rg already gave us an absolute path
            // outside root.
            let displayPath = renderPath(path, root: root)
            let hit = FileSearchHit(
                projectRoot: root.path,
                path: displayPath,
                lineNumber: lineNumber,
                line: stripTrailingNewline(text),
                contextBefore: pendingBefore[path],
                contextAfter: nil
            )
            hits.append(hit)
            awaitingAfter[path] = hits.count - 1
            pendingBefore[path] = nil
        case "end":
            if let path = pathString(payload["path"]) {
                awaitingAfter[path] = nil
                pendingBefore[path] = nil
            }
        default:
            break
        }
    }

    private func pathString(_ value: Any?) -> String? {
        if let dict = value as? [String: Any], let text = dict["text"] as? String {
            return text
        }
        return nil
    }

    private func linesText(_ value: Any?) -> String? {
        if let dict = value as? [String: Any], let text = dict["text"] as? String {
            return text
        }
        return nil
    }

    private func stripTrailingNewline(_ s: String) -> String {
        if s.hasSuffix("\n") { return String(s.dropLast()) }
        return s
    }

    private func renderPath(_ rgPath: String, root: URL) -> String {
        // rg echoes whatever path it walked; normalise so the projectRoot
        // prefix matches the value the caller passed in.
        let absolute: String
        if rgPath.hasPrefix("/") {
            absolute = rgPath
        } else {
            absolute = root.appendingPathComponent(rgPath).path
        }
        let canonical = URL(fileURLWithPath: absolute).standardizedFileURL.path
        let canonicalRoot = root.standardizedFileURL.path
        if canonical.hasPrefix(canonicalRoot) {
            return root.path + canonical.dropFirst(canonicalRoot.count)
        }
        return canonical
    }
}

/// Thread-safe accumulator for stdout chunks read off rg's pipe on a
/// background queue. `Process` reads are blocking, but the parse happens
/// after the process exits — so we only need atomic append/snapshot.
private final class StreamCollector: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

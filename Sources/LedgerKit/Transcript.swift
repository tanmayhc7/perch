import Foundation

/// Which model a Claude Code session is using, read from the session's own transcript
/// (`~/.claude/projects/<project>/<session id>.jsonl`): token-meter's ledger only has counts.
///
/// Only the `model` field of the newest assistant message is read; nothing else from the
/// transcript is kept, and only the end of the file is opened.
public enum Transcript {
    /// `$CLAUDE_CONFIG_DIR/projects`, else `~/.claude/projects`: next to token-meter's folder.
    public static var defaultProjectsDirectory: URL {
        Ledger.defaultDirectory.deletingLastPathComponent().appendingPathComponent("projects")
    }

    /// The transcript for a session id, wherever its project folder is (the folder is named after the
    /// directory Claude Code started in, which can differ from the ledger's `cwd`).
    public static func find(sessionID: String, in projects: URL = defaultProjectsDirectory) -> URL? {
        // The id becomes part of a path: only plain ids.
        guard !sessionID.isEmpty, sessionID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// The model of the newest assistant message in the transcript at `url`, or nil.
    /// Reads the last 512 KB, then up to 8 MB if that held no complete assistant line (a huge tool result).
    public static func latestModel(at url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        for window in [UInt64(512 << 10), UInt64(8 << 20)] {
            let from = size > window ? size - window : 0
            guard (try? h.seek(toOffset: from)) != nil, let data = try? h.read(upToCount: Int(size - from)) else { return nil }
            if let m = modelName(inTail: data, startsMidLine: from > 0) { return m }
            if from == 0 { return nil }
        }
        return nil
    }

    /// The model in the newest assistant line of `data`, which is the end of a transcript.
    /// `startsMidLine`: the first line is cut off, so it's skipped.
    public static func modelName(inTail data: Data, startsMidLine: Bool = false) -> String? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        let marker = Data("\"model\"".utf8)
        for line in lines.reversed() {
            // Cheap test first: most lines (user turns, tool results) have no model.
            guard line.range(of: marker) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty,
                  // Claude Code marks its own messages (not from a model) with "<synthetic>".
                  !model.hasPrefix("<") else { continue }
            return model
        }
        return nil
    }

    /// "claude-sonnet-5-5" → "Sonnet 5.5", "claude-3-5-sonnet-20241022" → "Sonnet 3.5",
    /// "claude-opus-4-1[1m]" → "Opus 4.1 (1M)". Anything unrecognised comes back as it is.
    public static func displayName(_ id: String) -> String {
        var s = id.lowercased()
        var context = ""
        if let open = s.firstIndex(of: "["), s.hasSuffix("]") {
            context = String(s[s.index(after: open)..<s.index(before: s.endIndex)]).uppercased()
            s = String(s[..<open])
        }
        guard s.hasPrefix("claude-") else { return id }
        let parts = s.dropFirst("claude-".count).split(separator: "-").map(String.init)
        // A trailing date (20250805) isn't part of the version.
        let tokens = parts.filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) && $0 != "latest" }
        let names = tokens.filter { t in !t.allSatisfy(\.isNumber) }
        let numbers = tokens.filter { $0.allSatisfy(\.isNumber) }
        guard let family = names.first, names.count == 1, numbers.count <= 3 else { return id }
        var out = family.prefix(1).uppercased() + family.dropFirst()
        if !numbers.isEmpty { out += " " + numbers.joined(separator: ".") }
        if !context.isEmpty { out += " (\(context))" }
        return out
    }
}

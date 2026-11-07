import Foundation

/// A one-shot question to Claude Code (`claude -p`), streamed into the notch.
/// Runs with the person's own Claude Code login, from their home folder.
@MainActor @Observable
final class PromptModel {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    var text = ""
    var asked = ""
    var answer = ""
    var phase: Phase = .idle
    var costUSD: Double?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var buffer = Data()

    static let models: [(id: String, name: String)] = [("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")]

    /// The `claude` binary: the usual install places, then the login shell's PATH.
    static func findClaude() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
        if let c = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return c }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return s.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    func send(model: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, phase != .running else { return }
        cancel()
        asked = q
        answer = ""
        costUSD = nil
        text = ""
        phase = .running
        DispatchQueue.global(qos: .userInitiated).async {
            let path = Self.findClaude()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.launch(path, prompt: q, model: model) } }
        }
    }

    private func launch(_ path: String?, prompt: String, model: String) {
        guard phase == .running else { return }
        guard let path else {
            phase = .failed("Couldn't find the `claude` command. Install Claude Code, then try again.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(d) } }
        }
        p.terminationHandler = { [weak self] proc in
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    out.fileHandleForReading.readabilityHandler = nil
                    self.process = nil
                    if self.phase == .running {
                        if proc.terminationStatus == 0 || !self.answer.isEmpty {
                            self.phase = .done
                        } else {
                            self.phase = .failed(e.isEmpty ? "claude exited with status \(proc.terminationStatus)" : String(e.prefix(300)))
                        }
                    }
                }
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func consume(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
    }

    private func handle(_ o: [String: Any]) {
        switch o["type"] as? String {
        case "stream_event":
            if let ev = o["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let t = delta["text"] as? String {
                answer += t
            }
        case "result":
            if let r = o["result"] as? String, answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { answer = r }
            costUSD = o["total_cost_usd"] as? Double
            if o["is_error"] as? Bool == true, answer.isEmpty { phase = .failed("Claude returned an error.") } else { phase = .done }
        default: break
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        if phase == .running { phase = .idle }
    }

    func reset() {
        cancel()
        asked = ""
        answer = ""
        phase = .idle
    }
}

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
        guard (try? p.run()) != nil else { return nil }
        // A login shell can hang (a .zshrc that waits on something); give up after 5 seconds.
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
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
        // The question goes in on stdin, never as an argument: "--help" or "-v" typed into
        // the notch must be a question, not a flag.
        let model = Self.models.contains { $0.id == model } ? model : "haiku"
        p.arguments = ["-p", "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let input = Pipe()
        let out = Pipe()
        let err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        buffer = Data()
        // Each run reads only into its own state, so a cancelled run's last bytes can't
        // land in the next answer.
        let stderrBox = ErrBox()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            // EOF: stop, or the handler fires again and again with nothing.
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.process === p { self?.consume(d) } } }
        }
        // Drain stderr while the process runs: a full pipe would block it forever.
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            stderrBox.append(d)
        }
        p.terminationHandler = { [weak self] proc in
            let e = stderrBox.text
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.process === proc else { return }
                    // Whatever is still in the pipe, then a last line with no newline.
                    if let rest = try? out.fileHandleForReading.readToEnd() { self.consume(rest) }
                    out.fileHandleForReading.readabilityHandler = nil
                    self.consume(Data([0x0A]))
                    self.process = nil
                    if self.phase == .running {
                        if proc.terminationStatus == 0 || !self.answer.isEmpty {
                            self.phase = .done
                        } else {
                            let msg = e.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.phase = .failed(msg.isEmpty ? "claude exited with status \(proc.terminationStatus)" : String(msg.prefix(300)))
                        }
                    }
                }
            }
        }
        do {
            try p.run()
            process = p
            let h = input.fileHandleForWriting
            DispatchQueue.global(qos: .userInitiated).async {
                try? h.write(contentsOf: Data(prompt.utf8))
                try? h.close()
            }
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            phase = .failed(error.localizedDescription)
        }
    }

    private func consume(_ d: Data) {
        guard !d.isEmpty else { return }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty, let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(obj)
        }
        // A runaway line with no newline: don't let it grow without bound.
        if buffer.count > 8 << 20 { buffer.removeAll() }
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
        buffer = Data()
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

/// Collects stderr from a background thread, capped at 64 KB.
private final class ErrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); if data.count < 64 << 10 { data.append(d) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

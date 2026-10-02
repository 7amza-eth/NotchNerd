//
//  ClaudeCLI.swift
//  NotchNerd
//
//  Finds and runs the `claude` command-line tool. A GUI app doesn't inherit the user's shell PATH,
//  so this checks the usual install locations and falls back to asking a login shell.
//

import Foundation

enum ClaudeCLI {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }

        /// The `--json` result line: the last non-empty stdout line that parses as a JSON object.
        var resultLine: [String: Any]? {
            for line in stdoutText.split(separator: "\n").reversed() {
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return object
                }
            }
            return nil
        }
    }

    enum Failure: LocalizedError {
        case notFound
        case timedOut

        var errorDescription: String? {
            switch self {
            case .notFound: return "Claude Code's claude command wasn't found."
            case .timedOut: return "The claude command took too long and was stopped."
            }
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Extra PATH entries so `claude` can find git (marketplace clones) and node when launched from a GUI app.
    private static let searchPath = [
        "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    private static let lock = NSLock()
    private static var cachedURL: URL?

    /// The claude executable, or nil if Claude Code isn't installed. Cached once found.
    static func locate() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let cachedURL, FileManager.default.isExecutableFile(atPath: cachedURL.path) { return cachedURL }

        let fm = FileManager.default
        if let path = searchPath.map({ "\($0)/claude" }).first(where: { fm.isExecutableFile(atPath: $0) }) {
            cachedURL = URL(fileURLWithPath: path)
            return cachedURL
        }
        // Last resort: the user's login shell knows about nvm, asdf, custom prefixes and the like.
        if let output = try? runSync(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"], timeout: 10),
           output.status == 0 {
            let path = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/"), fm.isExecutableFile(atPath: path) {
                cachedURL = URL(fileURLWithPath: path)
                return cachedURL
            }
        }
        return nil
    }

    /// Runs `claude <arguments>` off the main thread. stdin is /dev/null, so the CLI never waits
    /// on a prompt; commands that would need confirmation fail with a message instead.
    static func run(_ arguments: [String], timeout: TimeInterval = 180) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let url = locate() else { throw Failure.notFound }
                    continuation.resume(returning: try runSync(url, arguments, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runSync(_ executable: URL, _ arguments: [String], timeout: TimeInterval) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        let inherited = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (searchPath + inherited).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes concurrently so a chatty command can't fill one and deadlock.
        let group = DispatchGroup()
        var stdout = Data()
        var stderr = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        var timedOut = false
        let killer = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        process.waitUntilExit()
        killer.cancel()
        group.wait()

        if timedOut { throw Failure.timedOut }
        return Output(status: process.terminationStatus, stdout: stdout,
                      stderr: String(decoding: stderr, as: UTF8.self))
    }
}

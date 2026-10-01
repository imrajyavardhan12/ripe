import Foundation

public struct ProcessResult: Sendable, Hashable {
    public var status: Int32
    public var output: String
    public var errorOutput: String

    public var succeeded: Bool { status == 0 }
}

/// Runs other programs (`brew`, `mas`, `hdiutil`, `ditto`, `spctl`). Arguments are always an
/// array handed straight to the executable, never a shell string, so nothing from a feed or
/// catalog can be interpreted by a shell.
public protocol ProcessRunner: Sendable {
    /// `interactive` lets the program use the terminal directly (so `brew` shows its progress)
    /// instead of capturing its output.
    func run(_ executable: URL, _ arguments: [String], interactive: Bool) async throws -> ProcessResult
}

extension ProcessRunner {
    func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessResult {
        try await run(executable, arguments, interactive: false)
    }
}

public struct LiveProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, _ arguments: [String], interactive: Bool) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errorOutput = Pipe()
        if !interactive {
            process.standardOutput = output
            process.standardError = errorOutput
            process.standardInput = FileHandle.nullDevice
        }
        // Read pipes concurrently with the process so a chatty program can't fill the pipe
        // buffer and deadlock waiting for us.
        async let outputData = interactive ? Data() : Self.readToEnd(output)
        async let errorData = interactive ? Data() : Self.readToEnd(errorOutput)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                // Never launched: close our write ends so the readers above see EOF instead of hanging.
                try? output.fileHandleForWriting.close()
                try? errorOutput.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
        return ProcessResult(
            status: status,
            output: String(decoding: await outputData, as: UTF8.self),
            errorOutput: String(decoding: await errorData, as: UTF8.self)
        )
    }

    private static func readToEnd(_ pipe: Pipe) async -> Data {
        await Task.detached { (try? pipe.fileHandleForReading.readToEnd()) ?? Data() }.value
    }
}

/// Finds a command-line tool the way a shell would, plus Homebrew's standard locations, which
/// may be missing from `PATH` when Ripe runs from a launch agent.
public enum ExecutableLocator {
    public static func find(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = path + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/usr/sbin", "/bin"]
        for directory in candidates where !directory.isEmpty {
            let url = URL(filePath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

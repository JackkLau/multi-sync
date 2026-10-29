import Foundation

/// The desktop adapter owns process lifetime. Rust owns transfer state and checkpoints.
@MainActor
public final class EngineProcess {
    private var process: Process?
    private var reader: Task<Void, Never>?
    public init() {}

    public func start(executable: URL, arguments: [String], input: String? = nil,
                      onEvent: @escaping @MainActor (EngineEvent) -> Void,
                      onExit: @escaping @MainActor (Int32) -> Void) throws {
        guard process == nil else { throw EngineError.alreadyRunning }
        let child = Process()
        child.executableURL = executable; child.arguments = arguments
        let output = Pipe(); let stdin = Pipe()
        child.standardOutput = output; child.standardError = output; child.standardInput = stdin
        try child.run()
        process = child
        try output.fileHandleForWriting.close()
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        reader = Task {
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    if let event = try? JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) { onEvent(event) }
                }
            } catch { /* termination or pipe closure; exit code remains authoritative */ }
            while child.isRunning { try? await Task.sleep(nanoseconds: 20_000_000) }
            let status = child.terminationStatus
            try? output.fileHandleForReading.close()
            self.process = nil
            onExit(status)
        }
    }
    public func stop() { if let process, process.isRunning { process.terminate() } }
    public enum EngineError: LocalizedError {
        case alreadyRunning
        public var errorDescription: String? { "该传输进程已在运行" }
    }
}

import Foundation
import TacticalCore

/// Actor managing IPC pipes to the screenenv_container Docker stdio process,
/// wrapping tool execution requests inside the HardwareInterlockGate validation layer.
public actor ContainerSocketBridge {
    private let containerName: String
    private let interlockGate: HardwareInterlockGate
    private let executableURL: URL
    private let customArguments: [String]?
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?

    public init(
        containerName: String = "screenenv_container",
        interlockGate: HardwareInterlockGate,
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        arguments: [String]? = nil
    ) {
        self.containerName = containerName
        self.interlockGate = interlockGate
        self.executableURL = executableURL
        self.customArguments = arguments
    }

    deinit {
        process?.terminate()
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
    }

    /// Whether the underlying stdio process bridge is currently running.
    public var isBridgeActive: Bool {
        process?.isRunning ?? false
    }

    /// Spawns the background stdio process bridge to screenenv_container
    public func launchBridge() throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = customArguments ?? ["docker", "exec", "-i", containerName, "python", "-m", "screenenv.mcp_server"]

        let inPipe = Pipe()
        let outPipe = Pipe()

        // Prevent SIGPIPE process termination when writing to a closed child pipe on Darwin
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        process.standardInput = inPipe
        process.standardOutput = outPipe

        try process.run()

        self.process = process
        self.stdinHandle = inPipe.fileHandleForWriting
        self.stdoutHandle = outPipe.fileHandleForReading
    }

    /// Executes a JSON-RPC payload against the ScreenEnv MCP server if Interlock conditions pass
    public func dispatchMCPCommand(_ payload: Data, isHighRiskAction: Bool) async throws -> Data {
        if isHighRiskAction {
            // Require permissive state from HardwareInterlockGate before passing frame to container
            try await interlockGate.requestPermissive(timeout: .seconds(5))
        }

        guard let stdinHandle = stdinHandle, let stdoutHandle = stdoutHandle else {
            throw HardwareInterlockError.subsystemFailure(reason: "Container stdio bridge handles uninitialized")
        }

        // Write line-delimited JSON-RPC to container stdio.
        // For payloads exceeding the kernel pipe buffer (64 KiB on macOS), drain stdout
        // concurrently while streaming chunks so echo/loopback processes cannot deadlock.
        let chunkSize = 16_384
        if payload.count > chunkSize {
            var accumulated = Data()
            var offset = 0
            do {
                while offset < payload.count {
                    let end = min(offset + chunkSize, payload.count)
                    try stdinHandle.write(contentsOf: payload.subdata(in: offset..<end))
                    offset = end
                    let drained = stdoutHandle.availableData
                    if !drained.isEmpty {
                        accumulated.append(drained)
                    }
                }
                try stdinHandle.write(contentsOf: Data([0x0A]))
            } catch let writeError as NSError {
                throw HardwareInterlockError.subsystemFailure(
                    reason: "Container stdin write failed: \(writeError.localizedDescription) (\(writeError.domain) \(writeError.code))"
                )
            }
            if accumulated.isEmpty {
                accumulated.append(stdoutHandle.availableData)
            }
            return accumulated
        }

        // Catch broken-pipe and other I/O faults (POSIX EPIPE, NSFileHandleOperationException)
        // so they are always surfaced as a typed subsystemFailure rather than raw Foundation errors.
        do {
            try stdinHandle.write(contentsOf: payload)
            try stdinHandle.write(contentsOf: Data([0x0A]))
        } catch let writeError as NSError {
            throw HardwareInterlockError.subsystemFailure(
                reason: "Container stdin write failed: \(writeError.localizedDescription) (\(writeError.domain) \(writeError.code))"
            )
        }

        // Read response payload from stdio handle
        let responseData = stdoutHandle.availableData
        return responseData
    }

    public func terminateBridge() {
        process?.terminate()
        process = nil
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
    }
}

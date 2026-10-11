import Foundation
import TacticalCore
@preconcurrency import Virtualization

/// Lifecycle state for hypervisor virtual machines.
public enum VirtualMachineState: String, Sendable, Hashable, Codable {
    case stopped = "STOPPED"
    case configuring = "CONFIGURING"
    case running = "RUNNING"
    case paused = "PAUSED"
    case error = "ERROR"
}

/// Errors occurring during virtual machine lifecycle management.
public enum VirtualizationError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case unsupportedHardware
    case vmNotRunning
    case executionFailed(String)
}

/// Hypervisor controller managing VZVirtualMachine lifecycle and hardware allocation.
public actor VirtualMachineController {
    private var state: VirtualMachineState
    private let cpuCount: Int
    private let memorySizeMegabytes: UInt64

    public init(cpuCount: Int = 2, memorySizeMegabytes: UInt64 = 2048) {
        self.state = .stopped
        self.cpuCount = cpuCount
        self.memorySizeMegabytes = memorySizeMegabytes
    }

    /// Current execution state of the virtual machine.
    public var currentState: VirtualMachineState {
        state
    }

    /// Prepare virtual machine configuration stub.
    public func configure() throws {
        guard VZVirtualMachine.isSupported else {
            throw VirtualizationError.unsupportedHardware
        }
        guard cpuCount > 0 else {
            throw VirtualizationError.invalidConfiguration("CPU count must be greater than zero")
        }
        self.state = .configuring
    }

    /// Launch guest machine stub.
    public func start() async throws {
        guard state == .configuring || state == .stopped else {
            throw VirtualizationError.executionFailed("Cannot start VM in state \(state)")
        }
        self.state = .running
    }

    /// Pause active execution stub.
    public func pause() async throws {
        guard state == .running else {
            throw VirtualizationError.vmNotRunning
        }
        self.state = .paused
    }

    /// Terminate guest virtual machine stub.
    public func stop() async throws {
        self.state = .stopped
    }
}

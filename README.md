# Tactical Hypervisor

A zero-AI-footprint, high-performance tactical macOS console built on native
Swift 6 actors. `TacticalHypervisor` arbitrates deterministic safety state via a
hardware interlock gate, bridges containerized tooling through Apple's
`Virtualization.framework` and a Docker ScreenEnv MCP stdio pipe, renders
avionics-style synthetic voice alerts through CoreAudio (elevenlabs integration being 
considered), and drives a real-time MetalKit telemetry viewport.

The design intent is determinism and privacy: no conversational AI layer, no
telemetry exfiltration, and no nondeterministic shared mutable state. Every
operational decision passes through an explicitly modelled interlock state
machine.

## Architecture

The package is decomposed into four library targets with a strict, acyclic
dependency graph. `TacticalCore` is the pure-Swift foundation; all other
subsystems depend on it and never on each other.

```
                        ┌───────────────────────────────┐
                        │          TacticalUI           │
                        │  AppKit / MetalKit telemetry  │
                        │   viewport (HUD renderer)     │
                        └───────────────┬───────────────┘
                                        │ depends on
          ┌─────────────────────────────┼─────────────────────────────┐
          │                             │                             │
┌─────────▼──────────┐      ┌───────────▼───────────┐      ┌──────────▼─────────┐
│  TacticalAudioSVS  │      │    TacticalCore       │      │ TacticalVirtualization│
│ CoreAudio tone     │─────▶│  State machine +      │◀─────│ ContainerSocketBridge│
│ synthesizer (SVS   │      │  HardwareInterlockGate│      │ + Docker screenenv   │
│ annunciators)      │      │  TelemetryFrame       │      │ MCP stdio pipe       │
└────────────────────┘      └───────────┬───────────┘      └──────────┬──────────┘
                                        │                             │
                                        └──────── VirtualMachineController
                                             (Apple Virtualization.framework)
```

### TacticalCore
The dependency-free heart of the system. Exposes the `HardwareInterlockGate`
actor — a deterministic safety state machine over four canonical states
(`locked`, `armed`, `permissiveGranted`, `emergencyAbort`) — plus the immutable,
`Sendable` `TelemetryFrame` used for inter-subsystem reporting.

### TacticalVirtualization
Hosts `ContainerSocketBridge`, an actor that manages the JSON-RPC 2.0 stdio pipe
to the Docker `screenenv_container` MCP server, and `VirtualMachineController`,
which models the `VZVirtualMachine` lifecycle. High-risk MCP commands are gated:
the bridge requests permissive clearance from the interlock before dispatch.

### TacticalAudioSVS
A Synthetic Voice System built on `AVFoundation` and `CoreAudio`.
`TacticalToneSynthesizer` generates deterministic sine-wave annunciator cues
(master caution, master warning, altitude alert, terrain proximity, ping) and
`SVSBridge` maps ingested `TelemetryFrame` health/interlock state to the correct
audible alert.

### TacticalUI
The AppKit/MetalKit presentation layer. `TacticalViewController` hosts
`TacticalMetalViewportView`, a `MTKView` driven by `TacticalViewportRenderer`
for real-time telemetry and HUD overlay rendering.

## Prerequisites

- **macOS 14.0+** (deployment target pinned to `.macOS(.v14)` in `Package.swift`)
- **Xcode 15.3+** / **Swift 6 toolchain** (package builds in `.v6` language mode)
- **Docker Desktop** running the ScreenEnv container:
  - Image: `amhma/ubuntu-desktop:22.04-0.1.0`
  - Container name: `screenenv_container`
  - Exposed on port `7860`

The MCP stdio bridge launches via:

```bash
docker exec -i screenenv_container python -m screenenv.mcp_server
```

## Build & Test

Full strict-concurrency build (the enforced baseline for this repo):

```bash
swift build -Xswiftc -strict-concurrency=complete
```

Run the complete verification suite:

```bash
swift test
```

Run only the interlock actor suite:

```bash
swift test --filter HardwareInterlockGateTests
```

## Author & Attribution

**Architect & Lead Engineer:** Suren Sahaydachny
**Design System:** Tactical Operating System & Hardware Interlock Architecture
*Designed and developed as a deterministic, privacy-focused macOS hypervisor console.*

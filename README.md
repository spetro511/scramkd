# Tactical Hypervisor

> A deterministic, zero-AI-footprint macOS safety interlock that places a
> human-approved hardware gate between tool-calling agents and real execution.

**Suren Sahaydachny** — Principal Enterprise Architect & AI Systems SDLC Director,
working across agentic AI, enterprise architecture, and systems security. This
deterministic safety interlock is one expression of that broader practice.

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Suren%20Sahaydachny-0A66C2?style=flat-square&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/suren-sahaydachny-6a4a7a143)

## What This Is

`TacticalHypervisor` is a native Swift 6 console that arbitrates deterministic
safety state via a `HardwareInterlockGate` actor, bridges containerised tooling
through Apple's `Virtualization.framework` and a Docker ScreenEnv MCP stdio
pipe, renders avionics-style audible annunciators through local CoreAudio tone
synthesis, and drives a real-time MetalKit telemetry viewport. Every alert is
generated offline on-device: there is no cloud speech service, no third-party
inference, and no network egress in the alert path.

The design intent is determinism and privacy: no conversational AI layer, no
telemetry exfiltration, and no nondeterministic shared mutable state. Every
operational decision passes through an explicitly modelled interlock state
machine before it can touch a socket, a pipe, or a keyboard event.

## Why This Exists

Agentic AI has collapsed the distance between language and execution. Model
Context Protocol (MCP) servers, computer-use loops, and tool-calling agents now
reach directly into filesystems, shells, browsers, and containers — turning the
operator's own workstation into the attack surface. Every tool an agent can
call is a fresh remote-code-execution primitive. Every untrusted tool response
is a prompt-injection vector. The blast radius of a poisoned agent is no longer
a bad paragraph of text; it is a `docker exec`, a keystroke into a chat window,
a payload dropped onto a mounted volume.

The models themselves have been uncensored at the weight level.
[Abliteration](https://github.com/ollama/ollama/issues/6696) — the surgical
removal of refusal behaviour from open-weight checkpoints — is a public
technique with public artifacts. Refusal-free derivatives of Llama, Mistral,
Qwen, and Gemma distribute via Hugging Face and run on consumer silicon: an
M-series MacBook, a single RTX 3060 with 12 GB of VRAM, or a modest ARM
single-board computer running a quantised 7B. The institutional gatekeeping
that once made offensive-capable models an insider capability is gone.

Red-team and penetration-test tradecraft is following the same curve. Automated
reconnaissance, exploit chaining, credential spraying, GUI-driven abuse, and
social-engineering drafting that used to demand a specialist engagement team
now fit inside a scripted agent loop. The cost curve has bent hard toward the
attacker: an agentic stack on a laptop reproduces what was, three years ago,
a four-person billable engagement.

The operational consequence is a computing environment where **non-deterministic
models are authoring deterministic actions on real hardware, with no
safety-grade arbitration between the two.** Defending against adversarial AI
with more AI is not a solution — that just doubles the surface. The defence has
to be *boring*: no inference, no hallucination, no telemetry exfiltration, no
shared mutable state. A hardware interlock that answers three questions in
constant time — *is this action permitted, is the gate armed, and who approved
it* — and shows the answer to a human operator at avionics-grade latency.

Tactical Hypervisor is that interlock.

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
the bridge requests permissive clearance from the interlock before dispatch and
suspends the caller until an operator grants it or the clearance times out.

### TacticalAudioSVS
A Synthetic Voice System built on `AVFoundation` and `CoreAudio`.
`TacticalToneSynthesizer` generates deterministic, fully offline sine/saw
annunciator tones, and `SVSBridge` subscribes to interlock state deltas and
telemetry health to play the cue for each security event:

| Interlock / telemetry event   | Audible cue emitted        |
| ----------------------------- | -------------------------- |
| Gate armed                    | `armedPulse`               |
| Permissive granted            | `permissivePulse`          |
| Emergency abort tripped       | `emergencyAbortTrip`       |
| Telemetry degraded            | `masterCaution`            |
| Telemetry critical            | `masterWarning`            |

No cue is tied to cloud speech generation; every tone is synthesised on-device.

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

## Quickstart & Usage

The package ships as Swift libraries (the `TacticalHypervisor` product); you
wire the actors into a host target rather than running a standalone binary. The
canonical operator transaction is: **arm the gate → launch the bridge → dispatch
a high-risk command → the caller suspends → the operator grants permissive → the
command crosses the pipe.**

```swift
import TacticalCore
import TacticalVirtualization
import Foundation

let gate = HardwareInterlockGate()                 // starts in .locked
let bridge = ContainerSocketBridge(interlockGate: gate)

try await bridge.launchBridge()                    // spawn the docker exec stdio pipe
try await gate.arm()                               // locked -> armed (no permissive yet)

// A high-risk MCP command suspends inside requestPermissive(timeout: .seconds(5)).
// It only crosses the pipe once a human grants clearance.
async let dispatch: Void = try await bridge.dispatchMCPCommand(payload, isHighRiskAction: true)

// --- Human-in-the-loop approval ---
// The operator explicitly grants clearance (from the console / HUD confirm path):
try await gate.grantPermissive()                   // armed -> permissiveGranted, releases waiters
_ = await try await dispatch

// To halt everything immediately, the operator can trip an abort instead:
// await gate.tripEmergencyAbort()                 // -> emergencyAbort, rejects pending waiters
```

If the operator does not grant permissive within the 5-second window, the
command fails closed with `HardwareInterlockError.timedOut` and nothing is
written to the container stdio. Locking or aborting the gate likewise rejects
any suspended caller rather than letting it through.

## Interaction Flow / Interlock States

The `HardwareInterlockGate` actor only permits canonical transitions; every
attempt is either accepted or thrown as a typed error, and every accepted move
is recorded to an append-only audit history and streamed to subscribers.

```
        arm()                grantPermissive()
 LOCKED ────────▶ ARMED ──────────────────────▶ PERMISSIVE_GRANTED
   ▲               │  ▲                               │
   │               │  └──── requestPermissive() ───────┤
   │               ▼                                   │  (high-risk callers
   │         EMERGENCY_ABORT ◀── tripEmergencyAbort() ─┤   suspend here until
   │               │                                   │   granted or timeout)
   └───────────────┴── resetEmergencyAbort()           │
   ◀──────────────── lock() ───────────────────────────┘
```

- **locked** — inert baseline. `requestPermissive` throws `gateLocked`; no command dispatches.
- **armed** — ready but unapproved. High-risk callers suspend inside `requestPermissive` until granted or timed out.
- **permissiveGranted** — the operator has approved execution; queued waiters are released and commands may cross the pipe.
- **emergencyAbort** — fail-safe. All pending waiters are rejected; only `resetEmergencyAbort()` returns the gate to `locked`.

## Project Status

> **3 of 4 phases complete.** The deterministic safety path — interlock actor,
> MCP transport gating, and fault containment — is built, hardened, and fully
> test-covered. The on-device render surfaces (CoreAudio output binding and the
> Metal HUD telemetry pipeline) are the remaining frontier.

```
Core safety + MCP gating  [████████████████████████░░]  Phases 1–3  ✅ shipped & hardened
Render surfaces           [░░░░░░░░░░░░░░░░░░░░░░░░░░]  Phase 4     ⏳ in progress
```

| Signal | Value |
| --- | --- |
| Strict-concurrency build | `0` errors · `0` warnings |
| Test suite | **45 / 45 passing** (0 failures) |
| Library targets | 4 (`TacticalCore`, `TacticalVirtualization`, `TacticalAudioSVS`, `TacticalUI`) |
| Dependency graph | Acyclic, rooted on pure-Swift `TacticalCore` |

### ✅ Completed

- **[Phase 1 — Layout]** Multi-target SPM package, `.macOS(.v14)` pin, `swiftLanguageModes: [.v6]`, acyclic graph rooted on `TacticalCore`.
- **[Phase 2 — Core Safety]** `HardwareInterlockGate` actor: four canonical states, exactly-once continuation resume (`OSAllocatedUnfairLock`-guarded `ContinuationWaiter`), permissive wait/queue with task-group timeouts, cancellation-vs-grant race handling, emergency-abort drain, and an append-only audit trail.
- **[Phase 3 — MCP Bridge]** `ContainerSocketBridge` JSON-RPC 2.0 stdio transport with permissive gating on high-risk frames; `VirtualMachineController` `VZVirtualMachine` lifecycle model.
- **[Phase 3.1 — Hardening wave]** `SIGPIPE` suppression, 16 KiB chunked I/O with concurrent stdout drain (defeats the 64 KiB pipe-buffer deadlock), and typed `HardwareInterlockError` fault containment — verified by the `ContainerSocketBridgeFaultTests` adversarial matrix.
- **[Phase 3.2 — Hygiene]** `subscribeTransitions()` real-time `AsyncStream` with self-healing subscriber map; interlock-state audio cues + per-state HUD colour binding.

### ⏳ Remaining (Phase 4)

- [ ] **Live CoreAudio render binding** — `TacticalToneSynthesizer.synthesizeTone(parameters:)` is a deterministic stub; bind the cue → frequency table to a real `AVAudioEngine` / AudioUnit output pipeline.
- [ ] **Metal HUD telemetry pipeline** — `TacticalViewportRenderer` drives the `MTKView` loop and frame counter; substantive shader + `TelemetryFrame` projection rendering still to be built.
- [ ] **Background stdout drain** — replace the synchronous `availableData` read with a `readabilityHandler` → `AsyncStream` bridge for sustained > 1 MiB streams.
- [ ] **stderr containment** — wire an explicit `Pipe()` with `F_SETNOSIGPIPE` and a bounded ring buffer so container stderr faults cannot re-enter as raw errors.

## Verification

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

**Architect & Lead Engineer:** Suren Sahaydachny — Principal Enterprise Architect
and AI Systems SDLC Director based in the San Francisco Bay Area, currently
leading flagship enterprise agentic-AI deployments at Sucoro AI. Over the past
2 decades he has designed 56+ AI-powered products and multi-agent orchestration
platforms at enterprise scale, with prior leadership roles at Oracle (Database &
Core Technology), Humanified (CIO / CPO), and RAXO (Managing Director). His focus
is self-improving, intent-aware software architectures — systems that build
systems — and this deterministic, zero-AI-footprint macOS hypervisor console is
one expression of that philosophy.

**Design System:** Tactical Operating System & Hardware Interlock Architecture
**LinkedIn:** [linkedin.com/in/suren-sahaydachny](https://www.linkedin.com/in/suren-sahaydachny)

*Designed and developed as a deterministic, privacy-focused macOS hypervisor console.*

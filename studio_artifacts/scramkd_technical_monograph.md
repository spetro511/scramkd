# SCRAMKD SYSTEMS AUDIT AND TECHNICAL ARCHITECTURE MONOGRAPH

---

## 1. MATHEMATICAL INVARIANT & SAFETY POSTURE: DETERMINISTIC BARE-METAL INTERLOCK

### 1.1 Probabilistic Fallacy vs. Deterministic Assertion: P(Safety) != 1.0

Autonomous agent architectures that rely on probabilistic guardrails—such as secondary Large Language Model (LLM) evaluators, semantic prompt classifiers, or input/output vector alignment filters—introduce inherently non-deterministic safety boundaries. In high-assurance bare-metal and kernel-level runtime environments, any safety boundary governed by stochastic inference exhibits a probability of failure greater than zero ($P(\text{Failure}) > 0$). Consequently, the overall safety posture probability fails to reach unity:

$$P(\text{Safety}) \neq 1.0 \implies \text{Unacceptable on Bare Metal}$$

When an autonomous LLM agent dispatches direct shell execution commands, file system modifications, or privileged network requests, semantic guardrails remain susceptible to adversarial jailbreaks, context window exhaustion, hallucinated state transitions, and non-deterministic evaluation latencies. Furthermore, over a sequence of $N$ discrete agent dispatches, the cumulative probability of system safety degradation compounds exponentially. Defining $P(\text{Bypass})$ as the probability that a given prompt or command bypasses the probabilistic evaluator, the composite system failure probability over $N$ executions is formulated as:

$$P(\text{System Failure}) = 1 - (1 - P(\text{Bypass}))^N$$

Because $P(\text{Bypass}) > 0$ for any inference-based evaluator, as $N \to \infty$, $P(\text{System Failure}) \to 1.0$. Conversely, kernel-level POSIX trap interception and deterministic interlock gates enforce physical state barriers where $P(\text{Bypass}) = 0$, guaranteeing:

$$P(\text{System Failure}) = 1 - (1 - 0)^N = 0 \implies P(\text{Safety}) = 1.0$$

`SCRAMKD` enforces high-assurance process isolation by replacing heuristic evaluators with POSIX-level signal mediation, hardware interlock gates, and low-latency memory barriers. Execution authority is gated through deterministic kernel primitives that evaluate state via atomic checks rather than context analysis.

| Attribute / Parameter | Probabilistic Guardrails (LLM / Secondary Evaluators) | Deterministic Kernel Mediation (`SCRAMKD`) |
| :--- | :--- | :--- |
| **Safety Invariant** | $P(\text{Safety}) < 1.0$ (Stochastic / Inferential) | $P(\text{Safety}) = 1.0$ (Deterministic Invariant) |
| **Execution Path** | LLM-in-the-loop / Prompt Classifier API calls | POSIX trap, `OSAllocatedUnfairLock`, C11 atomic state |
| **Decision Latency** | Non-deterministic (100 ms – 3000 ms) | Deterministic sub-384 microsecond (< 384 µs) trip latency |
| **Bypass Surface** | Prompt injection, jailbreak, token smuggling | Physical dielectric switch gap, zero file descriptor pass |
| **Concurrency Rules** | Thread-pool race conditions, soft context windows | Swift 6 complete strict concurrency (`-strict-concurrency=complete`) |
| **Failure State** | Open / Undefined (Execution proceeds on classifier timeout) | Fail-Safe Open / Immediate POSIX process severance |

### 1.2 System-Level Ground Truth and Zero-LLM-In-Loop Enforcement

The core runtime execution root runs natively on macOS 14 utilizing Swift 6 compiled under strict concurrency enforcement (`-strict-concurrency=complete`). System-level safety requires absolute isolation between untrusted agent intent generation and host execution capability. Under the zero-trust architecture governing the execution root:

1. **Deterministic State Locking**: Live startup state must unconditionally remain locked, detached, and with output audio disabled. No automatic container or virtual machine execution is permitted on daemon launch.
2. **Zero-LLM-In-Loop Enforcement**: Prompt-driven logic, secondary agent models, or untrusted network callers are strictly barred from approving tool requests or bypassing interlock gates.
3. **Immutable Boot Configuration**: Startup remains in a fail-safe open or armed state. Hardware interlocks require explicit physical operator interaction (`<SPACE>` or `<ESC>`) or deterministic CLI authorization (`scramkctl`) to transition out of locked states.

---

## 2. STATE MACHINE INVARIANTS & LEASE ARBITRATION

### 2.1 HardwareInterlockGate State Transitions

The `HardwareInterlockGate` actor coordinates execution clearance across four discrete, mutually exclusive states:
* `.locked`: Default startup and fail-closed state. All inbound tool requests and execution leases are denied.
* `.armed`: Interlock is armed and actively monitoring for operator intervention. Waiter continuation pools are suspended.
* `.permissiveGranted`: Transient state permitting exactly one single-use execution clearance.
* `.emergencyAbort`: Terminal abort state triggered by manual operator intervention, CLI invocation, or POSIX process signal traps.

```
       +-----------------------------------------------------------------------------------+
       |                                                                                   |
       v                                                                                   |
  +---------+         arm()         +---------+    grantPermissive()    +--------------------+
  | .locked | --------------------> |  .armed | ----------------------> | .permissiveGranted |
  +---------+                       +---------+     <SPACE> keycap      +--------------------+
       |                                 |                                         |
       | lock() / auto-relock            | tripEmergencyAbort() / <ESC>            | single-use
       +---------------------------------+-----------------------------------------+ lease consume
       |                                 |                                         |
       |                                 v                                         v
       |                      +-------------------+                          +-----------+
       +--------------------> |  .emergencyAbort  |                          |  .locked  |
                              +-------------------+                          +-----------+
                                        ^
                                        |  POSIX Traps (SIGILL / SIGSEGV)
                                        |  or CLI Abort (`scramkctl abort`)
```

Transitions out of any active state (`.locked`, `.armed`, `.permissiveGranted`) into `.emergencyAbort` are omnipresent circuit breakers, ensuring non-reentrant actor isolation and instantaneous execution severance.

| Initial State | Valid Event / Trigger | Target State | Mutex Mechanism | Terminal Behavior |
| :--- | :--- | :--- | :--- | :--- |
| `.locked` | Operator `arm()` request | `.armed` | `OSAllocatedUnfairLock` | Activates interlock monitoring; suspends caller continuations. |
| `.armed` | Operator `<SPACE>` keycap / `grantPermissive()` | `.permissiveGranted` | `OSAllocatedUnfairLock` | Issues single-use `PermissivePermit`; prepares 1x dispatch lease. |
| Any Active State | Operator `<ESC>` keycap / `tripEmergencyAbort()` / POSIX Trap | `.emergencyAbort` | `OSAllocatedUnfairLock` | Immediate execution circuit severance; purges all waiter pools. |
| `.permissiveGranted` | Single-use permit consumption / dispatch | `.locked` | `OSAllocatedUnfairLock` | Immediate automatic relock; revokes active clearance lease. |

### 2.2 Continuation Waiter FIFO Pool & Single-Use PermissivePermit Issuance

The interlock maintains asynchronous caller suspension through `ContinuationWaiter` and `OneShotGate` FIFO queues. Request-bound clearance leases (`BridgeRequestLease`) guarantee single-use execution rights without maintaining locks across asynchronous suspension points.

When an incoming tool dispatch suspends execution via Swift's `withCheckedContinuation`, the thread yields execution to the runtime back-end without holding an `OSAllocatedUnfairLock`. The lock is acquired purely during atomic state inspection and mutation critical sections. By eliminating lock retention across `await` points, the system guarantees zero data races and complete immunity from task deadlocks.

```
Incoming Request ----> Acquire Unfair Lock ----> Enqueue Waiter ----> Release Unfair Lock ----> await Continuation
                                                                                                      |
Operator <SPACE> ----> Acquire Unfair Lock ----> Resume Waiter -----> Grant Permissive Permit --------+
                                                                             |
                                                                             v
                                                                 Consume Token & Auto-Relock (.locked)
```

#### Operational Workflow: Token Consumption & Automatic Relock
1. **Invocation**: An incoming tool call submits payload parameters and requests an execution clearance lease (`BridgeRequestLease`).
2. **Queue Suspension**: If the gate is in the `.armed` state, the caller's execution path is appended to the `ContinuationWaiter` FIFO pool using Swift's `withCheckedContinuation`.
3. **Atomic State Inspection**: The `OneShotGate` uses `OSAllocatedUnfairLock` to verify state synchronously before yielding execution. Locks are strictly released prior to thread suspension (`await`).
4. **Single-Use Permit Issuance**: Upon operator keycap activation (`<SPACE>`), a single `PermissivePermit` token is instantiated. The leading `ContinuationWaiter` in the FIFO pool is dequeued and resumed.
5. **Consumption & Immediate Relock**: The token is consumed exclusively by `ContainerSocketBridge.approve(_:)`. The gate state instantaneously transitions back to `.locked`, atomically revoking active clearance leases and preventing subsequent tool dispatches from inheriting stale authorization.

### 2.3 Emergency Abort Circuit & Trip Latency

The emergency SCRAM circuit provides an instantaneous safety trip path. Triggered via the physical `<ESC>` keycap, `scramkctl abort`, or POSIX signal traps (`SIGILL`/`SIGSEGV` intercept), the circuit bypasses all queued tool dispatches.

* **Trip Latency Metrics**: Hard enforcement guarantees sub-384 microsecond (< 384 µs) trip execution latency from initial keycap/signal interrupt to POSIX process severance.
* **File Descriptor Severance**: The trip path executes immediate file descriptor detachment (`NO FD`) and nonblocking writer queue purge (`MCPNonblockingWriter`).
* **Truthful Execution Metrics**: System audit logs record actual elapsed nanoseconds and bytes transmitted. The abort circuit severs process communication without fabricating guest container destruction or unverified host side effects.

---

## 3. PROCESS HARDENING, MEMORY ISOLATION & NONBLOCKING TRANSPORT

### 3.1 7-Key Subprocess Environment Scrubbing

Subprocess execution boundaries inside `MCPProcessTransport` and `DefaultSubprocessCommandExecutor` enforce strict environment isolation. Standard ambient host environment variables (e.g., `AWS_SECRET_ACCESS_KEY`, `SSH_AUTH_SOCK`, `GPG_AGENT_INFO`, `DATABASE_URL`) are scrubbed ambient environment vectors prior to spawning subprocesses.

Only seven explicit configuration keys are permitted through the execution boundary allowlist:
1. `PATH` (Restricted minimal system path: `/usr/bin:/bin:/usr/sbin:/sbin`)
2. `HOME` (Isolated sandbox directory)
3. `TMPDIR` (Isolated temporary directory)
4. `USER` (Unprivileged runner identity)
5. `LOGNAME` (Unprivileged log identity)
6. `LC_ALL` (Standardized locale `C.UTF-8`)
7. `LANG` (Standardized language `C.UTF-8`)

If an explicit `PATH` is not supplied by the caller profile, `DefaultSubprocessCommandExecutor` defaults to the restricted minimal path string `/usr/bin:/bin:/usr/sbin:/sbin`. All unapproved ambient environment variables are stripped, eliminating privilege escalation and credential exfiltration surfaces.

### 3.2 Constant-Time SHA-256 Approval Digest Verification

To eliminate timing side-channel attacks during clearance key evaluation, `ContainerSocketBridge.approve(_:)` enforces constant-time byte and hexadecimal comparisons for all incoming `BridgeApprovalKey` digests.

```
       Caller Approval Digest           Stored Expected Digest
     [ 0x3F, 0x8A, ..., 0x12 ]        [ 0x3F, 0x8A, ..., 0x12 ]
                 |                                |
                 +---------------+----------------+
                                 |
                                 v
                Constant-Time Byte Comparison
               Accumulator: diff |= (byteA ^ byteB)
                                 |
                         [ Constant Time ]
                                 |
                 Result: Success (0) or Failure (!0)
```

Standard string or byte-array comparisons terminate execution upon encountering the first non-matching byte, exposing timing side-channels that allow attackers to reconstruct valid approval keys byte-by-byte. `ContainerSocketBridge.approve(_:)` compares fixed 64-character SHA-256 hexadecimal strings (representing 32 raw bytes). Evaluating string length equality prior to the byte loop does not introduce a variable-length side-channel because all valid SHA-256 hexadecimal digests are structurally bounded to exactly 64 characters.

```swift
// Production implementation pattern within ContainerSocketBridge.approve(_:)
public func verifyApprovalKey(submitted: BridgeApprovalKey, expected: BridgeApprovalKey) -> Bool {
    let lhsBytes = Array(submitted.sha256.utf8)
    let rhsBytes = Array(expected.sha256.utf8)
    
    // Equal length check on fixed 64-char SHA-256 hex strings avoids index out-of-bounds
    guard lhsBytes.count == 64, rhsBytes.count == 64 else { 
        return false 
    }
    
    var difference: UInt8 = 0
    for i in 0..<64 {
        difference |= (lhsBytes[i] ^ rhsBytes[i])
    }
    
    return difference == 0 && submitted.requestID == expected.requestID && submitted.connectionGeneration == expected.connectionGeneration
}
```

This guarantees that evaluation latency remains identical regardless of whether the submitted digest is valid, invalid at character 0, or invalid at character 63.

### 3.3 POSIX Pipe Stream Architecture & Cancellation-Safe Nonblocking I/O

Communication with virtualized execution contexts utilizes a nonblocking POSIX stream layer (`MCPNonblockingWriter`).
* **Pipe Configuration**: Stdio pipes enforce the `F_SETNOSIGPIPE` flag, preventing host process termination from `SIGPIPE` signals when reading or writing against closed remote sockets.
* **Continuous Framing Protocol**: Transport streams frame data in continuous 16 KiB (16,384 bytes) chunks.
* **Deadlock Remediation**: Nonblocking writer queue cancellation deadlocks are mitigated using `OneShotGate.finish -> Bool` atomic completion. When an abnormal socket detachment occurs, the writer release loop drains pending I/O buffers and releases held continuation locks safely, preventing task deadlocks during process teardown.

---

## 4. ACTIVE HOLD POLICY & DWELL GUARD MECHANICS

### 4.1 Monotonic Clock Deadlines & Bounded Authorization TTL

Authorization time-to-live (TTL) limits and deadline bounds are governed strictly by `ActiveHoldPolicy` using Swift's `ContinuousClock` monotonic reference.

* **Monotonic Measurement**: Authorization checks compute target deadlines via `ContinuousClock.now.advanced(by:)`. Monotonic deadlines measure continuous absolute time, rendering them immune to system wall-clock adjustments or NTP time shifts.
* **Architectural Decoupling**: Front-end UI presentation refresh rates (60 FPS / 16.6 ms render frames) are decoupled from safety enforcement. Backend authorization checks independently validate continuous monotonic clock deadlines on the backend actor prior to tool dispatch. Dropped UI presentation frames cannot extend an expired authorization window.

### 4.2 Critical-Read Dwell (1.5s) & Hard Ceiling (15s) Rules

`ActiveHoldPolicy` governs two non-negotiable timing invariants during physical operator hold interaction:

```
0.0s              1.5s Dwell Target                       15.0s Hard Ceiling
  |-------------------|------------------------------------------|
  |  CRITICAL READ    |        VALID DISPATCH WINDOW             | EXPIRED
  |  (Hold Locked)    |        (Release triggers grant)          | (Auto Abort)
```

1. **Mandatory Critical-Read Dwell (1.5 Seconds)**: Operator physical hold key activation (`<SPACE>`) enforces a mandatory 1.5-second minimum dwell time. If the operator releases the key prior to 1.5 seconds, the action is marked prematurely released, the clearance request is cancelled, and the interlock immediately relocks.
2. **Hard Ceiling Limit (15.0 Seconds)**: An active hold has an absolute maximum ceiling of 15 seconds. If a hold remains active at 15.0 seconds without dispatch completion, the authorization window expires automatically, invalidating the pending request.

### 4.3 Window-Focus Deactivation & Safety Relock Triggers

To prevent unattended or background execution dispatches, `scramkd` links interlock safety directly to AppKit window focus state.

#### Mandatory Focus & Lifecycle Cleanup Checks:
* **Focus Loss (`.windowClosed` / Focus Deactivation)**: Losing AppKit key window status instantly revokes all active clearance leases (`BridgeRequestLease`) and triggers an immediate gate relock (`.locked`).
* **UI Dismissal**: Dismissing the console window drops local event tokens and revokes queued dispatches.
* **Local Event Token Invalidation**: On focus loss or window close, local `NSEvent` monitoring tokens are explicitly removed. No global key-logging or ambient background key capture privileges are used.

---

## 5. LOCK-FREE REALTIME AUDIO ANNUNCIATION ARCHITECTURE

### 5.1 C11 SPSC Ring Buffer & Atomic Synchronization

Real-time audio feedback is managed across a strict architectural boundary between high-level Swift management (`ScramKAudio`) and a lock-free C11 realtime engine (`CScramKAudioRealtime`).

```
+------------------------------------+          +--------------------------------------+
|       SWIFT PRODUCER ACTOR         |          |      C11 REALTIME RENDER THREAD      |
|           (ScramKAudio)            |          |        (CScramKAudioRealtime)        |
|                                    |          |                                      |
|  1. Formulates TARTCommand         |          |  1. Reads atomic head/tail indices   |
|  2. Updates atomic write index     |          |  2. Fetches TARTCommand parameters   |
|  3. Publishes lock-free via SPSC   | -------> |  3. Synthesizes PCM in tart_render() |
|                                    |          |  4. Advances atomic read index       |
+------------------------------------+          +--------------------------------------+
                  |                                                |
                  +-------------------- SPSC ----------------------+
                                  Lock-Free Ring Buffer
```

Shared memory structures (`TARTConfig`, `TARTCommand`, `TARTPlane`) manage audio queue states without POSIX locks. Ring buffer read and write head pointers operate under C11 atomic memory ordering primitives using explicit acquire/release memory barriers (`atomic_load_explicit`, `atomic_store_explicit`). 

Atomic index wrap-around handling across `UInt32` boundary overflows is verified via deterministic test suites (`tart_seed_quiescent_indices_for_testing`), ensuring thread synchronization remains lock-free under continuous operation.

### 5.2 Zero-Allocation CoreAudio Render Callback Discipline

Audio synthesis occurs within the `AVAudioSourceNode` render thread callback (`tart_render`). The render thread operates under strict real-time discipline.

#### Swift ARC Vulnerability in Real-Time Threads
Swift Automatic Reference Counting (ARC) operations (`swift_retain` / `swift_release`) inside high-priority render threads present catastrophic safety risks. ARC increments and decrements invoke runtime calls that can trigger heap memory allocations (`malloc`/`free`) or acquire internal runtime mutexes. Under thread contention, a real-time CoreAudio callback thread acquiring a runtime lock held by a lower-priority worker thread experiences priority inversion. This causes dropped audio frames, render deadline overruns, and system latency spikes.

#### Prohibited Operations inside the Render Thread Callback (`tart_render`):
* **Zero Swift ARC Allocations/Deallocations**: No dynamic memory management or reference counting.
* **Zero Lock Acquisition**: No `OSAllocatedUnfairLock`, POSIX mutexes, or `pthread_mutex` calls.
* **Zero Swift Concurrency `Task` Instantiation**: No async worker creation.
* **Zero File or Network I/O**: No disk or device stream access.
* **Zero Actor Synchronization Calls**: No cross-isolation actor calls or `@MainActor` hops.

#### Audio Cue Catalog & Synthesized Profiles
The cue synthesizer (`ScramKToneSynthesizer`) generates real-time audio alerts defined in `AudioContracts.swift`:

| Cue Identifier | C11 `audioID` | Frequency (Hz) | Duration (s) | Peak Amplitude | Waveform Type | Priority |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `armedPulse` | `1` | 440 Hz | 0.15 s | 0.501187 ( -6 dB ) | Sine (`.sine`) | 1 |
| `permissivePulse` | `2` | 880 Hz | 0.20 s | 0.630957 ( -4 dB ) | Sine (`.sine`) | 1 |
| `emergencyAbortTrip` | `3` | 1200 Hz | 0.50 s | 0.891251 ( -1 dB ) | Sawtooth (`.saw`) | 4 (Highest) |
| `masterCaution` | `4` | 660 Hz / 880 Hz | 0.25 s (2 seg) | 0.501187 ( -6 dB ) | Sine (`.sine`) | 2 |
| `masterWarning` | `5` | 880 Hz / 660 Hz | 0.125 s (8 seg) | 0.630957 ( -4 dB ) | Sine (`.sine`) | 3 |

### 5.3 Audio Storage Reclamation & Quiescent Memory Lifecycle

Memory safety during audio thread teardown is governed by `AudioReclamationControl` and `AudioRealtimeStorage`.

To destroy non-render C memory allocations without causing use-after-free conditions on the CoreAudio render thread, the system enforces a strict dual-condition quiescent requirement:

$$\text{Quiescent State} \iff (\text{Producer Detached} \land \text{Callback Retired})$$

1. **Producer Detachment**: The Swift producer actor sets the producer detached atomic flag (`tart_mark_producer_detached`).
2. **Callback Retirement**: CoreAudio completes its final render cycle and sets the callback retired atomic flag (`tart_mark_callback_retired`).

Only when both atomic flags evaluate to true within `tart_is_quiescent(_:)` can `AudioReclamationControl` safely deallocate underlying C11 memory buffers.

---

## 6. NATIVE DISPLAY P3 HUD & METALSURFACE RENDER ENGINE

### 6.1 3-Tier Progressive Disclosure Canvas Topology

The native console layout (`ScramKUI` / `ScramKConsoleView`) implements a fixed 1440x900 logical-point content canvas designed according to progressive disclosure principles.

```
+---------------------------------------------------------------------------------------------------+
|  HEADER RAIL (44pt) - SCRAMKD // SUPERVISOR DAEMON - SYSTEM STATUS & TELEMETRY                    |
+------------------------------+------------------------------------+-------------------------------+
|                              |                                    |                               |
|                              |                                    |                               |
|  LEFT RAIL                   |  CENTER MAIN STAGE                 |  RIGHT COCKPIT                |
|  (160pt)                     |  (794pt)                           |  (486pt)                      |
|                              |                                    |                               |
|  Navigation &                |  MetalKit Framebuffer Viewport     |  Hardware Gate Controls,      |
|  Subsystem Telemetry         |  & Interlock Pipeline Canvas       |  Active Hold Policy,          |
|                              |  (580pt Height)                    |  & Inspection Drawer          |
|                              |                                    |                               |
|                              |                                    |                               |
+------------------------------+------------------------------------+-------------------------------+
|  LOWER TELEMETRY / AUDIT COCKPIT (276pt)                                                          |
|  Console Audit Ledger, Real-time Event Stream, & System Metrics                                   |
+---------------------------------------------------------------------------------------------------+
```

| Canvas Region | Vertical Dimension | Horizontal Dimension | Structural Role & Operational Component |
| :--- | :--- | :--- | :--- |
| **Top Header Rail** | `44pt` Height | `1440pt` Full Width | Daemon identity, status indicators, system telemetry readout. |
| **Left Rail Chamber** | `580pt` Center Stage | `160pt` Width | Subsystem navigation, process tree, sandbox isolation metrics. |
| **Center Main Stage** | `580pt` Center Stage | `794pt` Nominal Width | MetalKit framebuffer viewport, interlock schematic canvas. |
| **Right Cockpit Inspector** | `580pt` Center Stage | `486pt` Width | Hardware interlock controls, hold countdown, inspection drawer. |
| **Lower Telemetry Cockpit**| `276pt` Height | `1440pt` Full Width | Real-time audit ledger stream, JSON-RPC frame inspector. |

#### Structural Geometry Rules:
* **Structural Corner Radii**: `0pt` (strict orthogonal panels).
* **Interactive Keycap Radii**: `2pt` maximum radius.
* **Typography Discipline**: JetBrains Mono / Geist Mono tabular numeric formatting for exact column alignment.

### 6.2 Display P3 Color Pipeline & High-Contrast Avionics Design

`DesignTokens.swift` defines a wide-gamut Display P3 chromatic pipeline. Standard web/HTML sRGB hex triplets are explicitly converted into Display P3 color space coordinates using exact floating-point channel values rather than reinterpreting raw sRGB values.

```swift
// Production Display P3 conversion pattern in DesignTokens.swift
extension Color {
    static let radicalRed = Color(.displayP3, red: 0.937, green: 0.267, blue: 0.267, opacity: 1.0)
    static let amberAlert = Color(.displayP3, red: 0.961, green: 0.620, blue: 0.043, opacity: 1.0)
    static let emeraldPass = Color(.displayP3, red: 0.063, green: 0.725, blue: 0.506, opacity: 1.0)
    static let obsidianBase = Color(.displayP3, red: 0.039, green: 0.055, blue: 0.078, opacity: 1.0)
    static let metalHairline = Color(.displayP3, red: 0.110, green: 0.149, blue: 0.212, opacity: 1.0)
}
```

| UI System State | Semantic Token | Display P3 Hex | Display P3 Normalized Float Specification | Visual Intent & Usage |
| :--- | :--- | :--- | :--- | :--- |
| **Emergency Abort / Trap** | `Radical Red` | `#EF4444` | `p3: 0.937, 0.267, 0.267` | POSIX trap, SCRAM trip, high-risk interception. |
| **Armed / Interlock Gate** | `Amber Alert` | `#F59E0B` | `p3: 0.961, 0.620, 0.043` | Armed gate state, suspended waiters, active hold. |
| **Permissive / Verified** | `Emerald Pass` | `#10B981` | `p3: 0.063, 0.725, 0.506` | Single-use permit granted, verified transport frame. |
| **Obsidian Chassis Base** | `Obsidian Base`| `#0A0E14` | `p3: 0.039, 0.055, 0.078` | Deep background chassis, non-reflective HUD floor. |
| **Hairline Border** | `Metal Hairline`| `#1C2636`| `p3: 0.110, 0.149, 0.212` | 1pt structural panel division and grid lines. |

### 6.3 MetalKit Viewport Architecture & Framebuffer Synchronization

High-rate telemetry and isolated framebuffers render via `ScramKMetalViewport` and `ScramKFramebufferSurface`.

* **Framebuffer Synchronization**: Dual Metal texture slots are synchronized against in-flight GPU usage. The texture swapping mechanism prevents frame tearing without blocking the `@MainActor` UI thread or dropping below the target 60 FPS rendering rate.
* **Graceful Hardware Fallback**: If MetalKit hardware devices are missing or rendering context allocation fails:
  1. The viewport catches device allocation errors without throwing uncaught host exceptions.
  2. The HUD automatically drops back to an accessible text-based visual summary (`ScramK state viewport`).
  3. System audit logs explicitly record the GPU device status as unavailable (`SKIPPED / FALLBACK`).
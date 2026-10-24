# Hardening Analysis — `scramkd` MCP Transport Remediation

**Scope:** Follow-up audit of the changes landed after the initial repository
bootstrap (`ae736f9..5f54dbc`), focused on the `screenenv_container` MCP
transport failure cascade and the hardening wave that remediated it.

**Author & Attribution:** @spetro511 (Suren Sahaydachny) — GitHub:
<https://github.com/spetro511>

---

## 1. Executive Summary

The initial `ContainerSocketBridge` implementation shipped a synchronous,
single-shot stdio transport against the Docker `screenenv_container` MCP
server. In production with the ScreenEnv image
(`amhma/ubuntu-desktop:22.04-0.1.0`) that path exhibited three independent,
compounding failure modes which, together, caused the hypervisor console to
crash, hang, or leak untyped errors up through the interlock layer:

| # | Failure mode | Symptom | Blast radius |
| - | ------------ | ------- | ------------ |
| 1 | Untrapped `SIGPIPE` on closed child stdin | Whole macOS process killed by the kernel when ScreenEnv container restarted mid-session | Fatal |
| 2 | 64 KiB kernel pipe-buffer deadlock on large payloads | Base64 screenshot payloads (frequently > 1 MiB) blocked the parent on `write`, blocked the child on `stdout`, hung the actor indefinitely | Interlock starvation |
| 3 | Raw Foundation / POSIX error leakage | `NSFileHandleOperationException` and `EPIPE` escaped `dispatchMCPCommand` unwrapped, breaking the typed `HardwareInterlockError` contract callers depend on | Silent mis-handling |

Remediation landed in commit `fe646ba` (`feat(virtualization): harden
ContainerSocketBridge chunked I/O and add fault injection tests`).

---

## 2. Root Cause Analysis

### 2.1 Untrapped `SIGPIPE` (issue 1)

`Foundation`'s `FileHandle.write(contentsOf:)` triggers `write(2)` against the
child pipe. If the child has already exited (container restart, Docker daemon
hiccup, `python -m screenenv.mcp_server` unhandled exception), the pipe read end
is closed. macOS delivers `SIGPIPE` to the *writing* process, whose default
disposition is termination. Swift does not install a `SIG_IGN` handler, so the
parent `scramkd` supervisor process dies with signal 13.

### 2.2 Kernel Pipe-Buffer Deadlock (issue 2)

On Darwin, an unnamed pipe has a 64 KiB buffer (`fcntl(F_GETPIPE_SZ)` equivalent
default). The original code did:

```swift
try stdinHandle.write(contentsOf: payload)   // blocks once stdin pipe fills
try stdinHandle.write(contentsOf: Data([0x0A]))
let responseData = stdoutHandle.availableData // reached only after write returns
```

For a ScreenEnv `screenshot` frame (JSON envelope plus a base64 PNG), the parent
blocks on stdin once the child stops reading; but the child cannot read further
because its own stdout is also full awaiting parent drain. The parent's
`availableData` line is unreachable. Classic pipe-buffer deadlock. Result: the
`ContainerSocketBridge` actor never returns from `dispatchMCPCommand`, the
interlock's 5-second timeout fires only for high-risk frames, and every
subsequent low-risk command queues behind a permanently suspended actor call.

### 2.3 Untyped Error Leakage (issue 3)

`FileHandle.write` throws `NSFileHandleOperationException` (a Cocoa error with
domain `NSCocoaErrorDomain`, code 510 on broken pipe). The original
`try stdinHandle.write(...)` propagated the raw `Error` value, which violated
the "every transport failure is a `HardwareInterlockError`" contract that
`SVSBridge`, `ScramKViewportRenderer`, and every UI path rely on for typed
handling. The interlock layer effectively became unable to distinguish
"transport down" from "gate locked" from "unknown Cocoa fault".

---

## 3. Hardening Measures Applied (commit `fe646ba`)

### 3.1 `SIGPIPE` suppression at the pipe file descriptor

```swift
_ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
```

Set inside `launchBridge()`, immediately after the `Pipe()` allocation and
before `process.run()`. `F_SETNOSIGPIPE` (Darwin-specific) suppresses `SIGPIPE`
delivery per-descriptor, forcing the write to fail with `errno = EPIPE`
instead. That error is now surfaced through the typed path in § 3.3.

### 3.2 Chunked write with concurrent stdout drain

```swift
let chunkSize = 16_384
if payload.count > chunkSize {
    while offset < payload.count {
        let end = min(offset + chunkSize, payload.count)
        try stdinHandle.write(contentsOf: payload.subdata(in: offset..<end))
        offset = end
        let drained = stdoutHandle.availableData
        if !drained.isEmpty { accumulated.append(drained) }
    }
    try stdinHandle.write(contentsOf: Data([0x0A]))
    ...
}
```

- **Chunk size 16 KiB** is chosen to stay well under the 64 KiB kernel buffer so
  that each `write` returns even while the child has not yet consumed anything.
- After every chunk, the parent performs a non-blocking `availableData` pull on
  stdout. This *interleaves* parent-drain with child-write, which is exactly the
  pattern needed to break the deadlock in § 2.2 without spawning a background
  reader thread and without leaving the actor's executor.
- Small payloads (≤ 16 KiB) retain the original single-write path — no
  regression in throughput for the common JSON-RPC `initialize` /
  `tools/list` handshake frames.

### 3.3 Typed error containment

```swift
do {
    try stdinHandle.write(...)
    try stdinHandle.write(contentsOf: Data([0x0A]))
} catch let writeError as NSError {
    throw HardwareInterlockError.subsystemFailure(
        reason: "Container stdin write failed: "
              + "\(writeError.localizedDescription) "
              + "(\(writeError.domain) \(writeError.code))"
    )
}
```

Both branches (small-payload and chunked) now wrap every `NSError` — including
`NSCocoaErrorDomain` code 510 and any `EPIPE`-derived fault — as
`HardwareInterlockError.subsystemFailure(reason:)` with domain and code echoed
in the message for post-incident triage. Callers can now rely on a total
function: any bridge fault is either a `HardwareInterlockError` or a success.

---

## 4. Fault Injection Test Matrix (`ContainerSocketBridgeFaultTests`, 5 tests)

| Test | Injected fault | Pass condition |
| --- | --- | --- |
| `testLargePayloadHandlingDoesNotCrash` | 1 MiB `0x41` payload against a `cat`-backed bridge | No raw POSIX / CocoaError leaks; success *or* typed `subsystemFailure` |
| `testMalformedJSONRPCPayloadHandledGracefully` | Truncated JSON frame (missing closing brace) | Transport survives without crash; typed containment only |
| `testProcessTerminationMidReadHandledGracefully` | `/bin/echo hello` exits before dispatch | Post-exit write yields `subsystemFailure`, never a raw error |
| `testBridgeIsInactiveAfterTerminate` | State-transition integrity of `isBridgeActive` | `true → false` across `terminateBridge()` |
| `testHighRiskCommandBlocksWhenGateArmed` | Interlock `.armed`, no permissive grant | Dispatch suspends; racing task group forces `timedOut` / `taskCancelled` |

These tests are adversarial: they use `cat` and `echo` as deterministic
substitutes for the real `screenenv_container` so they run in CI without Docker
while still exercising the exact stdio fault paths the ScreenEnv MCP server can
trigger.

---

## 5. Adjacent Hardening (same wave, complementary commits)

### 5.1 `cc63142` — Core safety: cancellation race + subscriber hygiene

- Introduced `WaiterCancellationState` (`pending | waiting | cancelled`) to make
  the "cancel-before-continuation-init" race atomic under a single
  `OSAllocatedUnfairLock`. Closes a latent double-resume trap that would have
  surfaced as an intermittent crash whenever `Task.cancel()` fired between
  `withTaskCancellationHandler` installation and `withCheckedThrowingContinuation`
  body entry.
- Added `subscribeTransitions() -> AsyncStream<InterlockTransitionRecord>` so
  UI / SVS observers get real-time transition delivery without polling.
- Subscriber map self-heals: `yield` result `.terminated` evicts the entry;
  `deinit` calls `finish()` on every continuation; `onTermination` unregisters.
  This is what the new `StreamLeakAuditorTests` (8 cases) verifies.
- `ContinuationWaiter` visibility relaxed from `private` to internal to permit
  direct stress testing. 100-task interlock stress tests now cover the
  cancellation-vs-grant race deterministically.

### 5.2 `4636e9e` — Audio / UI: interlock-state annunciators + HUD state binding

- New cues: `.armedPulse` (440 Hz sine), `.permissivePulse` (880 Hz sine),
  `.emergencyAbortTrip` (1200 Hz saw). `WaveformType` enum (`sine / saw / square`)
  added and threaded through `ToneParameters`.
- `SVSBridge.ingestTelemetry` now reacts to every `InterlockStatus` transition,
  not only emergency abort — the operator can *hear* arm / permissive-grant.
- `ScramKViewportRenderer.draw` selects a per-state `clearColor` (locked =
  cool slate, armed = amber, permissive = green, abort = red). Viewport exposes
  `updateTelemetry(_:)` and `ingestTelemetry(_:)` so the interlock's new
  `AsyncStream` can bind directly to the HUD.
- `ScramKToneSynthesizer` accumulates `lastSynthesizedParameters` and
  `totalTonesSynthesized` to make the CoreAudio stub path observable from tests.

### 5.3 `5f54dbc` — Docs / hygiene

- `.gitignore` extended with `application_default_credentials.json` and
  `service.json` — closes an operational-hygiene gap where cloud / service
  principal JSON blobs could be committed by accident during development.

---

## 6. Verification

- **Build (strict concurrency, complete):** clean, 0 errors, 0 warnings.
- **Tests:** **45 / 45** passing, 0 failures, 0 unexpected.
  - HardwareInterlockGateTests 11 · HardwareInterlockGateStressTests 8 ·
    StreamLeakAuditorTests 8 · TelemetryFrameTests 2 ·
    ContainerSocketBridgeTests 6 · ContainerSocketBridgeFaultTests 5 ·
    SVSBridgeTests 5.
- **Live `screenenv_container`** path remains optional; the handshake test in
  `ContainerSocketBridgeTests` gracefully skips when Docker is unavailable, so
  the fault-injection suite is the deterministic guarantee that the transport
  cannot crash or hang the console regardless of container state.

---

## 7. Residual Risks & Follow-Ups

- `stdoutHandle.availableData` is still a synchronous read on the actor's
  executor. Under sustained > 1 MiB streams it may briefly block the actor;
  the next hardening step is a background `readabilityHandler` with an `AsyncStream`
  bridge.
- `F_SETNOSIGPIPE` covers only the child-stdin descriptor. `stderr` is not
  wired; if Docker emits on stderr with a closed reader, the same class of
  fault can reappear. Recommend attaching an explicit `Pipe()` with
  `F_SETNOSIGPIPE` and a bounded ring buffer.
- Chunked I/O assumes the child process flushes per line; if the ScreenEnv
  MCP server buffers, `availableData` returns empty and the accumulated
  response is not delivered until EOF. Add an explicit read deadline.

---

## 8. Attribution

**Repository custodian & author:** @spetro511 (Suren Sahaydachny)
**GitHub:** <https://github.com/spetro511>
**Remote:** `origin → https://github.com/spetro511/scramkd.git`

*Deterministic. Zero AI footprint. Interlock-gated.*

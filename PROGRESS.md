# Project Progress Ledger — `scramkd` (Darwin Supervisor Daemon & Hardware Interlock Runtime)

Historical audit record of build progress, state verification, and roadmap for `scramkd` (`com.scramk.daemon`).

## System Metrics (Verified)

| Metric | Value |
| --- | --- |
| Package & Daemon Identity | `scramkd` / `scramkctl` (`LaunchDaemons/com.scramk.daemon.plist`) |
| Language Mode | Swift 6 (`.v6`) + C11 (`.c11`), macOS 14 target |
| Strict Concurrency Build | `swift build -c release -Xswiftc -strict-concurrency=complete` → **0 errors, 0 warnings** |
| Unit & Stress Tests | **372 passing**, 0 failures, 0 unexpected (`swift test -Xswiftc -strict-concurrency=complete --skip 'ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState'`) |
| Live Integration Test | **1 / 1 passing** (`ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState` verified live FastMCP 2025-03-26 & 1080p RFB frame ingestion) |
| Targets | 4 library targets (`ScramKCore`, `ScramKAudio`, `ScramKVirtualization`, `ScramKUI`), 1 private C11 target (`CScramKAudioRealtime`), 2 executable targets (`scramkd`, `scramkctl`), 4 test targets (`ScramKCoreTests`, `ScramKVirtualizationTests`, `ScramKAudioTests`, `ScramKUITests`) |

## Milestone Audit

### ✅ Phase 1 — Layout (`ScramK` Multi-Target SPM Architecture)
Multi-target Swift Package Manager configuration with a `.macOS(.v14)` platform pin, `swiftLanguageModes: [.v6]`, and `cLanguageStandard: .c11`. Umbrella product `ScramK`, four library products (`ScramKCore`, `ScramKAudio`, `ScramKVirtualization`, `ScramKUI`), two executable products (`scramkd` daemon and `scramkctl` operator CLI), and four test targets with an acyclic dependency graph rooted on pure-Swift `ScramKCore`.

### ✅ Phase 2 — Core Safety (`ScramKCore`)
`HardwareInterlockGate` actor implementing the four canonical states (`locked`, `armed`, `permissiveGranted`, `emergencyAbort`). Thread-safe continuation resumption via `OSAllocatedUnfairLock`-guarded `ContinuationWaiter` instances guaranteeing exactly-once resume. Full coverage for:
- Deterministic transition validation and invalid-transition rejection.
- Single-use `PermissivePermit` issuance and one-shot consumption with automatic post-frame relock.
- Permissive wait/queue with `requestPermissive(timeout:)` task-group timeouts.
- Task cancellation handling (`withTaskCancellationHandler`) racing grant.
- Emergency-abort drain of all suspended waiters and strict recovery ladder back to `locked`.
- Immutable transition audit trail (`InterlockTransitionRecord`) and atomic observation stream (`observeTransitions(after:historyLimit:)`).

### ✅ Phase 3 — MCP Bridge (`ScramKVirtualization`)
`ContainerSocketBridge` stdio socket bridge transmitting JSON-RPC 2.0 payloads to the Docker `screenenv_container` MCP server. High-risk actions are interlock-gated: `dispatchMCPCommand(_:)` requires permissive clearance from `HardwareInterlockGate` before a frame is written to container stdin. Request-bound clearance leases (`BridgeRequestLease`) and single-use permits ensure approval of one tool call never authorizes subsequent commands. Complemented by `VirtualMachineController` (`VZVirtualMachine` lifecycle stubs behind `@preconcurrency import Virtualization`).

### ✅ Phase 4 — Live Virtualization, Framebuffer Pipeline & Real-Time Audio (`ScramKUI` & `ScramKAudio`)
- **Live Container Socket Attach & Request-Bound Dispatch**: `ContainerSocketBridge` wires directly into `ConsoleStateController` with explicit menu controls (`Virtualization → Attach ScreenEnv Bridge` `⌥⌘A`, `Detach Bridge` `⌥⌘D`). Outbound tool dispatches undergo strict JSON-RPC envelope classification and constant-time SHA-256 wire hash verification, enforcing one-shot gate authorization and automatic post-frame relocking.
- **MetalKit Real-Time Framebuffer Pipeline (`ScramKMetalViewportView`)**: `FramebufferClient` attaches to `ws://127.0.0.1:7860/websockify` via direct numeric BSD TCP sockets, decoding RFB 3.8 RAW rectangles into double-buffered `MTLTexture` instances (`rgba8Unorm_srgb`) managed by `ScramKFramebufferSurface`. Shader pipeline (`scramkVertex` / `scramkFragment`) performs single-pass linear sRGB to Display P3 matrix conversion.
- **CoreAudio Hardware Tone Synthesis (`ScramKAudio` / `CScramKAudioRealtime`)**: `ScramKToneSynthesizer` is bound to an `AVAudioEngine` / `AVAudioSourceNode` pipeline via a lock-free C11 SPSC ring buffer and native Objective-C block adapter (`CScramKAudioRealtime`), guaranteeing zero Swift/Objective-C runtime ARC calls, locks, or heap allocations on the real-time audio render thread.

### ✅ Stage 2 (`MB-00`–`MB-08`) — Rebrand, Adversarial Security Hardening & 3-Tier HUD
- **`MB-00` Atomic `scramkd` Namespace & Target Cutover**: Migrated package, targets, C11 headers (`CScramKAudioRealtime.h`), types (`ScramK*`), shaders (`scramkVertex`/`scramkFragment`), UI chrome (`SCRAMKD // SUPERVISOR DAEMON`, `SUPERVISOR OVERVIEW`), `scramkctl` CLI (`Sources/scramkctl/ScramKCLI.swift`), and `LaunchDaemons/com.scramk.daemon.plist`.
- **`MB-01` Single-Use `PermissivePermit` & One-Shot Gate Relock**: Enforced request-bound single-use permit tokens in `ScramKCore` and `ScramKVirtualization`.
- **`MB-02` `ContainerSecurityProfile`**: Enforced `.strictAirgap` vs `.loopbackFramebuffer` profiles (`--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--pids-limit`, memory/swap caps).
- **`MB-03` Cancellation-Safe Nonblocking Writer Handoff**: Fenced `MCPNonblockingWriter` and socket I/O against partial-write corruption and task-cancellation races.
- **`MB-04` 7-Key Subprocess Environment Scrubber**: Sanitized `MCPProcessTransport` child environment to an explicit 7-key allowlist, stripping `DYLD_*`, `LD_*`, `BASH_ENV`, and shell injection vectors.
- **`MB-05` Constant-Time SHA-256 Hex Digest Comparison**: Eliminated timing side-channels in wire payload digest verification.
- **`MB-06` Bounded `ActiveHoldPolicy`**: Enforced physical hold-to-grant dead-man switch with monotonic ceiling and instant relock on key-up or focus loss.
- **`MB-07` 3-Tier Progressive Disclosure HUD**: Structured `ScramKUI` into Tier 1 Primary Flight Display, Tier 2 Collapsible Diagnostic Drawer, and Tier 3 Modal Inspection Sheets.
- **`MB-08` Documentation & Governance Rebrand**: Synchronized `README.md`, `AGENTS.md`, `STATE.md`, and `PROGRESS.md` to canonical `scramkd` architecture.

## Roadmap Status

| Phase / Gate | Scope | Status |
| --- | --- | --- |
| Phase 1 | Multi-target SPM layout (`scramkd`, macOS 14, Swift 6 / C11) | Complete |
| Phase 2 | `HardwareInterlockGate` safety actor (`ScramKCore`) | Complete |
| Phase 3 | `ContainerSocketBridge` MCP gating (`ScramKVirtualization`) | Complete |
| Phase 4 | Live bridge, Display P3 framebuffer (`ScramKUI`) & CoreAudio SVS (`ScramKAudio`) | Complete |
| `MB-00` | Atomic `scramkd` / `scramkctl` / `ScramK*` target & symbol cutover | Complete |
| `MB-01`..`MB-05` | Track A: `PermissivePermit`, `ContainerSecurityProfile`, Writer Handoff, Env Scrubber, Constant-Time SHA-256 | Complete |
| `MB-06`..`MB-07` | Track B: Bounded `ActiveHoldPolicy` & 3-Tier Progressive Disclosure HUD | Complete |
| `MB-08` | Final Documentation & Governance Synchronization (`README.md`, `AGENTS.md`, `STATE.md`, `PROGRESS.md`) | Complete |

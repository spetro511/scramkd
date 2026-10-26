# `scramkd` (`v0.4.0`) — Stage 3 Engineering & Hardening Backlog

**Architect:** Suren Sahaydachny · **Baseline:** `scramkd` `v0.4.0` (Swift 6 / C11, macOS 14+)  
**Operating Rule:** Never fake a security boundary to make a dashboard look green.

---

## Why This Backlog Exists

Stage 2 (`MB-00`–`MB-08`) locked down the core in-process safety invariants: single-use `PermissivePermit` consumption, 7-key subprocess environment scrubbing, cancellation-safe 16 KiB `F_SETNOSIGPIPE` pipe writes, constant-time SHA-256 payload verification, and the bounded `ActiveHoldPolicy` dead-man switch across the 3-Tier Display P3 HUD. All 372 deterministic XCTests pass with zero strict-concurrency warnings.

What remains in Stage 3 are the places where **we explicitly chose to fail closed or mark a surface `NOT IMPLEMENTED` rather than ship security theater**. If a CLI tool isn't talking over an authenticated kernel socket yet, or if a panic key hasn't `fsync`ed a zeroized forensic dump to disk, the code says so to your face. These four issues track the exact systems work required to close those gaps.

### GitHub Label Taxonomy (`gh label create`)

If you are bootstrapping a fork of this repository, run the following once to sync the issue taxonomy:

```sh
gh label create "security:containment" --color "B60205" --description "Host/container boundary isolation and policy enforcement" --force
gh label create "security:ipc"         --color "D93F0B" --description "UNIX domain socket, peer-credential, and Mach/stdio IPC hardening" --force
gh label create "security:crypto"      --color "E99695" --description "Cryptographic digest, permit nonce, and session zeroization" --force
gh label create "severity:high"        --color "B60205" --description "High-severity security or containment boundary requirement" --force
gh label create "severity:medium"      --color "FBCA04" --description "Medium-severity defense-in-depth or operational hardening item" --force
gh label create "severity:low"         --color "0E8A16" --description "Low-severity governance, CI, or documentation item" --force
gh label create "subsystem:ScramKCore"           --color "1D76DB" --description "Sources/ScramKCore (HardwareInterlockGate, PermissivePermit)" --force
gh label create "subsystem:ScramKVirtualization" --color "0052CC" --description "Sources/ScramKVirtualization (ContainerSocketBridge, MCP, RFB)" --force
gh label create "subsystem:ScramKUI"             --color "5319E7" --description "Sources/ScramKUI (3-Tier HUD, Display P3 Metal Viewport)" --force
gh label create "subsystem:scramkctl"            --color "006B75" --description "Sources/ScramKctl (Operator CLI & launchd socket control)" --force
```

| Issue | ID & Title | Priority | Severity | CWEs | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| [#1](https://github.com/spetro511/scramkd/issues/1) | `[SEC-IPC-01]` Wire `scramkctl` to `/var/run/scramkd/control.sock` with `LOCAL_PEERCRED` Verification | `P1` | `HIGH` | `CWE-284`, `CWE-306` | `OPEN` |
| [#2](https://github.com/spetro511/scramkd/issues/2) | `[SEC-INTERLOCK-02]` Implement F12 Airgap Telemetry Dump & Cryptographic Wipe (`forceAirgapDump`) | `P2` | `MEDIUM` | `CWE-665`, `CWE-325` | `OPEN` |
| [#3](https://github.com/spetro511/scramkd/issues/3) | `[SEC-CI-03]` Live Container Runtime E2E CI Runner & `LOOPBACK_FB` / `STRICT_AIRGAP` Probe | `P2` | `MEDIUM` | `CWE-693`, `CWE-436` | `OPEN` |
| [#4](https://github.com/spetro511/scramkd/issues/4) | `[GOV-HYGIENE-04]` Continuous CI Lint Gate Preventing Legacy Namespace Drift & Hardcoded Host Paths | `P3` | `LOW` | `CWE-1059`, `CWE-200` | `IN_PROGRESS (Linter Delivered)` |

---

## Issue 1: `[SEC-IPC-01]` Wire `scramkctl` to `/var/run/scramkd/control.sock` with `LOCAL_PEERCRED` Verification

- **GitHub Issue**: [#1](https://github.com/spetro511/scramkd/issues/1)
- **Priority / Severity**: `P1` / `HIGH`
- **Labels**: `security:ipc`, `severity:high`, `subsystem:scramkctl`, `subsystem:ScramKCore`
- **CWE Mapping**: `CWE-284` (Improper Access Control), `CWE-306` (Missing Authentication for Critical Function)

### Where the Code Stands Today

Right now, [`ScramKCLI.main()`](../Sources/scramkctl/ScramKCLI.swift#L5-L36) instantiates its own in-process [`HardwareInterlockGate`](../Sources/scramkctl/ScramKCLI.swift#L9) (`HardwareInterlockGate(initialStatus: .armed)`) and runs `status`, `grant`, and `abort` against local process memory. That was intentional during Stage 2 so we could lock down the CLI state-machine grammar and exit codes (`0`, `1`, `64`) without mocking a daemon socket.

Meanwhile, [`LaunchDaemons/com.scramk.daemon.plist`](../LaunchDaemons/com.scramk.daemon.plist#L17-L30) already declares `SCRAMKD_CONTROL_SOCKET=/var/run/scramkd/control.sock` and provisions the `launchd` `Sockets.ControlSocket` dictionary (`SockPathName=/var/run/scramkd/control.sock`, `SockPathMode=384` / `0600` octal). What's missing is the actual UNIX domain socket transport connecting the two—and the kernel peer-credential check that keeps an untrusted local process from impersonating the operator.

### The Kernel / IPC Attack Surface

If you run `scramkctl abort` from a terminal tab while an agent loop is misbehaving, it has to trip the [`HardwareInterlockGate`](../Sources/ScramKCore/InterlockEngine.swift#L19-L260) inside the live `scramkd` process—not flip a struct inside a short-lived CLI process that immediately exits.

Conversely, once `scramkd` listens on `/var/run/scramkd/control.sock`, that socket becomes the crown jewel on the host. If permissions on `/var/run/scramkd` ever drift or a local process run by an unprivileged UID manages to `connect(2)` to that socket, accepting `grant` frames without inspecting kernel credentials turns the CLI socket into a privilege-escalation backdoor. We do not trust payload-level tokens on a local UNIX socket when the Darwin kernel already knows the caller's exact UID and PID.

Every connection accepted on `SCRAMKD_CONTROL_SOCKET` must extract kernel peer credentials via `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...)` (`xucred.cr_uid`) and `LOCAL_PEERPID` **before reading a single byte off the stream**. If `xucred.cr_uid` is neither `0` (`root`) nor the effective UID of `scramkd`, the daemon drops the descriptor immediately and records an unauthorized IPC probe in the audit log.

### Definition of Done (`XCTest` & Runtime Gate)

- [ ] Implement `ControlSocketServer` and `ControlSocketClient` binding `/var/run/scramkd/control.sock` (supporting both direct path bind and `launchd` socket activation via `launch_activate_socket("ControlSocket")` with `0600` / `SockPathMode=384` enforcement).
- [ ] Enforce `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...)` (`xucred.cr_uid == 0 || xucred.cr_uid == geteuid()`) and `LOCAL_PEERPID` extraction prior to frame deserialization, logging caller `(uid, pid)` provenance on every `status`, `grant`, and `abort` command.
- [ ] Rewire [`ScramKCLI.swift`](../Sources/scramkctl/ScramKCLI.swift#L5-L36) so `scramkctl status | grant | abort` transacts against the live `SCRAMKD_CONTROL_SOCKET` endpoint and fails closed with a deterministic diagnostic exit code when the daemon socket is unreachable.
- [ ] Add deterministic Breaker tests in `Tests/ScramKCoreTests` verifying unprivileged `cr_uid` rejection, truncated/oversized frame rejection, and concurrent `scramkctl abort` preemption of an active `HardwareInterlockGate` waiter queue.

---

## Issue 2: `[SEC-INTERLOCK-02]` Implement F12 Airgap Telemetry Dump & Cryptographic Wipe (`forceAirgapDump`)

- **GitHub Issue**: [#2](https://github.com/spetro511/scramkd/issues/2)
- **Priority / Severity**: `P2` / `MEDIUM`
- **Labels**: `security:crypto`, `security:containment`, `severity:medium`, `subsystem:ScramKUI`
- **CWE Mapping**: `CWE-665` (Improper Initialization / Incomplete Emergency Teardown State), `CWE-325` (Missing Cryptographic Step)

### Where the Code Stands Today

Look at [`ConsoleStateController.swift`](../Sources/ScramKUI/ConsoleStateController.swift#L619) (`forceAirgapDump()`) and its command handler at [`ConsoleStateController.swift`](../Sources/ScramKUI/ConsoleStateController.swift#L1210-L1215): pressing `F12` deliberately refuses to fake an action. It publishes `"F12 NOT IMPLEMENTED"` in amber and returns `.failure(ConsoleStateControllerError.notImplemented)`.

Likewise, [`SemanticInterceptInspector.defaultControlStripBadges`](../Sources/ScramKUI/SemanticInterceptInspector.swift#L187-L192) renders `"F12 (NOT IMPLEMENTED)"` right on the HUD control strip, and [`MakerBreakerUISecurityTests.testF12NotImplementedTruthfulnessAndInspectorDrawerHoldLifecycle`](../Tests/ScramKUITests/MakerBreakerUISecurityTests.swift#L94-L127) enforces that exact string in CI.

Why? Because in safety-critical systems, the worst lie you can tell an operator is wiring a panic key to a stub that prints `"AIRGAP DUMP COMPLETE"` while the pipe is still warm and the permit nonce is still sitting in heap memory.

### The Kernel / Memory Attack Surface

While `ESC` (`tripEmergencyAbort`) immediately trips the interlock gate and drains the FIFO waiter queue, an operator dealing with an active containment anomaly needs a dedicated single-keystroke (`F12`) forensic eject button. That operation has to do three things atomically before it ever tells the operator it succeeded:
1. Tear down all active `ContainerSocketBridge` and `FramebufferClient` descriptors so zero additional bytes can cross stdio or `127.0.0.1:7860`.
2. Cryptographically zeroize in-memory single-use `PermissivePermit` nonces, active `BridgeRequestLease` state, and any engaged `ActiveHoldPolicy` hold window.
3. Flush the bounded telemetry and audit ring buffer to an isolated, `0600`-permissioned forensic snapshot file on disk, compute its SHA-256 manifest digest, and wait for kernel `fsync(2)` confirmation.

Until all three steps are wired and verified under fault injection, `F12` stays labeled `NOT IMPLEMENTED`.

### Definition of Done (`XCTest` & Runtime Gate)

- [ ] Implement atomic forensic ring buffer serialization with a SHA-256 manifest digest, strict `0600` octal file permissions, and verified `fsync(2)` completion before returning success to `@MainActor`.
- [ ] Zeroize active `PermissivePermit` nonces, `ActiveHoldPolicy` hold leases, and pending `ContainerSocketBridge` continuations while forcibly retiring active bridge/framebuffer descriptors.
- [ ] Replace the `"F12 (NOT IMPLEMENTED)"` badge in [`SemanticInterceptInspector.swift`](../Sources/ScramKUI/SemanticInterceptInspector.swift#L187-L192) and the `.notImplemented` guard in [`ConsoleStateController.swift`](../Sources/ScramKUI/ConsoleStateController.swift#L1210-L1215) **only** after end-to-end cryptographic wipe and `fsync` failure-injection tests pass in [`MakerBreakerUISecurityTests.swift`](../Tests/ScramKUITests/MakerBreakerUISecurityTests.swift#L94-L127).

---

## Issue 3: `[SEC-CI-03]` Live Container Runtime E2E CI Runner & `LOOPBACK_FB` / `STRICT_AIRGAP` Probe

- **GitHub Issue**: [#3](https://github.com/spetro511/scramkd/issues/3)
- **Priority / Severity**: `P2` / `MEDIUM`
- **Labels**: `security:containment`, `severity:medium`, `subsystem:ScramKVirtualization`
- **CWE Mapping**: `CWE-693` (Protection Mechanism Failure), `CWE-436` (Interpretation Conflict: Host Policy Validator vs. Live Runtime Enforcement)

### Where the Code Stands Today

Our offline test suite runs 372 deterministic XCTests on every build via:

```sh
swift test -Xswiftc -strict-concurrency=complete --skip 'ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState'
```

Notice that `--skip`. [`ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState`](../Tests/ScramKVirtualizationTests/ContainerSocketBridgeTests.swift#L73-L77) (backed by `LiveFrameProbe` at [`ContainerSocketBridgeTests.swift`](../Tests/ScramKVirtualizationTests/ContainerSocketBridgeTests.swift#L83)) requires a live `screenenv_container` instance running on the host. Rather than wrapping that test in a silent `try?` that pretends to pass when Docker isn't running, we separated it cleanly from the offline suite.

At the same time, [`ContainerCreationPolicy.swift`](../Sources/ScramKVirtualization/ContainerCreationPolicy.swift#L5-L64) enforces two strict JSON AST profiles before a container is created: `.strictAirgap` (`"STRICT_AIRGAP"`, requiring `NetworkMode: "none"`) and `.loopbackFramebuffer` (`"LOOPBACK_FB"`, restricting port bindings strictly to `127.0.0.1:7860/tcp` alongside `--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, and `--pids-limit 256`).

### The Host / Container Drift Risk

Validating the `/containers/create` JSON payload in Swift proves what we *asked* the container runtime to enforce; it does not prove that a drifted Docker/containerd daemon on the host actually configured the Linux network namespace and seccomp/capability bounding set the way it was told (`CWE-436`).

We need a dedicated Apple Silicon CI runner that brings up the real hardened `screenenv_container` fixture, runs `testLiveContainerHandshakeUnderPermissiveGateState` without `--skip`, and actively probes the live container's network namespace and port bindings from both sides of the boundary.

### Definition of Done (`XCTest` & Runtime Gate)

- [ ] Provision a dedicated macOS Apple Silicon CI job that builds and launches the hardened `screenenv_container` fixture (`--read-only --cap-drop=ALL --security-opt=no-new-privileges --pids-limit 256 --memory 4g`).
- [ ] Execute `ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState` as a mandatory release gate—failing the pipeline immediately if the test is skipped or throws an infrastructure/protocol error.
- [ ] Add live runtime verification probes asserting that `STRICT_AIRGAP` containers possess only an isolated loopback interface (`--network=none`) with zero outbound route table entries, and that `LOOPBACK_FB` binds `7860/tcp` exclusively on `127.0.0.1` (`0.0.0.0:7860` and `::` rejected).

---

## Issue 4: `[GOV-HYGIENE-04]` Continuous CI Lint Gate Preventing Legacy Namespace Drift & Hardcoded Host Paths

- **GitHub Issue**: [#4](https://github.com/spetro511/scramkd/issues/4)
- **Priority / Severity**: `P3` / `LOW`
- **Labels**: `severity:low`, `subsystem:ScramKCore`
- **CWE Mapping**: `CWE-1059` (Insufficient Technical Documentation / Specification Drift), `CWE-200` (Exposure of Sensitive Information to an Unauthorized Actor — Local Workstation Path Disclosure)

### Where the Code Stands Today

In `MB-00` and `MB-08`, we executed a full atomic namespace cutover across the repository—transitioning every Swift module, type, C11 header, LaunchDaemon plist, and CLI binary to `scramkd` / `ScramK*` (`ScramKCore`, `ScramKVirtualization`, `ScramKAudio`, `CScramKAudioRealtime`, `ScramKUI`, `scramkctl`) and scrubbing local workstation paths from documentation.

### Why We Need an Automated Gate

Across multi-environment contributors and automated tooling, two regressions happen like clockwork unless CI blocks them at the door:
1. A stale branch or contributor reintroduces a pre-cutover `Tactical*` symbol or target name back into a doc or test fixture (`CWE-1059`).
2. A patch introduces a Markdown link or fixture path using the absolute filesystem path of a local workstation (`/Users/<username>/...` or `file://` local URI schemes), leaking local workstation directory structure into the public git history and breaking links for every other engineer who clones the repo (`CWE-200`).

### Definition of Done (`XCTest` & Runtime Gate)

- [x] Add a fast, zero-dependency shell lint script (`scripts/ci/check_legacy_rebrand.sh`) that scans `Package.swift`, `Sources/**`, `Tests/**`, `LaunchDaemons/**`, `.github/**`, and `docs/**` on every PR and push.
- [x] Fail the build immediately on any occurrence of legacy pre-cutover `Tactical*` module/symbol identifiers (outside explicit historical deprecation notes in `SECURITY.md`).
- [x] Fail the build immediately on any hardcoded `/Users/` workstation path or `file://` local URI across all tracked source, configuration, and Markdown files.
- [ ] Connect `scripts/ci/check_legacy_rebrand.sh` to a GitHub Actions PR/push workflow in `.github/workflows/ci.yml`.

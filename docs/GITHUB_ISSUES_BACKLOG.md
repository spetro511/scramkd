# `scramkd` (`v0.4.0`) Zero-Trust Security & Governance Backlog

**Audit Authority**: `tactical-security-architect`  
**Target Release Baseline**: `scramkd` `v0.4.0`  
**Governance Mandate**: Truthful capability reporting, fail-closed boundary enforcement, and deterministic verification ([AGENTS.md](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/AGENTS.md#L1-L101)).

---

## 0. GitHub Label & Security Taxonomy (`gh label create`)

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
gh label create "subsystem:scramkctl"            --color "006B75" --description "Sources/scramkctl (Operator CLI & launchd socket control)" --force
```

| Issue ID | Title | Priority | Severity | Primary CWE | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `[SEC-IPC-01]` | Wire `scramkctl` to `/var/run/scramkd/control.sock` with `LOCAL_PEERCRED` Verification | `P1` | `HIGH` | `CWE-284`, `CWE-306` | `OPEN` |
| `[SEC-INTERLOCK-02]` | Implement F12 Airgap Telemetry Dump & Cryptographic Wipe (`forceAirgapDump`) | `P2` | `MEDIUM` | `CWE-665`, `CWE-325` | `OPEN` |
| `[SEC-CI-03]` | Live Container Runtime E2E CI Runner & `LOOPBACK_FB` / `STRICT_AIRGAP` Probe | `P2` | `MEDIUM` | `CWE-693`, `CWE-436` | `OPEN` |
| `[GOV-AGENTS-04]` | Continuous CI Lint Gate Preventing Legacy Namespace Drift Across `.agents/` & `docs/` | `P3` | `LOW` | `CWE-1059` | `OPEN` |

---

## Issue 1: `[SEC-IPC-01]` Wire `scramkctl` to `/var/run/scramkd/control.sock` with `LOCAL_PEERCRED` Verification

- **Priority / Severity**: `P1` / `HIGH`
- **Labels**: `security:ipc`, `severity:high`, `subsystem:scramkctl`, `subsystem:ScramKCore`
- **CWE Mapping**:
  - `CWE-284`: Improper Access Control
  - `CWE-306`: Missing Authentication for Critical Function

### Evidence & Code Citations
- [`ScramKCLI.main()`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/scramkctl/ScramKCLI.swift#L5-L34) currently instantiates an in-process [`HardwareInterlockGate`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/scramkctl/ScramKCLI.swift#L9) and executes `status`, `grant`, and `abort` against local process memory for deterministic CLI contract validation rather than communicating with a running `scramkd` daemon over IPC.
- [`LaunchDaemons/com.scramk.daemon.plist`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/LaunchDaemons/com.scramk.daemon.plist#L17-L30) provisions `SCRAMKD_CONTROL_SOCKET=/var/run/scramkd/control.sock` and a launchd UNIX domain socket dictionary `Sockets.ControlSocket` with `SockPathName=/var/run/scramkd/control.sock` and `SockPathMode=384` (`0600` octal).

### Threat Model & Boundary Invariant
- **Threat**: Without an authenticated UNIX domain control channel between `scramkctl` and `scramkd`, out-of-band CLI invocations (`scramkctl abort` / `scramkctl grant`) do not mutate the live daemon's [`HardwareInterlockGate`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKCore/InterlockEngine.swift#L19-L260). Conversely, if `/var/run/scramkd/control.sock` is exposed without kernel-enforced peer credential inspection, an unprivileged local process could forge `grant` or `abort` frames if filesystem permissions are relaxed.
- **Boundary Invariant**: Every control socket connection accepted on `SCRAMKD_CONTROL_SOCKET` must extract kernel peer credentials via `getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, ...)` (`xucred.cr_uid`) and `LOCAL_PEERPID` before parsing any frame, rejecting non-root/non-owner callers fail-closed prior to deserialization.

### Acceptance Criteria
1. Implement a dedicated `ControlSocketServer` / `ControlSocketClient` binding `/var/run/scramkd/control.sock` (or launchd-inherited file descriptor via `launch_activate_socket("ControlSocket")`).
2. Enforce `LOCAL_PEERCRED` (`xucred.cr_uid == 0` or daemon effective UID) and `LOCAL_PEERPID` audit logging on every accepted connection before `status`, `grant`, or `abort` dispatch.
3. Connect [`ScramKCLI.swift`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/scramkctl/ScramKCLI.swift#L5-L34) to `SCRAMKD_CONTROL_SOCKET` with deterministic fallback/error reporting when the daemon socket is absent.
4. Add unit and adversarial Breaker tests verifying unprivileged UID rejection and malformed control frame handling.

---

## Issue 2: `[SEC-INTERLOCK-02]` Implement F12 Airgap Telemetry Dump & Cryptographic Wipe (`forceAirgapDump`)

- **Priority / Severity**: `P2` / `MEDIUM`
- **Labels**: `security:crypto`, `security:containment`, `severity:medium`, `subsystem:ScramKUI`
- **CWE Mapping**:
  - `CWE-665`: Improper Initialization / Incomplete Emergency Teardown State
  - `CWE-325`: Missing Cryptographic Step

### Evidence & Code Citations
- [`ConsoleStateController.triggerRekeyAndAirgapDisconnect()`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKUI/ConsoleStateController.swift#L140-L162) truthfully short-circuits `F12`, recording `"NOT IMPLEMENTED — F12 REKEY/DISCONNECT UNAVAILABLE"` in the audit ledger rather than fabricating a disconnect or silently substituting `abort`.
- [`SemanticInterceptInspector.defaultControlStripBadges`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKUI/SemanticInterceptInspector.swift#L187-L192) explicitly renders `"F12 (NOT IMPLEMENTED)"`.
- [`MakerBreakerUISecurityTests.testF12NotImplementedTruthfulnessAndInspectorDrawerHoldLifecycle`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Tests/ScramKUITests/MakerBreakerUISecurityTests.swift#L94-L127) locks this truthful non-implementation invariant in CI so UI layers never fabricate airgap dump completion.

### Threat Model & Boundary Invariant
- **Threat**: Operators responding to an active containment anomaly require a single-keystroke (`F12`) forensic snapshot, transport disconnect, and cryptographic zeroization of transient session tokens (`PermissivePermit`, ephemeral MCP session state, and buffered telemetry rings). Until implemented, claiming completion would violate Zero-Trust operator truthfulness ([AGENTS.md §4](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/AGENTS.md#L76-L86)).
- **Boundary Invariant**: `F12` must remain explicitly labeled `NOT IMPLEMENTED` until it atomically: (1) revokes active transport descriptors, (2) zeroizes in-memory permit material and active hold state, and (3) writes a SHA-256 signed, append-only forensic ring dump to an isolated, `0600`-permissioned audit file with `fsync` confirmation.

### Acceptance Criteria
1. Implement atomic forensic ring buffer serialization with SHA-256 manifest digest and `0600` file permissions.
2. Zeroize active `PermissivePermit` tokens, `ActiveHoldPolicy` hold leases, and pending `ContainerSocketBridge` continuations prior to returning completion.
3. Only remove the `"F12 (NOT IMPLEMENTED)"` badge in [`SemanticInterceptInspector.swift`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKUI/SemanticInterceptInspector.swift#L187-L192) and [`ConsoleStateController.swift`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKUI/ConsoleStateController.swift#L140-L162) once end-to-end cryptographic wipe and disk `fsync` verification tests pass.

---

## Issue 3: `[SEC-CI-03]` Live Container Runtime E2E CI Runner & `LOOPBACK_FB` / `STRICT_AIRGAP` Probe

- **Priority / Severity**: `P2` / `MEDIUM`
- **Labels**: `security:containment`, `severity:medium`, `subsystem:ScramKVirtualization`
- **CWE Mapping**:
  - `CWE-693`: Protection Mechanism Failure
  - `CWE-436`: Interpretation Conflict (Host Policy Validator vs. Live Runtime Enforcement)

### Evidence & Code Citations
- [`ContainerSocketBridgeTests.testLiveContainerHandshakeUnderPermissiveGateState`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Tests/ScramKVirtualizationTests/ContainerSocketBridgeTests.swift#L15-L75) requires a provisioned local container runtime (`screenenv_container`) and is skipped during offline `swift test` runs ([AGENTS.md §5](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/AGENTS.md#L92-L100)).
- [`ContainerCreationPolicy.swift`](file:///Users/surensahaydachny/MOSDEF/tactical-hypervisor-macos/Sources/ScramKVirtualization/ContainerCreationPolicy.swift#L5-L8) defines two security profiles: `.strictAirgap` (`"STRICT_AIRGAP"`) and `.loopbackFramebuffer` (`"LOOPBACK_FB"`, restricting port exposure and host bindings strictly to `127.0.0.1:7860/tcp`).

### Acceptance Criteria
1. Provision a dedicated macOS Apple Silicon CI job with an airgapped `screenenv_container` fixture.
2. Fail the release pipeline if `testLiveContainerHandshakeUnderPermissiveGateState` is skipped in release-gate mode.
3. Assert runtime network namespace isolation for both `STRICT_AIRGAP` and `LOOPBACK_FB` (`127.0.0.1:7860`).

---

## Issue 4: `[GOV-AGENTS-04]` Continuous CI Lint Gate Preventing Legacy Namespace Drift Across `.agents/` & `docs/`

- **Priority / Severity**: `P3` / `LOW`
- **Labels**: `severity:low`, `subsystem:ScramKCore`
- **CWE Mapping**:
  - `CWE-1059`: Insufficient Technical Documentation / Specification Drift

### Acceptance Criteria
1. Enforce a pre-commit / CI check verifying zero occurrences of legacy `Tactical*` target names across `Package.swift`, `Sources/**`, `Tests/**`, `.agents/**`, and `docs/**`.

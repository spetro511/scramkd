# Security Policy & Zero-Trust Vulnerability Disclosure (`scramkd`)

`scramkd` is a deterministic Darwin supervisor daemon and hardware-grade human-in-the-loop interlock runtime. Because its primary purpose is containing untrusted, autonomous, or compromised agent processes on bare-metal macOS (Apple Silicon), any bypass of its isolation, authorization, or transport boundaries is treated as a critical systems defect.

---

## 1. Supported Versions

Only the current hardened `scramkd` namespace cutover (`v0.4.0+`) compiled under Swift 6 complete strict concurrency (`-Xswiftc -strict-concurrency=complete`) receives security updates. Legacy `TacticalHypervisor` (`< v0.4.0`) pre-cutover snapshots are unsupported.

| Version | Namespace | Swift Language Mode | Status |
| :--- | :--- | :--- | :--- |
| **`v0.4.x`** | `scramkd` / `ScramK*` | Swift 6 (`.v6`) + C11 (`.c11`) | ✅ **Supported (Active Hardening)** |
| `< v0.4.0` | `TacticalHypervisor` | Pre-cutover | ❌ **Unsupported (End-of-Life)** |

---

## 2. Reporting a Vulnerability (Private Security Advisories)

**Do NOT report zero-day interlock bypasses, TOCTOU races, or container escape vectors in public GitHub Issues or public GitHub Discussions.**

Please submit vulnerability reports exclusively through **GitHub Private Vulnerability Reporting**:

- **Report Privately**: [Open a Private Security Advisory](https://github.com/spetro511/tactical-hypervisor-macos/security/advisories/new)

### Required Diagnostic Payload
To accelerate deterministic reproduction by the `tactical-breaker` and `tactical-security-architect` verification pipeline, include:
1. **Target Subsystem**: `ScramKCore`, `ScramKVirtualization`, `ScramKAudio`, `CScramKAudioRealtime`, `ScramKUI`, `scramkd`, or `scramkctl`.
2. **Boundary Invariant Violated**:
   - Single-use `PermissivePermit` replay, forgery, or multi-waiter piggybacking (`HardwareInterlockGate` / `BridgeRequestLease`).
   - `ContainerSecurityProfile` AST policy bypass (`ContainerCreationPolicy`, non-loopback port binding, writable rootfs, capability escalation).
   - `MCPNonblockingWriter` continuation leak, partial-frame injection, or cancellation race.
   - `DefaultSubprocessEnvironmentScrubber` 7-key allowlist escape or `DYLD_*` / `PATH` injection.
   - `ActiveHoldPolicy` dead-man switch bypass (`Space` hold / `ESC` preemption / `120s` monotonic lease ceiling).
   - Realtime CoreAudio C11 ring-buffer memory safety violation (`CScramKAudioRealtime`).
3. **Minimal Deterministic Reproduction**: Preferably formatted as an XCTest case that can be dropped into `Tests/ScramKCoreTests/MakerBreakerCoreSecurityTests.swift` or `Tests/ScramKVirtualizationTests/MakerBreakerVirtualizationSecurityTests.swift`.

### Response & Remediation SLA
- **Acknowledgment**: Within **24 hours** of private submission.
- **Triage & Deterministic Reproduction**: Within **72 hours**, verified by a failing adversarial XCTest.
- **Remediation & Coordinated Release**: Every confirmed vulnerability is patched alongside a permanent regression test in the `MakerBreaker*SecurityTests` suite and published with an annotated release tag and CVE/GHSA advisory credit.

---

## 3. Non-Exploit Hardening & Public Threat Modeling

For defense-in-depth enhancements, architecture RFCs, and tracked Stage 3 engineering work (`[SEC-IPC-01]` through `[GOV-AGENTS-04]`), use the repository's native zero-churn channels:

- **Stage 3 Security Backlog**: See [docs/GITHUB_ISSUES_BACKLOG.md](docs/GITHUB_ISSUES_BACKLOG.md) and active [GitHub Issues](https://github.com/spetro511/tactical-hypervisor-macos/issues).
- **Architecture RFCs & Threat Model Q&A**: Participate in [GitHub Discussions](https://github.com/spetro511/tactical-hypervisor-macos/discussions) under `Architecture RFCs` or `Threat Model & Bypass Bounties`.

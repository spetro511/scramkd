# Security Policy & Vulnerability Disclosure (`scramkd`)

`scramkd` is a deterministic Darwin supervisor daemon and human-in-the-loop hardware interlock built for one job: keeping autonomous, prompt-injected, or outright compromised agent processes from executing unapproved actions on bare-metal macOS.

Because this runtime sits directly on the containment boundary between untrusted agent containers and host memory, we treat any bypass of its state machine, permit lifecycle, environment scrubber, or transport framing as a critical systems defect. We do not hide behind "beta" disclaimers, and we do not ship silent workarounds.

---

## 1. Supported Versions

Only the current `scramkd` (`ScramK*`) architecture (`v0.4.0+`), compiled under Swift 6 complete strict concurrency (`-Xswiftc -strict-concurrency=complete`) and C11 (`.c11`), is supported. Pre-cutover `TacticalHypervisor` snapshots (`< v0.4.0`) are end-of-life and receive no patches.

| Version | Namespace & Binaries | Compiler Posture | Security Support |
| :--- | :--- | :--- | :--- |
| **`v0.4.x`** | `scramkd` / `scramkctl` / `ScramK*` | Swift 6 (`.v6`) + C11 (`.c11`), `0 warnings` | ✅ **Actively Supported** |
| `< v0.4.0` | `TacticalHypervisor` (pre-cutover) | Legacy | ❌ **End-of-Life (Unsupported)** |

---

## 2. Reporting an Exploitable Vulnerability (Private Advisory Only)

**If you have found a way to bypass the interlock gate, replay a `PermissivePermit`, smuggle environment variables past the 7-key scrubber, or escape the container bridge—do NOT post it in a public GitHub Issue or Discussion.**

Submit exploitable findings exclusively through **GitHub Private Vulnerability Reporting**:

- **Private Advisory Endpoint**: [Open a Private Security Advisory](https://github.com/spetro511/scramkd/security/advisories/new)

### What to Send Us (Skip the Fluff, Send the Reproducer)

If you want fast triage, give us the exact mechanism and a deterministic test case. Tell us:

1. **The Target Subsystem**: `ScramKCore`, `ScramKVirtualization`, `ScramKAudio`, `CScramKAudioRealtime`, `ScramKUI`, `scramkd`, or `scramkctl`.
2. **The Exact Invariant You Broke**:
   - **Single-use permit or gate race (`ScramKCore`)**: Did you get two concurrent MCP tool calls through a single `PermissivePermit`, forge a `BridgeRequestLease`, or trigger a continuation double-resume/leak under cancellation?
   - **Container policy or stdio framing bypass (`ScramKVirtualization`)**: Did you smuggle a forbidden Docker directive past `ContainerCreationPolicy` (e.g., duplicate canonical JSON keys, deep nesting, non-loopback port bindings), inject a partial frame through `MCPNonblockingWriter` during an abort, or leak a `DYLD_*` / `LD_PRELOAD` / `PATH` variable past `MCPProcessTransport`?
   - **Dead-man switch or HUD spoofing (`ScramKUI`)**: Did you keep `ActiveHoldPolicy` open past its monotonic lease ceiling, lose window focus without triggering an automatic relock, or spoof caller provenance (`UID`/`PID`) in `SemanticInterceptInspector`?
   - **Realtime audio memory safety (`CScramKAudioRealtime`)**: Did you trigger an out-of-bounds read/write, lock, or heap allocation inside the C11 SPSC ring buffer on the CoreAudio realtime render thread?
3. **A Deterministic XCTest Reproducer**: The gold standard is an XCTest method we can drop straight into `Tests/ScramKCoreTests/MakerBreakerCoreSecurityTests.swift`, `Tests/ScramKVirtualizationTests/MakerBreakerVirtualizationSecurityTests.swift`, or `Tests/ScramKUITests/MakerBreakerUISecurityTests.swift` that fails deterministically under:
   ```sh
   swift test -Xswiftc -strict-concurrency=complete
   ```

### Our Commitment to Researchers

- **24-Hour Acknowledgment**: A human systems architect—not an auto-responder—will acknowledge your report within **24 hours**.
- **72-Hour Deterministic Triage**: Within **72 hours**, we will reproduce the finding and convert it into a failing `MakerBreaker*SecurityTests` regression test.
- **Permanent Fix & Full Credit**: Every confirmed bypass is fixed at the architectural root, locked in CI with a permanent regression test, and published via a coordinated GitHub Security Advisory (GHSA / CVE) with full attribution to you (unless you prefer to remain anonymous).

---

## 3. Public Hardening Backlog & Architectural Debate

Not every security conversation is a zero-day. If you want to work on known Stage 3 hardening items (`[SEC-IPC-01]` through `[GOV-HYGIENE-04]`), debate Darwin/XPC supervisor patterns, or propose a new concurrency fault probe that doesn't expose a live exploit:

- **Stage 3 Engineering Backlog**: Read [docs/GITHUB_ISSUES_BACKLOG.md](docs/GITHUB_ISSUES_BACKLOG.md) and check the live [GitHub Issues](https://github.com/spetro511/scramkd/issues).
- **Architecture RFCs & Threat Modeling**: Start a thread in [GitHub Discussions](https://github.com/spetro511/scramkd/discussions).

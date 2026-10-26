# `SCRAMKD` // Brand Guidelines & Normative Systems Specification

> **System Authority**: Darwin Supervisor Daemon & Hardware Interlock Runtime  
> **Standard Compliance**: MIL-STD-1472H §05.02 / EAL6+ Audit Posture  
> **Source Project**: Stitch ID `6933813483536620899` (*SCRAMKD Tactical Interlock Branding*)

---

## 1. Retrieved Brand Assets Inventory

All screen artifacts, raw HTML source files, manifests, and high-resolution renders have been downloaded and cataloged locally under [`stitch_screens/brand_guidelines/`](../../../stitch_screens/brand_guidelines/):

| # | Screen / Asset Name | Stitch Screen ID | Type / Format | Local Files |
| :-: | :--- | :--- | :--- | :--- |
| **01** | Marketing Social Card (1:1) | `8f3dbc75921a4085abdb587d976b7519` | PNG (1024×1024) | [`01_marketing_card_1x1.png`](../../../stitch_screens/brand_guidelines/01_marketing_card_1x1.png) |
| **02** | Display Banner Ad (16:9) | `624faac8c3a44bb9b935f0b4033910f6` | PNG (1376×768) | [`02_display_banner_ad_16x9.png`](../../../stitch_screens/brand_guidelines/02_display_banner_ad_16x9.png) |
| **03** | Newsletter Header Banner (16:9) | `c6e6f42b89ce420bbd7af486e112f68d` | PNG (1376×768) | [`03_newsletter_header_16x9.png`](../../../stitch_screens/brand_guidelines/03_newsletter_header_16x9.png) |
| **04** | Marketing Launch Copy & Announcement | `bcd379fe94014bdb97f383e2ff7b2c69` | HTML + Render | [`04_marketing_launch_copy.html`](../../../stitch_screens/brand_guidelines/04_marketing_launch_copy.html)<br>[`04_marketing_launch_copy.png`](../../../stitch_screens/brand_guidelines/04_marketing_launch_copy.png) |
| **05** | Favicon & PWA Application Icon (1:1) | `b00586cbb81f4c0382b89a9911a4d856` | PNG (1024×1024) | [`05_favicon_pwa_icon.png`](../../../stitch_screens/brand_guidelines/05_favicon_pwa_icon.png) |
| **06** | Web Application Manifest | `9ced4d6428814406b8ddefb50c4d050e` | JSON | [`manifest.json`](../../../stitch_screens/brand_guidelines/manifest.json) |
| **07** | Apple Touch Icon (1:1) | `fabdd3d9d2644622b43f00b39cd45635` | PNG (1024×1024) | [`07_apple_touch_icon.png`](../../../stitch_screens/brand_guidelines/07_apple_touch_icon.png) |
| **08** | Normative Brand Book (Chassis Spec) | `866960c920ba4730b66029a610ab7200` | HTML + Render | [`08_normative_brand_book.html`](../../../stitch_screens/brand_guidelines/08_normative_brand_book.html)<br>[`08_normative_brand_book.png`](../../../stitch_screens/brand_guidelines/08_normative_brand_book.png) |
| **09** | Interactive Animated Brand Book | `da5890461fc24780b40198f916e3d4fc` | HTML + Render | [`09_interactive_brand_book.html`](../../../stitch_screens/brand_guidelines/09_interactive_brand_book.html)<br>[`09_interactive_brand_book.png`](../../../stitch_screens/brand_guidelines/09_interactive_brand_book.png) |

---

## 2. Logo Topology & Geometric Precision

The `SCRAMKD` mark is structured as an **authentic electrical circuit schematic** rather than a consumer graphic logo.

### 2.1 The 64×64 Normalized Vector Topology
```
┌──                                  ──┐
│ [4,4]                           [60,4]│
│                                       │
│   ──(22,32)───[ 45° BLADE ]───(42,32)──│
│                 (32,32)               │
│                                       │
│ [4,60]                         [60,60]│
└──                                  ──┘
```
1. **Four Machined Corner Brackets**: Bounded at normalized coordinates `[4,4]`, `[60,4]`, `[4,60]`, `[60,60]`, rendered in solid white (`#FFFFFF`) with 2.5px stroke width and square line caps.
2. **Conductive Bus Traces**: Horizontal axis lines (`#64748B`, stroke-width 3px) connecting terminal bus pads at `(22,32)` and `(42,32)`.
3. **45° Radical Red Circuit Sever Blade**: Precision diagonal line (`#EF4444`, stroke-width 4.5px) traversing from `(18,46)` to `(46,18)` through the central armed trip core at `(32,32)` ($r=5\text{px}$).

### 2.2 Wordmark Construction
* **Format**: `SCRAMKD` (never broken into two words).
* **Typography**: **Inter 900 (Black)**, tracking `-0.05em`, all caps.
* **Color Split**: `SCRAM` rendered in absolute white (`#FFFFFF`), `KD` rendered in slate titanium (`#94A3B8`).

---

## 3. Normative Chromatic System (Zero Ambient Trim Policy)

> [!IMPORTANT]
> **Operational Liability Rule**: Color is never decorative. Every hue corresponds directly to an inviolable finite-state machine (FSM) state in the Darwin mediation runtime.

| Identifier | Pantone / Wavelength | Hex / P3 Values | FSM Transition | Contrast | Operational Function |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Radical Red** | Pantone 1795 C<br>$\lambda = 625\text{ nm}$ | `#EF4444`<br>`rgb(239, 68, 68)` | `TRIP / SCRAM` | 7.4:1 (Pass) | **Emergency Abort**: Mach lease broker invalidates active leases; issues SIGKILL to agent stdio pipe; continuation queue drained. |
| **Armed Amber** | Pantone 137 C<br>$\lambda = 590\text{ nm}$ | `#F59E0B`<br>`rgb(245, 158, 11)` | `ARMED / GATE` | 11.2:1 (Pass) | **Intercept Trapped**: High-risk syscall intercepted; pipeline suspended pending physical operator permissive grant or TTL timeout. |
| **Tactical Emerald** | Pantone 340 C<br>$\lambda = 525\text{ nm}$ | `#10B981`<br>`rgb(16, 185, 129)` | `PERMISSIVE` | 8.1:1 (Pass) | **Operator Cleared**: Ephemeral single-use wire lease dispatched; automatically closes on buffer drain without persistent token retention. |
| **Slate Gray** | Pantone 431 C | `#64748B`<br>`#94A3B8` | `INERT / LOCKED` | 4.9:1 (Inert) | **Quiescent Baseline**: Default locked state; structural hairline grids; high-risk tool calls rejected prior to invocation. |

### Architectural Enclosure Palette
* **Pitch Canvas Substrate**: `#04060A` (Deepest subterranean obsidian)
* **Chassis Surface**: `#070A10` (Bead-blasted anodized titanium)
* **Milled Pocket**: `#090D15` (Recessed instrument bay)
* **Structural Hairlines**: `rgba(255, 255, 255, 0.08)` / `#0B111D` (1px precision dividers)

---

## 4. Typographic Discipline & Industrial Rigor

### Dual-Family Strict Division
1. **Inter (Swiss Sans)**:
   * **Role**: Executive titles, monograph headings, marketing prose, and structural authority.
   * **Constraints**: Max line length 75ch, line-height 1.6 for body copy. No drop shadows or decorative gradients.
2. **Geist Mono (Tabular Monospace)**:
   * **Role**: Memory addresses, latency timestamps, system call signatures, and POSIX descriptors.
   * **Constraints**: Strict tabular lining figures (`font-variant-numeric: tabular-nums`) to prevent layout jitter during microsecond telemetry streams. Double-slash separators (`//`) for hardware tags.

---

## 5. Marketing Positioning & Copy Framework

From [`04_marketing_launch_copy.html`](../../../stitch_screens/brand_guidelines/04_marketing_launch_copy.html):
* **Core Thesis**: *"Stop relying on conversational guardrails and probabilistic prompt classifiers. SCRAMKD delivers hardware-grade, non-bypassable process isolation to keep mission-critical agent workflows safe."*
* **Key Invariants**:
  1. **< 400 μs Trip**: Microsecond kernel signal drain of pending waiter continuations.
  2. **Zero Egress**: Complete air-gap sandbox without unauthorized network sockets.
  3. **Swift 6 Strict**: Data-race freedom guaranteed by compile-time actor isolation.

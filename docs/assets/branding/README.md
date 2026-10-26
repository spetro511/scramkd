# SCRAMKD // Brand Asset Architecture & Creative Matrix

> **System Authority**: Darwin Supervisor Daemon & Hardware Interlock Runtime  
> **Standard Compliance**: MIL-STD-1472H §05.02 / EAL6+ Interlock Audit Posture  
> **Source Stitch Project**: ID `6933813483536620899` (*SCRAMKD Tactical Interlock Branding*)  
> **Repository Location**: [`docs/assets/branding/`]()

---

## 1. Directory Structure

```text
docs/assets/branding/
├── README.md
├── vectors/
│   ├── scramkd_mark_primary.svg
│   ├── scramkd_mark_monochrome.svg
│   ├── scramkd_mark_inverse.svg
│   ├── scramkd_wordmark_severed.svg
│   ├── scramkd_reticle_emblem_120x120.svg
│   ├── scramkd_hardware_header_1200x320.svg
│   ├── scramkd_brand_lockup_master.svg
│   ├── scramkd_brand_lockup_transparent.svg
│   └── optical/
│       ├── scramkd_badge_64x64.svg
│       ├── scramkd_appicon_32x32.svg
│       └── scramkd_menubar_20x20.svg
├── icons/
│   ├── manifest.json
│   ├── favicon.ico
│   ├── favicon-16x16.png
│   ├── favicon-32x32.png
│   ├── favicon-48x48.png
│   ├── icon-192x192.png
│   ├── icon-512x512.png
│   ├── favicon_pwa_1024x1024.png
│   ├── apple_touch_icon_180x180.png
│   └── apple_touch_icon_1024x1024.png
├── marketing/
│   ├── scramkd_marketing_launch_copy.md
│   ├── scramkd_marketing_launch_copy.html
│   ├── scramkd_marketing_launch_copy.png
│   ├── scramkd_github_hero_banner_800x260.html
│   ├── scramkd_github_hero_banner_800x260.png
│   ├── scramkd_github_opengraph_1280x640.html
│   ├── scramkd_github_opengraph_1280x640.png
│   ├── scramkd_social_card_1024x1024.png
│   ├── scramkd_display_banner_1376x768.png
│   ├── scramkd_newsletter_header_1376x768.png
│   ├── marketing_kit.md
│   └── web_assets.md
├── diagrams/
│   ├── architectural_containment_pipeline.html
│   ├── architectural_containment_pipeline.png
│   ├── threat_model_interlock_flow.html
│   ├── threat_model_interlock_flow.png
│   ├── native_tactical_console_viewport.html
│   └── native_tactical_console_viewport.png
└── specifications/
    ├── scramkd_brand_guidelines.md
    ├── normative_brand_book.html
    ├── normative_brand_book.png
    ├── interactive_brand_book.html
    ├── interactive_brand_book.png
    ├── swiss_editorial_spec.html
    └── swiss_editorial_spec.png
```

---

## 2. Vector Marks & Geometry (`vectors/`)

All vector marks are standalone XML documents with explicit `viewBox`, dimension boundaries, and no external runtime dependencies.

| Asset | Format | Native Dimensions | Purpose & Technical Spec |
| :--- | :---: | :---: | :--- |
| [`scramkd_mark_primary.svg`](vectors/scramkd_mark_primary.svg) | SVG | 64×64 | Authoritative Primary Operational Mark: 4 machined white corner brackets (`#FFFFFF`), horizontal `#64748B` bus traces, 45° Radical Red (`#EF4444`) sever blade, armed central trip core ($r=5\text{px}$). |
| [`scramkd_mark_monochrome.svg`](vectors/scramkd_mark_monochrome.svg) | SVG | 64×64 | Monochromatic pure silhouette (`#FFFFFF` on transparent) for 1-bit thermal dispatch printing and laser engraving. |
| [`scramkd_mark_inverse.svg`](vectors/scramkd_mark_inverse.svg) | SVG | 64×64 | Inverse light / photoprint mark (`#0F172A` brackets/bus, `#DC2626` blade) for patent filings and compliance monographs. |
| [`scramkd_wordmark_severed.svg`](vectors/scramkd_wordmark_severed.svg) | SVG | 540×120 | Severed Wordmark Lockup: Bold geometric typography featuring 45° Radical Red cut separating `SCRAM` and `KD`. |
| [`scramkd_reticle_emblem_120x120.svg`](vectors/scramkd_reticle_emblem_120x120.svg) | SVG | 120×120 | Reticle Emblem: Concentric circular calibration rings, azimuth ticks, Cartesian grid lines, and central sever core. |
| [`scramkd_hardware_header_1200x320.svg`](vectors/scramkd_hardware_header_1200x320.svg) | SVG | 1200×320 | DIN-Rail Hardware Header Banner: Full-width chassis plate with machined hex mounting boltholes, telemetry buses, and status readouts. |
| [`scramkd_brand_lockup_master.svg`](vectors/scramkd_brand_lockup_master.svg) | SVG | 640×120 | Master Horizontal Lockup: Primary 64×64 mark, severed wordmark, `SWIFT 6 // ZERO EGRESS` badge, telemetry, on `#030508` obsidian substrate. |
| [`scramkd_brand_lockup_transparent.svg`](vectors/scramkd_brand_lockup_transparent.svg) | SVG | 640×120 | Master Horizontal Lockup on transparent canvas for embedding into documentation headers and third-party panels. |

### Optical Benchmark Suite (`vectors/optical/`)
To prevent visual hairline collapse across micro-scale renderings, stroke gauges and trip terminals are calibrated per scale tier:

| Scale Tier | Asset | Stroke Gauge | Blade Gauge | Terminal Radius |
| :--- | :--- | :---: | :---: | :---: |
| **64px Chassis** | [`scramkd_badge_64x64.svg`](vectors/optical/scramkd_badge_64x64.svg) | 3.0px | 5.0px | $r=6.0\text{px}$ |
| **32px AppIcon** | [`scramkd_appicon_32x32.svg`](vectors/optical/scramkd_appicon_32x32.svg) | 4.0px | 6.0px | $r=7.0\text{px}$ |
| **20px MenuBar** | [`scramkd_menubar_20x20.svg`](vectors/optical/scramkd_menubar_20x20.svg) | 6.0px | 9.0px (Merged) | $r=10.0\text{px}$ |

---

## 3. Web & Application Icon Suite (`icons/`)

Generated from the raw master 1024×1024 renders to ensure zero compression artifacting:

| File | Resolution | Format | Purpose / Usage |
| :--- | :---: | :---: | :--- |
| [`favicon.ico`](icons/favicon.ico) | Multi (16/32/48) | ICO | Legacy browser fallback container with 16×16, 32×32, and 48×48 frames. |
| [`favicon-16x16.png`](icons/favicon-16x16.png) | 16×16 | PNG | Browser tab icon for standard density displays. |
| [`favicon-32x32.png`](icons/favicon-32x32.png) | 32×32 | PNG | Browser tab icon for Retina / high-DPI displays. |
| [`favicon-48x48.png`](icons/favicon-48x48.png) | 48×48 | PNG | Windows taskbar / desktop pinned shortcut icon. |
| [`icon-192x192.png`](icons/icon-192x192.png) | 192×192 | PNG | Progressive Web App maskable application icon. |
| [`icon-512x512.png`](icons/icon-512x512.png) | 512×512 | PNG | Progressive Web App splash / installation icon. |
| [`favicon_pwa_1024x1024.png`](icons/favicon_pwa_1024x1024.png) | 1024×1024 | PNG | Master uncompressed square icon canvas. |
| [`apple_touch_icon_180x180.png`](icons/apple_touch_icon_180x180.png) | 180×180 | PNG | iOS / iPadOS Springboard touch icon (native edge-to-edge bleed). |
| [`apple_touch_icon_1024x1024.png`](icons/apple_touch_icon_1024x1024.png) | 1024×1024 | PNG | High-resolution Apple App Store / App Clip touch asset. |
| [`manifest.json`](icons/manifest.json) | — | JSON | W3C Web App Manifest pre-configured with icons, theme color (`#070A10`), and background (`#04060A`). |

---

## 4. Marketing Creatives & Collateral (`marketing/`)

| Asset | Dimensions / Type | Description / Channels |
| :--- | :---: | :--- |
| [`scramkd_github_hero_banner_800x260.png`](marketing/scramkd_github_hero_banner_800x260.png) | 2560×2048 Master (PNG/HTML) | High-impact GitHub repository header banner featuring the primary severed lockup, `< 400 μs TRIP` metrics, and status readouts. |
| [`scramkd_github_opengraph_1280x640.png`](marketing/scramkd_github_opengraph_1280x640.png) | 1280×640 (PNG/HTML) | Production OpenGraph / Twitter Card preview banner (`summary_large_image`). |
| [`scramkd_social_card_1024x1024.png`](marketing/scramkd_social_card_1024x1024.png) | 1024×1024 (PNG) | 1:1 square social card for LinkedIn, X (Twitter), and developer forums. |
| [`scramkd_display_banner_1376x768.png`](marketing/scramkd_display_banner_1376x768.png) | 1376×768 (PNG) | 16:9 widescreen display ad for technical sponsorships and security publications. |
| [`scramkd_newsletter_header_1376x768.png`](marketing/scramkd_newsletter_header_1376x768.png) | 1376×768 (PNG) | 16:9 newsletter header banner with flush anodized faceplate and LED indicator light-pipes. |
| [`scramkd_marketing_launch_copy.md`](marketing/scramkd_marketing_launch_copy.md) | Markdown | Monograph-grade launch copy: headline, positioning thesis, 3 core invariants, and executive CTA. |
| [`scramkd_marketing_launch_copy.html`](marketing/scramkd_marketing_launch_copy.html) | HTML + Render | Styled launch release document with embedded layout and typography. |
| [`marketing_kit.md`](marketing/marketing_kit.md) | Markdown | Production delivery notes and channel breakdown for the marketing collateral. |
| [`web_assets.md`](marketing/web_assets.md) | Markdown | Implementation guidelines for deploying the web application icon suite. |

---

## 5. Architectural & Threat Model Visualizations (`diagrams/`)

High-fidelity diagrams extracted and rendered directly from the high-assurance systems identity:

| Visual Schematic | Formats | Content & Verification |
| :--- | :---: | :--- |
| **Architectural Containment Pipeline** | [`HTML`](diagrams/architectural_containment_pipeline.html) / [`PNG`](diagrams/architectural_containment_pipeline.png) | FIG 2.1: End-to-end mediation pipeline from untrusted AI agent syscalls, through Mach lease validation and Darwin gatekeeper, into isolated execution runtimes. |
| **Threat Model & Interlock Flow** | [`HTML`](diagrams/threat_model_interlock_flow.html) / [`PNG`](diagrams/threat_model_interlock_flow.png) | Interlock FSM state flowchart detailing pre-write lease checking, token expiration boundaries, SIGKILL propagation, and crash containment. |
| **Native Supervisor Console Viewport** | [`HTML`](diagrams/native_tactical_console_viewport.html) / [`PNG`](diagrams/native_tactical_console_viewport.png) | Wireframe and chromatic blueprint for the native macOS SwiftUI / Metal supervisor cockpit (Display P3). |

---

## 6. Specifications & Normative Brand Books (`specifications/`)

| Specification Document | Formats | Scope & Normative Standards |
| :--- | :---: | :--- |
| **Normative Brand Book** | [`HTML`](specifications/normative_brand_book.html) / [`PNG`](specifications/normative_brand_book.png) | Authoritative reference specifying geometric ratios, optical compensation formulas, clearspace enclosures, and palette mappings. |
| **Interactive Brand Book** | [`HTML`](specifications/interactive_brand_book.html) / [`PNG`](specifications/interactive_brand_book.png) | Animated, telemetry-reactive web specification with live state toggling and interactive component inspection. |
| **Swiss Editorial Specification** | [`HTML`](specifications/swiss_editorial_spec.html) / [`PNG`](specifications/swiss_editorial_spec.html) | Industrial layout grid system, typographic scale hierarchies, margin calculations, and document structure guidelines. |
| **Brand Guidelines Monograph** | [`Markdown`](specifications/scramkd_brand_guidelines.md) | Exhaustive systems monograph detailing compliance with MIL-STD-1472H §05.02, zero-ambient-trim chromatic rules, and copy tone. |

---

## 7. Chromatic System & FSM Mappings (Zero-Ambient-Trim Policy)

> [!IMPORTANT]
> Color is functional, not decorative. Every chromatic token maps 1:1 to an authoritative supervisor FSM gate state.

| Token | Pantone / Wavelength | Hex Code | Display P3 Value | Supervisor State | Operational Meaning |
| :--- | :--- | :---: | :--- | :--- | :--- |
| **Radical Red** | Pantone 1795 C / $\lambda = 625\text{ nm}$ | `#EF4444` | `color(display-p3 0.937 0.267 0.267)` | `TRIP / SCRAM` | Emergency Abort: Wire leases revoked; SIGKILL sent to agent stdio; continuation queue drained. |
| **Armed Amber** | Pantone 137 C / $\lambda = 590\text{ nm}$ | `#F59E0B` | `color(display-p3 0.961 0.620 0.043)` | `ARMED / GATE` | Syscall Intercepted: Operation suspended pending physical operator grant or TTL expiry. |
| **Tactical Emerald** | Pantone 340 C / $\lambda = 525\text{ nm}$ | `#10B981` | `color(display-p3 0.063 0.725 0.506)` | `PERMISSIVE` | Operator Cleared: Ephemeral single-use lease issued; auto-invalidates on buffer drain. |
| **Slate Gray** | Pantone 431 C | `#64748B` | `color(display-p3 0.392 0.455 0.545)` | `INERT / LOCKED` | Quiescent Baseline: Default state; high-risk tool calls rejected prior to dispatch. |

### Architectural Substrates
* **Subterranean Pitch Substrate**: `#030508` / `#04060A`
* **Machined Chassis Faceplate**: `#070A10`
* **Milled Instrument Pocket**: `#090D15`
* **Structural Precision Hairlines**: `#0B1220` / `rgba(255, 255, 255, 0.08)`

---

## 8. Web & Documentation Quickstart

### HTML Head Integration
```html
<!-- Primary Favicon Suite -->
<link rel="icon" type="image/png" sizes="16x16" href="/docs/assets/branding/icons/favicon-16x16.png">
<link rel="icon" type="image/png" sizes="32x32" href="/docs/assets/branding/icons/favicon-32x32.png">
<link rel="icon" type="image/png" sizes="48x48" href="/docs/assets/branding/icons/favicon-48x48.png">
<link rel="shortcut icon" href="/docs/assets/branding/icons/favicon.ico">

<!-- Apple Touch Icon -->
<link rel="apple-touch-icon" sizes="180x180" href="/docs/assets/branding/icons/apple_touch_icon_180x180.png">

<!-- Web App Manifest -->
<link rel="manifest" href="/docs/assets/branding/icons/manifest.json">
<meta name="theme-color" content="#070A10">

<!-- OpenGraph / Social Metadata -->
<meta property="og:type" content="website">
<meta property="og:title" content="SCRAMKD // Darwin Supervisor Daemon & Hardware Interlock">
<meta property="og:description" content="Deterministic hardware-grade safety interlock and kill switch for autonomous AI agent runtimes.">
<meta property="og:image" content="/docs/assets/branding/marketing/scramkd_github_opengraph_1280x640.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:image" content="/docs/assets/branding/marketing/scramkd_github_opengraph_1280x640.png">
```

### GitHub README Markdown Integration
```markdown
<div align="center">
  <img src="docs/assets/branding/vectors/scramkd_brand_lockup_master.svg" width="640" alt="SCRAMKD // Hardware Interlock Runtime" />
</div>
```

import AppKit
import CoreText
import SwiftUI

/// Reference colors are encoded sRGB, not Display P3 RGB triplets.
public enum DesignTokens {
    public static let pitchBlack = color(0x030508)
    public static let canvasDark = color(0x030509)
    public static let railDark = color(0x050811)
    public static let chromeDark = color(0x080C16)
    public static let cockpitDark = color(0x090E1A)
    public static let panelDark = color(0x0B1220)
    public static let cardSlip = color(0x0C1322)
    public static let auditDark = color(0x04060C)
    public static let slateBorder = color(0x1E293B)
    public static let slateBorderLight = color(0x334155)
    public static let green = color(0x10B981)
    public static let amber = color(0xF59E0B)
    public static let red = color(0xEF4444)
    public static let lockedSlate = color(0x475569)
    public static let textReadout = color(0xDFE2F0)
    public static let textMuted = color(0x64748B)
    public static let textDim = color(0x94A3B8)

    public enum Layout {
        public static let width: CGFloat = 1440
        public static let height: CGFloat = 900
        public static let chromeHeight: CGFloat = 44
        public static let workspaceHeight: CGFloat = 580
        public static let auditHeight: CGFloat = 276
        public static let railWidth: CGFloat = 160
        public static let viewportWidth: CGFloat = 794
        public static let cockpitWidth: CGFloat = 486
        public static let nativeControlsReserve: CGFloat = 78
    }

    public enum Font {
        public static let hudTitleLarge = mono(14, weight: "SemiBold")
        public static let body = mono(11)
        public static let labelMd = mono(10, weight: "SemiBold")
        public static let labelSm = mono(9, weight: "Medium")
        public static let keycap = mono(10, weight: "ExtraBold")

        public static func mono(_ size: CGFloat, weight: String = "Regular") -> SwiftUI.Font {
            .custom("JetBrainsMono-\(weight)", fixedSize: size).monospacedDigit()
        }
    }

    private static func color(_ rgb: UInt32) -> Color {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        let nsColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        if let p3Color = nsColor.usingColorSpace(.displayP3) {
            return Color(nsColor: p3Color)
        }
        return Color(
            .sRGB,
            red: Double(r),
            green: Double(g),
            blue: Double(b),
            opacity: 1
        )
    }
}

/// Registers bundled, unmodified JetBrains Mono fonts for this process only.
/// Call before constructing the console. Failure must be surfaced by the app;
/// there is no approved substitute font.
@MainActor
public enum ScramKDesignResources {
    public enum RegistrationError: Error, CustomStringConvertible {
        case missingFont(String)
        case registrationFailed(String, String)
        case unavailableFont(String)

        public var description: String {
            switch self {
            case .missingFont(let name): "Missing bundled font: \(name)"
            case .registrationFailed(let name, let reason): "Font registration failed: \(name): \(reason)"
            case .unavailableFont(let name): "Registered font unavailable: \(name)"
            }
        }
    }

    public private(set) static var fontsRegistered = false
    private static var registeredNames: Set<String> = []

    public static func registerFonts() throws {
        guard !fontsRegistered else { return }
        for weight in ["Regular", "Medium", "SemiBold", "Bold", "ExtraBold"] {
            let name = "JetBrainsMono-\(weight)"
            guard !registeredNames.contains(name) else { continue }
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf") else {
                throw RegistrationError.missingFont(name)
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let failure = error?.takeRetainedValue()
                // A previously registered copy is usable only when the face resolves.
                let alreadyRegistered = failure.map {
                    CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue
                } ?? false
                guard alreadyRegistered, NSFont(name: name, size: 11) != nil else {
                    throw RegistrationError.registrationFailed(
                        name, failure.map { String(describing: $0) } ?? "No CoreText diagnostic"
                    )
                }
            }
            guard NSFont(name: name, size: 11) != nil else {
                throw RegistrationError.unavailableFont(name)
            }
            registeredNames.insert(name)
        }
        fontsRegistered = true
    }
}

/// Decorative hatching is confined to the control and never intercepts input.
public struct HazardStripesModifier: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content.overlay {
            Canvas { context, size in
                var stripes = Path()
                for x in stride(from: -size.height, through: size.width, by: 28) {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(stripes, with: .color(.black.opacity(0.1)), lineWidth: 10)
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .clipShape(Rectangle())
    }
}

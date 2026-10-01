import SwiftUI

// MARK: - Design tokens
//
// Shared look with the Mac app: near-black ground, one cyan accent, and one
// color + SF Symbol per stem so a stem reads the same everywhere.

public extension Color {
    /// App ground — near-black. Background of every screen.
    static let ssGround = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0C / 255.0)

    /// Raised surfaces (cards, lanes, transport).
    static let ssSurface = Color.white.opacity(0.06)

    /// Primary text/icons.
    static let ssTextPrimary = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)

    /// Secondary text — tinted from the ground hue.
    static let ssTextSecondary = Color(red: 0x94 / 255.0, green: 0x97 / 255.0, blue: 0xA8 / 255.0)

    /// The accent (same as the Mac app's tint).
    static let ssAccent = Color(red: 0.35, green: 0.78, blue: 0.95)
}

/// Per-stem color and icon (matches the Mac app).
public enum StemStyle {
    public static func color(_ stem: String) -> Color {
        switch stem {
        case "vocals": Color(red: 0.98, green: 0.42, blue: 0.62)
        case "drums": Color(red: 1.0, green: 0.62, blue: 0.25)
        case "bass": Color(red: 0.58, green: 0.48, blue: 1.0)
        case "other": Color(red: 0.36, green: 0.84, blue: 0.58)
        default: .ssAccent
        }
    }

    public static func icon(_ stem: String) -> String {
        switch stem {
        case "vocals": "music.mic"
        case "drums": "cylinder.split.1x2"
        case "bass": "guitars"
        case "other": "pianokeys"
        case "instrumental": "music.note"
        default: "waveform"
        }
    }

    public static func title(_ stem: String) -> String {
        stem == "other" ? "Other" : stem.capitalized
    }
}

/// Spacing + radius constants on the 8pt grid.
public enum DesignSystem {

    public enum Spacing {
        public static let unit: CGFloat = 8
        public static let unit2: CGFloat = 16
        public static let unit3: CGFloat = 24
        public static let unit4: CGFloat = 32
        public static let unit5: CGFloat = 40
    }

    public enum Radius {
        public static let card: CGFloat = 14
        public static let sheet: CGFloat = 20
    }
}

/// Full-width capsule button: accent fill, dark label.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Color.ssAccent.opacity(configuration.isPressed ? 0.75 : 1)))
            .foregroundStyle(Color.ssGround)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Full-width capsule button on a quiet surface.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .foregroundStyle(Color.ssTextPrimary)
    }
}

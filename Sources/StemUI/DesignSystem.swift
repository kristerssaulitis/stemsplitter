import SwiftUI

// MARK: - Design tokens (design review, Pass 5 — frozen with the scaffold)
//
// Dark, minimal, waveform-forward. The rules this block enforces (approved plan,
// "Design tokens (Pass 5)" + design acceptance obligations):
//   - Ground #0A0A0C; primary text #F5F5F7 (>15:1 — measured 18.17:1).
//   - Secondary text is TINTED FROM THE GROUND HUE (ground hue 240°, token hue
//     231°), never a neutral gray. Measured 6.83:1 on ground.
//   - Exactly ONE matte accent: #D9A962 (amber, hue 35.8°), measured 9.23:1 on
//     ground. Matte by rule: no glow (no .shadow() on accent elements), no
//     gradient (no .linearGradient()/AngularGradient/etc. anywhere). This block
//     deliberately ships no shadow or gradient tokens.
//   - 8pt spacing grid. Radii: 12pt cards / 20pt sheets.
//   - Type: SF Pro via system text styles with Dynamic Type — the platform
//     default; no custom font tokens by design.
// WCAG ratios above were computed with the WCAG 2.x relative-luminance formula
// and verified in this workspace (script run recorded in the scaffold report).

public extension Color {
    /// App ground — near-black, hue 240°. Background of every screen.
    static let ssGround = Color(red: 0x0A / 255.0, green: 0x0A / 255.0, blue: 0x0C / 255.0)

    /// Primary text/icons — 18.17:1 on ground.
    static let ssTextPrimary = Color(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0)

    /// Secondary text — tinted from the ground hue (231°), never neutral gray.
    /// 6.83:1 on ground; safe for body-size secondary copy.
    static let ssTextSecondary = Color(red: 0x94 / 255.0, green: 0x97 / 255.0, blue: 0xA8 / 255.0)

    /// The ONE matte accent (amber, hue 35.8°). No glow, no gradient, ever.
    /// 9.23:1 on ground. Used for: progress ring, waveform fill, primary CTA.
    static let ssAccent = Color(red: 0xD9 / 255.0, green: 0xA9 / 255.0, blue: 0x62 / 255.0)
}

/// Spacing + radius constants on the 8pt grid.
public enum DesignSystem {

    /// 8pt grid steps. Every vertical/horizontal gap in the app is one of these.
    public enum Spacing {
        /// 8pt — inline gaps, icon-to-label.
        public static let unit: CGFloat = 8
        /// 16pt — within-card padding, related-group gaps.
        public static let unit2: CGFloat = 16
        /// 24pt — card-to-card gaps.
        public static let unit3: CGFloat = 24
        /// 32pt — section gaps.
        public static let unit4: CGFloat = 32
        /// 40pt — screen edge insets / hero spacing.
        public static let unit5: CGFloat = 40
    }

    /// Corner radii (design tokens: 12pt cards / 20pt sheets).
    public enum Radius {
        /// 12pt — stem cards, waveform container, buttons.
        public static let card: CGFloat = 12
        /// 20pt — sheets (pre-flight confirm, cancel confirmation).
        public static let sheet: CGFloat = 20
    }
}

import SwiftUI
import StemUI

// Minimal iOS app shell (plan T7 will replace the placeholder flow).
// StemSplitterApp links the local package products StemCore + StemUI; the
// placeholder below uses StemUI's design tokens to prove the chain links.

@main
struct StemSplitterApp: App {
    var body: some Scene {
        WindowGroup {
            AppFlowView()
        }
    }
}

// SCAFFOLD PLACEHOLDER — the real AppFlowView (picker → pre-flight → processing →
// result, plan design F1/F4 + T7) is a StemUI file that does not exist yet, and
// this app target must compile today. Replace this entire struct when StemUI's
// AppFlowView lands; the @main block above then imports it from StemUI.
private struct AppFlowView: View {
    var body: some View {
        ZStack {
            Color.ssGround.ignoresSafeArea()
            VStack(spacing: DesignSystem.Spacing.unit2) {
                Text("StemSplitter")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(Color.ssTextPrimary)
                Text("Flow placeholder — AppFlowView lands in StemUI")
                    .font(.subheadline)
                    .foregroundStyle(Color.ssTextSecondary)
            }
        }
    }
}

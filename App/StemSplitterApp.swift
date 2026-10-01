import SwiftUI
import StemCore
import StemUI

@main
struct StemSplitterApp: App {
    private let engine = DemucsEngine()

    init() {
        // Splits live in caches only (plan output lifecycle): clear last launch's.
        SplitStore(baseDirectory: SplitStore.defaultBaseDirectory()).purgeOnLaunch()
        let engine = self.engine
        Task.detached(priority: .utility) { await engine.prewarmModel() }
    }

    var body: some Scene {
        WindowGroup {
            AppFlowView(engine: engine)
        }
    }
}

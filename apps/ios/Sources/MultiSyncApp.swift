import SwiftUI

@main
struct MultiSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = MobileModel()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model).tint(MobileTheme.accent)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { phase in
                    if phase == .background { model.background() }
                    if phase == .active { model.activate() }
                }
        }
    }
}

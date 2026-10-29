import AppKit
import SwiftUI

@main
struct MultiSyncApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MultiSync") {
            ContentView().environmentObject(model).tint(Theme.accent).preferredColorScheme(.light)
                .frame(minWidth: 800, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }.defaultSize(width: 1040, height: 760)
    }
}

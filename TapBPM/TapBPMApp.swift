import SwiftUI

@main
struct TapBPMApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
            #if os(iOS)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .defersSystemGestures(on: .all)
            #else
                .frame(minWidth: 360, minHeight: 640)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 420, height: 760)
        .windowStyle(.hiddenTitleBar)
        #endif
    }
}

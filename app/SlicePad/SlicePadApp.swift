import SwiftUI

@main
struct SlicePadApp: App {
    init() {
        // Returns immediately unless the environment asks for it, which only a
        // simulator launch can do.
        SmokeTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

import SwiftUI

@main
struct EmberApp: App {
    @State private var session = SessionController()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

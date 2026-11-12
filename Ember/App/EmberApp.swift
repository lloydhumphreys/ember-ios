import SwiftUI

@main
struct EmberApp: App {
    @State private var accounts = Accounts()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(accounts)
        }
    }
}

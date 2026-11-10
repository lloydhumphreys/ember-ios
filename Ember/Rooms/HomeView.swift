import SwiftUI
import EmberSDK

/// The signed-in app: your rooms and DMs, what's unread, and search.
///
/// Each tab owns its own `NavigationStack`, so a push in one doesn't disturb
/// where you were in another. The paths are `NavigationPath`s rather than
/// `[RoomLink]`, so a room can push something of its own on top.
struct HomeView: View {
    @Environment(Workspace.self) private var workspace

    @State private var tab: HomeTab = .home
    @State private var homePath = NavigationPath()
    @State private var activityPath = NavigationPath()
    @State private var searchPath = NavigationPath()

    init() {}

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: HomeTab.home) {
                NavigationStack(path: $homePath) {
                    RoomsView(path: $homePath)
                        .roomDestination()
                }
            } label: {
                tabLabel("Home", "house")
            }
            // `.badge(_:)` hides itself at zero.
            Tab(value: HomeTab.activity) {
                NavigationStack(path: $activityPath) {
                    ActivityView()
                        .roomDestination()
                }
            } label: {
                tabLabel("Activity", "bell")
            }
            .badge(workspace.unreadCount)
            Tab("Search", systemImage: "magnifyingglass", value: HomeTab.search, role: .search) {
                NavigationStack(path: $searchPath) {
                    SearchView()
                        .roomDestination()
                }
            }
        }
        // The tab bar shrinks out of the way while a list scrolls down and
        // comes back on the way up.
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    /// Outline symbols, not the filled ones a tab bar picks by default:
    /// lighter against the glass.
    private func tabLabel(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .environment(\.symbolVariants, .none)
    }
}

private enum HomeTab: Hashable {
    case home, activity, search
}

extension View {
    /// Where every tab's stack goes for a `RoomLink`.
    func roomDestination() -> some View {
        navigationDestination(for: RoomLink.self) { link in
            if link.threadID != nil {
                ThreadView(link: link)
            } else {
                RoomView(link: link)
            }
        }
    }
}

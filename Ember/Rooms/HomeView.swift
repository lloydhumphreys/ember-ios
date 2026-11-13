import SwiftUI
import EmberSDK

/// The signed-in app: your rooms and DMs, what's unread, and search.
///
/// Each tab owns its own `NavigationStack`, so a push in one doesn't disturb
/// where you were in another. The paths are `NavigationPath`s rather than
/// `[RoomLink]`, so a room can push something of its own on top.
///
/// The tab and the room or thread open in it are remembered for the account,
/// and a launch opens there again. A link to a room or message on the server
/// opens in the tab it was tapped in.
struct HomeView: View {
    @Environment(Workspace.self) private var workspace

    @State private var tab: HomeTab = .home
    @State private var homePath = NavigationPath()
    @State private var activityPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    /// The room or thread on top of each tab's stack, as far as one is.
    @State private var tops: [HomeTab: RoomLink] = [:]
    /// What a launch reopened, until the sidebar says whether the room is still yours.
    @State private var restored: HomePlace?
    @State private var hasRestored = false
    /// The New Message or New Room sheet, while one is up.
    @State private var composing: Composing?

    private let places: HomePlaces

    init(places: HomePlaces = HomePlaces()) {
        self.places = places
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab(value: HomeTab.home) {
                stack(.home, path: $homePath) {
                    RoomsView(path: $homePath)
                }
            } label: {
                tabLabel("Home", "house")
            }
            // `.badge(_:)` hides itself at zero.
            Tab(value: HomeTab.activity) {
                stack(.activity, path: $activityPath) {
                    ActivityView()
                }
            } label: {
                tabLabel("Activity", "bell")
            }
            .badge(workspace.unreadCount)
            // The badge's count, said as what it counts.
            .accessibilityValue(Text(UnreadValue.text(workspace.unreadCount) ?? ""), isEnabled: workspace.unreadCount > 0)
            Tab(value: HomeTab.search) {
                stack(.search, path: $searchPath) {
                    SearchView()
                }
            } label: {
                tabLabel("Search", "magnifyingglass")
            }
        }
        // The tab bar shrinks out of the way while a list scrolls down and
        // comes back on the way up.
        .minimizesTabBarOnScrollDown()
        .sheet(item: $composing) { composing in
            switch composing {
            case .message:
                NewDirectView(onStarted: open)
            case .room:
                NewRoomView(onCreated: open)
            }
        }
        .onAppear(perform: restore)
        .onChange(of: place) { _, place in
            places.remember(place, for: account)
        }
        .onChange(of: workspace.isLoaded) { checkRestored() }
    }

    private func stack<Root: View>(_ tab: HomeTab, path: Binding<NavigationPath>, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: path) {
            root()
                .overlay {
                    NewMessageButton(newRoom: canCreateRoom ? { composing = .room } : nil) { composing = .message }
                        .padding(.trailing, 16)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        // Stays above the tab bar; the keyboard covers it rather than lifting it.
                        // Full size, so ignoring the keyboard moves the button rather than nothing.
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                }
                .roomDestination()
        }
        .environment(\.roomShown) { tops[tab] = $0 }
        .environment(\.returnHome) {
            path.wrappedValue = NavigationPath()
            tops[tab] = nil
        }
        .onChange(of: path.wrappedValue.count) { _, count in
            if count == 0 { tops[tab] = nil }
        }
        .opensRoomLinks(origin: workspace.client.origin) { link in
            guard Self.pushes(link, over: tops[tab]) else { return }
            path.wrappedValue.append(link)
        }
    }

    private var canCreateRoom: Bool {
        RoomCreation.isOffered(account: workspace.account, me: workspace.me)
    }

    /// Opens a DM or room just started or made, on Home.
    private func open(_ roomID: RoomID) {
        composing = nil
        tab = .home
        homePath.append(RoomLink(roomID: roomID))
    }

    /// Whether a tapped link pushes onto a stack with `top` showing. A link to the room or thread
    /// already on top, or to a message in it, stays put rather than opening a second copy.
    static func pushes(_ link: RoomLink, over top: RoomLink?) -> Bool {
        top != RoomLink(roomID: link.roomID, threadID: link.threadID)
    }

    /// Outline symbols, not the filled ones a tab bar picks by default:
    /// lighter against the glass.
    private func tabLabel(_ title: String, _ systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .environment(\.symbolVariants, .none)
    }

    // MARK: Where you were

    private var account: String {
        HomePlaces.account(origin: workspace.client.origin, userID: workspace.me.id)
    }

    private var place: HomePlace {
        HomePlace(tab: tab, link: tops[tab])
    }

    private func restore() {
        guard !hasRestored else { return }
        hasRestored = true
        guard let saved = places.place(for: account) else { return }
        tab = saved.tab
        restored = saved
        for link in saved.path { setPath(for: saved.tab) { $0.append(link) } }
        checkRestored()
    }

    /// Once the sidebar has loaded, a reopened room you're no longer in goes back to the tab's list,
    /// unless you've moved on from it already.
    private func checkRestored() {
        guard workspace.isLoaded, let saved = restored else { return }
        restored = nil
        let checked = saved.checked { workspace.room($0) != nil }
        guard checked != saved, tops[saved.tab] == nil || tops[saved.tab] == saved.link else { return }
        setPath(for: saved.tab) { $0 = NavigationPath() }
        tops[saved.tab] = nil
        places.remember(HomePlace(tab: tab, link: tops[tab]), for: account)
    }

    private func setPath(for tab: HomeTab, _ change: (inout NavigationPath) -> Void) {
        switch tab {
        case .home: change(&homePath)
        case .activity: change(&activityPath)
        case .search: change(&searchPath)
        }
    }
}

/// What the New button's sheet makes.
private enum Composing: String, Identifiable {
    case message, room

    var id: String { rawValue }
}

extension View {
    /// Where every tab's stack goes for a `RoomLink`.
    func roomDestination() -> some View {
        navigationDestination(for: RoomLink.self) { link in
            RoomDestination(link: link)
        }
    }
}

/// A room or thread pushed on a tab's stack, telling the tab when it's the one showing.
private struct RoomDestination: View {
    let link: RoomLink

    @Environment(\.roomShown) private var roomShown

    var body: some View {
        Group {
            if link.threadID != nil {
                ThreadView(link: link)
            } else {
                RoomView(link: link)
            }
        }
        .onAppear { roomShown(RoomLink(roomID: link.roomID, threadID: link.threadID)) }
    }
}

extension EnvironmentValues {
    /// Called with the room or thread a tab's stack shows each time it comes into view.
    @Entry var roomShown: @MainActor (RoomLink) -> Void = { _ in }
}

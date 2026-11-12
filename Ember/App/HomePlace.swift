import Foundation
import EmberSDK

/// Where someone was in the signed-in app: the tab, and the room or thread open in it. Kept for each
/// account on each server, so a relaunch opens there rather than on Home. Which message a room was
/// opened at is left out: it reopens where the room itself would.
struct HomePlace: Codable, Equatable {
    var tab: HomeTab
    var roomID: RoomID?
    var threadID: String?

    init(tab: HomeTab, link: RoomLink? = nil) {
        self.tab = tab
        roomID = link?.roomID
        threadID = link?.roomID == nil ? nil : link?.threadID
    }

    /// What the tab's stack holds to show it: the room, and for a thread the thread on top of it.
    var path: [RoomLink] {
        guard let roomID else { return [] }
        let room = RoomLink(roomID: roomID)
        guard let threadID else { return [room] }
        return [room, RoomLink(roomID: roomID, threadID: threadID)]
    }

    /// The link on top of `path`.
    var link: RoomLink? { path.last }

    /// The same tab, without the room when `isKnown` says it isn't one you're in any more.
    func checked(isKnown: (RoomID) -> Bool) -> HomePlace {
        guard let roomID, !isKnown(roomID) else { return self }
        return HomePlace(tab: tab)
    }
}

/// The tabs of the signed-in app.
enum HomeTab: String, Codable, Hashable {
    case home, activity, search
}

/// Where each account's `HomePlace` is kept.
struct HomePlaces {
    var defaults: UserDefaults = .standard

    /// Who a place belongs to: one person on one server.
    static func account(origin: URL, userID: UserID) -> String {
        "\(origin.absoluteString)#\(userID)"
    }

    /// Nil too for a place that no longer reads, such as one on a tab that's gone.
    func place(for account: String) -> HomePlace? {
        guard let data = defaults.data(forKey: key(account)) else { return nil }
        return try? JSONDecoder().decode(HomePlace.self, from: data)
    }

    func remember(_ place: HomePlace, for account: String) {
        guard let data = try? JSONEncoder().encode(place) else { return }
        defaults.set(data, forKey: key(account))
    }

    /// Forgets the place of one person on the server at `origin`.
    func forget(origin: URL, userID: UserID) {
        defaults.removeObject(forKey: key(Self.account(origin: origin, userID: userID)))
    }

    /// Forgets the place of every account on the server at `origin`.
    func forget(origin: URL) {
        let prefix = key(Self.account(origin: origin, userID: ""))
        for name in defaults.dictionaryRepresentation().keys where name.hasPrefix(prefix) {
            defaults.removeObject(forKey: name)
        }
    }

    private func key(_ account: String) -> String {
        "homePlace.\(account)"
    }
}

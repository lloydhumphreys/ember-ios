import Foundation
import SwiftUI
import EmberSDK

/// Whether someone is offered New Room: anyone, unless the workspace leaves making rooms to its
/// administrators.
enum RoomCreation {
    static func isOffered(account: Account, me: Me) -> Bool {
        !account.restrictRoomCreation || me.administrator
    }
}

/// A shared room as its form has it, for New Room and Edit Room: its name, whether it's closed, and
/// who's in it when it is.
struct RoomDraft: Equatable {
    /// The longest name the server takes (`MAX_ROOM_NAME_LENGTH`).
    static let maxNameLength = 100

    var name: String
    var isClosed: Bool
    /// Who a closed room has in it. Kept while the room is open, so flipping back loses nothing.
    var members: Set<UserID>

    init(name: String = "", isClosed: Bool = false, members: Set<UserID> = []) {
        self.name = name
        self.isClosed = isClosed
        self.members = members
    }

    /// The room as its settings have it, its members ticked.
    init(settings: RoomSettings) {
        name = settings.room.name ?? ""
        isClosed = settings.room.kind == .closed
        members = Set(settings.people.filter(\.member).map(\.id))
    }

    /// The name as it's sent: without the spaces around it.
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var hasValidName: Bool { !trimmedName.isEmpty && trimmedName.count <= Self.maxNameLength }

    /// The members, in the order `people` lists them. Anyone ticked but no longer listed is left out.
    func memberIDs(in people: [UserID]) -> [UserID] {
        var seen = Set<UserID>()
        return people.filter { members.contains($0) && seen.insert($0).inserted }
    }

    /// The room to create. The workspace adds you to a closed one.
    func newRoom(people: [UserID]) -> NewRoom {
        NewRoom(name: trimmedName, access: isClosed ? .closed(memberIDs: memberIDs(in: people)) : .open)
    }

    /// What saving changes about `saved`: the name if it's another, and who can see it if the room
    /// was opened or closed, or a closed room's members changed. Nil when nothing did. The icon is
    /// never sent, so it stays.
    func changes(from saved: RoomDraft, people: [UserID]) -> RoomChanges? {
        var changes = RoomChanges()
        if trimmedName != saved.trimmedName { changes.name = trimmedName }
        if isClosed != saved.isClosed || (isClosed && members != saved.members) {
            changes.access = isClosed ? .closed(memberIDs: memberIDs(in: people)) : .open
        }
        return changes == RoomChanges() ? nil : changes
    }

    /// Whether saving `changes` takes `me` out of the room: closing it without them.
    static func removes(_ me: UserID, with changes: RoomChanges) -> Bool {
        if case let .closed(memberIDs) = changes.access { return !memberIDs.contains(me) }
        return false
    }
}

/// The people a room's form lists, and the ones a search keeps.
enum RoomPeople {
    /// The people whose name holds `typed`, ignoring case and accents, in the order given. Everyone
    /// when nothing's typed.
    static func matching(_ people: [User], typed: String, name: (User) -> String = \.name) -> [User] {
        let sought = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sought.isEmpty else { return people }
        return people.filter { name($0).localizedStandardContains(sought) }
    }
}

/// What Reorder offers: your starred rooms once there are two to put in order, and for an
/// administrator the order of shared rooms for everyone.
enum RoomReorder {
    static func offersStarred(favoriteCount: Int) -> Bool { favoriteCount > 1 }

    static func offersShared(me: Me, sharedCount: Int) -> Bool { me.administrator && sharedCount > 1 }

    static func isOffered(me: Me, favoriteCount: Int, sharedCount: Int) -> Bool {
        offersStarred(favoriteCount: favoriteCount) || offersShared(me: me, sharedCount: sharedCount)
    }
}

extension EnvironmentValues {
    /// Takes the tab's stack back to its list, as when the room on it is deleted or you leave it.
    @Entry var returnHome: @MainActor () -> Void = {}
}

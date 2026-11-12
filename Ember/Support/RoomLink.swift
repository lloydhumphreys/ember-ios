import EmberSDK

/// A link to a room, optionally at a message, as every NavigationStack's path carries it. With a
/// `threadID` it's that thread, opened at `messageID` (one of its replies) if there is one.
struct RoomLink: Hashable {
    var roomID: RoomID
    var messageID: String? = nil
    var threadID: String? = nil
}

extension RoomLink {
    /// Where a message lives: a reply in its thread, anything else in its room.
    static func to(_ message: Message) -> RoomLink {
        if let parentID = message.parentId {
            return RoomLink(roomID: message.roomId, messageID: message.id, threadID: parentID)
        }
        return RoomLink(roomID: message.roomId, messageID: message.id)
    }

    /// The thread a message belongs to: its own, or for a reply its parent's.
    static func thread(of message: Message) -> RoomLink {
        RoomLink(roomID: message.roomId, threadID: message.parentId ?? message.id)
    }
}

/// The SF Symbol a room shows: `number` for an open room, `lock` for a closed one, and a person
/// for a DM. (A mapping from Ember's Lucide/Iconoir icon names comes later.)
func roomSymbol(for room: Room) -> String {
    switch room.kind {
    case .open: "number"
    case .closed: "lock"
    case .direct: "person"
    case .unknown: "number"
    }
}

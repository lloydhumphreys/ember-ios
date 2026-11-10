import EmberSDK

extension Involvement {
    /// The levels a room offers, as the web's bell goes round them: all four
    /// in a shared room, and only all messages or off in a DM.
    static func levels(for kind: RoomKind) -> [Involvement] {
        kind == .direct ? [.everything, .nothing] : [.mentions, .everything, .nothing, .invisible]
    }

    var title: String {
        switch self {
        case .mentions: "Mentions"
        case .everything: "All Messages"
        case .nothing: "Off"
        case .invisible: "Hidden"
        }
    }

    /// The web's bells, as SF Symbols.
    var symbol: String {
        switch self {
        case .mentions: "at"
        case .everything: "bell"
        case .nothing: "bell.slash"
        case .invisible: "eye.slash"
        }
    }

    /// Whether the room's row looks muted: notifications are off.
    var isQuiet: Bool { self == .nothing || self == .invisible }
}

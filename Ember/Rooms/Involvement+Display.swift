import Foundation
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
        case .unknown(let raw): Self.readable(raw)
        }
    }

    /// A level the app doesn't know, as the server names it but readable: "mentions_and_threads"
    /// is "Mentions and threads".
    static func readable(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The web's bells, as SF Symbols.
    var symbol: String {
        switch self {
        case .mentions: "at"
        case .everything: "bell"
        case .nothing: "bell.slash"
        case .invisible: "eye.slash"
        case .unknown: "bell"
        }
    }

    /// Whether the room's row looks muted: notifications are off.
    var isQuiet: Bool { self == .nothing || self == .invisible }
}

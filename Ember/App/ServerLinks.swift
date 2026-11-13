import SwiftUI
import EmberSDK

extension RoomLink {
    /// The room, message, thread or reply a link to the signed-in server names, at the addresses the
    /// web app gives them, or nil for any other page or server. A server-relative address is on
    /// `origin`.
    ///
    /// `/rooms/<id>`, `/rooms/opens/<id>` (and `closeds`, `directs`), a message's permalink
    /// `/rooms/<id>/@<message>` or its address `/rooms/<id>/messages/<message>`, a thread
    /// `/rooms/<id>/threads/<message>`, and a reply's permalink `/rooms/<id>/threads/<message>/@<reply>`.
    init?(url: URL, on origin: URL) {
        guard let resolved = URL(string: url.relativeString, relativeTo: origin)?.absoluteURL,
              Self.sameServer(resolved, origin) else { return nil }
        let raw = resolved.path(percentEncoded: true).split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        var segments: [String] = []
        for segment in raw {
            guard let decoded = String(segment).removingPercentEncoding else { return nil }
            segments.append(decoded)
        }
        guard segments.first == "rooms", segments.count >= 2 else { return nil }
        let rest = Array(segments.dropFirst())

        if Self.kindSegments.contains(rest[0]) {
            guard rest.count == 2, Self.isID(rest[1]), rest[1] != "new" else { return nil }
            self.init(roomID: RoomID(rest[1]))
            return
        }
        guard Self.isID(rest[0]), rest[0] != "new" else { return nil }
        let roomID = RoomID(rest[0])
        switch rest.count {
        case 1:
            self.init(roomID: roomID)
        case 2 where rest[1].hasPrefix("@"):
            self.init(roomID: roomID, messageID: Self.id(String(rest[1].dropFirst())))
        case 3 where rest[1] == "messages":
            self.init(roomID: roomID, messageID: Self.id(rest[2]))
        case 3 where rest[1] == "threads":
            self.init(roomID: roomID, threadID: Self.id(rest[2]))
        case 4 where rest[1] == "threads" && rest[3].hasPrefix("@"):
            // A reply whose thread isn't named opens nothing more than the room, as on the web.
            guard let threadID = Self.id(rest[2]) else {
                self.init(roomID: roomID)
                return
            }
            self.init(roomID: roomID, messageID: Self.id(String(rest[3].dropFirst())), threadID: threadID)
        default:
            return nil
        }
    }

    /// The web's names for each kind of room's addresses.
    private static let kindSegments: Set<String> = ["opens", "closeds", "directs"]

    /// The most characters an id in an address can have, as the web reads one.
    private static let maxIDLength = 64

    private static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= maxIDLength
    }

    /// A message id from an address, or nil for one that's malformed, which opens the room at its
    /// newest messages instead, as on the web.
    private static func id(_ text: String) -> MessageID? {
        isID(text) ? MessageID(text) : nil
    }

    private static func sameServer(_ url: URL, _ origin: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == origin.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty,
              host == origin.host(percentEncoded: false)?.lowercased() else { return false }
        return effectivePort(url) == effectivePort(origin)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}

/// Opens a link to a room, message or thread on the signed-in server in the app with `open`, and
/// hands every other link to the `OpenURLAction` around it, which `SafeLinks` decides.
struct RoomLinkOpening: ViewModifier {
    let origin: URL
    let open: @MainActor (RoomLink) -> Void

    @Environment(\.openURL) private var outer

    func body(content: Content) -> some View {
        content.environment(\.openURL, OpenURLAction { url in
            if let link = RoomLink(url: url, on: origin) {
                open(link)
            } else {
                outer(url)
            }
            return .handled
        })
    }
}

extension View {
    func opensRoomLinks(origin: URL, open: @escaping @MainActor (RoomLink) -> Void) -> some View {
        modifier(RoomLinkOpening(origin: origin, open: open))
    }
}

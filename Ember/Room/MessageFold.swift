import SwiftUI
import EmberSDK

/// Whether a message's text is long enough to fold behind Show more, and how much of it shows
/// while folded.
enum MessageFold {
    /// Over this many characters of plain text, a message folds.
    static let foldCharacters = 1_500
    /// Over this many line breaks in its plain text, a message folds.
    static let foldLineBreaks = 15
    /// How many lines a folded message shows.
    static let shownLines = 10

    static func isLong(plainText: String) -> Bool {
        var characters = 0
        var lineBreaks = 0
        for character in plainText {
            characters += 1
            if character.isNewline { lineBreaks += 1 }
            if characters > foldCharacters || lineBreaks > foldLineBreaks { return true }
        }
        return false
    }

    /// The button's title for a long message, open or folded.
    static func buttonTitle(isOpen: Bool) -> String {
        isOpen ? "Show less" : "Show more"
    }

    /// Whether folding a message whose text starts `top` below the top of the region between
    /// the bars (negative above it; nil when it wasn't measured) brings its row to the top first.
    /// A fold then always happens with the message's top on screen, where holding the rows above it
    /// keeps it in view, however far below the rest of the room goes.
    static func raisesFirst(top: CGFloat?) -> Bool {
        (top ?? 0) < -0.5
    }
}

/// Which long messages are unfolded, kept apart from their rows so a row the timeline lets go of
/// and makes again comes back as it was left. A room's timeline and a thread's keep their own, so
/// a message opened in a thread doesn't change the room's rows while the room is off screen.
/// Also remembers each message's length, and where its fold was last measured to fall, which a
/// row made again starts from until it measures its own.
@MainActor @Observable final class MessageFolds {
    static var shared: MessageFolds { AccountStores.current.folds }

    /// A message folded or unfolded by the reader, for a scroll view that keeps the reader's
    /// place as the row changes height.
    struct Toggle: Equatable {
        let messageID: MessageID
        let isOpen: Bool
        let serial: Int
        /// Where the row that was tapped is: a room's timeline, or a thread's.
        var place: MessagePlace = .room
    }

    /// A fold asked for with the message's top above what's in view (`MessageFold.raisesFirst`):
    /// the timeline at `place` brings the row to the top, then folds it (`raised`).
    struct Raise: Equatable {
        let messageID: MessageID
        let place: MessagePlace
    }

    private var open: Set<String> = []
    private(set) var lastToggle: Toggle?
    private(set) var raising: Raise?

    @ObservationIgnored private var lengths: [String: Bool] = [:]
    @ObservationIgnored private var heights: [MessageID: CGFloat] = [:]
    @ObservationIgnored private var tops: [String: CGFloat] = [:]

    func isOpen(_ messageID: MessageID, in place: MessagePlace = .room) -> Bool {
        open.contains(Self.key(messageID, place))
    }

    /// Opens or folds a message in the timeline at `place`. A fold with its text's top above
    /// what's in view waits for the timeline to bring the row to the top (`raising`); asked for
    /// again meanwhile, it waits on.
    func toggle(_ messageID: MessageID, in place: MessagePlace = .room) {
        if raising?.messageID == messageID { return }
        let key = Self.key(messageID, place)
        if open.contains(key), MessageFold.raisesFirst(top: tops[key]) {
            raising = Raise(messageID: messageID, place: place)
            return
        }
        flip(messageID, in: place)
    }

    /// Folds the message `raise` brought to the top, once.
    func raised(_ raise: Raise) {
        guard raising == raise else { return }
        raising = nil
        flip(raise.messageID, in: raise.place)
    }

    /// Lets `raise` go, the message still open, when its timeline no longer has the message to
    /// bring up: otherwise it would wait on for good and the message couldn't be folded again.
    func dropped(_ raise: Raise) {
        guard raising == raise else { return }
        raising = nil
    }

    private func flip(_ messageID: MessageID, in place: MessagePlace) {
        let key = Self.key(messageID, place)
        let isOpen = !open.contains(key)
        if isOpen { open.insert(key) } else { open.remove(key) }
        lastToggle = Toggle(messageID: messageID, isOpen: isOpen, serial: (lastToggle?.serial ?? 0) + 1, place: place)
    }

    /// Notes how far below the top of the region between the bars a message's text starts, in the
    /// timeline at `place`; nil once it's off screen.
    func setTop(_ y: CGFloat?, for messageID: MessageID, in place: MessagePlace) {
        tops[Self.key(messageID, place)] = y
    }

    /// A thread's parent is shown in the room too, each with a button and a fold of its own.
    private static func key(_ messageID: MessageID, _ place: MessagePlace) -> String {
        "\(place == .room ? "room" : "thread")|\(messageID.rawValue)"
    }

    /// Whether `message` folds, worked out once for each version of it.
    func isLong(_ message: Message) -> Bool {
        let key = "\(message.id.rawValue)|\(message.updatedAt.timeIntervalSince1970)"
        if let known = lengths[key] { return known }
        let isLong = MessageFold.isLong(plainText: message.plainText)
        lengths[key] = isLong
        return isLong
    }

    /// Where the fold was last measured to fall in a message's text.
    func foldHeight(_ messageID: MessageID) -> CGFloat? { heights[messageID] }

    func setFoldHeight(_ height: CGFloat?, for messageID: MessageID) {
        heights[messageID] = height
    }

    /// Forgets every unfolded message, length and fold, as signing out should.
    func removeAll() {
        open = []
        lastToggle = nil
        raising = nil
        lengths = [:]
        heights = [:]
        tops = [:]
    }
}

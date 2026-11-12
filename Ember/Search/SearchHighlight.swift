import EmberSDK
import Foundation
import SwiftUI

enum SearchHighlight {
    /// How much of a message a result shows. Its row is four lines at most, so the rest is never
    /// seen, and leaving it out keeps a long message from costing more than a short one.
    static let shownLength = 1_000

    /// `text` with each of `words` emphasised wherever it occurs, ignoring case and diacritics.
    /// It finds every occurrence first, then builds the string once from the pieces in between, so
    /// a common word in a long message costs no more than reading the message.
    static func attributed(_ text: String, words: [String]) -> AttributedString {
        let text = text.count > shownLength ? String(text.prefix(shownLength)) : text
        var found: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                found.append(range)
                start = range.upperBound
            }
        }
        guard !found.isEmpty else { return AttributedString(text) }
        found.sort { $0.lowerBound < $1.lowerBound }

        var result = AttributedString()
        var plainFrom = text.startIndex
        var index = 0
        while index < found.count {
            var strong = found[index]
            index += 1
            while index < found.count, found[index].lowerBound <= strong.upperBound {
                strong = strong.lowerBound..<max(strong.upperBound, found[index].upperBound)
                index += 1
            }
            if strong.lowerBound < plainFrom { strong = plainFrom..<max(plainFrom, strong.upperBound) }
            if plainFrom < strong.lowerBound { result += AttributedString(text[plainFrom..<strong.lowerBound]) }
            if strong.lowerBound < strong.upperBound {
                var piece = AttributedString(text[strong])
                piece.inlinePresentationIntent = .stronglyEmphasized
                piece.foregroundColor = .primary
                result += piece
            }
            plainFrom = max(plainFrom, strong.upperBound)
        }
        if plainFrom < text.endIndex { result += AttributedString(text[plainFrom...]) }
        return result
    }

    /// Each match's text with its words emphasised, worked out away from the main thread so a page
    /// of long results doesn't hold up typing.
    @concurrent static func attributed(_ matches: [SearchMatch]) async -> [SearchMatch.ID: AttributedString] {
        var highlighted: [SearchMatch.ID: AttributedString] = [:]
        for match in matches {
            highlighted[match.id] = attributed(match.message.plainText, words: match.words)
        }
        return highlighted
    }
}

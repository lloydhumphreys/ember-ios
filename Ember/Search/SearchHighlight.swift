import Foundation

enum SearchHighlight {
    /// `text` with each of `words` emphasised wherever it occurs, ignoring case and diacritics.
    static func attributed(_ text: String, words: [String]) -> AttributedString {
        var result = AttributedString(text)
        for word in words where !word.isEmpty {
            var start = text.startIndex
            while start < text.endIndex,
                  let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
                if let range = Range(found, in: result) {
                    result[range].inlinePresentationIntent = .stronglyEmphasized
                    result[range].foregroundColor = .primary
                }
                start = found.upperBound
            }
        }
        return result
    }
}

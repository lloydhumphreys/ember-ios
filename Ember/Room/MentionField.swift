import SwiftUI
import UIKit
import EmberRichText
import EmberSDK

/// The composer's field: it grows with what's written up to `lines` lines and then scrolls, shows
/// each mention in the accent colour, and takes a mention away whole when a Backspace would leave
/// half a name. A text view rather than a `TextField`, which can't colour part of its text.
struct MentionField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var selection: TextSelection?
    @Binding var isFocused: Bool
    /// Who the text can mention, by id, each with the name written after "@".
    let mentions: [UserID: String]
    let lines: Int

    var body: some View {
        MentionTextView(text: $text, selection: $selection, isFocused: $isFocused, mentions: mentions, lines: lines, label: placeholder)
            // Under the text view, so the caret is drawn over the placeholder's first letter, as a
            // system field's is, rather than the letter over the caret.
            .background(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(Color(.placeholderText))
                        .lineLimit(1)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// What a deletion of `range` in `text` takes instead: the whole of the mention it falls inside
    /// and is shorter than, or nil to leave it as it is.
    static func wholeMention(deleting range: NSRange, in text: String, mentions: [UserID: String]) -> NSRange? {
        guard range.length > 0 else { return nil }
        for mention in RichText.mentionRanges(in: text, mentions: mentions) {
            let whole = NSRange(mention, in: text)
            if range.length < whole.length, NSIntersectionRange(range, whole) == range { return whole }
        }
        return nil
    }

    /// The height of `count` lines at `font`, measured in a text view set up as the field is: the
    /// most the field grows to before it scrolls. A line is taller than the font's `lineHeight`, so
    /// a height worked out from that held a sliver less than its lines.
    @MainActor static func height(ofLines count: Int, font: UIFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize) \(count)"
        if let known = heights[key] { return known }
        let probe = UITextView()
        configure(probe)
        probe.font = font
        probe.text = Array(repeating: "X", count: max(count, 1)).joined(separator: "\n")
        let height = probe.sizeThatFits(CGSize(width: CGFloat(1000), height: CGFloat.greatestFiniteMagnitude)).height
        heights[key] = height
        return height
    }

    @MainActor private static var heights: [String: CGFloat] = [:]

    /// The setup the field's text view and the one measuring its lines share.
    @MainActor static func configure(_ view: UITextView) {
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.contentInsetAdjustmentBehavior = .never
        view.autocapitalizationType = .sentences
    }

    /// Where a scroll that would put the field's top edge at `offset` stops instead, so that edge
    /// doesn't cut through a line. `line` is the top and bottom of the line it would cut, `direction`
    /// which way the scroll goes (down is positive; nought takes the nearer edge), and `most` the
    /// furthest the field scrolls. Going down it stops below the line, so the foot, where the caret
    /// goes as you type, shows more; going up, above it. Lines all the same height then end at the
    /// foot too, as the field is a whole number of them tall.
    nonisolated static func lineAligned(_ offset: CGFloat, in line: (top: CGFloat, bottom: CGFloat)?, direction: CGFloat, most: CGFloat, pixel: CGFloat) -> CGFloat {
        let offset = min(max(offset, 0), most)
        guard let line, offset > line.top + pixel / 2, offset < line.bottom - pixel / 2, offset < most else { return offset }
        let aligned: CGFloat
        if direction > 0 {
            aligned = line.bottom
        } else if direction < 0 {
            aligned = line.top
        } else {
            aligned = offset - line.top <= line.bottom - offset ? line.top : line.bottom
        }
        return min(max(aligned, 0), most)
    }
}

private struct MentionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: TextSelection?
    @Binding var isFocused: Bool
    let mentions: [UserID: String]
    let lines: Int
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = FieldTextView()
        view.onTintChange = { [weak coordinator = context.coordinator] view in coordinator?.restyle(view) }
        MentionField.configure(view)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.sizeCategory = UIContentSizeCategory(context.environment.dynamicTypeSize)
        view.accessibilityLabel = label
        coordinator.show(text, selection: selection, in: view)
        if isFocused != view.isFirstResponder {
            // After this update, and only if it's still wanted then: a view not yet in a window
            // can't take the keyboard.
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, view.window != nil else { return }
                let wanted = coordinator.parent.isFocused
                guard wanted != view.isFirstResponder else { return }
                if wanted { view.becomeFirstResponder() } else { view.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let font = view.font ?? .preferredFont(forTextStyle: .body)
        let most = MentionField.height(ofLines: lines, font: font)
        let fitted = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let scrolls = fitted > most + 0.5
        if view.isScrollEnabled != scrolls {
            view.isScrollEnabled = scrolls
            if scrolls {
                // Down to the caret once the field is its new height.
                DispatchQueue.main.async { [weak view] in
                    guard let view, view.isScrollEnabled else { return }
                    view.scrollRangeToVisible(view.selectedRange)
                }
            } else {
                view.contentOffset = .zero
            }
        }
        return CGSize(width: width, height: scrolls ? most : max(fitted, MentionField.height(ofLines: 1, font: font)))
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionTextView
        var sizeCategory: UIContentSizeCategory = .large
        /// While SwiftUI is setting the view, whose changes aren't the person's.
        var isUpdating = false

        init(_ parent: MentionTextView) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            guard !isUpdating else { return }
            parent.text = Self.text(of: view)
            restyle(view)
            view.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isUpdating else { return }
            let text = Self.text(of: view)
            guard let range = Range(view.selectedRange, in: text) else { return }
            parent.selection = range.isEmpty ? TextSelection(insertionPoint: range.lowerBound) : TextSelection(range: range)
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            (scrollView as? FieldTextView)?.scrollTarget = nil
        }

        /// A flick comes to rest between lines too.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset target: UnsafeMutablePointer<CGPoint>) {
            guard let view = scrollView as? FieldTextView, view.isScrollEnabled else { return }
            target.pointee.y = view.lineAligned(target.pointee.y, direction: velocity.y)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            (scrollView as? FieldTextView)?.scrollTarget = nil
        }

        /// A Backspace inside a mention takes all of it.
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            // A name chosen a moment ago that SwiftUI hasn't put in the view yet goes in first, and
            // what was typed lands at the caret it leaves, not where it would have gone before.
            if !isUpdating, view.markedTextRange == nil, parent.text != Self.text(of: view) {
                show(parent.text, selection: parent.selection, in: view)
                if range.length == 0, !replacement.isEmpty, let caret = view.selectedTextRange {
                    view.replace(caret, withText: replacement)
                    if parent.text != view.text { textViewDidChange(view) }
                }
                return false
            }
            guard replacement.isEmpty, view.markedTextRange == nil,
                  let whole = MentionField.wholeMention(deleting: range, in: Self.text(of: view), mentions: parent.mentions),
                  let start = view.position(from: view.beginningOfDocument, offset: whole.location),
                  let end = view.position(from: start, offset: whole.length),
                  let mention = view.textRange(from: start, to: end) else { return true }
            // Through the text view's own input, so it can be undone.
            view.replace(mention, withText: "")
            if parent.text != view.text { textViewDidChange(view) }
            return false
        }

        /// Puts `text` and `selection` in the view, as changes that aren't the person's.
        func show(_ text: String, selection: TextSelection?, in view: UITextView) {
            isUpdating = true
            defer { isUpdating = false }
            if view.text != text {
                view.text = text
                view.invalidateIntrinsicContentSize()
            }
            restyle(view)
            if let selection, let range = Self.range(of: selection, in: text), view.selectedRange != range {
                view.selectedRange = range
            }
        }

        /// The body font at the size the screen asks for, mentions in the accent colour, and what's
        /// typed next plain whatever it follows.
        func restyle(_ view: UITextView) {
            // Text being composed (a keyboard's marked text) keeps the look the keyboard gave it.
            guard view.markedTextRange == nil else { return }
            let size = sizeCategory
            let traits = view.traitCollection.modifyingTraits { $0.preferredContentSizeCategory = size }
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
            let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            if view.font != font { view.font = font }
            let storage = view.textStorage
            let text = storage.string
            storage.beginEditing()
            storage.setAttributes(plain, range: NSRange(location: 0, length: storage.length))
            for mention in RichText.mentionRanges(in: text, mentions: parent.mentions) {
                storage.addAttribute(.foregroundColor, value: view.tintColor ?? .tintColor, range: NSRange(mention, in: text))
            }
            storage.endEditing()
            view.typingAttributes = plain
        }

        /// The view's text as a Swift string of its own, so indices into it fit the draft's text.
        static func text(of view: UITextView) -> String {
            var text = view.text ?? ""
            text.makeContiguousUTF8()
            return text
        }

        static func range(of selection: TextSelection, in text: String) -> NSRange? {
            guard case .selection(let range) = selection.indices,
                  range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
            return NSRange(range, in: text)
        }
    }
}

/// The field's text view. It says when its tint changes (dimmed under an alert, and back), as its
/// mentions are drawn in it, and once it scrolls, each scroll it makes itself (following the caret,
/// say) stops between lines rather than through one.
private final class FieldTextView: UITextView {
    var onTintChange: ((UITextView) -> Void)?
    /// Where an animated scroll is going while it goes, so the steps on the way are left alone.
    var scrollTarget: CGPoint?

    override func tintColorDidChange() {
        super.tintColorDidChange()
        onTintChange?(self)
    }

    override var contentOffset: CGPoint {
        get { super.contentOffset }
        set {
            if let target = scrollTarget {
                if abs(newValue.y - target.y) < 0.5 { scrollTarget = nil }
                super.contentOffset = newValue
            } else {
                super.contentOffset = CGPoint(x: newValue.x, y: settled(newValue.y))
            }
        }
    }

    override func setContentOffset(_ offset: CGPoint, animated: Bool) {
        let aligned = CGPoint(x: offset.x, y: settled(offset.y))
        scrollTarget = animated && aligned != contentOffset ? aligned : nil
        super.setContentOffset(aligned, animated: animated)
    }

    /// `offset` moved to a line's edge in the direction it goes, while the field scrolls and no
    /// finger is moving it.
    private func settled(_ offset: CGFloat) -> CGFloat {
        guard isScrollEnabled, !isTracking, !isDragging, !isDecelerating else { return offset }
        return lineAligned(offset, direction: offset - contentOffset.y)
    }

    func lineAligned(_ offset: CGFloat, direction: CGFloat) -> CGFloat {
        let pixel = 1 / max(traitCollection.displayScale, 1)
        let most = max(0, contentSize.height - bounds.height)
        return MentionField.lineAligned(offset, in: line(at: offset), direction: abs(direction) < pixel / 2 ? 0 : direction, most: most, pixel: pixel)
    }

    /// The top and bottom of the laid-out line at `y`, in the view's content.
    private func line(at y: CGFloat) -> (top: CGFloat, bottom: CGFloat)? {
        guard let layout = textLayoutManager,
              let fragment = layout.textLayoutFragment(for: CGPoint(x: 1, y: y)) else { return nil }
        let origin = fragment.layoutFragmentFrame.origin
        for line in fragment.textLineFragments {
            let bounds = line.typographicBounds.offsetBy(dx: origin.x, dy: origin.y)
            if y >= bounds.minY, y < bounds.maxY { return (bounds.minY, bounds.maxY) }
        }
        return nil
    }
}

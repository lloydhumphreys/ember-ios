import EmberSDK
import EmberTesting
import Foundation
import SwiftUI
import Testing
@testable import Ember

@MainActor
@Suite struct TimelineScrollTests {
    /// 2,000 points of content in a 700-point region, 100 of composer under it and 50 of bar over
    /// it, at `offset`.
    private func geometry(
        offset: CGFloat, content: CGFloat = 2000, width: CGFloat = 390, height: CGFloat = 700, top: CGFloat = 50, bottom: CGFloat = 100
    ) -> TimelineGeometry {
        TimelineGeometry(offset: offset, contentHeight: content, containerWidth: width, containerHeight: height, insetTop: top, insetBottom: bottom)
    }

    private var atEnd: TimelineGeometry { geometry(offset: 1250) }

    // MARK: Geometry

    @Test func theEndIsWhereTheLastPointOfContentMeetsTheComposer() {
        #expect(atEnd.maxOffset == 1250)
        #expect(atEnd.distanceToEnd == 0)
        #expect(atEnd.isNearEnd)
        #expect(!geometry(offset: 1100).isNearEnd)
    }

    @Test func contentShorterThanTheRegionIsAtItsEndAndItsStart() {
        let short = geometry(offset: -50, content: 300)
        #expect(short.maxOffset == -50)
        #expect(short.isNearEnd)
        #expect(short.isNearStart)
    }

    // MARK: The region changing size

    @Test func aReaderAtTheEndStaysThereWhenTheRegionGrows() {
        let decision = TimelineScroll.decide(from: atEnd, to: geometry(offset: 1250, height: 900), isPinnedToEnd: true, canHoldEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aReaderAtTheEndStaysThereWhenTheyRotate() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 1400, width: 844, height: 300), isPinnedToEnd: true, canHoldEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aReaderAtTheEndIsntMovedWhileALaterPageExistsButStaysPinned() {
        let decision = TimelineScroll.decide(from: atEnd, to: geometry(offset: 1250, height: 900), isPinnedToEnd: true, canHoldEnd: false)
        #expect(decision == .init(move: .none, isPinnedToEnd: true))
    }

    @Test func aReaderMidwayKeepsTheirRowWhenTheyRotate() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 600), to: geometry(offset: 600, content: 1300, width: 844, height: 300), isPinnedToEnd: false, canHoldEnd: true)
        #expect(decision == .init(move: .keepRow, isPinnedToEnd: false))
    }

    @Test func aReaderMidwayIsLeftAloneWhenTheComposerGrows() {
        let decision = TimelineScroll.decide(from: geometry(offset: 600), to: geometry(offset: 600, bottom: 180), isPinnedToEnd: false, canHoldEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func anOffsetLeftPastTheEndOfTheContentIsBroughtBack() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1200, height: 400), to: geometry(offset: 1200, height: 900), isPinnedToEnd: false, canHoldEnd: true)
        #expect(decision.move == .keepRow)
        #expect(geometry(offset: 1200, height: 900).maxOffset < 1200)
    }

    // MARK: The offset moving

    @Test func scrollingUpUnpinsTheEndAndScrollingBackPinsIt() {
        let up = TimelineScroll.decide(from: atEnd, to: geometry(offset: 900), isPinnedToEnd: true, canHoldEnd: true)
        #expect(up == .init(move: .none, isPinnedToEnd: false))
        let back = TimelineScroll.decide(from: geometry(offset: 900), to: geometry(offset: 1230), isPinnedToEnd: false, canHoldEnd: true)
        #expect(back == .init(move: .none, isPinnedToEnd: true))
    }

    // MARK: The content changing height

    @Test func aMessageArrivingAtTheEndIsFollowed() {
        let decision = TimelineScroll.decide(from: atEnd, to: geometry(offset: 1250, content: 2080), isPinnedToEnd: true, canHoldEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aMessageArrivingWhileScrolledUpDoesntMoveTheView() {
        let decision = TimelineScroll.decide(from: geometry(offset: 600), to: geometry(offset: 600, content: 2080), isPinnedToEnd: false, canHoldEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func aMessageArrivingWhileAFingerIsOnTheTimelineIsntFollowed() {
        let decision = TimelineScroll.decide(from: atEnd, to: geometry(offset: 1250, content: 2080), isPinnedToEnd: true, canHoldEnd: false)
        #expect(decision == .init(move: .none, isPinnedToEnd: true))
    }

    // MARK: On the way to the end

    @Test func aMessageSentDuringTheScrollToTheEndIsFollowedThere() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1100), to: geometry(offset: 1140, content: 2300), isPinnedToEnd: true, canHoldEnd: true,
            isGoingToEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
        let unheld = TimelineScroll.decide(
            from: geometry(offset: 1100), to: geometry(offset: 1140, content: 2300), isPinnedToEnd: true, canHoldEnd: true)
        #expect(unheld == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func theScrollToTheEndDoesntCountAsTheReaderLeavingIt() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 900), to: geometry(offset: 1000), isPinnedToEnd: true, canHoldEnd: true, isGoingToEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: true))
    }

    @Test func theComposerGrowingOnTheWayToTheEndIsFollowed() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1200), to: geometry(offset: 1180, bottom: 190), isPinnedToEnd: true, canHoldEnd: true,
            isGoingToEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aFingerOnTheWayToTheEndTakesOver() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1100), to: geometry(offset: 900), isPinnedToEnd: true, canHoldEnd: false,
            isTouched: true, isGoingToEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func aFoldOnTheWayToTheEndIsHeldAsAnyOther() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 2400), isPinnedToEnd: true, canHoldEnd: true,
            isHoldingFold: true, isGoingToEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func theEndOfAPageWithALaterOneIsntHeldOnTheWayThere() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1100), to: geometry(offset: 1100, content: 2300), isPinnedToEnd: true, canHoldEnd: false,
            isGoingToEnd: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: true))
    }

    // MARK: The reader's row through a rotation

    @Test func theRowBeforeARotationIsKeptWhileItsLayoutsMoveTheTop() {
        let tracker = TimelineTracker()
        tracker.topID = "a"
        tracker.noteTop(resized: false)
        tracker.topID = "z"
        tracker.noteTop(resized: true)
        #expect(tracker.settledTopID == "a")
        tracker.noteTop(resized: false)
        #expect(tracker.settledTopID == "z")
    }

    @Test func aRowHeldIsntReplacedByWhatPassesTheTopMeanwhile() {
        let tracker = TimelineTracker()
        tracker.topID = "a"
        tracker.noteTop(resized: false)
        tracker.keepOnNextLayout("a", for: .seconds(5))
        tracker.topID = "q"
        tracker.noteTop(resized: false)
        #expect(tracker.settledTopID == "a")
        tracker.handTookOver()
        #expect(tracker.settledTopID == "q")
        #expect(tracker.keepID == nil)
    }

    @Test func aFingerEndsTheWayToTheEnd() {
        let tracker = TimelineTracker()
        tracker.goingToEnd {}
        #expect(tracker.isGoingToEnd)
        tracker.handTookOver()
        #expect(!tracker.isGoingToEnd)
    }

    // MARK: A fold

    @Test func aMessageOpenedAtTheEndKeepsTheOffsetAndLetsGoOfTheEnd() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 2600), isPinnedToEnd: true, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func aMessageOpenedNearTheEndThatStillShowsTheEndStaysPinned() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 2010), isPinnedToEnd: true, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: true))
    }

    @Test func aMessageFoldedMidwayKeepsTheOffset() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 600), to: geometry(offset: 600, content: 1700), isPinnedToEnd: false, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func aMessageFoldedAtTheEndBringsTheOffsetBackToTheEnd() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 1700), isPinnedToEnd: true, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aMessageFoldedNearTheEndThatLeavesTheOffsetPastItIsBroughtBackWhileALaterPageExists() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 1000), to: geometry(offset: 1000, content: 1700), isPinnedToEnd: false, canHoldEnd: false, isHoldingFold: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aMessageFoldedWithItsTopOnScreenKeepsTheRowsAboveIt() {
        #expect(TimelineScroll.sizeChangeAnchor(isHoldingFold: true) == .top)
        let decision = TimelineScroll.decide(
            from: geometry(offset: 900), to: geometry(offset: 900, content: 2700), isPinnedToEnd: false, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .none, isPinnedToEnd: false))
    }

    @Test func theContentIsKeptByItsFootUnlessAFoldIsHeld() {
        #expect(TimelineScroll.sizeChangeAnchor(isHoldingFold: false) == .bottom)
    }

    @Test func aMessageFoldedSoTheOffsetWouldGoPastTheStartBringsBackTheTopRow() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 100), to: geometry(offset: -400, content: 1500), isPinnedToEnd: false, canHoldEnd: true, isHoldingFold: true)
        #expect(decision.move == .keepRow)
    }

    @Test func aMessageFoldedSoTheContentNoLongerFillsTheScreenGoesBackToTheEnd() {
        let short = geometry(offset: 600, content: 500)
        #expect(short.maxOffset == short.minOffset)
        let decision = TimelineScroll.decide(
            from: geometry(offset: 600), to: short, isPinnedToEnd: false, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aFoldUnderAFingerIsLeftToTheFinger() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 1700), isPinnedToEnd: true, canHoldEnd: false,
            isHoldingFold: true, isTouched: true)
        #expect(decision.move == .none)
    }

    @Test func aMessageArrivingAtTheEndOnceTheFoldIsLetGoIsFollowed() {
        let decision = TimelineScroll.decide(
            from: atEnd, to: geometry(offset: 1250, content: 2080), isPinnedToEnd: true, canHoldEnd: true, isHoldingFold: false)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aRotationWhileAFoldIsHeldStillKeepsTheReadersRow() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 600), to: geometry(offset: 600, content: 1300, width: 844, height: 300),
            isPinnedToEnd: false, canHoldEnd: true, isHoldingFold: true)
        #expect(decision == .init(move: .keepRow, isPinnedToEnd: false))
    }

    @Test func holdingAFoldLetsGoOfTheRowBeingKeptOnceForEachFold() {
        let tracker = TimelineTracker()
        tracker.keepOnNextLayout("m2", for: .seconds(5))
        let folded = MessageFolds.Toggle(messageID: "m5", isOpen: false, serial: 7)
        tracker.hold(folded)
        #expect(tracker.keepID == nil)
        tracker.keepOnNextLayout("m2", for: .seconds(5))
        tracker.hold(folded)
        #expect(tracker.keepID == "m2")
        tracker.hold(MessageFolds.Toggle(messageID: "m5", isOpen: true, serial: 8))
        #expect(tracker.keepID == nil)
    }

    @Test func leavingTheTimelineLetsGoOfTheRowBeingKept() {
        let tracker = TimelineTracker()
        tracker.keepOnNextLayout("m2", for: .seconds(5))
        tracker.leave()
        #expect(tracker.keepID == nil)
        #expect(!tracker.isGoingToEnd)
    }

    @Test func aCheckForABlankTimelineWaitsAndIsReplacedByTheNext() async throws {
        let tracker = TimelineTracker()
        var first = 0
        var second = 0
        tracker.watchForBlank { first += 1; return false }
        tracker.watchForBlank { second += 1; return false }
        try await Task.sleep(for: TimelineScroll.blankWait + .milliseconds(400))
        #expect(first == 0)
        #expect(second == 1)
    }

    @Test func aCheckForABlankTimelineIsDroppedAsTheTimelineLeaves() async throws {
        let tracker = TimelineTracker()
        var checks = 0
        tracker.watchForBlank { checks += 1; return true }
        tracker.leave()
        try await Task.sleep(for: TimelineScroll.blankWait + .milliseconds(400))
        #expect(checks == 0)
    }

    // MARK: The offset stays within the content

    @Test func anOffsetPastTheEndGoesBackToTheEnd() {
        #expect(TimelineScroll.bringBack(geometry(offset: 1251), isTouched: false) == .toEnd)
        #expect(TimelineScroll.bringBack(geometry(offset: 1250, content: 1500), isTouched: false) == .toEnd)
    }

    @Test func anOffsetBeforeTheStartPutsBackTheTopRow() {
        #expect(TimelineScroll.bringBack(geometry(offset: -51), isTouched: false) == .keepRow)
    }

    @Test func anOffsetWithinTheContentStays() {
        #expect(TimelineScroll.bringBack(geometry(offset: -50), isTouched: false) == nil)
        #expect(TimelineScroll.bringBack(geometry(offset: 600), isTouched: false) == nil)
        #expect(TimelineScroll.bringBack(atEnd, isTouched: false) == nil)
        #expect(TimelineScroll.bringBack(geometry(offset: 1250.4), isTouched: false) == nil)
    }

    @Test func anOffsetOutsideTheContentUnderAFingerIsLeftToTheScrollView() {
        #expect(TimelineScroll.bringBack(geometry(offset: 1400), isTouched: true) == nil)
        #expect(TimelineScroll.bringBack(geometry(offset: -200), isTouched: true) == nil)
    }

    @Test func contentShrinkingUnderAStillOffsetBringsItBackToTheEndHoweverItWasHeld() {
        for (pinned, folding) in [(false, false), (false, true), (true, false), (true, true)] {
            let decision = TimelineScroll.decide(
                from: geometry(offset: 1100), to: geometry(offset: 1100, content: 1500),
                isPinnedToEnd: pinned, canHoldEnd: false, isHoldingFold: folding)
            #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
        }
    }

    @Test func anOffsetLeftPastTheEndByAScrollIsBroughtBackToo() {
        let decision = TimelineScroll.decide(
            from: geometry(offset: 900), to: geometry(offset: 1400), isPinnedToEnd: false, canHoldEnd: true)
        #expect(decision == .init(move: .toEnd, isPinnedToEnd: true))
    }

    @Test func aRowHeldWithTheOffsetPastTheEndIsPutBackAsTheRowsReflow() {
        let move = TimelineScroll.keeping(
            from: geometry(offset: 1100, content: 2500), to: geometry(offset: 1100, content: 1500), isTouched: false)
        #expect(move == .keepRow)
    }

    @Test func aRowHeldWithinTheContentIsPutBackAsTheContentChanges() {
        let move = TimelineScroll.keeping(
            from: geometry(offset: 600, content: 2500), to: geometry(offset: 600, content: 1500), isTouched: false)
        #expect(move == .keepRow)
    }

    @Test func aRowHeldFarFromTheEndIsPutBackWhenAnEstimateLeavesTheOffsetPastTheEnd() {
        let move = TimelineScroll.keeping(
            from: geometry(offset: 4200, content: 6600), to: geometry(offset: 4200, content: 4500), isTouched: false)
        #expect(move == .keepRow)
    }

    @Test func aRowHeldIsPutBackAsTheRegionChangesSize() {
        let move = TimelineScroll.keeping(
            from: geometry(offset: 600), to: geometry(offset: 600, width: 844, height: 300), isTouched: false)
        #expect(move == .keepRow)
    }

    @Test func aRowHeldIsLeftWhileNothingChanges() {
        let move = TimelineScroll.keeping(from: geometry(offset: 600), to: geometry(offset: 610), isTouched: false)
        #expect(move == .none)
    }

    @Test func aRowHeldUnderAFingerIsPutBackOnlyAsTheContentChanges() {
        let reflowed = TimelineScroll.keeping(
            from: geometry(offset: 1100, content: 2500), to: geometry(offset: 1100, content: 1500), isTouched: true)
        #expect(reflowed == .keepRow)
        let past = TimelineScroll.keeping(from: geometry(offset: 1100), to: geometry(offset: 1400), isTouched: true)
        #expect(past == .none)
    }

    // MARK: The row being read

    @Test func theRowBeingReadIsTheHighestWhollyInView() {
        let order = ["m1": 0, "m2": 1, "m3": 2]
        #expect(TimelineScroll.readerRow(["m2", "m1", "m3"], whole: ["m1", "m2"], position: { order[$0] }) == "m1")
    }

    @Test func theRowBeingReadIsTheNextOneDownWhenOnlyTheFootOfTheHighestShows() {
        let order = ["m1": 0, "m2": 1, "m3": 2]
        #expect(TimelineScroll.readerRow(["m3", "m1", "m2"], whole: ["m2"], position: { order[$0] }) == "m2")
        #expect(TimelineScroll.readerRow(["m1", "m2"], whole: [], position: { order[$0] }) == "m2")
    }

    @Test func theRowBeingReadSkipsADaysHeadingAndTheEndsSpacer() {
        let day = "day-2026-11-11"
        #expect(TimelineItem.isDay(day))
        let order = ["m1": 0, day: 1, "m2": 2]
        #expect(TimelineScroll.readerRow(["m1", day, "m2"], whole: [day, "m2"], position: { order[$0] }) == "m2")
        #expect(TimelineScroll.readerRow(["m1", "spacer"], whole: ["spacer"], position: { order[$0] }) == "m1")
    }

    @Test func aRowFillingTheScreenIsTheOneBeingRead() {
        let order = ["m1": 0]
        #expect(TimelineScroll.readerRow(["m1"], whole: [], position: { order[$0] }) == "m1")
        #expect(TimelineScroll.readerRow([], whole: [], position: { order[$0] }) == nil)
    }

    // MARK: A timeline showing none of its rows

    @Test func aStillTimelineShowingNoneOfItsRowsGoesBackToTheRowItWasKeeping() {
        #expect(TimelineScroll.recover(hasRows: true, rowsInView: false, isMoving: false, keeping: "m4") == .row("m4"))
    }

    @Test func aStillTimelineShowingNoneOfItsRowsAndKeepingNoneGoesToTheEnd() {
        #expect(TimelineScroll.recover(hasRows: true, rowsInView: false, isMoving: false, keeping: nil) == .toEnd)
    }

    @Test func aTimelineShowingARowOrHavingNoneIsLeftAlone() {
        #expect(TimelineScroll.recover(hasRows: true, rowsInView: true, isMoving: false, keeping: "m4") == nil)
        #expect(TimelineScroll.recover(hasRows: false, rowsInView: false, isMoving: false, keeping: nil) == nil)
    }

    @Test func aTimelineBeingMovedIsLeftAloneUntilItStops() {
        #expect(TimelineScroll.recover(hasRows: true, rowsInView: false, isMoving: true, keeping: "m4") == nil)
        #expect(TimelineScroll.recover(hasRows: true, rowsInView: false, isMoving: true, keeping: nil) == nil)
    }

    @Test func aTimelineComingBackWithTheReaderAtTheEndGoesBackThere() {
        #expect(TimelineScroll.returning(isPinnedToEnd: true, readerRow: "m4", foldedAway: true) == .toEnd)
        #expect(TimelineScroll.returning(isPinnedToEnd: true, readerRow: nil, foldedAway: false) == .toEnd)
    }

    @Test func aTimelineComingBackAfterAFoldElsewhereGoesBackToTheReadersRow() {
        #expect(TimelineScroll.returning(isPinnedToEnd: false, readerRow: "m4", foldedAway: true) == .row("m4"))
        #expect(TimelineScroll.returning(isPinnedToEnd: false, readerRow: nil, foldedAway: true) == .toEnd)
    }

    @Test func aTimelineComingBackWithNothingFoldedAwayStaysPut() {
        #expect(TimelineScroll.returning(isPinnedToEnd: false, readerRow: "m4", foldedAway: false) == nil)
    }

    @Test func anOffsetWithinTheContentShowsIt() {
        let atEnd = TimelineGeometry(offset: 9_243, contentHeight: 9_986, containerWidth: 402, containerHeight: 627, insetTop: 116)
        let atTop = TimelineGeometry(offset: -116, contentHeight: 9_986, containerWidth: 402, containerHeight: 627, insetTop: 116)
        #expect(atEnd.showsContent)
        #expect(atTop.showsContent)
    }

    @Test func anOffsetWhollyPastEitherEndShowsNoneOfTheContent() {
        let pastEnd = TimelineGeometry(offset: 9_900, contentHeight: 9_986, containerWidth: 402, containerHeight: 627, insetTop: 116)
        let beforeStart = TimelineGeometry(offset: -800, contentHeight: 9_986, containerWidth: 402, containerHeight: 627, insetTop: 116)
        let empty = TimelineGeometry(offset: -116, contentHeight: 0, containerWidth: 402, containerHeight: 627, insetTop: 116)
        #expect(!pastEnd.showsContent)
        #expect(!beforeStart.showsContent)
        #expect(!empty.showsContent)
    }

    // MARK: The row at the top

    @Test func theRowAtTheTopIsTheHighestOfThoseInViewWhateverTheirOrder() {
        let order = ["m1": 0, "m2": 1, "m3": 2, "m4": 3]
        #expect(TimelineScroll.topmost(["m3", "m2", "m4"], position: { order[$0] }) == "m2")
        #expect(TimelineScroll.topmost(["spacer", "m4", "m3"], position: { order[$0] }) == "m3")
        #expect(TimelineScroll.topmost(["spacer"], position: { order[$0] }) == "spacer")
        #expect(TimelineScroll.topmost([], position: { order[$0] }) == nil)
    }

    @Test func aDaysHeadingIsTheRowAtTheTopOnlyWhenNothingElseIsInView() {
        let order = ["day-0": 0, "m1": 1, "m2": 2]
        #expect(TimelineScroll.topmost(["m2", "day-0", "m1"], position: { order[$0] }) == "m1")
        #expect(TimelineScroll.topmost(["day-0"], position: { order[$0] }) == "day-0")
    }

    @Test func anOlderPagesRowsInViewArentTheReadersRow() {
        // An older page of three rows laid out above m1, read before the timeline heard of it.
        let order = ["p1": 0, "p2": 1, "p3": 2, "m1": 3, "m2": 4]
        let start = order["m1"]!
        #expect(TimelineScroll.topmost(["m2", "p2", "m1", "p3"], position: { order[$0] }, from: start) == "m1")
        #expect(TimelineScroll.topmost(["p1", "p2"], position: { order[$0] }, from: start) == nil)
    }

    // MARK: The count on the jump-down button

    @Test func theButtonCountsOthersMessagesSinceTheReaderLeftTheEnd() {
        let messages = [
            Fixtures.message("m1", "one", by: Fixtures.grace, minute: 1),
            Fixtures.message("m2", "two", by: Fixtures.grace, minute: 2),
            Fixtures.message("m3", "mine", by: Fixtures.ada, minute: 3),
            Fixtures.message("m4", "four", by: Fixtures.grace, minute: 4),
        ]
        #expect(TimelineScroll.unseen(in: messages, after: "m1", me: Fixtures.ada.id) == 2)
        #expect(TimelineScroll.unseen(in: messages, after: "m4", me: Fixtures.ada.id) == 0)
        #expect(TimelineScroll.unseen(in: messages, after: nil, me: Fixtures.ada.id) == 0)
        #expect(TimelineScroll.unseen(in: messages, after: "gone", me: Fixtures.ada.id) == 0)
    }

    // MARK: Paging

    @Test func aPageAskedForNearTheStartIsntFollowedByAnotherUntilTheReaderMoves() {
        var gate = PagingGate()
        #expect(gate.isOpen)
        gate.asked()
        gate.saw(isNear: true, scrollingByHand: false)
        #expect(!gate.isOpen)
        gate.saw(isNear: false, scrollingByHand: false)
        #expect(gate.isOpen)
    }

    @Test func aScrollByHandAtTheStartAsksForTheNextPage() {
        var gate = PagingGate()
        gate.asked()
        gate.saw(isNear: true, scrollingByHand: true)
        #expect(gate.isOpen)
    }

    @Test func aFingerComingDownWithoutTrackingStillCountsAsAScrollByHand() {
        #expect(PagingGate.fingerCameDown(from: .idle, to: .interacting))
        #expect(PagingGate.fingerCameDown(from: .decelerating, to: .interacting))
        #expect(PagingGate.fingerCameDown(from: .idle, to: .tracking))
        #expect(!PagingGate.fingerCameDown(from: .tracking, to: .interacting))
        #expect(!PagingGate.fingerCameDown(from: .interacting, to: .decelerating))
        #expect(!PagingGate.fingerCameDown(from: .decelerating, to: .idle))
        #expect(!PagingGate.fingerCameDown(from: .idle, to: .animating))
    }
}

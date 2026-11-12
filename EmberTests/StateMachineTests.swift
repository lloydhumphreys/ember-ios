import Foundation
import Testing
import EmberSDK
import EmberTesting
@testable import Ember

/// The small state types that stand in for pairs of flags: a form being sent, a file being opened,
/// a picture being loaded, and the next page of search results.
@MainActor
@Suite struct StateMachineTests {
    // MARK: Submission

    @Test func aFormStartsSendingFromIdleAndFromFailed() {
        var submission = Submission.idle
        let began1 = submission.begin()
        #expect(began1)
        #expect(submission.isWorking)
        submission.fail("No.")
        #expect(submission.failure == "No.")
        #expect(!submission.isWorking)
        let began2 = submission.begin()
        #expect(began2)
        #expect(submission == .working)
        #expect(submission.failure == nil)
    }

    @Test func aSecondSendWhileOneIsOnItsWayDoesNothing() {
        var submission = Submission.working
        let began3 = submission.begin()
        #expect(!began3)
        #expect(submission == .working)
    }

    @Test func correctingClearsAComplaintButNotASendOnItsWay() {
        var submission = Submission.failed("No.")
        submission.clearFailure()
        #expect(submission == .idle)
        submission = .working
        submission.clearFailure()
        #expect(submission == .working)
    }

    @Test func finishingOnlyEndsASendOnItsWay() {
        var submission = Submission.working
        submission.finish()
        #expect(submission == .idle)
        submission = .failed("No.")
        submission.finish()
        #expect(submission == .failed("No."))
    }

    // MARK: File opening

    @Test func aFileOpensOneDownloadAtATimeAndForgetsTheLastFailure() {
        var opening = FileOpening.idle
        let began4 = opening.begin()
        #expect(began4)
        let began5 = opening.begin()
        #expect(!began5)
        opening.finish(failed: true)
        #expect(opening == .failed)
        let began6 = opening.begin()
        #expect(began6)
        #expect(opening == .downloading)
        opening.finish(failed: false)
        #expect(opening == .idle)
    }

    // MARK: Pictures

    @Test func aPictureHoldsEitherItselfOrAFailureNeverBoth() {
        var load = ImageLoad<Int>.loading
        #expect(load.picture == nil && load.failure == nil)
        load = .failed(.unreachable)
        #expect(load.picture == nil)
        #expect(load.failure == .unreachable)
        load = .loaded(3)
        #expect(load.picture == 3)
        #expect(load.failure == nil)
    }

    @Test func aFailureFromAnEarlyTryIsGoneOnceThePictureComes() async {
        var answers: [Result<Int, ImageLimits.Failure>] = [.failure(.unreachable), .failure(.status(503)), .success(7)]
        var told: [ImageLoad<Int>] = []
        var load = ImageLoad<Int>.loading
        await ImageLoad.keepTrying(pauses: [.zero, .zero, .zero]) {
            answers.removeFirst()
        } update: {
            told.append($0)
            load = $0
        }
        #expect(told == [.failed(.unreachable), .failed(.status(503)), .loaded(7)])
        #expect(load.picture == 7)
        #expect(load.failure == nil)
    }

    @Test func aPictureThatArrivesAfterItsLoadWasCancelledIsNotTold() async {
        let told = await Self.toldAfterCancelling(.success(7))
        #expect(told == 0)
    }

    @Test func aFailureThatArrivesAfterItsLoadWasCancelledIsNotTold() async {
        let told = await Self.toldAfterCancelling(.failure(.status(503)))
        #expect(told == 0)
    }

    /// How many times a load is told anything when its task is cancelled while the attempt is
    /// out, as a row going away does, and the attempt then answers `answer`.
    private static func toldAfterCancelling(_ answer: Result<Int, ImageLimits.Failure>) async -> Int {
        await Task { @MainActor in
            var told = 0
            await ImageLoad.keepTrying(pauses: [.zero]) {
                withUnsafeCurrentTask { $0?.cancel() }
                return answer
            } update: { _ in told += 1 }
            return told
        }.value
    }

    @Test func aPictureThatNeverComesLeavesItsLastFailure() async {
        var load = ImageLoad<Int>.loading
        await ImageLoad.keepTrying(pauses: [.zero]) {
            .failure(.status(404))
        } update: { load = $0 }
        #expect(load == .failed(.status(404)))
    }

    // MARK: Search paging

    @Test func searchResultsStartWithNoPageOnItsWay() {
        let model = SearchModel()
        #expect(model.more == .idle)
        #expect(!model.isLoadingMore)
        #expect(model.moreFailure == nil)
        model.loadMore()
        #expect(model.more == .idle)
        model.text = "🔥"
        model.run(record: false)
        #expect(model.phase == .loaded)
        #expect(model.more == .idle)
    }
}

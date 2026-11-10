import Foundation
import Testing
@testable import Ember

/// Landing a jump on its message, without a screen or a clock: where `JumpLanding` judges a row
/// to have landed, what the landing loop answers when the row settles or never does, and that a
/// thread's focus is marked shown once the landing is over.
@MainActor
@Suite struct TimelineLandingTests {
    /// A landing whose measurements come from `frames`, one per look (the last repeating), with
    /// every scroll and wait counted and no time passing.
    @MainActor private final class Run {
        var frames: [CGRect?]
        var viewport: CGFloat = 600
        var scrolls: [JumpLanding.Placement] = []
        var waits = 0
        var cancelAfterWaits: Int?

        init(_ frames: [CGRect?]) { self.frames = frames }

        var lander: JumpLander {
            JumpLander(
                scroll: { self.scrolls.append($0) },
                measure: {
                    let index = min(self.waits - 1, self.frames.count - 1)
                    return JumpLander.Measure(frame: self.frames[index], viewport: self.viewport)
                },
                wait: {
                    self.waits += 1
                    if let limit = self.cancelAfterWaits, self.waits >= limit { throw CancellationError() }
                })
        }
    }

    private static let inView = CGRect(x: 0, y: 200, width: 390, height: 80)
    private static let aboveBar = CGRect(x: 0, y: -300, width: 390, height: 80)

    // MARK: JumpLanding

    @Test func aRowWhollyInViewHasLanded() {
        #expect(JumpLanding.isLanded(minY: 200, height: 80, viewport: 600))
        #expect(JumpLanding.isLanded(minY: 0, height: 600, viewport: 600))
    }

    @Test func aRowUnderTheBarOrPastTheFootHasNotLanded() {
        #expect(!JumpLanding.isLanded(minY: -40, height: 80, viewport: 600))
        #expect(!JumpLanding.isLanded(minY: 560, height: 80, viewport: 600))
        #expect(!JumpLanding.isLanded(minY: 600, height: 80, viewport: 600))
    }

    @Test func aRowTallerThanTheScreenHasLandedWithItsTopInView() {
        #expect(JumpLanding.isLanded(minY: 0, height: 900, viewport: 600))
        #expect(!JumpLanding.isLanded(minY: -10, height: 900, viewport: 600))
        #expect(JumpLanding.placement(rowHeight: 900, viewport: 600) == .top)
        #expect(JumpLanding.placement(rowHeight: 80, viewport: 600) == .center)
    }

    @Test func missesAlternateBottomThenTop() {
        #expect(JumpLanding.placement(afterMisses: 1) == .bottom)
        #expect(JumpLanding.placement(afterMisses: 2) == .top)
        #expect(JumpLanding.placement(afterMisses: 3) == .bottom)
    }

    // MARK: The landing loop

    @Test func landsOnceTheRowHasStayedInViewForTwoLooks() async throws {
        let run = Run([Self.inView])
        #expect(try await run.lander.land())
        #expect(run.waits == 2)
        // Scrolled once, then left alone while it held.
        #expect(run.scrolls == [.center])
    }

    @Test func landsAfterTheEstimatesSettle() async throws {
        let run = Run([nil, Self.aboveBar, Self.inView])
        #expect(try await run.lander.land())
        // Unbuilt, so to its bottom; built but under the bar, so centred again; then held.
        #expect(run.scrolls == [.center, .bottom, .center])
        #expect(run.waits == 4)
    }

    @Test func doesNotLandWhenTheRowNeverSettles() async throws {
        let run = Run([Self.aboveBar])
        #expect(try await run.lander.land() == false)
        #expect(run.waits == 12)
        #expect(run.scrolls.count == 12)
    }

    @Test func doesNotLandWhenTheRowIsNeverBuilt() async throws {
        let run = Run([nil])
        #expect(try await run.lander.land() == false)
        #expect(run.waits == 12)
    }

    @Test func doesNotLandBeforeTheViewportIsKnown() async throws {
        let run = Run([Self.inView])
        run.viewport = 0
        #expect(try await run.lander.land() == false)
    }

    // MARK: Showing

    @Test func lightsAndMarksShownOnceAfterLanding() async {
        let run = Run([Self.inView])
        var events: [String] = []
        await run.lander.show(highlight: { events.append("highlight") }, shown: { events.append("shown") })
        #expect(events == ["highlight", "shown"])
    }

    @Test func marksShownOnceWithoutLightingWhenItDoesNotLand() async {
        let run = Run([Self.aboveBar])
        var events: [String] = []
        await run.lander.show(highlight: { events.append("highlight") }, shown: { events.append("shown") })
        #expect(events == ["shown"])
        #expect(run.waits == 12)
    }

    @Test func leavesTheFocusWhenCancelled() async {
        let run = Run([Self.aboveBar])
        run.cancelAfterWaits = 3
        var events: [String] = []
        await run.lander.show(highlight: { events.append("highlight") }, shown: { events.append("shown") })
        #expect(events.isEmpty)
    }
}

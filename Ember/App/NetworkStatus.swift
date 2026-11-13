import Foundation
import Observation
import EmberSDK

/// Whether the device has a way to the internet at all, which says nothing about whether the server
/// answers. Offline is only what the system reports; until it reports, the app counts as online.
@MainActor @Observable final class NetworkStatus {
    private(set) var isOnline = true

    @ObservationIgnored private var waiters: [UUID: AsyncStream<Void>.Continuation] = [:]
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// `source` is the SDK's, the same the sockets listen to; tests pass EmberTesting's
    /// `MockNetworkPath`.
    init(source: any NetworkPathSource = SystemNetworkPath.shared) {
        let updates = source.availability()
        watching = Task { [weak self] in
            for await online in updates {
                self?.update(online)
            }
        }
    }

    isolated deinit {
        watching?.cancel()
    }

    /// One element each time the device goes from offline to online, for as long as it's iterated.
    func returns() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        waiters[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.waiters[id] = nil }
        }
        return stream
    }

    private func update(_ online: Bool) {
        let cameBack = online && !isOnline
        if online != isOnline { isOnline = online }
        if cameBack {
            for waiter in waiters.values { waiter.yield() }
        }
    }
}

/// How long to wait before trying something that failed again, and the wait itself.
enum Retrying {
    /// Two seconds after the first failure, doubling each time, and never more than a minute.
    static func delay(attempt: Int) -> Duration {
        min(.seconds(2) * (1 << min(max(attempt, 0), 6)), .seconds(60))
    }

    /// Returns after `delay(attempt:)` on `clock`, or as soon as the network comes back, whichever is
    /// first, or when cancelled.
    @MainActor static func wait(attempt: Int, clock: any Clock<Duration>, network: NetworkStatus) async {
        let returns = network.returns()
        let delay = delay(attempt: attempt)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await clock.sleep(for: delay) }
            group.addTask {
                for await _ in returns { return }
            }
            await group.next()
            group.cancelAll()
        }
    }
}

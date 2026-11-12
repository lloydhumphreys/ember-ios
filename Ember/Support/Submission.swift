import Foundation

/// Where something sent from a form is: not sent, on its way, or refused with a message to show.
/// A form that's on its way has no complaint, and one with a complaint isn't on its way, which a
/// pair of a flag and an optional message would leave to each place that writes them.
enum Submission: Equatable {
    case idle
    case working
    case failed(String)

    var isWorking: Bool { self == .working }

    /// The message to show, while there is one.
    var failure: String? {
        if case .failed(let message) = self { message } else { nil }
    }

    /// Starts sending, dropping any complaint about the last try. False, and nothing changed,
    /// while one is already on its way.
    @discardableResult
    mutating func begin() -> Bool {
        guard !isWorking else { return false }
        self = .working
        return true
    }

    /// What was on its way came to nothing worth keeping on screen, or the screen is about to go.
    mutating func finish() {
        if isWorking { self = .idle }
    }

    /// What was on its way was refused, with `message` to show.
    mutating func fail(_ message: String) {
        self = .failed(message)
    }

    /// Correcting what failed is what clears the complaint about it. Nothing else is cleared: a
    /// send on its way carries on.
    mutating func clearFailure() {
        if case .failed = self { self = .idle }
    }
}

import Foundation

/// Where a picture's load is: on its way, here, or failed with a reason. The picture and the
/// failure are never both held, so a failure from an early try doesn't outlive the try that
/// brought the picture.
enum ImageLoad<Picture> {
    case loading
    case loaded(Picture)
    case failed(ImageLimits.Failure)

    var picture: Picture? {
        if case .loaded(let picture) = self { picture } else { nil }
    }

    /// Why it failed, while it has and no picture has come since.
    var failure: ImageLimits.Failure? {
        if case .failed(let failure) = self { failure } else { nil }
    }

    /// Tries `attempt` as `ImageRetry.keepTrying` does, telling `update` of each change: `.failed`
    /// for each failure on the way, and `.loaded` once a picture comes, which is the last word.
    /// Nothing is said when it stops on a failure already told, or is cancelled.
    @MainActor static func keepTrying(
        pauses: [Duration] = ImageRetry.pauses,
        _ attempt: @MainActor () async -> Result<Picture, ImageLimits.Failure>,
        update: @MainActor (ImageLoad<Picture>) -> Void
    ) async {
        let picture = await ImageRetry.keepTrying(pauses: pauses, attempt) { update(.failed($0)) }
        if let picture { update(.loaded(picture)) }
    }
}

extension ImageLoad: Equatable where Picture: Equatable {}

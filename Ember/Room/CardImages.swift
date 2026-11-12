import SwiftUI
import UIKit
import ImageIO
import EmberSDK
import EmberRichText

/// What a picture's load came to: the picture, downsampled to the size it's drawn at, and its own
/// size in pixels, which caps how large it's drawn.
struct LoadedImage {
    let image: UIImage
    let pixelSize: CGSize

    /// Width over height.
    var aspectRatio: CGFloat { pixelSize.width / max(pixelSize.height, 1) }
}

/// The bounds every picture is held to, whoever serves it: a card's server or the chat server, as
/// both carry what other people and bots chose to send.
enum ImageLimits {
    /// The most a picture may weigh before it's left out.
    static let maxBytes = 10 * 1024 * 1024
    /// The most pixels a picture may have before it's left out, as it would be too large to decode.
    static let maxPixels = 50_000_000

    /// Why a picture didn't load.
    enum Failure: Error, Equatable {
        /// Its address, or one it redirected to, isn't one it may be fetched from.
        case refused
        case tooLarge
        case notAnImage
        case status(Int)
        /// Offline, timed out, or the server didn't answer.
        case unreachable

        /// Whether trying again could never come to anything else, so it's remembered. A sign-in, a
        /// timeout or a rate limit can pass, and a 5xx or an unreachable server can come back.
        var isLasting: Bool {
            switch self {
            case .refused, .tooLarge, .notAnImage: true
            case let .status(status): (400 ..< 500).contains(status) && ![401, 403, 408, 429].contains(status)
            case .unreachable: false
            }
        }
    }

    /// Why `response` can't be a picture's: not a success (a redirect that was refused reaches here
    /// as its 3xx), or larger than `maxBytes` by its own account. Nil when it may be read.
    static func failure(of response: URLResponse) -> Failure? {
        guard let http = response as? HTTPURLResponse else { return .notAnImage }
        if (300 ..< 400).contains(http.statusCode) { return .refused }
        guard (200 ..< 300).contains(http.statusCode) else { return .status(http.statusCode) }
        return http.expectedContentLength > Int64(maxBytes) ? .tooLarge : nil
    }

    /// The bytes as they arrive, or `tooLarge` once there are more than `maxBytes`, whatever the
    /// answer said its length was.
    static func collect(_ bytes: URLSession.AsyncBytes, expected: Int64) async throws -> Result<Data, Failure> {
        var data = Data()
        if expected > 0 { data.reserveCapacity(Int(min(expected, Int64(maxBytes)))) }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes { return .failure(.tooLarge) }
        }
        return .success(data)
    }

    /// The most an animated picture's frames may weigh once decoded; past it, frames are skipped
    /// evenly, each one shown for as long as those it stands for.
    static let animationBytes = 16 * 1024 * 1024
    /// The most frames an animated picture keeps, whatever their size.
    static let maxFrames = 240

    /// Decoded off the main actor at no more than `maxPixel` on its longer side, and only when it has
    /// no more than `maxPixels`. A picture of more than one frame (GIF, APNG, WebP) comes back
    /// animated.
    @concurrent static func decode(_ data: Data, maxPixel: Int) async -> Result<LoadedImage, Failure> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return .failure(.notAnImage) }
        guard width * height <= maxPixels else { return .failure(.tooLarge) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel, max(width, height))),
        ]
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        // The transform above turned it upright; a quarter turn swaps its own sides.
        let pixelSize = orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        if CGImageSourceGetCount(source) > 1, let animated = animation(source, options: options) {
            return .success(LoadedImage(image: animated, pixelSize: pixelSize))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return .failure(.notAnImage) }
        return .success(LoadedImage(image: UIImage(cgImage: image), pixelSize: pixelSize))
    }

    /// The frames of an animated picture within `animationBytes` and `maxFrames`, or nil when not
    /// even one decodes.
    private static func animation(_ source: CGImageSource, options: [CFString: Any]) -> UIImage? {
        let count = CGImageSourceGetCount(source)
        guard let first = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let frameBytes = max(first.bytesPerRow * first.height, 1)
        let kept = max(1, min(maxFrames, animationBytes / frameBytes, count))
        let step = Int((Double(count) / Double(kept)).rounded(.up))
        var frames: [UIImage] = []
        var duration: Double = 0
        for index in stride(from: 0, to: count, by: step) {
            let image = index == 0 ? first : CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
            guard let image else { continue }
            frames.append(UIImage(cgImage: image))
            duration += (index ..< min(index + step, count)).reduce(0) { $0 + frameDelay(source, at: $1) }
        }
        guard frames.count > 1 else { return frames.first }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    /// How long a frame shows, in seconds, as browsers have it: a delay of next to nothing is a
    /// tenth of a second.
    static func frameDelay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let containers: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (container, unclamped, clamped) in containers {
            guard let values = properties[container] as? [CFString: Any] else { continue }
            let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
            return delay < 0.011 ? 0.1 : delay
        }
        return 0.1
    }

    /// What a decoded picture costs a cache: its bitmaps' bytes, every frame of an animated one.
    static func cost(_ loaded: LoadedImage) -> Int {
        let frames = loaded.image.images ?? [loaded.image]
        return max(1, frames.reduce(0) { total, frame in
            guard let image = frame.cgImage else { return total }
            return total + image.bytesPerRow * image.height
        })
    }
}

/// When a picture that failed is tried again by itself: after a pause that grows with each try, a
/// few times, and never after a failure that's lasting. A tap, or the connection coming back, tries
/// again whatever this says.
enum ImageRetry {
    /// The pauses before each try of its own, in turn.
    static let pauses: [Duration] = [.seconds(2), .seconds(10), .seconds(30)]
}

/// Addresses whose pictures failed for good, and how, so a row scrolled past again doesn't fetch
/// them again this run; past `limit`, the oldest are forgotten.
struct LastingFailures {
    let limit: Int
    private var failures: [String: ImageLimits.Failure] = [:]
    private var order: [String] = []

    init(limit: Int) { self.limit = limit }

    func contains(_ address: String) -> Bool { failures[address] != nil }

    func failure(for address: String) -> ImageLimits.Failure? { failures[address] }

    var count: Int { failures.count }

    mutating func insert(_ address: String, _ failure: ImageLimits.Failure = .notAnImage) {
        guard failures.updateValue(failure, forKey: address) == nil else { return }
        order.append(address)
        if order.count > limit { failures[order.removeFirst()] = nil }
    }

    mutating func remove(_ address: String) {
        guard failures.removeValue(forKey: address) != nil else { return }
        order.removeAll { $0 == address }
    }

    mutating func removeAll() {
        failures = [:]
        order = []
    }
}

/// A cache entry for `NSCache`, which keeps only objects.
final class LoadedImageBox {
    let loaded: LoadedImage
    init(_ loaded: LoadedImage) { self.loaded = loaded }
}

/// A picture in a bot's card. It comes from someone else's server, so it's fetched on a session of
/// its own that keeps no cookies and offers no credentials, never through the signed-in client,
/// and only at an address that passes the card address rule, redirects included.
@MainActor final class CardImages {
    static var shared: CardImages { AccountStores.current.cardImages }

    typealias Loaded = LoadedImage

    private let images = NSCache<NSString, LoadedImageBox>()
    private var inFlight: [String: Task<Result<Loaded, ImageLimits.Failure>, Never>] = [:]
    private var failed = LastingFailures(limit: 500)
    /// Moves on at each `reset()`, so a load that started before one doesn't fill the caches after it.
    private var generation = 0

    let session: URLSession

    /// `protocolClasses` stand in for the network in tests.
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        // No cookie store at all, so not even one a redirect might pick up: the chat server's
        // session cookie is the signed-in client's, which this session never reads.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 20
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: NoCredentials(), delegateQueue: nil)
        images.totalCostLimit = 32 * 1024 * 1024
    }

    static func key(_ url: String, maxPixel: Int) -> String { "\(maxPixel)|\(url)" }

    func cached(_ url: String, maxPixel: Int) -> Loaded? {
        images.object(forKey: Self.key(url, maxPixel: maxPixel) as NSString)?.loaded
    }

    func hasFailed(_ url: String) -> Bool { failed.contains(url) }

    /// Forgets that the picture at `url` failed, so the next ask fetches it again.
    func forget(_ url: String) { failed.remove(url) }

    /// Empties the pictures and the failures kept, and lets loads under way finish for whoever asked
    /// without keeping what they bring.
    func reset() {
        images.removeAllObjects()
        inFlight = [:]
        failed.removeAll()
        session.configuration.urlCache?.removeAllCachedResponses()
        generation += 1
    }

    /// The picture at `url`, checked against the card address rule for the server at `host`.
    func image(_ url: String, host: String, maxPixel: Int) async -> Loaded? {
        try? await result(url, host: host, maxPixel: maxPixel).get()
    }

    /// The picture at `url`, or why it didn't load. One load per address and size, whoever asks; it
    /// finishes for the others when one of them goes away.
    func result(_ url: String, host: String, maxPixel: Int) async -> Result<Loaded, ImageLimits.Failure> {
        let key = Self.key(url, maxPixel: maxPixel)
        if let loaded = cached(url, maxPixel: maxPixel) { return .success(loaded) }
        if let failure = failed.failure(for: url) { return .failure(failure) }
        if let task = inFlight[key] { return await task.value }
        let session = session
        let generation = generation
        // Unstructured, so cancelling the view that started it doesn't cancel it for the rest.
        let task = Task<Result<Loaded, ImageLimits.Failure>, Never> {
            let result = await Self.load(url, host: host, maxPixel: maxPixel, session: session)
            guard generation == self.generation else { return result }
            self.inFlight[key] = nil
            switch result {
            case let .success(loaded):
                self.images.setObject(LoadedImageBox(loaded), forKey: key as NSString, cost: ImageLimits.cost(loaded))
            case let .failure(failure):
                if failure.isLasting { self.failed.insert(url, failure) }
            }
            return result
        }
        inFlight[key] = task
        return await task.value
    }

    @concurrent nonisolated private static func load(_ url: String, host: String, maxPixel: Int, session: URLSession) async -> Result<Loaded, ImageLimits.Failure> {
        guard CardText.address(url, host: host) != nil, let address = URL(string: url) else { return .failure(.refused) }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: address), delegate: Redirects(host: host))
            if let failure = ImageLimits.failure(of: response) { return .failure(failure) }
            switch try await ImageLimits.collect(bytes, expected: response.expectedContentLength) {
            case let .success(data): return await ImageLimits.decode(data, maxPixel: maxPixel)
            case let .failure(failure): return .failure(failure)
            }
        } catch {
            return .failure(.unreachable)
        }
    }

    /// The redirect to follow, or nil to stop at the 3xx: only to an address the card address rule
    /// would have let the card name in the first place, which never includes the chat server.
    nonisolated static func redirect(_ request: URLRequest, host: String) -> URLRequest? {
        guard let url = request.url, CardText.address(url.absoluteString, host: host) != nil else { return nil }
        return request
    }

    /// Each load's own delegate, as the rule needs the chat server's host.
    private final class Redirects: NSObject, URLSessionTaskDelegate, Sendable {
        let host: String

        init(host: String) { self.host = host }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(CardImages.redirect(request, host: host))
        }
    }

    /// Answers every challenge but the server's certificate by declining it, so no password or
    /// client certificate is ever offered to a card's server.
    private final class NoCredentials: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                return (.performDefaultHandling, nil)
            }
            return (.cancelAuthenticationChallenge, nil)
        }

        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
                return (.performDefaultHandling, nil)
            }
            return (.cancelAuthenticationChallenge, nil)
        }
    }
}

/// A card's picture at an address that passed the card address rule, drawn filling its frame, or
/// a quiet placeholder (`placeholder`) or nothing while it loads and when it fails.
struct CardImageView: View {
    let url: String
    /// The longer side it's drawn at, in points, which it's downsampled to.
    let points: CGFloat
    var placeholder = true

    @Environment(Workspace.self) private var workspace
    @Environment(\.displayScale) private var displayScale
    @State private var load = ImageLoad<CardImages.Loaded>.loading
    /// The address `load` is for: the view is kept when the card's picture changes.
    @State private var loadURL: String?
    @State private var reconnects = 0

    private var maxPixel: Int { Int((points * displayScale).rounded(.up)) }

    var body: some View {
        let current = loadURL == url ? load : .loading
        let image = current.picture ?? CardImages.shared.cached(url, maxPixel: maxPixel)
        let host = workspace.client.origin.host() ?? ""
        Group {
            if let image {
                PictureImage(image: image.image)
            } else if placeholder {
                Rectangle().fill(Color(.secondarySystemFill))
            } else {
                Color.clear
            }
        }
        .task(id: "\(CardImages.key(url, maxPixel: maxPixel))#\(reconnects)") {
            guard image == nil else { return }
            let url = url
            await ImageLoad.keepTrying {
                await CardImages.shared.result(url, host: host, maxPixel: maxPixel)
            } update: {
                load = $0
                loadURL = url
            }
        }
        .retryingOnReconnect(after: image == nil ? current.failure : nil, count: $reconnects)
    }
}

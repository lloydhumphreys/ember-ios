import SwiftUI
import UIKit
import EmberSDK

/// The sizes, in pixels, of pictures whose shape the server didn't store, once they've loaded, so
/// a row shown again takes the room its picture needs before the picture is back. Kept between
/// launches in a small file; past `limit`, the oldest are forgotten.
@MainActor final class PictureSizes {
    static var shared: PictureSizes { AccountStores.current.pictureSizes }

    let limit: Int
    private let file: URL?
    private var sizes: [String: CGSize] = [:]
    private var order: [String] = []
    private var saving: Task<Void, Never>?

    private struct Entry: Codable {
        let key: String
        let width: Double
        let height: Double
    }

    /// `file` is where they're kept, or nil to keep them only for this run.
    init(file: URL?, limit: Int = 2000) {
        self.file = file
        self.limit = limit
        guard let file, let data = try? Data(contentsOf: file),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        for entry in entries.suffix(limit) where entry.width > 0 && entry.height > 0 {
            if sizes.updateValue(CGSize(width: entry.width, height: entry.height), forKey: entry.key) == nil { order.append(entry.key) }
        }
    }

    static func key(file id: String) -> String { "file:\(id)" }
    static func key(card url: String) -> String { "card:\(url)" }

    func size(for key: String) -> CGSize? { sizes[key] }

    var count: Int { sizes.count }

    func remember(_ size: CGSize, for key: String) {
        guard size.width > 0, size.height > 0, sizes[key] != size else { return }
        if sizes.updateValue(size, forKey: key) == nil {
            order.append(key)
            if order.count > limit { sizes[order.removeFirst()] = nil }
        }
        saveSoon()
    }

    /// Forgets every size, here and in the file.
    func reset() {
        saving?.cancel()
        saving = nil
        sizes = [:]
        order = []
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Writes them to the file now.
    func save() {
        saving?.cancel()
        saving = nil
        guard let file else { return }
        let entries = order.compactMap { key in sizes[key].map { Entry(key: key, width: $0.width, height: $0.height) } }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// One write for a run of new sizes, as a screen of pictures loads together.
    private func saveSoon() {
        guard file != nil, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
}

/// A loaded picture filling the frame it's given: moving, when it has frames and Reduce Motion is
/// off, and otherwise its first frame.
struct PictureImage: View {
    let image: UIImage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let frames = image.images, frames.count > 1, !reduceMotion {
            AnimatedImage(image: image)
                .aspectRatio(image.size, contentMode: .fill)
        } else {
            Image(uiImage: image.images?.first ?? image)
                .resizable()
                .scaledToFill()
        }
    }
}

/// An animated picture, which SwiftUI's `Image` draws only the first frame of.
private struct AnimatedImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        if view.image !== image { view.image = image }
        if !view.isAnimating { view.startAnimating() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? image.size.width, height: proposal.height ?? image.size.height)
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: ()) {
        view.stopAnimating()
    }
}

/// What a picture that didn't load shows in its place; `retry` says a tap tries it again.
struct PictureFailure: View {
    var retry = true

    var body: some View {
        ViewThatFits {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                Text(retry ? "Couldn’t load. Retry" : "Couldn’t load")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding(8)
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension ImageRetry {
    /// Tries `attempt` until it brings a picture, fails for good, or runs out of tries of its own,
    /// telling `failed` of each failure on the way. Nil when it stopped without one, or was
    /// cancelled.
    @MainActor static func keepTrying<Value>(
        pauses: [Duration] = pauses,
        _ attempt: @MainActor () async -> Result<Value, ImageLimits.Failure>,
        failed: @MainActor (ImageLimits.Failure) -> Void
    ) async -> Value? {
        var tries = 0
        while !Task.isCancelled {
            let result = await attempt()
            // Cancelled while it was out: whoever asked has gone, so neither is told.
            guard !Task.isCancelled else { return nil }
            switch result {
            case let .success(value):
                return value
            case let .failure(failure):
                failed(failure)
                guard !failure.isLasting, tries < pauses.count else { return nil }
                let pause = pauses[tries]
                tries += 1
                do { try await Task.sleep(for: pause) } catch { return nil }
            }
        }
        return nil
    }
}

extension View {
    /// Moves `count` on when the connection comes back while `failure` could pass, so a picture
    /// that failed while offline is tried again then.
    func retryingOnReconnect(after failure: ImageLimits.Failure?, count: Binding<Int>) -> some View {
        modifier(RetryOnReconnect(failure: failure, count: count))
    }
}

private struct RetryOnReconnect: ViewModifier {
    let failure: ImageLimits.Failure?
    @Binding var count: Int

    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.onChange(of: workspace.connection) { _, now in
            if now == .open, let failure, !failure.isLasting { count += 1 }
        }
    }
}

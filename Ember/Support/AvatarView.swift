import SwiftUI
import UIKit
import EmberSDK

/// Someone's avatar: their initials on their colour, drawn here (the server's default avatar is
/// an SVG, which UIKit can't decode), with their picture over it once it loads, if they have one.
/// Reads `Workspace` from the environment when there is one; without it (sign-in, previews) it's
/// the initials alone.
struct AvatarView: View {
    let userID: UserID
    let name: String
    let size: CGFloat

    @Environment(Workspace.self) private var workspace: Workspace?
    @Environment(\.displayScale) private var displayScale
    @State private var loaded: UIImage?

    init(userID: UserID, name: String, size: CGFloat) {
        self.userID = userID
        self.name = name
        self.size = size
    }

    /// The picture's address on the server, which changes (`?v=`) when they upload a new one.
    private var source: AvatarImages.Source? {
        guard let workspace, let path = workspace.avatarPath(for: userID) else { return nil }
        return AvatarImages.Source(client: workspace.client, path: path)
    }

    var body: some View {
        let source = source
        let pixels = AvatarImages.pixels(points: size, scale: displayScale)
        // The cache is asked as the view is drawn too, so a row scrolled back into view shows the
        // picture at once rather than the initials for a frame.
        let image = source.flatMap { AvatarImages.shared.cached($0, pixels: pixels) } ?? loaded
        AvatarInitials(userID: userID, name: name, size: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(Self.shape(size))
            .accessibilityHidden(true)
            // Leaving the screen cancels this, and with it the load once no other row wants it.
            .task(id: source?.key(pixels: pixels)) {
                loaded = nil
                guard let source else { return }
                loaded = await AvatarImages.shared.image(for: source, pixels: pixels)
            }
    }

    /// The shape avatars are drawn in: a square whose corners round in proportion to its size, so
    /// a small face and a large one look alike.
    static func shape(_ size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
    }
}

/// Up to four people as one avatar: one face, or a 2×2 grid for a group DM.
struct GroupAvatarView: View {
    let people: [User]
    let size: CGFloat

    @Environment(Workspace.self) private var workspace: Workspace?

    init(people: [User], size: CGFloat) {
        self.people = people
        self.size = size
    }

    private var shown: [User] { Array(people.prefix(4)) }

    var body: some View {
        Group {
            switch shown.count {
            case 0:
                Image(systemName: "person.crop.square.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            case 1:
                face(shown[0], size: size)
            case 2:
                // Diagonal, as Messages draws two.
                ZStack {
                    face(shown[0], size: size * 0.62).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    face(shown[1], size: size * 0.62).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            default:
                let cell = (size - spacing) / 2
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        face(shown[0], size: cell)
                        face(shown[1], size: cell)
                    }
                    HStack(spacing: spacing) {
                        face(shown[2], size: cell)
                        if shown.count > 3 { face(shown[3], size: cell) }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var spacing: CGFloat { max(1, size * 0.04) }

    private func face(_ user: User, size: CGFloat) -> some View {
        AvatarView(userID: user.id, name: workspace?.name(of: user) ?? user.name, size: size)
    }
}

/// Two initials at most on their colour, as Ember's web app picks it (darker where white needs it).
private struct AvatarInitials: View {
    let userID: UserID
    let name: String
    let size: CGFloat

    var body: some View {
        let colour = AvatarColour.behindWhite(userID: userID)
        Text(AvatarStyle.initials(of: name, atMost: 2))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(Color(red: colour.red, green: colour.green, blue: colour.blue))
    }
}

/// Avatar pictures, decoded at the size they're drawn and kept in memory up to `costLimit` bytes of
/// bitmap. A path whose bytes aren't an image UIKit can decode (the server's SVG initials) is
/// remembered too, so it isn't asked for again with every row that shows it.
///
/// Rows that ask for the same picture share one load, no more than `concurrentLoads` run at once,
/// and a load nobody is waiting for any more (its rows scrolled away) is cancelled.
@MainActor final class AvatarImages {
    static var shared: AvatarImages { AccountStores.current.avatars }

    struct Source {
        let client: EmberClient
        let path: String
        /// Origin and path, so two servers' `/users/1/avatar` aren't confused.
        var address: String { client.url(path)?.absoluteString ?? client.origin.absoluteString + path }
        /// The address and the size it's decoded at.
        func key(pixels: Int) -> String { "\(pixels)|\(address)" }
    }

    /// The size in pixels to decode a picture drawn `points` wide at `scale`: rounded up to a step of
    /// 32, so sizes a point or two apart share one bitmap, and never more than the server's 512.
    static func pixels(points: CGFloat, scale: CGFloat) -> Int {
        let exact = Int((points * scale).rounded(.up))
        return min(512, max(32, (exact + 31) / 32 * 32))
    }

    let costLimit: Int
    let concurrentLoads: Int

    private let images = NSCache<NSString, UIImage>()
    private var undecodable: Set<String> = []
    private var loads: [String: Load] = [:]
    private let slots: LoadSlots

    /// A load and the callers waiting for it. Each caller is answered as soon as it's cancelled,
    /// rather than when the load ends, and the last one to go cancels the load.
    private final class Load {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiting: [UUID: CheckedContinuation<UIImage?, Never>] = [:]
    }

    init(costLimit: Int = 16 * 1024 * 1024, concurrentLoads: Int = 4) {
        self.costLimit = costLimit
        self.concurrentLoads = concurrentLoads
        slots = LoadSlots(limit: concurrentLoads)
        images.totalCostLimit = costLimit
    }

    func cached(_ source: Source, pixels: Int) -> UIImage? {
        images.object(forKey: source.key(pixels: pixels) as NSString)
    }

    /// How many loads are under way or waiting for a turn.
    var loadCount: Int { loads.count }

    /// The picture at `source`, decoded at no more than `pixels` on its longer side. Nil when it
    /// didn't load, isn't a picture UIKit decodes, or the caller was cancelled.
    func image(for source: Source, pixels: Int) async -> UIImage? {
        let key = source.key(pixels: pixels)
        if let image = images.object(forKey: key as NSString) { return image }
        if undecodable.contains(source.address) { return nil }
        if Task.isCancelled { return nil }

        let load = loads[key] ?? start(source, key: key, pixels: pixels)
        let ticket = UUID()
        let image = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                load.waiting[ticket] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.leave(ticket: ticket, key: key) }
        }
        return Task.isCancelled ? nil : image
    }

    /// Forgets every picture and every undecodable path, and cancels every load, as after signing out.
    func removeAll() {
        let ending = loads.values
        loads = [:]
        for load in ending {
            load.task?.cancel()
            for waiter in load.waiting.values { waiter.resume(returning: nil) }
        }
        images.removeAllObjects()
        undecodable = []
    }

    private func start(_ source: Source, key: String, pixels: Int) -> Load {
        let client = source.client
        let path = source.path
        let address = source.address
        let slots = slots
        let load = Load()
        let id = load.id
        loads[key] = load
        load.task = Task { [weak self] in
            var image: UIImage?
            if await slots.acquire() {
                // A fetch that fails is asked again next time; bytes that arrive and don't decode
                // aren't. The version in the path changes when they upload a picture, which asks anew.
                switch await Self.fetch(client: client, path: path, pixels: pixels) {
                case let .success(loaded):
                    image = loaded
                    if let self, !Task.isCancelled {
                        let cost = loaded.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
                        self.images.setObject(loaded, forKey: key as NSString, cost: cost)
                    }
                case .undecodable:
                    self?.undecodable.insert(address)
                case .failed:
                    break
                }
                slots.release()
            }
            self?.finish(key: key, id: id, image: image)
        }
        return load
    }

    /// Answers everyone still waiting for the load `id`, unless it was let go of first.
    private func finish(key: String, id: UUID, image: UIImage?) {
        guard let load = loads[key], load.id == id else { return }
        loads[key] = nil
        for waiter in load.waiting.values { waiter.resume(returning: image) }
    }

    /// A caller that was cancelled is answered nil at once; the last one to go cancels the load.
    private func leave(ticket: UUID, key: String) {
        guard let load = loads[key], let waiter = load.waiting.removeValue(forKey: ticket) else { return }
        waiter.resume(returning: nil)
        guard load.waiting.isEmpty else { return }
        load.task?.cancel()
        loads[key] = nil
    }

    private enum Fetched {
        case success(UIImage)
        case undecodable
        case failed
    }

    /// Fetched and decoded off the main actor, at the size it's drawn rather than the server's.
    @concurrent nonisolated private static func fetch(client: EmberClient, path: String, pixels: Int) async -> Fetched {
        guard let data = try? await client.data(at: path), !Task.isCancelled else { return .failed }
        switch await ImageLimits.decode(data, maxPixel: pixels) {
        case let .success(loaded): return .success(loaded.image)
        case .failure(.notAnImage): return .undecodable
        case .failure: return .failed
        }
    }
}

/// Turns for loads: no more than `limit` at once, the rest waiting in the order they asked. A
/// waiter that's cancelled gives up its place.
@MainActor final class LoadSlots {
    let limit: Int
    private(set) var running = 0
    private var waiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = limit
    }

    /// True once it's the caller's turn; false when it was cancelled first.
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { turn in
                waiting.append((id, turn))
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(id) }
        }
    }

    /// Hands the turn to the next waiter, if there is one.
    func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().turn.resume(returning: true)
        }
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(returning: false)
    }
}

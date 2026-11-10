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
        // The cache is asked as the view is drawn too, so a row scrolled back into view shows the
        // picture at once rather than the initials for a frame.
        let image = source.flatMap { AvatarImages.shared.cached($0) } ?? loaded
        AvatarInitials(userID: userID, name: name, size: size)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
            .task(id: source?.key) {
                loaded = nil
                guard let source else { return }
                loaded = await AvatarImages.shared.image(for: source)
            }
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
                Image(systemName: "person.crop.circle.fill")
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

/// The initials on their colour, as Ember's web app picks it.
private struct AvatarInitials: View {
    let userID: UserID
    let name: String
    let size: CGFloat

    var body: some View {
        let colour = AvatarStyle.colour(for: userID)
        Text(AvatarStyle.initials(of: name))
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: size, height: size)
            .background(Color(red: colour.red, green: colour.green, blue: colour.blue))
    }
}

/// Avatar pictures, fetched once each and kept in memory. A path whose bytes aren't an image
/// UIKit can decode (the server's SVG initials) is remembered too, so it isn't asked for again
/// with every row that shows it.
@MainActor final class AvatarImages {
    static let shared = AvatarImages()

    struct Source {
        let client: EmberClient
        let path: String
        /// Origin and path, so two servers' `/users/1/avatar` aren't confused.
        var key: String { client.url(path)?.absoluteString ?? client.origin.absoluteString + path }
    }

    private let images = NSCache<NSString, UIImage>()
    private var undecodable: Set<String> = []
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        images.countLimit = 300
    }

    func cached(_ source: Source) -> UIImage? {
        images.object(forKey: source.key as NSString)
    }

    func image(for source: Source) async -> UIImage? {
        let key = source.key
        if let image = images.object(forKey: key as NSString) { return image }
        if undecodable.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }

        let client = source.client
        let path = source.path
        let task = Task<UIImage?, Never> { [weak self] in
            // A fetch that fails is asked again next time; bytes that arrive and don't decode
            // aren't. The version in the path changes when they upload a picture, which asks anew.
            guard let data = try? await client.data(at: path) else { return nil }
            guard let image = UIImage(data: data) else {
                self?.undecodable.insert(key)
                return nil
            }
            // Decoded ahead of the first draw, off the main actor, so a list of new faces
            // scrolling in doesn't hitch.
            let prepared = await image.byPreparingForDisplay() ?? image
            self?.images.setObject(prepared, forKey: key as NSString)
            return prepared
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }
}

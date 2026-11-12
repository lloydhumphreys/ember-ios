import SwiftUI
import UIKit
import EmberSDK

/// Your avatar in the navigation bar, as a menu of every account on the device with a tick on the
/// one on screen, adding another, the app's appearance, and signing out of this one.
struct AccountMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Accounts.self) private var accounts
    @Environment(\.displayScale) private var displayScale
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 26
    /// The size each account's face is drawn at for the menu, following the text size as the menu's
    /// rows do.
    @ScaledMetric(relativeTo: .body) private var menuAvatarPoints: CGFloat = 28
    /// Each account's face for the menu, by `Face.key`, once its picture has loaded.
    @State private var pictures: [String: UIImage] = [:]
    /// Signing out asks first: it's a menu item away from the account switcher, and undoing it
    /// means signing in again.
    @State private var isConfirmingSignOut = false

    /// What VoiceOver says of the account button besides "Account": who's signed in, and with more
    /// than one account on the device, which workspace it's in.
    static func accessibilityValue(name: String, workspace: String, accountCount: Int) -> String {
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accountCount > 1, !workspace.isEmpty else { return name }
        return "\(name), \(workspace)"
    }

    private var myName: String {
        workspace.name(ofUserID: workspace.me.id) ?? workspace.me.name
    }

    private var faces: [Face] {
        accounts.slots.map {
            Face(slot: $0, points: menuAvatarPoints, pixels: AvatarImages.pixels(points: menuAvatarPoints, scale: displayScale))
        }
    }

    /// The account on screen, as the picker's selection: choosing another switches to it.
    private var selection: Binding<String> {
        Binding(
            get: { accounts.current?.id ?? "" },
            set: { id in
                if let slot = accounts.slots.first(where: { $0.id == id }) { accounts.select(slot) }
            })
    }

    var body: some View {
        let faces = faces
        Menu {
            Section {
                Picker("Accounts", selection: selection) {
                    ForEach(faces) { face in
                        Label {
                            Text(face.title)
                            if let subtitle = face.subtitle { Text(subtitle) }
                        } icon: {
                            Image(uiImage: pictures[face.key] ?? face.image(picture: nil, scale: displayScale))
                        }
                        .tag(face.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Button {
                    accounts.beginAdding()
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
            }
            Section {
                Picker(selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                } label: {
                    Label("Appearance", systemImage: appearance.symbol)
                }
                .pickerStyle(.menu)
            }
            Button(role: .destructive) {
                isConfirmingSignOut = true
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            AvatarView(userID: workspace.me.id, name: myName, size: avatarSize)
                .accessibilityLabel("Account")
                .accessibilityValue(Self.accessibilityValue(
                    name: myName, workspace: workspace.account.name, accountCount: accounts.slots.count))
        }
        // On the menu, not in it: the menu's closed by the time the dialog shows.
        .confirmationDialog("Sign Out", isPresented: $isConfirmingSignOut, titleVisibility: .hidden) {
            Button("Sign Out", role: .destructive) {
                Task { await accounts.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: faces.map(\.key)) {
            await load(faces)
        }
    }

    /// Each account's picture, from its own server with its own cookies.
    private func load(_ faces: [Face]) async {
        for face in faces where pictures[face.key] == nil {
            guard let source = face.source else { continue }
            guard let picture = await face.avatars.image(for: source, pixels: face.pixels) else { continue }
            if Task.isCancelled { return }
            pictures[face.key] = face.image(picture: picture, scale: displayScale)
        }
    }
}

/// One account as the menu shows it: its workspace, who's signed in, and their avatar.
@MainActor private struct Face: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let userID: UserID?
    let name: String
    let source: AvatarImages.Source?
    let avatars: AvatarImages
    let points: CGFloat
    let pixels: Int

    init(slot: Accounts.Slot, points: CGFloat, pixels: Int) {
        id = slot.id
        self.points = points
        self.pixels = pixels
        avatars = slot.stores.avatars
        if let profile = slot.liveProfile {
            title = profile.workspaceName.isEmpty ? ServerAddress.display(profile.origin) : profile.workspaceName
            subtitle = profile.name
            userID = profile.userID
            name = profile.name
            if let client = slot.client, let path = profile.avatarPath {
                source = AvatarImages.Source(client: client, path: path)
            } else {
                source = nil
            }
        } else {
            title = slot.signedIn.map { ServerAddress.display($0.origin) } ?? "Ember"
            subtitle = nil
            userID = slot.signedIn?.userID
            name = ""
            source = nil
        }
    }

    /// Changes when anything drawn does, so a new picture or name is drawn again.
    var key: String { "\(id)|\(name)|\(points)|\(source?.key(pixels: pixels) ?? "")" }

    /// The avatar as a menu draws it, untinted: the picture, or the initials on their colour.
    func image(picture: UIImage?, scale: CGFloat) -> UIImage {
        let size = points
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(bounds: rect, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: size * 0.16).addClip()
            if let picture {
                let scale = max(size / picture.size.width, size / picture.size.height)
                let drawn = CGSize(width: picture.size.width * scale, height: picture.size.height * scale)
                picture.draw(in: CGRect(x: (size - drawn.width) / 2, y: (size - drawn.height) / 2, width: drawn.width, height: drawn.height))
                return
            }
            let colour = AvatarColour.behindWhite(userID: userID)
            UIColor(red: colour.red, green: colour.green, blue: colour.blue, alpha: 1).setFill()
            UIRectFill(rect)
            let initials = AvatarStyle.initials(of: name, atMost: 2) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.4, weight: .semibold),
                .foregroundColor: UIColor.white,
            ]
            let text = initials.size(withAttributes: attributes)
            initials.draw(at: CGPoint(x: (size - text.width) / 2, y: (size - text.height) / 2), withAttributes: attributes)
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

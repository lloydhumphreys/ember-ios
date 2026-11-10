import SwiftUI
import EmberSDK

/// Your avatar in the navigation bar, as a menu of who you are, which server
/// you're on, the app's appearance, and signing out.
struct AccountMenu: View {
    @Environment(Workspace.self) private var workspace
    @Environment(SessionController.self) private var session
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 26

    private var myName: String {
        workspace.name(ofUserID: workspace.me.id) ?? workspace.me.name
    }

    var body: some View {
        Menu {
            Section {
                // Who and where, not something to do: there to read, so it's
                // a disabled item rather than a header the menu might clip.
                Button {} label: {
                    Label {
                        Text(myName)
                        Text(ServerAddress.display(workspace.client.origin))
                    } icon: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                .disabled(true)
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
                Task { await session.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            AvatarView(userID: workspace.me.id, name: myName, size: avatarSize)
                .accessibilityLabel("Account")
        }
    }
}

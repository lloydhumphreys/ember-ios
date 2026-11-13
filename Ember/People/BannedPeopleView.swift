import SwiftUI
import EmberSDK

/// Everyone banned, by name, for an administrator: each opens their screen, to unban them.
struct BannedPeopleView: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 36

    var body: some View {
        NavigationStack {
            List(workspace.bannedPeople) { person in
                // By value, so someone unbanned on their screen stays there as the list loses them.
                NavigationLink(value: PersonChoice(userID: person.id)) {
                    HStack(spacing: 12) {
                        AvatarView(userID: person.id, name: person.name, size: avatarSize)
                        Text(person.name)
                    }
                }
            }
            .overlay {
                if workspace.bannedPeople.isEmpty {
                    ContentUnavailableView("No Banned People", systemImage: "nosign")
                }
            }
            .navigationTitle("Banned")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: PersonChoice.self) { choice in
                PersonView(userID: choice.userID)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.dismissesSheet, dismiss)
    }
}

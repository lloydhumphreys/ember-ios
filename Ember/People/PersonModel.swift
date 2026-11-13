import EmberSDK
import Foundation
import Observation

/// What a person's screen holds: them as the directory lists them, their email address for an
/// administrator, and what came of the last ban, unban or DM asked for.
///
/// The sign-in link the server gives administrators beside them is never kept.
@MainActor @Observable
final class PersonModel {
    let userID: UserID

    /// Their email address, which only administrators are told.
    private(set) var emailAddress: String?
    /// Them as the server answered, for someone the directory doesn't list.
    private(set) var fetched: DirectoryUser?
    private(set) var isWorking = false
    private(set) var failure: String?
    @ObservationIgnored private var workspace: Workspace?

    init(userID: UserID) {
        self.userID = userID
    }

    func attach(_ workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: What the screen asks

    /// Them as the directory lists them now, kept current by the workspace socket.
    var person: DirectoryUser? {
        workspace?.person(userID) ?? fetched
    }

    var name: String {
        person?.name ?? workspace?.name(ofUserID: userID) ?? ""
    }

    var isMe: Bool { userID == workspace?.me.id }
    var isBanned: Bool { person?.status == .banned }

    private var isAdministrator: Bool { workspace?.me.administrator ?? false }

    /// The assistant, or any other bot.
    private var isBot: Bool {
        person?.role == .bot || workspace?.isAssistant(userID) == true
    }

    /// Message, which opens your DM with them or starts one: for anyone active but you.
    var canMessage: Bool {
        !isMe && person?.status == .active
    }

    /// Ban, for an administrator: anyone else active, or suspended, who isn't a bot.
    var canBan: Bool {
        guard isAdministrator, !isMe, !isBot, let status = person?.status else { return false }
        return status == .active || status == .suspended
    }

    /// Unban, for an administrator, while they're banned.
    var canUnban: Bool {
        isAdministrator && isBanned
    }

    func clearFailure() {
        failure = nil
    }

    // MARK: Talking to the server

    /// Asks for what the directory doesn't say: their email address, for an administrator, or them
    /// at all when the directory doesn't list them.
    func load() async {
        guard let workspace else { return }
        let listed = workspace.person(userID) != nil
        guard !listed || (isAdministrator && !isBot) else { return }
        do {
            // Only who they are: the sign-in link beside it is left where it came.
            let details = try await workspace.client.person(userID)
            emailAddress = details.emailAddress
            if workspace.person(userID) == nil { fetched = details.user }
        } catch {
            if !listed { failure = Self.message(error) }
        }
    }

    func ban() async {
        await change { try await $0.ban(self.userID) }
    }

    func unban() async {
        await change { try await $0.unban(self.userID) }
    }

    /// Opens your DM with them, starting it if there isn't one. Its room, once it's open.
    func startDirect() async -> RoomID? {
        guard let workspace, !isWorking else { return nil }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            return try await workspace.startDirect(with: [userID]).id
        } catch {
            failure = Self.message(error)
            return nil
        }
    }

    private func change(_ work: (Workspace) async throws -> Void) async {
        guard let workspace, !isWorking else { return }
        isWorking = true
        failure = nil
        defer { isWorking = false }
        do {
            try await work(workspace)
            // The directory has them now, as the server answered.
            fetched = nil
        } catch {
            failure = Self.message(error)
        }
    }

    static func message(_ error: any Error) -> String {
        error.localizedDescription
    }
}

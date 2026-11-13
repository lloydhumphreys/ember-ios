import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
import EmberSDK
import EmberTesting
@testable import Ember

/// Profile, someone's screen and banning: what each change sends, what's refused before asking,
/// the passwords leaving their fields, photos made ready to upload, and who's offered Ban, Unban
/// and Message. Nothing here touches the network.
@MainActor
@Suite struct ProfileAndBansTests {
    static let profilePath = "/api/users/me/profile"

    // MARK: Profile

    /// A profile screen's model, loaded with `profile`, on a workspace that isn't started.
    func loadedProfile(_ profile: UserProfile = Fixtures.profile) async -> (ProfileModel, MockHTTPTransport, Workspace) {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport)
        transport.stub("GET", Self.profilePath, json: Fixtures.profileJSON(profile))
        let model = ProfileModel()
        model.attach(workspace)
        await model.load()
        return (model, transport, workspace)
    }

    @Test(.timeLimit(.minutes(1)))
    func loadingFillsTheFields() async {
        let (model, _, _) = await loadedProfile()
        #expect(model.loading == .loaded)
        #expect(model.name == "Ada Lovelace")
        #expect(model.emailAddress == "ada@example.com")
        #expect(model.bio == "Poet of numbers")
        #expect(model.newPassword.isEmpty && model.currentPassword.isEmpty)
        #expect(!model.hasChanges)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedLoadSaysWhy() async {
        let transport = MockHTTPTransport()
        let workspace = Workspace.mock(transport: transport)
        transport.stub("GET", Self.profilePath, status: 500, json: Fixtures.errorJSON("Something went wrong"))
        let model = ProfileModel()
        model.attach(workspace)
        await model.load()
        #expect(model.loading == .failed("Something went wrong"))
    }

    @Test(.timeLimit(.minutes(1)))
    func onlyTheChangedNameAndBioAreSentWithoutAPassword() async throws {
        let (model, transport, workspace) = await loadedProfile()
        model.name = "  Ada King "
        model.bio = "Countess"
        var saved = Fixtures.profile
        saved.name = "Ada King"
        saved.bio = "Countess"
        transport.stub("PATCH", Self.profilePath, json: Fixtures.profileJSON(saved))
        #expect(await model.save())
        let body = try #require(transport.lastBody("PATCH", Self.profilePath))
        #expect(Set(body.keys) == ["name", "bio"])
        #expect(body["name"] as? String == "Ada King")
        #expect(body["bio"] as? String == "Countess")
        #expect(model.name == "Ada King")
        #expect(workspace.me.name == "Ada King")
        #expect(!model.hasChanges)
    }

    @Test(.timeLimit(.minutes(1)))
    func anEmptiedBioIsSentEmptyToTakeItOut() async {
        let (model, _, _) = await loadedProfile()
        model.bio = "   "
        #expect(model.changes() == ProfileChanges(bio: ""))
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewEmailAddressAsksForTheCurrentPasswordAndSendsIt() async throws {
        let (model, transport, _) = await loadedProfile()
        model.emailAddress = "countess@example.com"
        #expect(model.needsCurrentPassword)
        #expect(await model.save() == false)
        #expect(model.failure == "Enter your current password to change your email address or password.")
        #expect(model.failedField == .currentPassword)
        #expect(transport.requests("PATCH", Self.profilePath).isEmpty)

        model.currentPassword = "fake-current-password"
        var saved = Fixtures.profile
        saved.emailAddress = "countess@example.com"
        transport.stub("PATCH", Self.profilePath, json: Fixtures.profileJSON(saved))
        #expect(await model.save())
        let body = try #require(transport.lastBody("PATCH", Self.profilePath))
        #expect(Set(body.keys) == ["emailAddress", "currentPassword"])
        #expect(model.currentPassword.isEmpty)
        #expect(model.failure == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCurrentPasswordTypedForANameChangeIsntSent() async throws {
        let (model, transport, _) = await loadedProfile()
        model.name = "Ada King"
        model.currentPassword = "fake-current-password"
        #expect(model.changes() == ProfileChanges(name: "Ada King"))
        var saved = Fixtures.profile
        saved.name = "Ada King"
        transport.stub("PATCH", Self.profilePath, json: Fixtures.profileJSON(saved))
        #expect(await model.save())
        #expect(Set(try #require(transport.lastBody("PATCH", Self.profilePath)).keys) == ["name"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aNewPasswordIsSentWithTheCurrentOneAndBothFieldsAreCleared() async throws {
        let (model, transport, _) = await loadedProfile()
        model.newPassword = "fake-new-password"
        model.currentPassword = "fake-current-password"
        transport.stub("PATCH", Self.profilePath, json: Fixtures.profileJSON())
        #expect(await model.save())
        let body = try #require(transport.lastBody("PATCH", Self.profilePath))
        #expect(Set(body.keys) == ["password", "currentPassword"])
        #expect(body["password"] as? String == "fake-new-password")
        #expect(model.newPassword.isEmpty)
        #expect(model.currentPassword.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func withoutAPasswordAFirstOneNeedsNoCurrentPassword() async throws {
        var noPassword = Fixtures.profile
        noPassword.hasPassword = false
        let (model, transport, _) = await loadedProfile(noPassword)
        model.newPassword = "fake-new-password"
        #expect(!model.needsCurrentPassword)
        transport.stub("PATCH", Self.profilePath, json: Fixtures.profileJSON(noPassword))
        #expect(await model.save())
        #expect(Set(try #require(transport.lastBody("PATCH", Self.profilePath)).keys) == ["password"])
        #expect(model.newPassword.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func nothingChangedSendsNothing() async {
        let (model, transport, _) = await loadedProfile()
        #expect(await model.save())
        #expect(transport.requests("PATCH", Self.profilePath).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func whatTheServerWouldRefuseIsRefusedFirstWithItsField() async {
        let (model, transport, _) = await loadedProfile()
        func refused(_ change: (ProfileModel) -> Void) -> (message: String, field: ProfileModel.Field)? {
            model.name = Fixtures.profile.name
            model.emailAddress = Fixtures.profile.emailAddress ?? ""
            model.bio = Fixtures.profile.bio ?? ""
            model.newPassword = ""
            model.currentPassword = "fake-current-password"
            change(model)
            return model.refusal(of: model.changes())
        }
        #expect(refused { $0.name = "  " }?.message == "Enter your name.")
        #expect(refused { $0.name = "  " }?.field == .name)
        #expect(refused { $0.name = String(repeating: "a", count: 101) }?.field == .name)
        #expect(refused { $0.name = String(repeating: "a", count: 100) } == nil)
        #expect(refused { $0.bio = String(repeating: "b", count: 201) }?.field == .bio)
        #expect(refused { $0.emailAddress = "not an address" }?.field == .emailAddress)
        #expect(refused { $0.newPassword = "short" }?.message == "Password must be at least 8 characters.")
        #expect(refused { $0.newPassword = "short" }?.field == .password)
        #expect(refused { $0.newPassword = String(repeating: "p", count: 73) }?.field == .password)
        #expect(refused { $0.newPassword = String(repeating: "p", count: 72) } == nil)

        model.name = " "
        model.currentPassword = ""
        #expect(await model.save() == false)
        #expect(model.failedField == .name)
        #expect(transport.requests("PATCH", Self.profilePath).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func theServersRefusalIsShownWithTheFieldAndThePasswordsStay() async {
        let (model, transport, _) = await loadedProfile()
        model.newPassword = "fake-new-password"
        model.currentPassword = "fake-wrong-password"
        transport.stub("PATCH", Self.profilePath, status: 422, json: Fixtures.errorJSON("That isn't your current password."))
        #expect(await model.save() == false)
        #expect(model.failure == "That isn't your current password.")
        #expect(model.failedField == .currentPassword)
        #expect(model.newPassword == "fake-new-password")

        transport.stub("PATCH", Self.profilePath, status: 409, json: Fixtures.errorJSON("Taken", field: "emailAddress"))
        #expect(await model.save() == false)
        #expect(model.failure == "Taken")
        #expect(model.failedField == .emailAddress)

        model.clearFailure()
        #expect(model.failure == nil && model.failedField == nil)
    }

    @Test func noPasswordShowsInWhatIsSentsDescription() {
        let changes = ProfileChanges(password: "fake-new-password", currentPassword: "fake-current-password")
        #expect(!String(describing: changes).contains("fake"))
        #expect(!String(reflecting: changes).contains("fake"))
    }

    // MARK: Pictures

    @Test(.timeLimit(.minutes(1)))
    func aPickedPhotoIsUploadedAndRemoveTakesItAway() async throws {
        let (model, transport, _) = await loadedProfile()
        model.name = "Typed meanwhile"
        var withPicture = Fixtures.profile
        withPicture.hasAvatar = true
        withPicture.avatarUrl = "/users/user_ada/avatar?v=2"
        transport.stub("PUT", "/api/users/me/avatar", json: Fixtures.profileJSON(withPicture))
        await model.changePicture(try Self.image(width: 64, height: 64, type: .jpeg))
        #expect(model.hasAvatar)
        #expect(transport.requests("PUT", "/api/users/me/avatar").count == 1)
        #expect(model.name == "Typed meanwhile")

        transport.stub("DELETE", "/api/users/me/avatar", json: Fixtures.profileJSON())
        await model.removePicture()
        #expect(!model.hasAvatar)
    }

    @Test(.timeLimit(.minutes(1)))
    func whatIsntAPictureIsntUploaded() async {
        let (model, transport, _) = await loadedProfile()
        await model.changePicture(Data("not a picture".utf8))
        #expect(model.failure != nil)
        #expect(transport.requests("PUT", "/api/users/me/avatar").isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedPictureSaysWhy() async throws {
        let (model, transport, _) = await loadedProfile()
        transport.stub("PUT", "/api/users/me/avatar", status: 422, json: Fixtures.errorJSON("Avatar must be an image"))
        await model.changePicture(try Self.image(width: 16, height: 16, type: .png))
        #expect(model.failure == "Avatar must be an image")
        #expect(!model.isChangingPicture)
    }

    @Test func aJPEGOrPNGUnderTheLimitIsSentAsItIs() throws {
        let jpeg = try Self.image(width: 40, height: 30, type: .jpeg)
        #expect(ProfileModel.preparedAvatar(jpeg) == .init(data: jpeg, contentType: "image/jpeg"))
        let png = try Self.image(width: 40, height: 30, type: .png)
        #expect(ProfileModel.preparedAvatar(png) == .init(data: png, contentType: "image/png"))
    }

    @Test func otherTypesAreMadeJPEGs() throws {
        let tiff = try Self.image(width: 40, height: 30, type: .tiff)
        let prepared = try #require(ProfileModel.preparedAvatar(tiff))
        #expect(prepared.contentType == "image/jpeg")
        #expect(Self.type(of: prepared.data) == UTType.jpeg.identifier)
    }

    @Test func aHEICPhotoIsMadeAJPEG() throws {
        // Where the simulator can write HEIC at all.
        guard let heic = try? Self.image(width: 40, height: 30, type: .heic) else { return }
        let prepared = try #require(ProfileModel.preparedAvatar(heic))
        #expect(prepared.contentType == "image/jpeg")
        #expect(Self.type(of: prepared.data) == UTType.jpeg.identifier)
        #expect(Self.size(of: prepared.data) == CGSize(width: 40, height: 30))
    }

    @Test func aPhotoOverTheLimitIsScaledDownUnderIt() throws {
        let big = try Self.image(width: 3000, height: 1500, type: .png)
        let limit = big.count - 1
        let prepared = try #require(ProfileModel.preparedAvatar(big, limit: limit))
        #expect(prepared.data.count <= limit)
        #expect(prepared.contentType == "image/jpeg")
        let size = try #require(Self.size(of: prepared.data))
        #expect(max(size.width, size.height) <= 2048)
    }

    @Test func aTransparentPhotoStaysAPNG() throws {
        let big = try Self.image(width: 3000, height: 1500, type: .png, opaque: false)
        let prepared = try #require(ProfileModel.preparedAvatar(big, limit: big.count - 1))
        #expect(prepared.contentType == "image/png")
        #expect(prepared.data.count < big.count)
    }

    // MARK: Someone's screen

    /// A started workspace, signed in as `Fixtures.me` or, with `administrator` false, as a member,
    /// with its directory loaded.
    func started(administrator: Bool = true) async throws -> (Workspace, MockHTTPTransport) {
        let transport = MockHTTPTransport()
        let connector = MockSocketConnector()
        let workspace: Workspace
        if administrator {
            workspace = Workspace.mock(transport: transport, connector: connector)
        } else {
            let member = Me(id: Fixtures.me.id, name: Fixtures.me.name, administrator: false)
            transport.stubSignedIn(me: member)
            connector.welcomeEverySocket(me: member)
            let client = EmberClient.mock(transport: transport, connector: connector)
            workspace = Workspace(client: client, me: member, account: Fixtures.account)
        }
        workspace.start()
        try #require(await eventually { workspace.isLoaded && workspace.person(Fixtures.grace.id) != nil })
        return (workspace, transport)
    }

    func person(_ id: UserID, in workspace: Workspace) -> PersonModel {
        let model = PersonModel(userID: id)
        model.attach(workspace)
        return model
    }

    @Test(.timeLimit(.minutes(1)))
    func anAdministratorIsOfferedBanAndMessageForSomeoneElse() async throws {
        let (workspace, _) = try await started()
        let grace = person(Fixtures.grace.id, in: workspace)
        #expect(grace.canBan)
        #expect(!grace.canUnban)
        #expect(grace.canMessage)
        #expect(!grace.isBanned)
    }

    @Test(.timeLimit(.minutes(1)))
    func nobodyIsOfferedBanOrMessageForThemselves() async throws {
        let (workspace, _) = try await started()
        let me = person(Fixtures.me.id, in: workspace)
        #expect(!me.canBan)
        #expect(!me.canUnban)
        #expect(!me.canMessage)
    }

    @Test(.timeLimit(.minutes(1)))
    func theAssistantCantBeBannedButCanBeMessaged() async throws {
        let (workspace, _) = try await started()
        let assistant = person(Assistant.id, in: workspace)
        #expect(!assistant.canBan)
        #expect(assistant.canMessage)
    }

    @Test(.timeLimit(.minutes(1)))
    func aMemberIsOfferedMessageButNotBan() async throws {
        let (workspace, _) = try await started(administrator: false)
        #expect(!workspace.me.administrator)
        let grace = person(Fixtures.grace.id, in: workspace)
        #expect(!grace.canBan)
        #expect(grace.canMessage)
    }

    @Test(.timeLimit(.minutes(1)))
    func anAdministratorSeesTheEmailAddressButNeverKeepsTheLink() async throws {
        let (workspace, transport) = try await started()
        let grace = workspace.person(Fixtures.grace.id)!
        transport.stub("GET", "/api/users/user_grace", json: Fixtures.personJSON(grace, emailAddress: "grace@example.com", transferID: Fixtures.transferID))
        let model = person(Fixtures.grace.id, in: workspace)
        await model.load()
        #expect(model.emailAddress == "grace@example.com")
        #expect(!String(reflecting: model).contains(Fixtures.transferID.revealed))
    }

    @Test(.timeLimit(.minutes(1)))
    func banningShowsThemBannedWithUnbanAndUnbanningTakesItBack() async throws {
        let (workspace, transport) = try await started()
        var grace = workspace.person(Fixtures.grace.id)!
        grace.status = .banned
        transport.stub("POST", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(grace))
        let model = person(Fixtures.grace.id, in: workspace)
        await model.ban()
        #expect(model.isBanned)
        #expect(!model.canBan)
        #expect(model.canUnban)
        #expect(!model.canMessage)
        #expect(model.failure == nil)
        #expect(workspace.bannedPeople.map(\.id) == [Fixtures.grace.id])

        grace.status = .active
        transport.stub("DELETE", "/api/users/user_grace/ban", json: Fixtures.changedPersonJSON(grace))
        await model.unban()
        #expect(!model.isBanned)
        #expect(model.canBan)
        #expect(model.canMessage)
        #expect(workspace.bannedPeople.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aRefusedBanSaysWhyAndChangesNothing() async throws {
        let (workspace, transport) = try await started()
        transport.stub("POST", "/api/users/user_grace/ban", status: 422, json: Fixtures.errorJSON("Their address can't be blocked"))
        let model = person(Fixtures.grace.id, in: workspace)
        await model.ban()
        #expect(model.failure == "Their address can't be blocked")
        #expect(!model.isBanned)
        #expect(model.canBan)
        #expect(!model.isWorking)
    }

    @Test(.timeLimit(.minutes(1)))
    func someoneBannedElsewhereShowsBannedAsTheSocketSays() async throws {
        let transport = MockHTTPTransport()
        let connector = MockSocketConnector()
        let workspace = Workspace.mock(transport: transport, connector: connector)
        workspace.start()
        try #require(await eventually { workspace.isLoaded && workspace.person(Fixtures.grace.id) != nil })
        let model = person(Fixtures.grace.id, in: workspace)
        var grace = workspace.person(Fixtures.grace.id)!
        grace.status = .banned
        connector.latest?.serverSends(Fixtures.WorkspaceFrames.userUpdated(grace))
        #expect(await eventually { model.isBanned })
        #expect(model.canUnban)
    }

    @Test(.timeLimit(.minutes(1)))
    func theBannedListIsEveryoneBannedByName() async throws {
        let (workspace, transport) = try await started()
        for user in [Fixtures.grace, Fixtures.alan] {
            var banned = workspace.person(user.id)!
            banned.status = .banned
            transport.stub("POST", "/api/users/\(user.id.rawValue)/ban", json: Fixtures.changedPersonJSON(banned))
            await person(user.id, in: workspace).ban()
        }
        #expect(workspace.bannedPeople.map(\.name) == ["Alan Turing", "Grace Hopper"])
    }

    @Test func theMenuOffersEachOfItsSheets() {
        #expect(Set([AccountSheet.profile, .invite, .banned].map(\.id)).count == 3)
    }

    // MARK: Pictures for the tests

    enum ImageType {
        case jpeg, png, tiff, heic
        var identifier: String {
            switch self {
            case .jpeg: UTType.jpeg.identifier
            case .png: UTType.png.identifier
            case .tiff: UTType.tiff.identifier
            case .heic: UTType.heic.identifier
            }
        }
    }

    struct CantWrite: Error {}

    /// A smooth gradient of `width` by `height` as `type`.
    static func image(width: Int, height: Int, type: ImageType, opaque: Bool = true) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            for x in stride(from: 0, to: width, by: 10) {
                UIColor(hue: CGFloat(x) / CGFloat(width), saturation: 0.8, brightness: 0.9, alpha: opaque ? 1 : 0.5).setFill()
                context.fill(CGRect(x: x, y: 0, width: 10, height: height))
            }
        }
        guard let cgImage = image.cgImage else { throw CantWrite() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { throw CantWrite() }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw CantWrite() }
        return output as Data
    }

    static func type(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

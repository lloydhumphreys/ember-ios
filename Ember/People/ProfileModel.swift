import EmberSDK
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// What the Profile screen holds: your profile as last loaded or saved, the fields as typed, and
/// what came of the last save or change of picture.
///
/// The passwords are kept in memory only while they're typed, and leave their fields once saved.
/// The sign-in link the server answers with is never kept.
@MainActor @Observable
final class ProfileModel {
    enum Loading: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// A field a refusal is about.
    enum Field: String, Hashable {
        case name, emailAddress, bio, password, currentPassword
    }

    /// The limits the server keeps, as `@ember/protocol` has them.
    enum Limits {
        static let name = 100
        static let bio = 200
        static let emailAddress = 254
        static let shortestPassword = 8
        static let longestPassword = 72
    }

    var name = ""
    var emailAddress = ""
    var bio = ""
    var newPassword = ""
    var currentPassword = ""

    /// Your profile as the server last answered it.
    private(set) var profile: UserProfile?
    private(set) var loading = Loading.idle
    private(set) var isSaving = false
    private(set) var isChangingPicture = false
    private(set) var failure: String?
    /// The field `failure` is about, when it's about one.
    private(set) var failedField: Field?
    @ObservationIgnored private var workspace: Workspace?

    func attach(_ workspace: Workspace) {
        self.workspace = workspace
    }

    // MARK: What the screen asks

    var hasPassword: Bool { profile?.hasPassword ?? false }
    var hasAvatar: Bool { profile?.hasAvatar ?? false }
    var isBusy: Bool { isSaving || isChangingPicture }

    /// Whether the current password is needed: to change your email address or password, while you
    /// have one.
    var needsCurrentPassword: Bool {
        let changes = changes()
        return hasPassword && (changes.emailAddress != nil || changes.password != nil)
    }

    /// Whether anything typed differs from what's saved.
    var hasChanges: Bool {
        let changes = changes()
        return changes.name != nil || changes.emailAddress != nil || changes.bio != nil || changes.password != nil
    }

    /// What Save sends: only the fields typed differently from what's saved, a new password when
    /// one's typed, and the current password only when it's typed and the change needs it.
    func changes() -> ProfileChanges {
        guard let profile else { return ProfileChanges() }
        var changes = ProfileChanges()
        let name = Self.trimmed(name)
        if name != profile.name { changes.name = name }
        let emailAddress = Self.trimmed(emailAddress)
        if emailAddress != (profile.emailAddress ?? "") { changes.emailAddress = emailAddress }
        let bio = Self.trimmed(bio)
        if bio != (profile.bio ?? "") { changes.bio = bio }
        if !newPassword.isEmpty { changes.password = newPassword }
        if changes.emailAddress != nil || changes.password != nil, !currentPassword.isEmpty {
            changes.currentPassword = currentPassword
        }
        return changes
    }

    /// Why `changes` can't be sent as they are, before asking the server, and the field at fault.
    func refusal(of changes: ProfileChanges) -> (message: String, field: Field)? {
        if let name = changes.name {
            if name.isEmpty { return ("Enter your name.", .name) }
            if name.utf16.count > Limits.name { return ("Name must be at most \(Limits.name) characters", .name) }
        }
        if let emailAddress = changes.emailAddress, !emailAddress.isEmpty {
            if emailAddress.utf16.count > Limits.emailAddress {
                return ("Email address must be at most \(Limits.emailAddress) characters", .emailAddress)
            }
            if InviteModel.addresses(in: emailAddress).valid != [emailAddress] {
                return ("This isn’t an email address: \(emailAddress)", .emailAddress)
            }
        }
        if let bio = changes.bio, bio.utf16.count > Limits.bio {
            return ("Bio must be at most \(Limits.bio) characters", .bio)
        }
        if let password = changes.password {
            if password.unicodeScalars.count < Limits.shortestPassword {
                return ("Password must be at least \(Limits.shortestPassword) characters.", .password)
            }
            if password.utf16.count > Limits.longestPassword {
                return ("Password must be at most \(Limits.longestPassword) characters.", .password)
            }
        }
        if hasPassword, changes.emailAddress != nil || changes.password != nil, changes.currentPassword == nil {
            return ("Enter your current password to change your email address or password.", .currentPassword)
        }
        return nil
    }

    /// Correcting what was refused is what clears the complaint about it.
    func clearFailure() {
        failure = nil
        failedField = nil
    }

    // MARK: Talking to the server

    func load() async {
        guard let workspace else { return }
        if loading != .loaded { loading = .loading }
        do {
            // Only the profile: the sign-in link beside it is left where it came.
            let profile = try await workspace.client.profile().profile
            take(profile)
            loading = .loaded
        } catch {
            let message = Self.message(error)
            if loading == .loaded { fail(message) } else { loading = .failed(message) }
        }
    }

    /// Saves what's changed. True once it's saved, or when there was nothing to save.
    @discardableResult
    func save() async -> Bool {
        guard let workspace, profile != nil, !isBusy else { return false }
        let changes = changes()
        if let refusal = refusal(of: changes) {
            fail(refusal.message, field: refusal.field)
            return false
        }
        guard hasChanges else { return true }
        isSaving = true
        clearFailure()
        defer { isSaving = false }
        do {
            let saved = try await workspace.changeProfile(changes)
            take(saved)
            newPassword = ""
            currentPassword = ""
            return true
        } catch {
            fail(Self.message(error), field: Self.field(of: error))
            return false
        }
    }

    /// Makes the photo in `data` your picture, converted and scaled down first when it needs to be.
    func changePicture(_ data: Data) async {
        guard let workspace, !isBusy else { return }
        guard let prepared = Self.preparedAvatar(data) else {
            fail("This photo can’t be used.")
            return
        }
        isChangingPicture = true
        clearFailure()
        defer { isChangingPicture = false }
        do {
            takePicture(of: try await workspace.changeAvatar(prepared.data, contentType: prepared.contentType))
        } catch {
            fail(Self.message(error))
        }
    }

    func removePicture() async {
        guard let workspace, !isBusy else { return }
        isChangingPicture = true
        clearFailure()
        defer { isChangingPicture = false }
        do {
            takePicture(of: try await workspace.removeAvatar())
        } catch {
            fail(Self.message(error))
        }
    }

    /// Shows `profile` as saved, in the fields too.
    private func take(_ profile: UserProfile) {
        self.profile = profile
        name = profile.name
        emailAddress = profile.emailAddress ?? ""
        bio = profile.bio ?? ""
    }

    /// Takes the picture `profile` has, leaving what's typed in the fields as it is.
    private func takePicture(of profile: UserProfile) {
        guard var saved = self.profile else { return take(profile) }
        saved.avatarUrl = profile.avatarUrl
        saved.hasAvatar = profile.hasAvatar
        self.profile = saved
    }

    private func fail(_ message: String, field: Field? = nil) {
        failure = message
        failedField = field
    }

    static func message(_ error: any Error) -> String {
        error.localizedDescription
    }

    /// The field a refusal is about: the one the server names, or for the refusals it doesn't name
    /// one for, the field they're about.
    static func field(of error: any Error) -> Field? {
        guard let error = error as? EmberError else { return nil }
        if let named = error.field { return Field(rawValue: named) }
        let message = error.message
        if message.localizedCaseInsensitiveContains("current password") { return .currentPassword }
        if message.hasPrefix("Password") { return .password }
        if message.localizedCaseInsensitiveContains("email address") { return .emailAddress }
        if message.hasPrefix("Name") || message.localizedCaseInsensitiveContains("assistant’s name")
            || message.localizedCaseInsensitiveContains("assistant's name") { return .name }
        if message.hasPrefix("Bio") { return .bio }
        return nil
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Preparing a photo

    /// A picture as it's uploaded.
    struct PreparedAvatar: Equatable, Sendable {
        var data: Data
        var contentType: String
    }

    /// The types sent as they are, by their uniform type.
    nonisolated private static let keptTypes: [String: String] = [
        UTType.jpeg.identifier: "image/jpeg",
        UTType.png.identifier: "image/png",
        UTType.webP.identifier: "image/webp",
        UTType.gif.identifier: "image/gif",
    ]

    /// The longest sides a converted photo is tried at, largest first, until it's under `limit`.
    nonisolated static let convertedSides = [2048, 1024, 512]

    /// `data` ready to upload: a JPEG, PNG, WebP or GIF under `limit` as it is; anything else, a
    /// HEIC photo say, or one over `limit`, made a JPEG (a PNG when it has transparency) no larger
    /// than 2048 points a side, and smaller until it's under `limit`. Nil when it can't be read.
    nonisolated static func preparedAvatar(_ data: Data, limit: Int = EmberClient.avatarByteLimit) -> PreparedAvatar? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        if let type = CGImageSourceGetType(source) as String?, let contentType = keptTypes[type], data.count <= limit {
            return PreparedAvatar(data: data, contentType: contentType)
        }
        for side in convertedSides {
            guard let converted = converted(source, longestSide: side) else { return nil }
            if converted.data.count <= limit { return converted }
        }
        return nil
    }

    /// The first image in `source`, upright and no longer than `longestSide` on either side.
    nonisolated private static func converted(_ source: CGImageSource, longestSide: Int) -> PreparedAvatar? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let opaque: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: true
        default: false
        }
        let type = opaque ? UTType.jpeg : UTType.png
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedAvatar(data: output as Data, contentType: opaque ? "image/jpeg" : "image/png")
    }
}

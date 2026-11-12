import Foundation
import Testing
import SwiftUI
import UIKit
import ImageIO
import EmberSDK
import EmberRichText
import EmberTesting
@testable import Ember

/// The bounds pictures are held to, what's remembered when one fails, where a card's picture may be
/// redirected, and which links reach the system. Nothing here touches the network.
@MainActor
@Suite struct ImagesAndLinksTests {
    private let host = "chat.example.com"

    // MARK: Card image redirects

    @Test func aCardImageRedirectFollowsOnlyWhereTheCardRuleAllows() {
        func follows(_ address: String) -> Bool {
            CardImages.redirect(URLRequest(url: URL(string: address)!), host: host) != nil
        }
        #expect(follows("https://cdn.example.org/a.png"))
        #expect(follows("http://cdn.example.org/a.png"))
        // The chat server itself, whatever the case or a trailing dot.
        #expect(!follows("https://chat.example.com/files/secret"))
        #expect(!follows("https://CHAT.example.com./files/secret"))
        // Not a named host.
        #expect(!follows("http://localhost/a.png"))
        #expect(!follows("http://10.0.0.1/a.png"))
        #expect(!follows("http://[::1]/a.png"))
        // Not http or https.
        #expect(!follows("file:///etc/hosts"))
        #expect(!follows("ftp://cdn.example.org/a.png"))
        #expect(!follows("data:image/png;base64,AAAA"))
    }

    @Test func aCardImageFollowsAnAllowedRedirect() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        ImageStub.answer("https://hop-a.example.org/a.png", .redirect("https://hop-b.example.org/b.png"))
        ImageStub.answer("https://hop-b.example.org/b.png", .body(Self.png(width: 40, height: 20)))
        let loaded = await images.image("https://hop-a.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded?.pixelSize == CGSize(width: 40, height: 20))
    }

    @Test func aCardImageRefusesARedirectToTheChatServer() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let target = "https://chat.example.com/files/f.png"
        ImageStub.answer("https://hop-c.example.org/a.png", .redirect(target))
        ImageStub.answer(target, .body(Self.png(width: 40, height: 20)))
        let loaded = await images.image("https://hop-c.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "chat.example.com").isEmpty)
        // Refused by the rule: it will be refused again, so it's remembered.
        #expect(images.hasFailed("https://hop-c.example.org/a.png"))
    }

    @Test func aCardImageRefusesARedirectToALocalAddress() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        ImageStub.answer("https://hop-d.example.org/a.png", .redirect("http://169.254.169.254/latest/meta-data"))
        let loaded = await images.image("https://hop-d.example.org/a.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "169.254.169.254").isEmpty)
    }

    @Test func aCardImageAddressTheRuleRefusesIsNeverFetched() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let loaded = await images.image("https://chat.example.com/files/direct.png", host: host, maxPixel: 100)
        #expect(loaded == nil)
        #expect(ImageStub.requests(to: "chat.example.com").isEmpty)
        #expect(images.hasFailed("https://chat.example.com/files/direct.png"))
    }

    @Test func aCardImageRequestCarriesNoCookieEvenAfterARedirect() async throws {
        let first = "https://cookie-a.example.org/a.png"
        let second = "https://cookie-b.example.org/b.png"
        let cookies = try [first, second].map { address in
            try #require(HTTPCookie(properties: [
                .domain: URL(string: address)!.host()!, .path: "/", .name: "session_token", .value: "secret", .secure: "TRUE",
            ]))
        }
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
        defer { for cookie in cookies { HTTPCookieStorage.shared.deleteCookie(cookie) } }
        ImageStub.answer(first, .redirect(second))
        ImageStub.answer(second, .body(Self.png(width: 4, height: 4)))

        let images = CardImages(protocolClasses: [ImageStub.self])
        // A stand-in protocol sees requests before the loading system adds cookies, so the session's
        // own settings are what show none will be: no store to read one from, and none set.
        let configuration = images.session.configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCredentialStorage == nil)
        let loaded = await images.image(first, host: host, maxPixel: 10)
        #expect(loaded != nil)
        let sent = ImageStub.requests(to: "cookie-a.example.org") + ImageStub.requests(to: "cookie-b.example.org")
        #expect(sent.count == 2)
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil && $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    // MARK: Card image bounds and failures

    @Test func aCardImageDeclaringTooManyBytesIsRefusedAndRemembered() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://big-declared.example.org/a.png"
        ImageStub.answer(address, .body(Self.png(width: 4, height: 4), headers: ["Content-Length": String(ImageLimits.maxBytes + 1)]))
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(images.hasFailed(address))
    }

    @Test func aCardImageSendingTooManyBytesWithNoLengthIsRefused() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://big-undeclared.example.org/a.png"
        ImageStub.answer(address, .body(Data(count: ImageLimits.maxBytes + 1)))
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(images.hasFailed(address))
    }

    @Test func aCardImageIsDownsampledToTheSizeItsDrawnAt() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://downsample.example.org/a.png"
        ImageStub.answer(address, .body(Self.png(width: 400, height: 200)))
        let loaded = await images.image(address, host: host, maxPixel: 100)
        #expect(loaded?.pixelSize == CGSize(width: 400, height: 200))
        #expect(loaded?.image.cgImage?.width == 100)
        #expect(loaded?.image.cgImage?.height == 50)
    }

    @Test func aCardImageServerErrorIsTriedAgainButANotFoundIsNot() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let flaky = "https://flaky.example.org/a.png"
        let gone = "https://gone.example.org/a.png"
        ImageStub.answer(flaky, .status(503))
        ImageStub.answer(gone, .status(404))
        #expect(await images.image(flaky, host: host, maxPixel: 10) == nil)
        #expect(await images.image(gone, host: host, maxPixel: 10) == nil)
        #expect(!images.hasFailed(flaky))
        #expect(images.hasFailed(gone))

        ImageStub.answer(flaky, .body(Self.png(width: 4, height: 4)))
        #expect(await images.image(flaky, host: host, maxPixel: 10) != nil)
        #expect(await images.image(gone, host: host, maxPixel: 10) == nil)
        #expect(ImageStub.requests(to: "flaky.example.org").count == 2)
        #expect(ImageStub.requests(to: "gone.example.org").count == 1)
    }

    @Test func aCardImageThatCouldNotBeReachedIsTriedAgain() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://offline.example.org/a.png"
        ImageStub.answer(address, .fail)
        #expect(await images.image(address, host: host, maxPixel: 10) == nil)
        #expect(!images.hasFailed(address))
        ImageStub.answer(address, .body(Self.png(width: 4, height: 4)))
        #expect(await images.image(address, host: host, maxPixel: 10) != nil)
    }

    // MARK: Server image bounds and failures

    @Test func aServerImageIsDownsampledOffItsFullSize() async {
        let (images, client, transport) = Self.remote(.init(body: Self.png(width: 1000, height: 500)))
        let image = await images.image(client: client, path: "/files/a.png", maxPixel: 120)
        #expect(image?.cgImage?.width == 120)
        #expect(image?.cgImage?.height == 60)
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 120)) != nil)
        #expect(transport.count == 1)
    }

    @Test func aServerImageDeclaringTooManyBytesIsRefused() async {
        let (images, client, _) = Self.remote(.init(body: Self.png(width: 4, height: 4), headers: ["Content-Length": String(ImageLimits.maxBytes + 1)]))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
    }

    @Test func aServerImageLargerThanItSaidIsRefused() async {
        var body = Self.png(width: 4, height: 4)
        body.append(Data(count: ImageLimits.maxBytes))
        let (images, client, _) = Self.remote(.init(body: body, headers: ["Content-Length": "100"]))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
    }

    @Test func aServerImageWithTooManyPixelsIsRefused() async throws {
        // 56 million pixels in well under the byte bound.
        let header = Self.greyPNG(width: 8_000, height: 7_000)
        #expect(header.count < ImageLimits.maxBytes)

        let decoded = await ImageLimits.decode(header, maxPixel: 100)
        guard case .failure(.tooLarge) = decoded else {
            Issue.record("Expected tooLarge, got \(decoded)")
            return
        }
        let (images, client, _) = Self.remote(.init(body: header))
        #expect(await images.image(client: client, path: "/files/huge.png", maxPixel: 100) == nil)
        #expect(images.hasFailed(client, "/files/huge.png"))
    }

    @Test func aServerAnswerThatIsNotAnImageIsRemembered() async {
        let (images, client, transport) = Self.remote(.init(body: Data("<html>".utf8)))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/a.png"))
        #expect(transport.count == 1)
    }

    @Test func aServerImageThatFailedForNowIsTriedAgain() async {
        let (images, client, transport) = Self.remote(.init(status: 502))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(!images.hasFailed(client, "/files/a.png"))
        transport.answer = .init(fails: true)
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) == nil)
        #expect(!images.hasFailed(client, "/files/a.png"))
        transport.answer = .init(body: Self.png(width: 4, height: 4))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) != nil)
        #expect(transport.count == 3)
    }

    @Test func oneLoadIsSharedAndOutlivesAViewThatGoesAway() async {
        let gate = AsyncGate()
        let (images, client, transport) = Self.remote(.init(body: Self.png(width: 8, height: 8)), gate: gate)
        let first = Task { await images.image(client: client, path: "/files/a.png", maxPixel: 10) }
        let second = Task { await images.image(client: client, path: "/files/a.png", maxPixel: 10) }
        await gate.waitForRequest()
        first.cancel()
        gate.release()
        #expect(await second.value != nil)
        _ = await first.value
        #expect(transport.count == 1)
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 10)) != nil)
    }

    // MARK: What's remembered

    @Test func onlyFailuresThatWillNotChangeAreLasting() {
        #expect(ImageLimits.Failure.refused.isLasting)
        #expect(ImageLimits.Failure.tooLarge.isLasting)
        #expect(ImageLimits.Failure.notAnImage.isLasting)
        #expect(ImageLimits.Failure.status(404).isLasting)
        #expect(ImageLimits.Failure.status(410).isLasting)
        #expect(!ImageLimits.Failure.status(401).isLasting)
        #expect(!ImageLimits.Failure.status(403).isLasting)
        #expect(!ImageLimits.Failure.status(408).isLasting)
        #expect(!ImageLimits.Failure.status(429).isLasting)
        #expect(!ImageLimits.Failure.status(500).isLasting)
        #expect(!ImageLimits.Failure.status(503).isLasting)
        #expect(!ImageLimits.Failure.unreachable.isLasting)
    }

    @Test func rememberedFailuresForgetTheOldestPastTheirLimit() {
        var failures = LastingFailures(limit: 3)
        for address in ["a", "b", "c", "b", "d"] { failures.insert(address) }
        #expect(failures.count == 3)
        #expect(!failures.contains("a"))
        #expect(failures.contains("b") && failures.contains("c") && failures.contains("d"))
    }

    // MARK: Links

    @Test(arguments: [
        ("https://example.com/a", "https://example.com/a"),
        ("http://example.com", "http://example.com"),
        ("HTTPS://EXAMPLE.COM/a", "HTTPS://EXAMPLE.COM/a"),
        ("mailto:someone@example.com", "mailto:someone@example.com"),
        ("tel:+15555550100", "tel:+15555550100"),
        ("https://chat.example.com/rooms/3", "https://chat.example.com/rooms/3"),
        // Server-relative, as message links have always been resolved and opened.
        ("/rooms/3", "https://chat.example.com/rooms/3"),
        ("rooms/3?x=1", "https://chat.example.com/rooms/3?x=1"),
        ("//elsewhere.example.org/a", "https://elsewhere.example.org/a"),
    ])
    func aLinkTheAppOpens(_ link: String, _ opened: String) {
        let origin = URL(string: "https://chat.example.com")!
        #expect(LinkOpening.destination(URL(string: link)!, origin: origin)?.absoluteString == opened)
    }

    @Test(arguments: [
        "javascript:alert(1)", "JavaScript:alert(1)", "file:///etc/hosts", "data:text/html,hi", "ftp://example.com/a",
        "sms:5555550100", "facetime:someone@example.com", "ember://rooms/3", "prefs:root=General", "https:/no-host", "http://",
    ])
    func aLinkTheAppDrops(_ link: String) {
        let origin = URL(string: "https://chat.example.com")!
        #expect(LinkOpening.destination(URL(string: link)!, origin: origin) == nil)
    }

    @Test func aRelativeLinkWithNoServerIsDropped() {
        #expect(LinkOpening.destination(URL(string: "/rooms/3")!, origin: nil) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func theRootActionReachesPushedScreensSheetsAndCovers() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let recorder = OpenedLinks()
        let (appearances, reported) = AsyncStream<String>.makeStream()
        let probe = PresentationProbe(report: { reported.yield($0) })
            .modifier(SafeLinks(origin: URL(string: "https://chat.example.com")!, hand: { recorder.urls.append($0) }))
        UIView.setAnimationsEnabled(false)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: probe)
        window.makeKeyAndVisible()
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true
            UIView.setAnimationsEnabled(true)
        }
        var seen: Set<String> = []
        for await name in appearances {
            seen.insert(name)
            if seen.count == 3 { break }
        }
        let opened = Set(recorder.urls.map(\.absoluteString))
        // Each screen tried a refused link and a relative one: only the relative ones came through,
        // resolved, and none of them reached the system's own handler.
        #expect(opened == [
            "https://chat.example.com/rooms/pushed",
            "https://chat.example.com/rooms/sheet",
            "https://chat.example.com/rooms/cover",
        ])
        #expect(recorder.urls.count == 3)
    }

    // MARK: A message's picture

    @Test func aPictureFitsItsBoxAtItsOwnShape() {
        // Tall: as high as the box, and only as wide as that makes it.
        #expect(PictureBounds.size(aspectRatio: 0.5) == CGSize(width: 160, height: 320))
        // Wide or square: as wide as the box.
        #expect(PictureBounds.size(aspectRatio: 2) == CGSize(width: 280, height: 140))
        #expect(PictureBounds.size(aspectRatio: 1) == CGSize(width: 280, height: 280))
    }

    /// The outline once ran round the whole box, leaving a tall picture in the left of an empty frame.
    @Test func aTallPictureIsOutlinedAtItsOwnWidth() throws {
        let tall = UIImage(data: Self.png(width: 100, height: 200))!
        func picture() -> some View { Image(uiImage: tall).resizable().scaledToFill() }

        // Its shape known ahead, as the server tells it: the frame is the picture's own size.
        let known = try Self.drawn(picture().pictureFrame(aspectRatio: 0.5))
        #expect(known.size == CGSize(width: 160, height: 320))
        #expect(try Self.inkedWidth(of: known) == 160)
        // Its shape found from the picture: the same.
        let found = try Self.drawn(picture().pictureFrame(aspectRatio: nil))
        #expect(found.size == CGSize(width: 160, height: 320))
        #expect(try Self.inkedWidth(of: found) == 160)
        // A wide one still takes the box's width.
        let wide = try Self.drawn(picture().pictureFrame(aspectRatio: 2))
        #expect(wide.size == CGSize(width: 280, height: 140))
    }

    /// A wide picture whose shape is found from it leaves no empty box beneath it.
    @Test func aWidePictureOfNoKnownShapeIsOnlyAsTallAsItIs() throws {
        let wide = UIImage(data: Self.png(width: 200, height: 100))!
        let drawn = try Self.drawn(Image(uiImage: wide).resizable().scaledToFill().pictureFrame(aspectRatio: nil))
        #expect(drawn.size == CGSize(width: 280, height: 140))
    }

    @Test func aPictureThatIsNotTheShapeItWasSaidToBeStaysInItsBox() throws {
        // Said to be square, and ten times as tall as it is wide.
        let strip = UIImage(data: Self.png(width: 20, height: 200))!
        let drawn = try Self.drawn(Image(uiImage: strip).resizable().scaledToFill().pictureFrame(aspectRatio: 1))
        #expect(drawn.size == CGSize(width: 280, height: 280))
    }

    // MARK: Trying a picture again

    @Test func aPictureThatFailedForNowIsTriedAgainUntilItLoads() async {
        var answers: [Result<Int, ImageLimits.Failure>] = [.failure(.status(503)), .failure(.status(503)), .success(7)]
        var attempts = 0
        var failures: [ImageLimits.Failure] = []
        let value = await ImageRetry.keepTrying(pauses: [.zero, .zero, .zero]) {
            attempts += 1
            return answers.removeFirst()
        } failed: { failures.append($0) }
        #expect(value == 7)
        #expect(attempts == 3)
        #expect(failures == [.status(503), .status(503)])
    }

    @Test func aPictureThatIsNotThereIsNotTriedAgainByItself() async {
        var attempts = 0
        let value: Int? = await ImageRetry.keepTrying(pauses: [.zero, .zero, .zero]) {
            attempts += 1
            return .failure(.status(404))
        } failed: { _ in }
        #expect(value == nil)
        #expect(attempts == 1)
    }

    @Test func aPictureThatCantBeReachedStopsAfterItsTries() async {
        var attempts = 0
        let value: Int? = await ImageRetry.keepTrying(pauses: [.zero, .zero]) {
            attempts += 1
            return .failure(.unreachable)
        } failed: { _ in }
        #expect(value == nil)
        #expect(attempts == 3)
        #expect(ImageRetry.pauses.count == 3)
    }

    @Test func aServerPictureThatWasNotThereIsFetchedAgainOnceForgotten() async {
        let (images, client, transport) = Self.remote(.init(status: 404))
        #expect(await images.result(client: client, path: "/files/a.png", maxPixel: 10) == .failure(.status(404)))
        // Remembered: the same answer, and no second fetch.
        #expect(await images.result(client: client, path: "/files/a.png", maxPixel: 10) == .failure(.status(404)))
        #expect(transport.count == 1)

        transport.answer = .init(body: Self.png(width: 4, height: 4))
        images.forget(client, "/files/a.png")
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) != nil)
        #expect(transport.count == 2)
    }

    @Test func resettingServerPicturesEmptiesThemAndTheirFailures() async {
        let (images, client, transport) = Self.remote(.init(body: Self.png(width: 4, height: 4)))
        #expect(await images.image(client: client, path: "/files/a.png", maxPixel: 10) != nil)
        transport.answer = .init(status: 404)
        #expect(await images.image(client: client, path: "/files/b.png", maxPixel: 10) == nil)
        #expect(images.hasFailed(client, "/files/b.png"))

        images.reset()
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 10)) == nil)
        #expect(!images.hasFailed(client, "/files/b.png"))
    }

    @Test func aLoadUnderWayAtAResetIsNotKept() async {
        let gate = AsyncGate()
        let (images, client, _) = Self.remote(.init(body: Self.png(width: 4, height: 4)), gate: gate)
        let load = Task { await images.image(client: client, path: "/files/a.png", maxPixel: 10) }
        await gate.waitForRequest()
        images.reset()
        gate.release()
        #expect(await load.value != nil)
        #expect(images.cached(RemoteImages.key(client, "/files/a.png", maxPixel: 10)) == nil)
    }

    @Test func aCardPictureThatWasNotThereIsFetchedAgainOnceForgottenOrReset() async {
        let images = CardImages(protocolClasses: [ImageStub.self])
        let address = "https://forgotten.example.org/a.png"
        guard case .failure(.status(404)) = await images.result(address, host: host, maxPixel: 10) else {
            Issue.record("Expected a 404")
            return
        }
        #expect(images.hasFailed(address))
        images.forget(address)
        #expect(!images.hasFailed(address))

        ImageStub.answer(address, .body(Self.png(width: 4, height: 4)))
        #expect(await images.image(address, host: host, maxPixel: 10) != nil)
        #expect(images.cached(address, maxPixel: 10) != nil)
        #expect(ImageStub.requests(to: "forgotten.example.org").count == 2)

        images.reset()
        #expect(images.cached(address, maxPixel: 10) == nil)
    }

    // MARK: A picture's shape

    @Test func aPictureFarTallerOrWiderThanThreeToOneIsCroppedToThat() {
        let tall = PictureBounds.size(aspectRatio: 60.0 / 900.0)
        #expect(abs(tall.width - 320.0 / 3) < 0.01 && tall.height == 320)
        let wide = PictureBounds.size(aspectRatio: 900.0 / 60.0)
        #expect(wide.width == 280 && abs(wide.height - 280.0 / 3) < 0.01)
        // Within the bounds, its own shape.
        #expect(PictureBounds.clamped(0.5) == 0.5)
        #expect(PictureBounds.clamped(2) == 2)
    }

    @Test func aVeryTallPictureIsDrawnAtTheShapeItsCroppedTo() throws {
        let strip = UIImage(data: Self.png(width: 60, height: 900))!
        let drawn = try Self.drawn(Image(uiImage: strip).resizable().scaledToFill().pictureFrame(aspectRatio: 60.0 / 900.0))
        #expect(abs(drawn.size.width - 320.0 / 3) < 0.5)
        #expect(drawn.size.height == 320)
        #expect(abs(try Self.inkedWidth(of: drawn) - 320.0 / 3) < 1)
    }

    @Test func aPictureOfNoKnownShapeWaitsInAModestBox() throws {
        let drawn = try Self.drawn(Color.gray.pictureFrame(expected: nil))
        #expect(drawn.size == PictureBounds.placeholder)
        #expect(PictureBounds.placeholder == CGSize(width: 200, height: 150))
        // Once known, its own shape.
        let known = try Self.drawn(Color.gray.pictureFrame(expected: 2))
        #expect(known.size == CGSize(width: 280, height: 140))
    }

    @Test func aFileWithAPreviewButNoSizeHasNoStoredShape() throws {
        #expect(AttachmentView.storedAspectRatio(try Self.file(width: nil, height: nil)) == nil)
        #expect(AttachmentView.storedAspectRatio(try Self.file(width: 400, height: 200)) == 2)
    }

    // MARK: Remembered sizes

    @Test func aPicturesSizeIsRememberedOnceKnown() {
        let sizes = PictureSizes(file: nil)
        let key = PictureSizes.key(file: "file_1")
        #expect(sizes.size(for: key) == nil)
        sizes.remember(CGSize(width: 300, height: 100), for: key)
        #expect(sizes.size(for: key) == CGSize(width: 300, height: 100))
        // Nothing of no size.
        sizes.remember(.zero, for: PictureSizes.key(card: "https://example.com/a.png"))
        #expect(sizes.count == 1)
        #expect(PictureSizes.key(file: "a") != PictureSizes.key(card: "a"))
    }

    @Test func rememberedSizesForgetTheOldestPastTheirLimit() {
        let sizes = PictureSizes(file: nil, limit: 2)
        for key in ["a", "b", "c"] { sizes.remember(CGSize(width: 1, height: 1), for: key) }
        #expect(sizes.count == 2)
        #expect(sizes.size(for: "a") == nil)
        #expect(sizes.size(for: "c") != nil)
    }

    @Test func rememberedSizesLastBetweenLaunchesUntilReset() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "PictureSizes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = PictureSizes(file: file)
        first.remember(CGSize(width: 640, height: 480), for: "a")
        first.save()
        #expect(PictureSizes(file: file).size(for: "a") == CGSize(width: 640, height: 480))

        first.reset()
        #expect(first.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(PictureSizes(file: file).size(for: "a") == nil)
    }

    // MARK: Moving pictures

    @Test func aGIFComesBackWithItsFramesAndTiming() async throws {
        let gif = Self.gif(frames: 6, width: 40, height: 20, delay: 0.05)
        let loaded = try await ImageLimits.decode(gif, maxPixel: 100).get()
        #expect(loaded.pixelSize == CGSize(width: 40, height: 20))
        #expect(loaded.image.images?.count == 6)
        #expect(abs(loaded.image.duration - 0.3) < 0.01)
        #expect(ImageLimits.cost(loaded) >= 6 * 40 * 20 * 4)
    }

    @Test func aGIFWhoseFramesWouldWeighTooMuchKeepsFewerForAsLong() async throws {
        // Ten frames of 4 MB each against a 16 MB bound.
        let gif = Self.gif(frames: 10, width: 1_000, height: 1_000, delay: 0.1)
        let loaded = try await ImageLimits.decode(gif, maxPixel: 1_000).get()
        let frames = try #require(loaded.image.images)
        #expect(frames.count > 1 && frames.count <= 4)
        #expect(ImageLimits.cost(loaded) <= ImageLimits.animationBytes)
        #expect(abs(loaded.image.duration - 1.0) < 0.01)
    }

    @Test func aFrameOfNoDelayShowsForATenthOfASecond() throws {
        let gif = Self.gif(frames: 2, width: 4, height: 4, delay: 0)
        let source = try #require(CGImageSourceCreateWithData(gif as CFData, nil))
        #expect(ImageLimits.frameDelay(source, at: 0) == 0.1)
        let single = try #require(CGImageSourceCreateWithData(Self.png(width: 4, height: 4) as CFData, nil))
        #expect(ImageLimits.frameDelay(single, at: 0) == 0.1)
    }

    @Test func aStillPictureComesBackStill() async throws {
        let loaded = try await ImageLimits.decode(Self.png(width: 8, height: 8), maxPixel: 10).get()
        #expect(loaded.image.images == nil)
    }

    // MARK: Files opened in the app

    @Test func aFileIsDownloadedOnceAndKeptUnderItsName() async throws {
        let (downloads, client, directory) = try Self.downloads(origin: "https://files-once.example.com")
        defer { try? FileManager.default.removeItem(at: directory) }
        ImageStub.answer("https://files-once.example.com/files/f?download=1", .body(Data("hello".utf8)))
        let file = try Self.file(name: "notes.txt")
        let saved = try await downloads.file(file, client: client)
        #expect(saved.lastPathComponent == "notes.txt")
        #expect(try Data(contentsOf: saved) == Data("hello".utf8))
        _ = try await downloads.file(file, client: client)
        #expect(ImageStub.requests(to: "files-once.example.com").count == 1)

        downloads.reset()
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func aDownloadCancelledByAResetLeavesTheNextOneForTheSameFileAlone() async throws {
        let (downloads, client, directory) = try Self.downloads(origin: "https://files-reset.example.com")
        defer { try? FileManager.default.removeItem(at: directory) }
        ImageStub.answer("https://files-reset.example.com/files/f?download=1", .hold)
        let file = try Self.file(name: "held.txt")
        let first = Task { try await downloads.file(file, client: client) }
        #expect(await eventually { ImageStub.requests(to: "files-reset.example.com").count == 1 })
        downloads.reset()
        let second = Task { try await downloads.file(file, client: client) }
        #expect(await eventually { ImageStub.requests(to: "files-reset.example.com").count == 2 })
        _ = await first.result
        // The second is still on its way, so a third joins it rather than fetching again.
        let third = Task { try await downloads.file(file, client: client) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(ImageStub.requests(to: "files-reset.example.com").count == 2)
        downloads.reset()
        _ = await second.result
        _ = await third.result
    }

    @Test func aFileThatFailsToDownloadIsNotKept() async throws {
        let (downloads, client, directory) = try Self.downloads(origin: "https://files-gone.example.com")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try Self.file(name: "gone.pdf")
        await #expect(throws: (any Error).self) { try await downloads.file(file, client: client) }
        #expect(!FileManager.default.fileExists(atPath: downloads.location(of: file).path))
    }

    @Test func aDownloadCarriesTheSessionOnlyToTheServerItself() throws {
        let cookies = EphemeralCookieStorage()
        cookies.setCookie(HTTPCookie(properties: [.name: "session", .value: "s3cret", .domain: "chat.example.com", .path: "/", .secure: "TRUE"])!)
        let client = EmberClient(origin: URL(string: "https://chat.example.com")!, transport: ImageTransport(.init(), gate: nil), connector: MockSocketConnector(), cookies: cookies)
        let own = try FileDownloads.request(for: try Self.file(download: "/files/f?download=1"), client: client)
        #expect(own.value(forHTTPHeaderField: "Cookie")?.contains("s3cret") == true)
        let signed = try FileDownloads.request(for: try Self.file(download: "https://bucket.example.net/f?sig=1"), client: client)
        #expect(signed.value(forHTTPHeaderField: "Cookie") == nil)

        var redirected = own
        redirected.url = URL(string: "https://bucket.example.net/f")
        #expect(FileDownloads.redirect(redirected, origin: client.origin).value(forHTTPHeaderField: "Cookie") == nil)
        #expect(FileDownloads.redirect(own, origin: client.origin).value(forHTTPHeaderField: "Cookie") != nil)
        #expect(VideoViewer.cookies(for: URL(string: "https://chat.example.com/files/v.mp4")!, client: client).count == 1)
        #expect(VideoViewer.cookies(for: URL(string: "https://bucket.example.net/v.mp4")!, client: client).isEmpty)
    }

    @Test func onlyTheSameSchemeHostAndPortAreTheServer() {
        let origin = URL(string: "https://chat.example.com")!
        #expect(FileDownloads.isSameOrigin(URL(string: "https://CHAT.example.com:443/a")!, origin))
        #expect(!FileDownloads.isSameOrigin(URL(string: "http://chat.example.com/a")!, origin))
        #expect(!FileDownloads.isSameOrigin(URL(string: "https://chat.example.com:8443/a")!, origin))
        #expect(!FileDownloads.isSameOrigin(URL(string: "https://chat.example.com.evil.net/a")!, origin))
    }

    @Test func aFilesNameStaysInsideItsFolder() {
        #expect(FileDownloads.safe("../../etc/passwd", otherwise: "file") == "_.._etc_passwd")
        #expect(FileDownloads.safe(".hidden", otherwise: "file") == "hidden")
        #expect(FileDownloads.safe("a:b\\c", otherwise: "file") == "a_b_c")
        #expect(FileDownloads.safe("...", otherwise: "file") == "file")
        #expect(FileDownloads.safe(String(repeating: "x", count: 500), otherwise: "file").count == 200)
    }

    @Test func savedFilesPastTheirLimitLoseTheLeastRecentlyUsed() async throws {
        let (downloads, client, directory) = try Self.downloads(origin: "https://files-trim.example.com", limit: 2_500)
        defer { try? FileManager.default.removeItem(at: directory) }
        for id in ["a", "b", "c"] {
            ImageStub.answer("https://files-trim.example.com/files/\(id)", .body(Data(count: 1_000)))
        }
        let a = try Self.file(id: "a", download: "/files/a"), b = try Self.file(id: "b", download: "/files/b"), c = try Self.file(id: "c", download: "/files/c")
        _ = try await downloads.file(a, client: client)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await downloads.file(b, client: client)
        try await Task.sleep(for: .milliseconds(20))
        _ = try await downloads.file(c, client: client)
        #expect(!FileManager.default.fileExists(atPath: downloads.location(of: a).path))
        #expect(FileManager.default.fileExists(atPath: downloads.location(of: b).path))
        #expect(FileManager.default.fileExists(atPath: downloads.location(of: c).path))
    }

    // MARK: Long addresses

    @Test func aLongAddressMayWrapAtItsMarksAndWithinLongRuns() {
        let address = "https://example.com/" + String(repeating: "c", count: 45)
        let broken = TextBreaks.breakable(address)
        let opportunity = TextBreaks.opportunity
        #expect(broken.filter { $0 != opportunity } == address)
        #expect(broken.hasPrefix("https://\u{200B}example.\u{200B}com/\u{200B}"))
        // No run longer than `run` without a place to wrap.
        #expect(broken.split(separator: opportunity).allSatisfy { $0.count <= TextBreaks.run })
        // Never one at the end.
        #expect(broken.last != opportunity)
    }

    @Test func shortWordsAndTheSpacesBetweenWordsAreLeftAlone() {
        #expect(TextBreaks.breakable("see https://ex.com/a") == "see https://ex.com/a")
        let text = "a fairly ordinary sentence with no long words in it at all"
        #expect(TextBreaks.breakable(text) == text)
        let mixed = "go to https://example.com/some/long/path/here now"
        let broken = TextBreaks.breakable(mixed)
        #expect(broken.hasPrefix("go to https://"))
        #expect(broken.hasSuffix(" now"))
        #expect(broken.filter { $0 != TextBreaks.opportunity } == mixed)
    }

    // MARK: Helpers

    /// A view as a message's column lays it out: offered more width than a picture needs, and
    /// whatever height it likes.
    private static func drawn(_ view: some View) throws -> UIImage {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 350, height: nil)
        return try #require(renderer.uiImage)
    }

    /// How far across, in points, anything at all is drawn in an image.
    private static func inkedWidth(of image: UIImage) throws -> CGFloat {
        let source = try #require(image.cgImage)
        let width = source.width, height = source.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var last = -1
        for y in 0..<height {
            for x in stride(from: width - 1, to: last, by: -1) where pixels[(y * width + x) * 4 + 3] > 0 {
                last = x
                break
            }
        }
        return CGFloat(last + 1) / image.scale
    }

    private static func remote(_ answer: ImageTransport.Answer, gate: AsyncGate? = nil) -> (RemoteImages, EmberClient, ImageTransport) {
        let transport = ImageTransport(answer, gate: gate)
        let client = EmberClient(origin: URL(string: "https://chat.example.com")!, transport: transport, connector: MockSocketConnector(), cookies: EphemeralCookieStorage())
        return (RemoteImages(), client, transport)
    }

    private static func file(id: String = "file_1", name: String = "f", width: Int? = nil, height: Int? = nil, download: String = "/files/f?download=1") throws -> StoredFile {
        var object: [String: Any] = [
            "id": id, "name": name, "contentType": "application/octet-stream", "byteSize": 1_000,
            "url": "/files/f", "downloadUrl": download, "previewUrl": "/files/f/preview",
        ]
        if let width { object["width"] = width }
        if let height { object["height"] = height }
        return try JSONDecoder().decode(StoredFile.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func downloads(origin: String, limit: Int = 300 * 1024 * 1024) throws -> (FileDownloads, EmberClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "Files-\(UUID().uuidString)", directoryHint: .isDirectory)
        let downloads = FileDownloads(directory: directory, limit: limit, protocolClasses: [ImageStub.self])
        let client = EmberClient(origin: URL(string: origin)!, transport: ImageTransport(.init(), gate: nil), connector: MockSocketConnector(), cookies: EphemeralCookieStorage())
        return (downloads, client, directory)
    }

    /// An animated GIF of `frames` frames, each a different grey, shown for `delay` seconds.
    static func gif(frames: Int, width: Int, height: Int, delay: Double) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, frames, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<frames {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let grey = CGFloat(frame) / CGFloat(max(frames, 1))
            context.setFillColor(red: grey, green: grey, blue: grey, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]]
            CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        }
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func png(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// A blank greyscale PNG: one byte a pixel to draw, and a few kilobytes once compressed.
    static func greyPNG(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}

// MARK: - Stand-ins

@MainActor private final class OpenedLinks {
    var urls: [URL] = []
}

/// Pushes a screen, which presents a sheet, which presents a cover; each tries two links as it appears.
private struct PresentationProbe: View {
    let report: @MainActor (String) -> Void
    @State private var path: [Int] = []

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .navigationDestination(for: Int.self) { _ in PushedProbe(report: report) }
                .task { path = [1] }
        }
    }
}

private struct PushedProbe: View {
    let report: @MainActor (String) -> Void
    @State private var isPresenting = false

    var body: some View {
        LinkTrier(name: "pushed", report: report)
            .task { isPresenting = true }
            .sheet(isPresented: $isPresenting) { SheetProbe(report: report) }
    }
}

private struct SheetProbe: View {
    let report: @MainActor (String) -> Void
    @State private var isPresenting = false

    var body: some View {
        LinkTrier(name: "sheet", report: report)
            .task { isPresenting = true }
            .fullScreenCover(isPresented: $isPresenting) { LinkTrier(name: "cover", report: report) }
    }
}

private struct LinkTrier: View {
    let name: String
    let report: @MainActor (String) -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear.onAppear {
            openURL(URL(string: "javascript:void(0)")!)
            openURL(URL(string: "/rooms/\(name)")!)
            report(name)
        }
    }
}

/// Answers every request with one answer, counting them, optionally held at a gate first.
private final class ImageTransport: HTTPTransport, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = [:]
        var fails = false
    }

    private let lock = NSLock()
    private var current: Answer
    private var sent = 0
    private let gate: AsyncGate?

    init(_ answer: Answer, gate: AsyncGate?) {
        current = answer
        self.gate = gate
    }

    var answer: Answer {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var count: Int { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let answer = lock.withLock { () -> Answer in
            sent += 1
            return current
        }
        if let gate { await gate.pass() }
        if answer.fails { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        return (answer.body, response)
    }
}

/// Holds a request until `release()`, telling a waiter once one has reached it.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var isReached = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRequest() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReached {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            defer { self.held = [] }
            return self.held
        }
        for continuation in held { continuation.resume() }
    }

    func pass() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isReached = true
            let waiting = waiters
            waiters = []
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                held.append(continuation)
                lock.unlock()
            }
            for waiter in waiting { waiter.resume() }
        }
    }
}

/// Answers card image requests from what each test set for its own address, and records them.
final class ImageStub: URLProtocol {
    enum Answer: Sendable {
        case body(Data, headers: [String: String] = [:])
        case redirect(String)
        case status(Int)
        case fail
        /// Never answers, as a download still on its way.
        case hold
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [URLRequest] = []

    static func answer(_ address: String, _ answer: Answer) {
        lock.withLock { answers[address] = answer }
    }

    static func requests(to host: String) -> [URLRequest] {
        lock.withLock { seen.filter { $0.url?.host() == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = Self.lock.withLock { () -> Answer in
            Self.seen.append(request)
            return Self.answers[url.absoluteString] ?? .status(404)
        }
        switch answer {
        case let .body(data, headers):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // Where the redirect isn't followed, the 302 is the answer.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .status(status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .fail:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .hold:
            break
        }
    }

    override func stopLoading() {}
}

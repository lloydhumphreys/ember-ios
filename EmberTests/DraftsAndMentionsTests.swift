import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers
import EmberSDK
@testable import Ember

private let ann: UserID = "0abcdefghijklmno"
private let anna: UserID = "1abcdefghijklmno"
private let bo: UserID = "2abcdefghijklmno"

private func person(_ id: UserID, _ name: String, role: Role = .member, status: UserStatus = .active) -> DirectoryUser {
    DirectoryUser(id: id, name: name, role: role, status: status, avatarUrl: "/users/\(id)/avatar")
}

/// The stored form of a mention, as the server keeps every one a client sends.
private func stored(_ userId: UserID) -> String {
    "<action-text-attachment content-type=\"application/vnd.campfire.mention\" sgid=\"\(userId.rawValue)\"></action-text-attachment>"
}

/// Drafts kept per room and thread across launches, mentions typed after "@", how far a draft runs
/// over the limit, and staged files kept in the order picked.
@MainActor
@Suite final class DraftsAndMentionsTests {
    private let root: URL
    private let room = DraftKey(server: "https://ember.example", user: "me", room: "room1")

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DraftsAndMentionsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private var file: URL { root.appending(path: "Drafts.json") }

    // MARK: Drafts

    @Test func aDraftIsKeptForItsRoomAndThreadAlone() {
        let drafts = Drafts(file: nil)
        var thread = room
        thread.thread = "parent1"
        let elsewhere = DraftKey(server: "https://other.example", user: "me", room: "room1")
        drafts.set(Draft(text: "in the room"), for: room)
        drafts.set(Draft(text: "in the thread"), for: thread)
        #expect(drafts.draft(for: room).text == "in the room")
        #expect(drafts.draft(for: thread).text == "in the thread")
        #expect(drafts.draft(for: elsewhere).isEmpty)
        #expect(drafts.draft(for: DraftKey(server: "https://ember.example", user: "someone", room: "room1")).isEmpty)
    }

    @Test func aDraftsKeyOnDiskIsTheServerPersonRoomAndThread() {
        var thread = room
        thread.thread = "parent1"
        #expect(room.storageKey == "https://ember.example me room1 ")
        #expect(thread.storageKey == "https://ember.example me room1 parent1")
    }

    @Test func draftsOnDiskAreAnObjectOfDraftsWithMentionsByID() throws {
        let drafts = Drafts(file: file)
        drafts.set(Draft(text: "@Ann half written", mentions: [ann: "Ann"]), for: room)
        drafts.save()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary
        #expect(written == [
            "https://ember.example me room1 ": ["text": "@Ann half written", "mentions": ["0abcdefghijklmno": "Ann"]],
        ] as NSDictionary)

        try Data(#"{"https://ember.example me room1 parent1":{"text":"@Bo hi","mentions":{"2abcdefghijklmno":"Bo"}}}"#.utf8).write(to: file)
        var thread = room
        thread.thread = "parent1"
        #expect(Drafts(file: file).draft(for: thread) == Draft(text: "@Bo hi", mentions: [bo: "Bo"]))
    }

    @Test func aDraftIsThereAfterARelaunch() {
        let first = Drafts(file: file)
        first.set(Draft(text: "@Ann half written", mentions: [ann: "Ann"]), for: room)
        first.save()
        let relaunched = Drafts(file: file)
        #expect(relaunched.draft(for: room) == Draft(text: "@Ann half written", mentions: [ann: "Ann"]))
    }

    @Test func clearingADraftForgetsItOnDiskToo() {
        let drafts = Drafts(file: file)
        drafts.set(Draft(text: "sent soon"), for: room)
        drafts.save()
        drafts.clear(room)
        drafts.save()
        #expect(Drafts(file: file).draft(for: room).isEmpty)
    }

    @Test func emptyingTheStoreForgetsEveryDraftAndStagedFile() throws {
        let drafts = Drafts(file: file)
        drafts.set(Draft(text: "one"), for: room)
        drafts.save()
        let staged = drafts.staged(for: room)
        let copy = try Staging.copied(try picked("a.jpg"), isScoped: false, into: root.appending(path: "Uploads"))
        staged.append(StagedFile(source: try UploadSource.temporary(fileURL: copy, contentType: "image/jpeg"), thumbnail: nil))
        drafts.removeAll()
        #expect(drafts.drafts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(Drafts(file: file).drafts.isEmpty)
        #expect(drafts.staged(for: room) !== staged)
    }

    @Test func stagedFilesAreTheSameOnComingBack() {
        let drafts = Drafts(file: nil)
        let first = drafts.staged(for: room)
        #expect(drafts.staged(for: room) === first)
        var thread = room
        thread.thread = "parent1"
        #expect(drafts.staged(for: thread) !== first)
    }

    @Test func aMentionWhoseNameIsGoneFromTheTextIsDropped() {
        let drafts = Drafts(file: nil)
        drafts.set(Draft(text: "@An", mentions: [ann: "Ann", bo: "Bo"]), for: room)
        #expect(drafts.draft(for: room).mentions.isEmpty)
        drafts.set(Draft(text: "@Ann and @Bo", mentions: [ann: "Ann", bo: "Bo"]), for: room)
        #expect(drafts.draft(for: room).mentions == [ann: "Ann", bo: "Bo"])
    }

    // MARK: Mentions

    @Test func anAtAndLettersAreANameBeingTyped() throws {
        let query = try #require(MentionQuery.active(in: "hi @an"))
        #expect(query.text == "an")
        #expect(MentionQuery.active(in: "@")?.text == "")
        #expect(MentionQuery.active(in: "(@Pia Mon")?.text == "Pia Mon")
    }

    @Test func anAtInsideAWordOrOnAnEarlierLineIsNot() {
        #expect(MentionQuery.active(in: "me@example") == nil)
        #expect(MentionQuery.active(in: "@ann\nlater") == nil)
        #expect(MentionQuery.active(in: "no at here") == nil)
        #expect(MentionQuery.active(in: "@" + String(repeating: "a", count: MentionQuery.longest + 1)) == nil)
    }

    @Test func aChosenNameIsNotAskedAboutAgain() {
        #expect(MentionQuery.active(in: "@Ann ", chosen: ["Ann"]) == nil)
        #expect(MentionQuery.active(in: "@Ann, and", chosen: ["Ann"]) == nil)
        #expect(MentionQuery.active(in: "@Anna", chosen: ["Ann"])?.text == "Anna")
        #expect(MentionQuery.active(in: "@Ann", chosen: ["Ann"]) == nil)
    }

    @Test func theCaretDecidesWhichNameIsBeingTyped() throws {
        let text = "@an then more"
        let caret = text.index(text.startIndex, offsetBy: 3)
        #expect(MentionQuery.active(in: text, caret: caret)?.text == "an")
    }

    @Test func suggestionsAreActivePeopleWithAWordOfTheirNameStartingWithWhatsTyped() {
        let people = [
            person(bo, "Bo"), person(anna, "anna"), person(ann, "Ann"),
            person("3abcdefghijklmno", "Joanne"), person("4abcdefghijklmno", "Annette", status: .deactivated),
        ]
        #expect(MentionQuery.candidates(people, matching: "AN").map(\.name) == ["Ann", "anna"])
        #expect(MentionQuery.candidates(people, matching: "").map(\.name) == ["Ann", "anna", "Bo", "Joanne"])
        #expect(MentionQuery.candidates(people, matching: "", limit: 2).count == 2)
    }

    @Test func aFirstOrLastNameMatchesFromItsStartAndNotFromItsMiddle() {
        let people = [
            person("0leo000000000000", "Leo Park"), person("0jordan000000000", "Jordan Lee"),
            person("0priya0000000000", "Priya Patel"), person("0deploy000000000", "Deploy Bot", role: .bot),
        ]
        #expect(MentionQuery.candidates(people, matching: "L").map(\.name) == ["Jordan Lee", "Leo Park"])
        #expect(MentionQuery.candidates(people, matching: "lee").map(\.name) == ["Jordan Lee"])
        #expect(MentionQuery.candidates(people, matching: "ark").isEmpty)
    }

    @Test func whatsTypedCanRunOnIntoTheNextWordAndIgnoresAccents() {
        #expect(MentionQuery.wordStarts(in: "Sam Rivera", with: "Sam R"))
        #expect(MentionQuery.wordStarts(in: "Sam Rivera", with: "sam riv"))
        #expect(!MentionQuery.wordStarts(in: "Sam Rivera", with: "am R"))
        #expect(MentionQuery.wordStarts(in: "José Núñez", with: "nun"))
        #expect(MentionQuery.wordStarts(in: "Mary-Jane Holt", with: "Jane"))
        #expect(MentionQuery.wordStarts(in: "Mary-Jane Holt", with: "Mary-J"))
    }

    @Test func youAreNotSuggestedToYourself() {
        let people = [person(ann, "Ann"), person(anna, "Anna"), person(bo, "Bo")]
        #expect(MentionQuery.candidates(people, matching: "", excluding: anna).map(\.name) == ["Ann", "Bo"])
        #expect(MentionQuery.candidates(people, matching: "An", excluding: anna).map(\.name) == ["Ann"])
    }

    @Test func botsComeAfterPeopleEvenFromTheRoom() {
        let deploy: UserID = "0deploy000000000"
        let people = [person(deploy, "Deploy Bot", role: .bot), person(bo, "Bo"), person(ann, "Ann"), person("0ember0000000000", "Ember", role: .bot)]
        #expect(MentionQuery.candidates(people, matching: "").map(\.name) == ["Ann", "Bo", "Deploy Bot", "Ember"])
        #expect(MentionQuery.candidates(people, matching: "", first: [deploy, bo]).map(\.name) == ["Bo", "Ann", "Deploy Bot", "Ember"])
        #expect(MentionQuery.candidates(people, matching: "", limit: 2).map(\.name) == ["Ann", "Bo"])
    }

    @Test func aBackspaceInsideAMentionTakesAllOfIt() throws {
        let text = "Hi @Sam Rivera and @Bo, ok"
        let mentions = [ann: "Sam Rivera", bo: "Bo"]
        let sam = NSRange(try #require(text.range(of: "@Sam Rivera")), in: text)
        let last = NSRange(location: sam.location + sam.length - 1, length: 1)
        #expect(MentionField.wholeMention(deleting: last, in: text, mentions: mentions) == sam)
        let middle = NSRange(location: sam.location + 4, length: 1)
        #expect(MentionField.wholeMention(deleting: middle, in: text, mentions: mentions) == sam)
        let boEnd = NSRange(try #require(text.range(of: "o,")), in: text).location
        #expect(MentionField.wholeMention(deleting: NSRange(location: boEnd, length: 1), in: text, mentions: mentions) == NSRange(try #require(text.range(of: "@Bo")), in: text))
    }

    @Test func aBackspaceBesideAMentionOrOverAllOfItIsLeftAlone() throws {
        let text = "Hi @Sam Rivera and @Samuel ok"
        let mentions = [ann: "Sam Rivera", bo: "Sam"]
        let sam = NSRange(try #require(text.range(of: "@Sam Rivera")), in: text)
        // The space after it, the space before it, and the whole of it.
        #expect(MentionField.wholeMention(deleting: NSRange(location: sam.location + sam.length, length: 1), in: text, mentions: mentions) == nil)
        #expect(MentionField.wholeMention(deleting: NSRange(location: sam.location - 1, length: 1), in: text, mentions: mentions) == nil)
        #expect(MentionField.wholeMention(deleting: sam, in: text, mentions: mentions) == nil)
        // "@Samuel" isn't a mention of Sam, so its letters go one at a time.
        let samuel = NSRange(try #require(text.range(of: "@Samuel")), in: text)
        #expect(MentionField.wholeMention(deleting: NSRange(location: samuel.location + 6, length: 1), in: text, mentions: mentions) == nil)
        // Nobody chosen, nothing taken whole.
        #expect(MentionField.wholeMention(deleting: NSRange(location: sam.location + 3, length: 1), in: text, mentions: [:]) == nil)
    }

    @Test func choosingSomeoneWritesTheirNameAndGoesAsTheirMention() throws {
        let draft = Draft(text: "ask @an")
        let query = try #require(MentionQuery.active(in: draft.text))
        let chosen = query.choosing(ann, name: "Ann", in: draft)
        #expect(chosen.draft == Draft(text: "ask @Ann ", mentions: [ann: "Ann"]))
        #expect(chosen.caret == chosen.draft.text.endIndex)
        #expect(RoomComposer.outgoing(chosen.draft) == .mentions(body: "<p>ask \(stored(ann)) </p>", plainText: "ask @Ann "))
    }

    @Test func choosingInTheMiddleLeavesTheRestAndPutsTheCaretAfterTheName() throws {
        let text = "@b and the rest"
        let query = try #require(MentionQuery.active(in: text, caret: text.index(after: text.index(after: text.startIndex))))
        let chosen = query.choosing(bo, name: "Bo", in: Draft(text: text))
        #expect(chosen.draft.text == "@Bo and the rest")
        #expect(chosen.draft.text[..<chosen.caret] == "@Bo ")
    }

    @Test func choosingBeforePunctuationOrALineBreakAddsNoSpace() throws {
        // The text typed, then what choosing Bo leaves, and the text before the caret.
        let cases = [
            ("thanks @b!", "thanks @Bo!", "thanks @Bo"),
            ("@b\nnext", "@Bo\nnext", "@Bo"),
            ("@b more", "@Bo more", "@Bo "),
            ("@bx", "@Bo x", "@Bo "),
        ]
        for (text, expected, beforeCaret) in cases {
            let caret = try #require(text.range(of: "@b")).upperBound
            let query = try #require(MentionQuery.active(in: text, caret: caret))
            let chosen = query.choosing(bo, name: "Bo", in: Draft(text: text))
            #expect(chosen.draft.text == expected)
            #expect(chosen.draft.text[..<chosen.caret] == beforeCaret)
        }
    }

    @Test func aMentionDeletedFromTheTextGoesAsPlainText() throws {
        #expect(RoomComposer.outgoing(Draft(text: "@An there", mentions: [ann: "Ann"])) == .text("@An there"))
    }

    // MARK: The limit

    @Test func aDraftOverTheLimitSaysByHowMuch() {
        #expect(RoomComposer.overLimit(String(repeating: "a", count: Limits.message)) == 0)
        #expect(RoomComposer.overLimit(String(repeating: "a", count: Limits.message + 3)) == 3)
        // Counted as the server counts it: UTF-16 units of the plain text, its trailing newlines dropped.
        #expect(RoomComposer.overLimit(String(repeating: "a", count: Limits.message) + "\n\n") == 0)
        #expect(RoomComposer.overLimit(String(repeating: "😀", count: Limits.message / 2 + 1)) == 2)
        #expect(RoomComposer.overLimit("") == 0)
    }

    @Test func theFieldGrowsLessWhereThereIsLittleHeight() {
        #expect(RoomComposer.lines(compactHeight: false, accessibilitySize: false) == 8)
        #expect(RoomComposer.lines(compactHeight: true, accessibilitySize: false) < 8)
        #expect(RoomComposer.lines(compactHeight: true, accessibilitySize: true) == 1)
        #expect(RoomComposer.lines(compactHeight: false, accessibilitySize: true) < 8)
    }

    @Test func theFieldStopsGrowingAtAWholeNumberOfLines() {
        for size in [UIContentSizeCategory.large, .extraExtraExtraLarge, .accessibilityExtraLarge] {
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: size))
            let line = MentionField.height(ofLines: 1, font: font)
            for lines in [2, 4, 8] {
                #expect(abs(MentionField.height(ofLines: lines, font: font) - line * CGFloat(lines)) < 0.5, "\(size.rawValue), \(lines) lines")
            }
        }
    }

    @Test func aScrollInTheFieldStopsBetweenLines() {
        let line = (top: CGFloat(21), bottom: CGFloat(42))
        let pixel = CGFloat(1) / 3
        // Down, past the line the top edge would cut; up, above it; at rest, to its nearer edge.
        #expect(MentionField.lineAligned(30, in: line, direction: 1, most: 200, pixel: pixel) == 42)
        #expect(MentionField.lineAligned(30, in: line, direction: -1, most: 200, pixel: pixel) == 21)
        #expect(MentionField.lineAligned(25, in: line, direction: 0, most: 200, pixel: pixel) == 21)
        #expect(MentionField.lineAligned(38, in: line, direction: 0, most: 200, pixel: pixel) == 42)
        // Already between lines, or no line known there: left where it is.
        #expect(MentionField.lineAligned(21, in: line, direction: 1, most: 200, pixel: pixel) == 21)
        #expect(MentionField.lineAligned(30, in: nil, direction: 1, most: 200, pixel: pixel) == 30)
        // Never past either end.
        #expect(MentionField.lineAligned(30, in: line, direction: 1, most: 35, pixel: pixel) == 35)
        #expect(MentionField.lineAligned(-4, in: line, direction: -1, most: 200, pixel: pixel) == 0)
    }

    @Test func aStagedFilesRemoveButtonIsAFullTarget() {
        #expect(StagedFileView.removeTarget >= 44)
    }

    // MARK: Picking

    @Test func aLivePhotoGoesAsItsPicture() {
        let bundle = UTType("com.apple.live-photo-bundle") ?? .livePhoto
        #expect(PickedFile.goesAsPicture([bundle, .heic, .quickTimeMovie]))
        #expect(PickedFile.goesAsPicture([.livePhoto, .jpeg]))
        #expect(PickedFile.goesAsPicture([.heic]))
        #expect(!PickedFile.goesAsPicture([.quickTimeMovie]))
        #expect(!PickedFile.goesAsPicture([.mpeg4Movie, .jpeg]))
    }

    private func picked(_ name: String) throws -> URL {
        let folder = root.appending(path: "Picked-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        try Data(repeating: 7, count: 4).write(to: url)
        return url
    }

    @Test func picksStayInTheOrderPickedHoweverLongEachTakes() async throws {
        let uploads = root.appending(path: "Uploads")
        let files = StagedFiles(concurrentCopies: 3)
        let names = ["slow.txt", "quick.txt", "middling.txt"]
        let delays = [300, 0, 100]
        for (name, delay) in zip(names, delays) {
            let original = try picked(name)
            files.stage({
                try await Task.sleep(for: .milliseconds(delay))
                return try Staging.copied(original, isScoped: false, into: uploads)
            }, refuse: { _ in })
        }
        while files.copying > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(files.files.map(\.name) == names)
    }

    @Test func onlyAFewPicksAreCopiedAtOnce() async throws {
        let gauge = Gauge()
        let files = StagedFiles(concurrentCopies: 2)
        for _ in 0..<7 {
            files.stage({
                await gauge.enter()
                try await Task.sleep(for: .milliseconds(30))
                await gauge.leave()
                return nil
            }, refuse: { _ in })
        }
        #expect(files.copying == 7)
        while files.copying > 0 { try await Task.sleep(for: .milliseconds(20)) }
        let most = await gauge.most, done = await gauge.done
        #expect(most == 2)
        #expect(done == 7)
    }

    @Test func aPickWaitingItsTurnGoesWithTheComposer() async throws {
        let gauge = Gauge()
        var files: StagedFiles? = StagedFiles(concurrentCopies: 1)
        for _ in 0..<3 {
            files?.stage({
                await gauge.enter()
                try await Task.sleep(for: .milliseconds(50))
                await gauge.leave()
                return nil
            }, refuse: { _ in })
        }
        try await Task.sleep(for: .milliseconds(10))
        files = nil
        try await Task.sleep(for: .milliseconds(200))
        let started = await gauge.started
        #expect(started == 1)
    }

    // MARK: Files from a provider

    @Test func aFileFromOutsideTheSandboxIsCopiedThroughACoordinator() throws {
        let original = try picked("report.pdf")
        let copy = try Staging.copied(original, isScoped: true, into: root.appending(path: "Uploads"))
        #expect(copy.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: copy) == Data(repeating: 7, count: 4))
    }
}

/// How many copies run at once, and the most that ever did.
private actor Gauge {
    private var running = 0
    private(set) var most = 0
    private(set) var started = 0
    private(set) var done = 0

    func enter() {
        running += 1
        started += 1
        most = max(most, running)
    }

    func leave() {
        running -= 1
        done += 1
    }
}

import Foundation
import Testing
import UIKit
import EmberSDK
@testable import Ember

/// What VoiceOver is told, and the contrast of the colours white is drawn on and the accent's text.
@MainActor
@Suite struct AccessibilityTests {
    // MARK: VoiceOver

    @Test func mutedRoomsSayMuted() {
        #expect(MutedMark.label == "Muted")
        #expect(MutedMark.shows(for: .nothing))
        #expect(MutedMark.shows(for: .invisible))
        #expect(!MutedMark.shows(for: .mentions))
        #expect(!MutedMark.shows(for: .everything))
    }

    @Test func unreadCountsAreSaidAsUnread() {
        #expect(UnreadValue.text(0) == nil)
        #expect(UnreadValue.text(-1) == nil)
        #expect(UnreadValue.text(1) == "1 unread")
        #expect(UnreadValue.text(2) == "2 unread")
        #expect(UnreadValue.text(1_200) == "\(1_200.formatted()) unread")
    }

    @Test func accountButtonSaysWhoAndWhere() {
        #expect(AccountMenu.accessibilityValue(name: "Maya Chen", workspace: "Fernwood", accountCount: 1) == "Maya Chen")
        #expect(AccountMenu.accessibilityValue(name: "Maya Chen", workspace: "Fernwood", accountCount: 2) == "Maya Chen, Fernwood")
        #expect(AccountMenu.accessibilityValue(name: "Maya Chen", workspace: "  ", accountCount: 2) == "Maya Chen")
    }

    // MARK: Contrast

    private static let darkBackground = (red: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0)

    private func traits(dark: Bool, high: Bool) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: dark ? .dark : .light),
            UITraitCollection(accessibilityContrast: high ? .high : .normal),
        ])
    }

    private func components(_ colour: UIColor, dark: Bool, high: Bool) -> (red: Double, green: Double, blue: Double) {
        let resolved = colour.resolvedColor(with: traits(dark: dark, high: high))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (Double(red), Double(green), Double(blue))
    }

    private func asset(_ name: String) throws -> UIColor {
        try #require(UIColor(named: name, in: .main, compatibleWith: nil), "\(name) isn't in the app's assets")
    }

    private func ratio(_ a: (red: Double, green: Double, blue: Double), _ b: (red: Double, green: Double, blue: Double)) -> Double {
        Contrast.ratio(
            Contrast.luminance(red: a.red, green: a.green, blue: a.blue),
            Contrast.luminance(red: b.red, green: b.green, blue: b.blue))
    }

    @Test func accentTextReadsOnItsBackground() throws {
        let accent = try asset("AccentColor")
        let white = (red: 1.0, green: 1.0, blue: 1.0)
        #expect(ratio(components(accent, dark: false, high: false), white) >= 4.5)
        #expect(ratio(components(accent, dark: true, high: false), Self.darkBackground) >= 4.5)
        // Increase Contrast aims for 7:1.
        #expect(ratio(components(accent, dark: false, high: true), white) >= 7)
        #expect(ratio(components(accent, dark: true, high: true), Self.darkBackground) >= 7)
    }

    @Test func whiteReadsOnTheAccentFill() throws {
        let fill = try asset("AccentFill")
        for dark in [false, true] {
            for high in [false, true] {
                #expect(Contrast.ofWhite(on: components(fill, dark: dark, high: high)) >= 4.5, "dark \(dark), high \(high)")
            }
        }
    }

    @Test func swipeActionsHoldWhite() throws {
        let star = try asset("StarAction")
        let indigo = UIColor.systemIndigo
        for dark in [false, true] {
            #expect(Contrast.ofWhite(on: components(star, dark: dark, high: false)) >= 4.5)
            #expect(Contrast.ofWhite(on: components(indigo, dark: dark, high: false)) >= 3)
        }
    }

    @Test func everyAvatarColourHoldsWhiteInitials() throws {
        var darkened = 0
        for hex in AvatarStyle.colours {
            let value = try #require(UInt32(hex.dropFirst(), radix: 16))
            let colour = (red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
            let shown = Contrast.darkenedForWhite(colour)
            #expect(Contrast.ofWhite(on: shown) >= 3, "\(hex)")
            if Contrast.ofWhite(on: colour) >= 3 {
                #expect(shown == colour, "\(hex) was fine as it was")
            } else {
                darkened += 1
                // Only as far as it needs.
                #expect(Contrast.ofWhite(on: shown) < 3.1, "\(hex)")
            }
        }
        #expect(darkened == 3)
    }
}

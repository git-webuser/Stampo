import AppKit
import Foundation
import Testing
@testable import Stampo

/// The flattening behind "Copy All" / "Share All": both commands run through
/// `NotchTrayModel.payload`, so they can never disagree about what the tray
/// holds.
@Suite struct TrayPayloadTests {

    private let shot = URL(fileURLWithPath: "/tmp/tray/shot.png")
    private let a = URL(fileURLWithPath: "/tmp/drop/a.pdf")
    private let b = URL(fileURLWithPath: "/tmp/drop/b.pdf")

    private func color(_ hex: String) -> TrayItem {
        .color(TrayColor(color: NSColor(hexString: hex)!, hex: hex))
    }

    @Test func emptyTrayHasNoPayload() {
        #expect(NotchTrayModel.payload(for: [], colorScheme: .hex).isEmpty)
    }

    @Test func displayOrderIsPreservedAcrossKinds() {
        let items: [TrayItem] = [
            .screenshot(TrayScreenshot(url: shot)),
            .text(TrayText(text: "hello")),
            color("#FF0000")
        ]
        #expect(NotchTrayModel.payload(for: items, colorScheme: .hex) == [
            .file(shot), .string("hello"), .string("#FF0000")
        ])
    }

    @Test func stackContributesEveryMember() {
        let items: [TrayItem] = [.stack(TrayStack(urls: [a, b]))]
        #expect(NotchTrayModel.payload(for: items, colorScheme: .hex) == [.file(a), .file(b)])
    }

    /// Colors follow the format selected in the tray header, so what lands on
    /// the pasteboard matches what the cells show.
    @Test func colorsFollowTheSelectedScheme() {
        let items = [color("#FF0000")]
        #expect(NotchTrayModel.payload(for: items, colorScheme: .rgb) == [.string("255 0 0")])
        #expect(NotchTrayModel.payload(for: items, colorScheme: .hex) == [.string("#FF0000")])
    }

    /// Files must stay files through the boxing step — a URL flattened to a
    /// string would paste as text in Finder and AirDrop nothing.
    @Test func filesBoxAsURLsAndTextAsStrings() {
        let objects: [Any] = [TrayPayloadItem.file(shot), .string("hello")].objects
        #expect(objects.count == 2)
        #expect((objects[0] as? NSURL) as URL? == shot)
        #expect(objects[1] as? NSString == "hello")
    }
}

// MARK: - Share Last Screenshot hotkey

@Suite struct ShareLastCaptureHotkeyTests {

    @Test func rowMetadataIsFilledIn() {
        #expect(HotkeyAction.shareLastCapture.labelKey == "Share Last Screenshot")
        #expect(HotkeyAction.shareLastCapture.icon == "square.and.arrow.up")
        #expect(HotkeyAction.shareLastCapture.rawValue == 10)
    }

    @Test func sharingSitsWithTheOtherPanelActions() {
        #expect(HotkeyAction.shareLastCapture.group == .panel)
    }

    @Test func defaultComboIsUsableAndUnreserved() {
        let combo = HotkeyAction.shareLastCapture.defaultCombo
        #expect(combo.displayString == "⌃⌥⌘D")
        let result = HotkeyValidator.validate(combo, for: .shareLastCapture)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }
}

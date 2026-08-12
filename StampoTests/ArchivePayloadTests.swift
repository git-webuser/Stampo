import AppKit
import Foundation
import Testing
@testable import Stampo

/// The flattening behind the archive's Copy and Share: both commands run
/// through `NotchArchiveModel.payload`, so they can never disagree about what
/// was picked.
@Suite struct ArchivePayloadTests {

    private let shot = URL(fileURLWithPath: "/tmp/archive/shot.png")
    private let a = URL(fileURLWithPath: "/tmp/drop/a.pdf")
    private let b = URL(fileURLWithPath: "/tmp/drop/b.pdf")

    private func color(_ hex: String) -> ArchiveItem {
        .color(ArchiveColor(color: NSColor(hexString: hex)!, hex: hex))
    }

    @Test func emptyArchiveHasNoPayload() {
        #expect(NotchArchiveModel.payload(for: [], colorScheme: .hex).isEmpty)
    }

    @Test func displayOrderIsPreservedAcrossKinds() {
        let items: [ArchiveItem] = [
            .screenshot(ArchiveScreenshot(url: shot)),
            .text(ArchiveText(text: "hello")),
            color("#FF0000")
        ]
        #expect(NotchArchiveModel.payload(for: items, colorScheme: .hex) == [
            .file(shot), .string("hello"), .string("#FF0000")
        ])
    }

    @Test func stackContributesEveryMember() {
        let items: [ArchiveItem] = [.stack(ArchiveStack(urls: [a, b]))]
        #expect(NotchArchiveModel.payload(for: items, colorScheme: .hex) == [.file(a), .file(b)])
    }

    /// Colors follow the format selected in the archive header, so what lands on
    /// the pasteboard matches what the cells show.
    @Test func colorsFollowTheSelectedScheme() {
        let items = [color("#FF0000")]
        #expect(NotchArchiveModel.payload(for: items, colorScheme: .rgb) == [.string("255 0 0")])
        #expect(NotchArchiveModel.payload(for: items, colorScheme: .hex) == [.string("#FF0000")])
    }

    /// Files must stay files through the boxing step — a URL flattened to a
    /// string would paste as text in Finder and AirDrop nothing.
    @Test func filesBoxAsURLsAndTextAsStrings() {
        let objects: [Any] = [ArchivePayloadItem.file(shot), .string("hello")].objects
        #expect(objects.count == 2)
        #expect((objects[0] as? NSURL) as URL? == shot)
        #expect(objects[1] as? NSString == "hello")
    }
}

// MARK: - Share Last Item hotkey

@Suite struct ShareLastItemHotkeyTests {

    /// The hotkey shares whatever sits at the top of the archive, so it runs
    /// through the same flattening as Share — a color goes as a string in
    /// the selected notation, a stack goes as every one of its files.
    @Test func newestEntryIsWhatGetsShared() throws {
        let shot = URL(fileURLWithPath: "/tmp/archive/shot.png")
        let items: [ArchiveItem] = [
            .color(ArchiveColor(color: NSColor(hexString: "#00FF00")!, hex: "#00FF00")),
            .screenshot(ArchiveScreenshot(url: shot))
        ]
        let newest = try #require(items.first)
        #expect(NotchArchiveModel.payload(for: [newest], colorScheme: .rgb) == [.string("0 255 0")])

        let stack = ArchiveItem.stack(ArchiveStack(urls: [shot, URL(fileURLWithPath: "/tmp/archive/b.pdf")]))
        #expect(NotchArchiveModel.payload(for: [stack], colorScheme: .hex).count == 2)
    }

    @Test func rowMetadataIsFilledIn() {
        #expect(HotkeyAction.shareLastItem.labelKey == "Share Last Item")
        #expect(HotkeyAction.shareLastItem.icon == "square.and.arrow.up")
        #expect(HotkeyAction.shareLastItem.rawValue == 10)
    }

    @Test func sharingSitsWithTheOtherPanelActions() {
        #expect(HotkeyAction.shareLastItem.group == .panel)
    }

    @Test func defaultComboIsUsableAndUnreserved() {
        let combo = HotkeyAction.shareLastItem.defaultCombo
        #expect(combo.displayString == "⌃⌥⌘D")
        let result = HotkeyValidator.validate(combo, for: .shareLastItem)
        #expect(result != .systemReserved)
        #expect(result != .noStrongModifier)
    }
}

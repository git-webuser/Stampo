import Carbon.HIToolbox
import Testing
@testable import Stampo

@Suite struct HotkeyRegistrationStatusTests {
    @Test func statusDistinguishesRegisteredDisabledAndFailures() {
        #expect(HotkeyRegistrationStatus.registered.messageKey == nil)
        #expect(!HotkeyRegistrationStatus.registered.isError)
        #expect(!HotkeyRegistrationStatus.disabled.isError)
        #expect(HotkeyRegistrationStatus.conflict(OSStatus(eventHotKeyExistsErr)).isError)
        #expect(HotkeyRegistrationStatus.handlerUnavailable.isError)
    }

    /// The Carbon status is diagnostic, and it belongs in the log line that
    /// records the refusal — not in the settings pane, where a number from a
    /// 1990s API says nothing the user can act on.
    @Test func conflictKeepsCarbonStatusOutOfTheUserFacingText() {
        let status = HotkeyRegistrationStatus.conflict(OSStatus(eventHotKeyExistsErr))
        let key = status.messageKey
        #expect(key != nil)
        #expect(key?.contains(String(eventHotKeyExistsErr)) == false)
    }

    /// Every status that says something has to say it with a key the catalogue
    /// can translate, or it reaches the row in English whatever the UI language.
    @Test func everyMessageIsALocalizationKey() {
        let keys = [
            HotkeyRegistrationStatus.disabled.messageKey,
            HotkeyRegistrationStatus.conflict(OSStatus(eventHotKeyExistsErr)).messageKey,
            HotkeyRegistrationStatus.handlerUnavailable.messageKey,
        ]
        for key in keys {
            let key = try! #require(key)
            #expect(!key.isEmpty)
            #expect(LocaleManager.string(key, locale: Locale(identifier: "ru")) != key)
        }
    }
}

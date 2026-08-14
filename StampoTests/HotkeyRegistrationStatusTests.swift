import Carbon.HIToolbox
import Testing
@testable import Stampo

@Suite struct HotkeyRegistrationStatusTests {
    @Test func statusDistinguishesRegisteredDisabledAndFailures() {
        #expect(HotkeyRegistrationStatus.registered.message == nil)
        #expect(!HotkeyRegistrationStatus.registered.isError)
        #expect(!HotkeyRegistrationStatus.disabled.isError)
        #expect(HotkeyRegistrationStatus.conflict(OSStatus(eventHotKeyExistsErr)).isError)
        #expect(HotkeyRegistrationStatus.handlerUnavailable.isError)
    }

    @Test func conflictMessageKeepsCarbonStatusForDiagnostics() {
        let status = HotkeyRegistrationStatus.conflict(OSStatus(eventHotKeyExistsErr))
        #expect(status.message?.contains(String(eventHotKeyExistsErr)) == true)
    }
}

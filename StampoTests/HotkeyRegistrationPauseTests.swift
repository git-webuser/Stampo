import Testing
@testable import Stampo

/// The registrations are lifted while a shortcut field records and must come
/// back on every way a recording can end. A restore that never happens leaves
/// every global shortcut dead until quit, so the exits are what is pinned
/// down here.
@Suite struct HotkeyRegistrationPauseTests {

    @Test func startsWithTheRegistrationsInPlace() {
        let pause = HotkeyRegistrationPause()
        #expect(!pause.isPaused)
        #expect(pause.allowsRegistrationChanges)
    }

    @Test func recordingLiftsTheRegistrationsOnceAndEndingBringsThemBack() {
        var pause = HotkeyRegistrationPause()

        #expect(pause.recordingBegan() == .lift)
        #expect(pause.isPaused)

        #expect(pause.recordingEnded() == .restore)
        #expect(!pause.isPaused)
    }

    /// Callers that register on their own schedule — the defaults observer, the
    /// wake-up check — have to stay out for the whole recording and be let
    /// back in the moment it ends.
    @Test func registrationChangesAreForbiddenExactlyWhileRecording() {
        var pause = HotkeyRegistrationPause()
        #expect(pause.allowsRegistrationChanges)

        _ = pause.recordingBegan()
        #expect(!pause.allowsRegistrationChanges)

        _ = pause.recordingEnded()
        #expect(pause.allowsRegistrationChanges)
    }

    /// Moving from one field to the next posts "stopped" and "started" in
    /// either order. Neither order may bring the registrations back while a
    /// field is still recording.
    @Test func switchingFieldsKeepsThePauseWhicheverNoticeComesFirst() {
        var stopFirst = HotkeyRegistrationPause()
        _ = stopFirst.recordingBegan()
        #expect(stopFirst.recordingEnded() == .restore)
        #expect(stopFirst.recordingBegan() == .lift)
        #expect(stopFirst.isPaused)

        var startFirst = HotkeyRegistrationPause()
        _ = startFirst.recordingBegan()
        #expect(startFirst.recordingBegan() == .unchanged)   // second field armed
        #expect(startFirst.recordingEnded() == .unchanged)   // first one let go
        #expect(startFirst.isPaused)
        #expect(startFirst.recordingEnded() == .restore)
        #expect(!startFirst.isPaused)
    }

    /// Every exit of a recording posts "stopped" once — accepted combo, Esc, a
    /// click outside, Tab away, the view disappearing. A second one for the
    /// same recording must not push the count below zero and break the next.
    @Test func aStrayStoppedNoticeChangesNothing() {
        var pause = HotkeyRegistrationPause()
        #expect(pause.recordingEnded() == .unchanged)
        #expect(!pause.isPaused)

        // …and the next recording still lifts and restores normally.
        #expect(pause.recordingBegan() == .lift)
        #expect(pause.recordingEnded() == .restore)
    }

    @Test func closingSettingsMidRecordingBringsTheRegistrationsBack() {
        var pause = HotkeyRegistrationPause()
        _ = pause.recordingBegan()

        #expect(pause.settingsDidClose() == .restore)
        #expect(!pause.isPaused)
        #expect(pause.allowsRegistrationChanges)

        // The recorder's view may still report "stopped" after the close.
        #expect(pause.recordingEnded() == .unchanged)
        #expect(!pause.isPaused)
    }

    @Test func closingSettingsClearsEveryRecorderNotJustOne() {
        var pause = HotkeyRegistrationPause()
        _ = pause.recordingBegan()
        _ = pause.recordingBegan()

        #expect(pause.settingsDidClose() == .restore)
        #expect(!pause.isPaused)
    }

    /// Settings closes all the time without a recording; the controller
    /// re-registers on that notification only when something was lifted.
    @Test func closingSettingsWithoutARecordingChangesNothing() {
        var pause = HotkeyRegistrationPause()
        #expect(pause.settingsDidClose() == .unchanged)
        #expect(!pause.isPaused)
    }

    @Test func resetForgetsTheRecordersWithoutAskingForAnything() {
        var pause = HotkeyRegistrationPause()
        _ = pause.recordingBegan()
        pause.reset()
        #expect(!pause.isPaused)
        #expect(pause.recordingEnded() == .unchanged)
    }
}

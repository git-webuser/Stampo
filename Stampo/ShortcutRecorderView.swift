import SwiftUI
import AppKit

// MARK: - Shake effect

/// Horizontal shake driven by an incrementing trigger — used to reject an
/// invalid combo with a quick wiggle.
private struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        let dx = sin(animatableData * .pi * 3) * 5
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}

// MARK: - ShortcutRecorderView

/// Click- or key-to-record shortcut field, styled with the app's key caps.
/// Inspired by Snapzy's ShortcutRecorderView (BSD 3-Clause), rebuilt on
/// Stampo's KeyCapView and HotkeyValidator.
struct ShortcutRecorderView: View {
    let action: HotkeyAction
    let combo: HotkeyCombo?
    /// Called with the accepted combo (nil = cleared/disabled).
    let onChange: (HotkeyCombo?) -> Void

    @State private var isRecording = false
    @State private var rejectionKey: String?
    @State private var shake: CGFloat = 0
    @State private var monitor: Any?
    @State private var clickMonitor: Any?
    @FocusState private var isFocused: Bool

    /// Field width measured while the × button is present. When the shortcut is
    /// cleared the × disappears, so the field grows to (this + gap + ×) and the
    /// overall block width stays put.
    @State private var widthWithButton: CGFloat = 96

    private let buttonGap: CGFloat = 8
    private let buttonWidth: CGFloat = 16

    private var showsClearButton: Bool { combo != nil && !isRecording }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: buttonGap) {
                recorderField
                if showsClearButton {
                    Button {
                        onChange(nil)            // clear → disabled
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Remove shortcut"))
                    // The glyph is the whole label, so it is also the whole
                    // thing VoiceOver has to go on: unnamed it reads out as
                    // "xmark circle fill".
                    .accessibilityLabel(Text("Remove shortcut"))
                }
            }

            if let rejectionKey {
                Text(LocalizedStringKey(rejectionKey))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    // MARK: Field

    @ViewBuilder
    private var recorderField: some View {
        let content = HStack(spacing: 3) {
            if isRecording {
                Text("Press keys…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else if let combo {
                ForEach(Array(combo.displayCaps.enumerated()), id: \.offset) { _, cap in
                    KeyCapView(key: cap)
                }
            } else {
                Text("None")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(5)
        .frame(minWidth: 96, minHeight: 38)
        // When the × is gone, take over its footprint so nothing collapses.
        .frame(width: showsClearButton ? nil : widthWithButton + buttonGap + buttonWidth)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { captureWidth(geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in captureWidth(w) }
            }
        )
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(borderColor, lineWidth: isRecording || rejectionKey != nil ? 2 : 1)
        )
        // Focus ring, drawn rather than inherited: the field is a plain shape
        // with its own corner radius and border, and the system effect lands
        // on the rectangle around it. `focusEffectDisabled` below keeps the
        // two from stacking.
        //
        // The halo is the whole focus signal — the border above stays neutral.
        // Tinting it accent as well reads as the armed state, which is exactly
        // what a focused-but-not-recording field is not.
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 3)
                .padding(-2)
                .opacity(isFocused ? 1 : 0)
        )
        .modifier(Shake(animatableData: shake))

        content
            .onTapGesture {
                isFocused = true
                toggleRecording()
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            // Space and Return arm the field; from there the local monitor
            // owns the keyboard, so Escape — which it already handles — is
            // what backs out. Both keys are swallowed while recording, so
            // there is no second meaning to disambiguate here.
            .onKeyPress(.space) { toggleRecording(); return .handled }
            .onKeyPress(.return) { toggleRecording(); return .handled }
            // Tabbing away has to disarm: the monitor is global to the app and
            // would otherwise keep swallowing keys for a field the user left.
            .onChange(of: isFocused) { _, focused in
                if !focused { stopRecording() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabelText)
            .accessibilityValue(accessibilityValueText)
            .accessibilityHint(Text("Press Space to record a shortcut, Escape to cancel"))
            .accessibilityAddTraits(.isButton)
    }

    /// The row's own title is not part of this control, and until SettingRow
    /// groups itself for VoiceOver the field is announced on its own — so it
    /// names the action it binds.
    private var accessibilityLabelText: Text {
        let name = String(localized: String.LocalizationValue(action.labelKey))
        return Text("\(name) shortcut")
    }

    private var accessibilityValueText: Text {
        if isRecording { return Text("Press keys…") }
        if let combo { return Text(combo.spokenDescription) }
        return Text("None")
    }

    /// Remember the field width only while the × is showing — that's the size to
    /// preserve (plus the button footprint) once it's cleared.
    private func captureWidth(_ w: CGFloat) {
        if showsClearButton { widthWithButton = w }
    }

    private var borderColor: Color {
        if rejectionKey != nil { return .red }
        if isRecording { return .accentColor }
        return Color(nsColor: .separatorColor)
    }

    // MARK: Recording lifecycle

    private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        rejectionKey = nil
        NotificationCenter.default.post(name: .hotkeyRecordingChanged, object: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil   // swallow while recording so nothing types/acts
        }
        // Clicking anywhere else cancels recording.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            DispatchQueue.main.async { self.stopRecording() }
            return event
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        rejectionKey = nil
        NotificationCenter.default.post(name: .hotkeyRecordingChanged, object: false)
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        monitor = nil
        clickMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .keyDown else { return }   // ignore bare modifier changes

        // Escape cancels recording (and is never bindable here).
        if event.keyCode == KeyCode.escape {
            stopRecording()
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let candidate = HotkeyCombo(keyCode: event.keyCode, modifierFlags: flags)

        switch HotkeyValidator.validate(candidate, for: action) {
        case .valid:
            onChange(candidate)
            stopRecording()
        case let result:
            rejectionKey = result.reasonKey
            withAnimation(.linear(duration: 0.3)) { shake += 1 }
            // stay armed for another try
        }
    }
}

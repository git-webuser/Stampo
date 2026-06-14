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

/// Click-to-record shortcut field, styled with the app's key caps.
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
        .modifier(Shake(animatableData: shake))

        content.onTapGesture { toggleRecording() }
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

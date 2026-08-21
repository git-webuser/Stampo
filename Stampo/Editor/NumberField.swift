import AppKit
import SwiftUI

/// A number field whose value lives in the *placeholder*, so the editable
/// text is always empty and typing starts a fresh number.
///
/// Three attempts at selecting the text on click failed for the same
/// reason: `mouseDown` runs its own tracking loop and sets the selection
/// when the button comes back up, after anything the app chose. Rather than
/// race that, there is simply nothing to select — the number is drawn as a
/// placeholder in the ordinary label colour, so it reads as a value while
/// behaving like an empty field. Confirming a number puts it back into the
/// placeholder and empties the text again.
struct NumberField: NSViewRepresentable {
    @Binding var value: Double
    var alignment: NSTextAlignment = .right
    var onCommit: (Double) -> Void

    final class Field: NSTextField {
        /// The number goes the moment editing starts. Overridden on the
        /// field rather than handled through the delegate: this is the
        /// control's own hook and it fires whether or not anything else is
        /// listening — the delegate route left the placeholder standing.
        /// The number is ordinary text, and taking the keyboard empties it:
        /// the field editor is installed *after* this, so it starts on an
        /// empty string and the first keystroke begins a new number. No
        /// placeholder is involved — a placeholder that survives the click
        /// looks like text you could edit, and it is not.
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                stringValue = ""
                watchForClicksOutside()
            }
            return accepted
        }

        /// Editing is over however it ended — Return, Escape, a click
        /// elsewhere — so this is where the watch stops.
        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            stopWatchingForClicksOutside()
        }

        private var clicksOutside: Any?

        /// A click beside the field used to leave it editing: almost
        /// nothing in a SwiftUI panel takes the keyboard when clicked, so
        /// nobody took it away from the field and the number stayed
        /// uncommitted with the field still empty. Watching the window's
        /// own clicks is the only place that sees all of them — sliders,
        /// tiles, plain labels and the panel's background alike.
        private func watchForClicksOutside() {
            guard clicksOutside == nil else { return }
            clicksOutside = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                // The event is returned untouched: this ends the editing
                // session, it does not swallow the click that ended it.
                guard let self, let window = self.window, event.window === window
                else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                if !self.bounds.contains(point) { window.makeFirstResponder(nil) }
                return event
            }
        }

        private func stopWatchingForClicksOutside() {
            if let clicksOutside { NSEvent.removeMonitor(clicksOutside) }
            clicksOutside = nil
        }

        func show(_ number: Double) {
            stringValue = Self.formatter.string(from: NSNumber(value: number))
                ?? String(Int(number))
        }

        static let formatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.numberStyle = .none
            formatter.usesGroupingSeparator = false
            formatter.maximumFractionDigits = 0
            return formatter
        }()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onCommit: (Double) -> Void = { _ in }
        var current: Double = 0

        /// An empty field means "unchanged": clicking in clears the number,
        /// and leaving without typing must not rewrite it.
        private func commit(_ field: NSTextField) {
            let typed = field.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // A decimal comma is what a Russian keyboard produces, and
            // `Double.init` only reads a point — without this, a fractional
            // number typed on that layout silently did nothing.
            if !typed.isEmpty,
               let value = Double(typed.replacingOccurrences(of: ",", with: ".")) {
                onCommit(value)
            }
            repaint(field)
        }

        /// The field goes back to showing the model — one runloop hop later.
        ///
        /// `current` is written by `updateNSView`, which runs *after* the
        /// commit has travelled through the document and back. Drawing it
        /// inline therefore drew the number from before the edit: that is
        /// what made Return look like it threw the typed value away, even
        /// though the model had taken it.
        private func repaint(_ field: NSTextField) {
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field = field as? Field else { return }
                // Not if the keyboard came back in the meantime — the field
                // is then showing something the user is in the middle of.
                guard field.currentEditor() == nil,
                      field.window?.firstResponder !== field else { return }
                field.show(self.current)
            }
        }

        /// Return.
        @objc func changed(_ sender: NSTextField) {
            commit(sender)
            // Give the keyboard back, so the value on screen is the model's
            // again and the next click starts a fresh number.
            sender.window?.makeFirstResponder(nil)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }

        /// Escape: leave without changing anything.
        ///
        /// The field is empty from the moment it takes the keyboard, so
        /// AppKit's own abort has nothing to put back — the number is
        /// redrawn from the model here instead. Nothing is committed on
        /// this path, which is the whole point of Escape.
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            let value = current
            // Not inside the command: tearing the field editor down while
            // it is dispatching its own command is how AppKit ends up
            // waiting on itself.
            DispatchQueue.main.async { [weak control] in
                guard let field = control as? Field else { return }
                field.abortEditing()
                field.show(value)
                field.window?.makeFirstResponder(nil)
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        // `isBezeled`, not `isBordered`: a plain border draws the square box
        // that replaced the panel's rounded fields.
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.alignment = alignment
        // Match the rest of the panel's controls, which are all large.
        field.controlSize = .large
        field.font = .monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .large), weight: .regular
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.current = value
        field.alignment = alignment
        // Never disturb a field that has the keyboard — including the
        // moment after the click when its editor is not installed yet.
        guard field.currentEditor() == nil,
              field.window?.firstResponder !== field else { return }
        field.show(value)
    }
}

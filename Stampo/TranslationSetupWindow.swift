import AppKit
import SwiftUI

// MARK: - TranslationSetupWindowController

/// The window that explains translation and sets it up.
///
/// A window rather than a state on the panel, and that is the whole point:
/// `prepareTranslation()` presents its download sheet only from a real titled
/// window — measured on 15.7, from the borderless panel it returns in ten
/// milliseconds having shown nothing. Every earlier sketch of this feature was
/// an attempt to lead the user from the panel to somewhere a sheet could
/// attach. Opening such a window *is* that somewhere, so there is no journey
/// left to design.
///
/// Modelled on `FirstLaunchWindowController` down to the chrome, but not
/// reusing it: that one mutes permission alerts, closes Settings and posts
/// `.onboardingWindowClosed` on the way out, which releases deferred launch
/// work. None of that belongs to a language download.
@MainActor
final class TranslationSetupWindowController: NSObject, NSWindowDelegate {
    static let shared = TranslationSetupWindowController()
    private var window: NSWindow?

    /// True while the window is up, so a second trigger raises the one that is
    /// already open instead of stacking another.
    var isWindowOpen: Bool { window != nil }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: TranslationSetupView().managedLocale())
        hosting.sizingOptions = .preferredContentSize

        let win = TranslationSetupWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = LocaleManager.shared.string("Set up translation")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isReleasedWhenClosed = false
        // Transparent through the first layout pass: the preferred height is
        // not final until then, and revealing it earlier shows the window
        // jumping from AppKit's placeholder origin to the centre.
        win.alphaValue = 0
        win.delegate = self
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.window = win

        DispatchQueue.main.async { [weak win] in
            guard let win else { return }
            win.contentView?.layoutSubtreeIfNeeded()
            win.centerOnPointerScreen()
            win.alphaValue = 1
        }
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) { window = nil }

    func windowDidResize(_ notification: Notification) {
        (notification.object as? NSWindow)?.keepOnScreen()
    }
}

/// Esc closes it, the way the title-bar button does — the same arrangement the
/// wizard uses, and for the same reason: the only button here is the primary
/// one, so `.cancelAction` has nowhere to live.
private final class TranslationSetupWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

// MARK: - TranslationSetupView

/// What the window says, and the controls that fix it.
///
/// The controls are `TranslationSettingsSection` itself rather than a second
/// copy of them. There is one list of languages, one install button per row and
/// one place that knows how to run a download; showing a rebuilt version here
/// would be two things to keep in step, and the first release where they
/// disagreed would be the one nobody could explain.
struct TranslationSetupView: View {
    private var languages: TranslationLanguages { TranslationLanguages.shared }

    /// Room for the rows the section will draw: one per language, one to add
    /// another, and the primary-language row once there are more than two.
    /// Clamped so a long list scrolls instead of growing the window past the
    /// screen.
    private var formHeight: CGFloat {
        let rows = languages.favourites.count + 1 + (languages.offersChoice ? 1 : 0)
        return min(300, 52 + CGFloat(rows) * 52)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "translate")
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(.tint)

                Text("Set up translation")
                    .font(.title.bold())

                Text("Translation runs on your Mac and needs two languages before it can start. macOS downloads each one once — usually a few hundred megabytes — and nothing leaves the machine afterwards.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 420)
            }
            .padding(.top, 26)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)

            Form {
                Section {
                    TranslationSettingsSection(isInsideSetupWindow: true)
                }
            }
            .formStyle(.grouped)
            // A Form is a scroll view: left alone it claims a screen's worth of
            // height, and this window sizes itself to its content, so the
            // height has to be stated. Counted from the rows rather than fixed
            // — a single language under a 260pt frame left a third of the
            // window empty, which read as something failing to load.
            .frame(height: formHeight)

            HStack {
                Spacer()
                Button {
                    TranslationSetupWindowController.shared.close()
                } label: {
                    Text("Done").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .padding(.top, 4)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await languages.refresh() }
    }
}

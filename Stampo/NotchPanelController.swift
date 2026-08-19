import AppKit
import SwiftUI

// MARK: - Panel timing constants

/// Animation durations and dispatch delays used throughout NotchPanelController.
/// Centralised here so every phase of the open/close/morph choreography is
/// documented and easy to tune without hunting for magic numbers.
/// Runs `body` on the main actor, synchronously when it is already there.
///
/// `MainActor.assumeIsolated` on its own is a precondition: it traps instead of
/// hopping, and AppKit does not promise which thread an animation completion
/// arrives on. Running *synchronously* is what these completions need — a
/// deferred one opened the gap that swallowed delayed captures — so take that
/// when it is available and hop rather than crash when it is not.
/// `nonisolated` because its callers are AppKit completion handlers, which are
/// not: the project defaults to MainActor isolation, and inheriting it here
/// would make the very hop this exists to perform a warning at every call site.
nonisolated private func onMainActorNow(_ body: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { body() }
    } else {
        Task { @MainActor in body() }
    }
}

enum PanelTiming {
    /// Panel reveal (frame descent + content fade-in, decelerate curve).
    static let openAnimation:       TimeInterval = 0.30
    /// Panel close / content fade-out before an archive→main morph (accelerate curve).
    static let hideAnimation:       TimeInterval = 0.22
    /// Countdown / archive-content crossfade (easeOut).
    static let crossfade:           TimeInterval = 0.16
    /// One-frame settle: lets SwiftUI process a visibility change before
    /// starting the shape morph that follows it.
    static let oneFrameSettle:      TimeInterval = 0.03
    /// Body content fading out before an expanded route collapses. Long enough
    /// to read as a dissolve rather than a disappearance, short enough that
    /// the close still feels like one gesture.
    static let contentDissolve:     TimeInterval = 0.12
    /// Body content fading in once an expanded route has finished opening.
    /// Slower than the dissolve: arriving deserves more ceremony than leaving.
    static let contentReveal:       TimeInterval = 0.18
    /// How much longer the shape keeps moving after the window's frame
    /// animation reports done. The frame is driven by `NSAnimationContext`
    /// and the height by a SwiftUI spring, and a spring is still travelling
    /// when its response has elapsed — so anything waiting on the frame is
    /// early by roughly this much.
    static let morphTail:           TimeInterval = 0.12
    /// The shape settling between two expanded routes. Shorter than the spring
    /// that drives it: the body may reappear while the last of the travel is
    /// still easing out, and waiting for the spring to be arithmetically done
    /// reads as a pause.
    static let routeSwapMorph:      TimeInterval = 0.26
    /// Full archive-open/close morph (shape + position).
    static let archiveCloseMorph:      TimeInterval = 0.32
    /// Delay between showAnimated() and switchToArchive() so the open
    /// animation has a head-start before archive content appears.
    static let showBeforeArchive:      TimeInterval = 0.25
    /// The panel widening or narrowing because the delay label changed length.
    /// The symbol and digits leave and return around it on `crossfade`, the
    /// same easeOut the countdown arrives on — one way of appearing inside this
    /// panel rather than a second one invented for the timer cell.
    /// Short: it answers a click on a menu item, and anything slower reads as
    /// the panel thinking about it. Used by the timer cell and the window frame
    /// alike — they are two halves of one motion and must share a duration.
    ///
    /// Driven linearly at both ends, which is the one curve the two animation
    /// systems agree on. SwiftUI and Core Animation sample an eased curve
    /// differently enough that the content and the window drift apart in the
    /// middle of the travel even when their control points match — visible
    /// here as the background lagging the buttons and catching up.
    static let delayWidthMorph:        TimeInterval = 0.16
    /// The timer cell's glyphs dissolving and returning around a value change.
    ///
    /// Its own number rather than `crossfade`, which it started out sharing:
    /// that one also times the countdown's own arrival, and tuning the feel of
    /// the timer cell should not quietly retime a different animation.
    ///
    /// Between the panel's 0.16 crossfade and the 0.35 the countdown's digits
    /// blur-replace each other on — the effect this is imitating. Slow enough
    /// to read as a dissolve, short enough that a widening change (travel, out,
    /// in) still lands well under a second.
    static let delayGlyphFade:         TimeInterval = 0.24
    /// The timer cell's highlight leaving, before anything else moves.
    ///
    /// It goes first rather than last. Held through the resize it is a lit
    /// plate being stretched — and it is drawn by SwiftUI inside a window whose
    /// frame Core Animation is moving at the same time, so it visibly trails
    /// the edge it is supposed to fill. Gone before the travel starts, there is
    /// nothing to trail: the button widens unlit and the glyphs arrive into it.
    ///
    /// Shared with the hover fade on the cell itself, which is the same plate
    /// appearing and disappearing for the same reason.
    static let delayHighlightRelease:  TimeInterval = 0.12

    // MARK: Shared easing curves

    /// Smooth deceleration — quick off the mark, gentle settle. Reveals / opens.
    static let decelerate = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.2, 1.0)
    /// Smooth acceleration — soft start, quick finish. Closes / retractions
    /// where the panel leaves the screen (the hard stop is masked by orderOut).
    static let accelerate = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.9, 0.6)
    /// Soft-landing ease-in-out for morphs that end on-screen: matches the
    /// gentle settle of the Y-axis spring so X and Y arrive together.
    static let settle = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)

    /// SwiftUI twin of `accelerate`, for `withAnimation` on shape progress so
    /// the morph reads as one motion with the window frame.
    static func accelerateSwift(_ d: TimeInterval) -> Animation { .timingCurve(0.4, 0.0, 0.9, 0.6, duration: d) }

    /// Content fade-in during panel open. Delayed so the buttons appear once
    /// the GeometryReader shoulders are near final width — fading them in
    /// earlier shows the squeezed mid-expansion layout ("chewed" look).
    /// Ends together with the 0.30s frame animation.
    static var contentFadeIn: Animation { .easeOut(duration: 0.20).delay(0.10) }
    /// Content fade-out on close: fast, so the content is gone before the
    /// collapsing frame starts squeezing the layout (accelerate moves the
    /// frame slowly at first, giving the fade a head start).
    static var contentFadeOut: Animation { .easeOut(duration: 0.12) }
}

// MARK: - Interaction state

@Observable final class NotchPanelInteractionState {
    var isEnabled: Bool = true
    var contentVisibility: Double = 1.0
}

// MARK: - Root state

/// `nonisolated` because the project defaults every type to the main actor,
/// which would isolate the synthesized `Equatable` too — and this gets compared
/// inside `NSAnimationContext` completion handlers, which are not isolated.
/// Swift 6 turns that from a warning into an error.
nonisolated enum NotchPanelRoute {
    case main
    case archive
    case translate
    case cdwn
}

/// Identity of work scheduled during a panel transition. The animation
/// generation catches ordinary show/hide/morph races; the binding UUID also
/// invalidates callbacks when WindowServer gives us a newly-created panel
/// after sleep, display reconfiguration, or a Space rebind.
nonisolated struct PanelTransitionToken: Equatable, Sendable {
    let generation: Int
    let bindingID: UUID
}

// MARK: - Panel state machine

/// Drives the controller through every visible phase of the panel.
/// `route` (in `NotchPanelRootState`) continues to feed the SwiftUI morph
/// animations; `PanelState` is the controller-side authority that
/// replaces the old isExpanded/archiveTransitionInFlight flag pair.
enum PanelState {
    case hidden
    case showing
    case main
    case transitioning(to: TransitionTarget)
    case archive
    case translate
    case hiding
    case countdown
    /// A translation is running and the panel is showing the wait. Its own
    /// state because the panel must not auto-hide out from under it: it was
    /// raised by the app, not by the pointer, so the pointer is nowhere near
    /// it and the ordinary "mouse left" rule would close it mid-thought.
    case translating
    /// Panel hidden, an external selection overlay (rect or window) is up.
    /// The overlay session is part of the panel lifecycle so the hover
    /// controller knows to suppress auto-close while it's active.
    case preSelection(OverlayKind)
    /// WindowServer / Spaces binding is stale (sleep, wake, display
    /// reconfiguration, or a Space switch while hidden). The next show
    /// must rebind, and the hover controller cannot trust panel.isVisible.
    case stale(reason: StaleReason)
}

enum TransitionTarget { case archive, translate, main }
enum OverlayKind { case selection, window }
enum StaleReason { case sleep, spaceChange, displayChange }

extension PanelState {
    /// True when the panel is at rest and visible, or in transit between
    /// visible states. The hover controller uses this to decide whether
    /// an outside click should auto-close the panel.
    var allowsAutoHide: Bool {
        switch self {
        case .transitioning, .countdown, .translating, .preSelection: return false
        case .hidden, .showing, .main, .archive, .translate, .hiding, .stale: return true
        }
    }

    /// True while a Space/sleep/display rebind is pending. Replaces the
    /// old `needsSpaceRebind` flag.
    var isStale: Bool {
        if case .stale = self { return true }
        return false
    }

    /// Whether the panel should hold the Esc hotkey right now.
    ///
    /// Registration consumes Esc application-wide, so it may only be held in
    /// states where the panel is on screen to act on it. `.hiding` is excluded
    /// — the panel is already going away, and the key should return to the
    /// system as early as possible. A share sheet takes it back too: the sheet
    /// is a window of ours, so a registered hotkey would swallow the Esc meant
    /// to dismiss it and close the panel out from under the sheet instead.
    func wantsEscapeHotkey(isSharePickerOpen: Bool) -> Bool {
        guard !isSharePickerOpen else { return false }
        switch self {
        case .showing, .main, .archive, .translate, .countdown, .translating: return true
        case .hidden, .transitioning, .hiding, .preSelection, .stale: return false
        }
    }

    /// Whether the panel may hold ⇥ right now.
    ///
    /// Only the two routes with a list in their header: the archive's colour
    /// format and the translator's language. Everything else — Main, the
    /// countdown, the wait, and every state where the panel is leaving or gone
    /// — hands the key back, because holding it consumes ⇥ for every app on
    /// the machine and the panel can be pinned open indefinitely.
    ///
    /// Being in one of these states is necessary, not sufficient: the view
    /// pushes the owner only while the pointer is also on the panel, the way
    /// Space is only held over a cell.
    var wantsCycleHotkey: Bool {
        switch self {
        case .archive, .translate: return true
        case .hidden, .showing, .main, .transitioning, .hiding,
             .countdown, .translating, .preSelection, .stale: return false
        }
    }

    /// Which layer Esc unwinds — one press, one layer, innermost first.
    ///
    /// Inside the archive that is the ladder in `archiveUnwindStep`: an
    /// expanded stack, then a selection in progress, then the panel itself.
    /// The back chevron climbs the same ladder; they differ only at the
    /// bottom, where Esc closes the panel outright and Back returns to Main.
    /// Nothing below that: a further press before the panel disappears would
    /// undo the "Esc means gone" reflex.
    func escapeAction(hasExpandedStack: Bool,
                      isSelecting: Bool,
                      translateCameFromArchive: Bool) -> EscapeAction {
        if case .archive = self {
            switch archiveUnwindStep(hasExpandedStack: hasExpandedStack, isSelecting: isSelecting) {
            case .collapseStack: return .collapseStack
            case .exitSelection: return .exitSelection
            case .leaveArchive:  return .hidePanel
            }
        }
        // Reading an archive entry in the Translator is a layer over the
        // archive, like the expanded stack is: Esc puts it back rather than
        // taking the panel with it, the same way it behaves over Quick Look.
        if case .translate = self, translateCameFromArchive { return .backToArchive }
        return .hidePanel
    }
}

/// What a press of Esc does at a given moment (see `PanelState.escapeAction`).
enum EscapeAction: Equatable {
    case collapseStack
    case exitSelection
    case backToArchive
    case hidePanel
}

@Observable final class NotchPanelRootState {
    var route: NotchPanelRoute = .main
    var metrics: NotchMetrics = .fallback()
    /// 0.0 = Main, 1.0 = Archive
    var progress: CGFloat = 0.0
    /// Whatever the current route puts in the body — archive cells or the
    /// translation. Pre-faded to 0.0 before the morph back to Main starts and
    /// reset to 1.0 once the close completes, so content is gone before the
    /// panel starts squeezing the layout it was laid out in.
    var routeContentVisible: CGFloat = 1.0
    /// 0.0 = Main visible, 1.0 = Countdown visible (crossfade, no morph)
    var countdownVisible: CGFloat = 0.0
    var countdownSeconds: Int = 0
    var countdownTotal: Int = 0
    var isArchivePinned: Bool = false
    /// 0 = Main visible, 1 = the "translating" strip's contents visible.
    /// Crossfaded over Main without a morph, exactly as the countdown is.
    var translatingVisible: CGFloat = 0.0
    /// Whether the panel is *shaped* as the strip — its own width and its own
    /// fixed-radius outline. Separate from the opacity above because the two
    /// have to move at different moments: the glyphs dissolve first, and only
    /// once they are gone does the panel stop being a strip and start morphing
    /// into the Translator. Sharing one value snapped them away at the instant
    /// the morph began.
    var translatingStripVisible: Bool = false
}

private struct NotchPanelRootView: View {
    var rootState: NotchPanelRootState
    var interaction: NotchPanelInteractionState
    var model: NotchPanelModel
    var archiveModel: NotchArchiveModel
    var archiveExpansion: ArchiveExpansionState
    var archiveSelection: ArchiveSelectionState
    let shareAnchor: SharePickerAnchor

    let onClose: () -> Void
    let onCapture: (CaptureMode, CaptureDelay) -> Void
    let onToggleArchive: () -> Void
    let onPickColor: () -> Void
    let onScan: () -> Void
    let onModeDelayChanged: () -> Void
    let onBack: () -> Void
    let onLeaveTranslate: () -> Void
    let onPreviewText: (String) -> Void
    let onPickLanguage: (String, Locale.Language) -> Void
    let onHidePanel: () -> Void
    let onTogglePin: () -> Void
    let onStopCountdown: () -> Void
    let onCaptureNow: () -> Void
    let onCycleHeader: (_ backwards: Bool) -> Void

    /// Whether ⇥ is claimed right now. Shared with the colour picker's own F,
    /// because the setting governs one idea — step to the next one — and the
    /// user should not have to find two switches for it.
    @AppStorage(AppSettings.Keys.hotkeyHUDFormatEnabled) private var cycleEnabled = true
    @State private var isPointerInside = false
    @State private var tabToken: UUID?
    @State private var shiftTabToken: UUID?

    private var m: NotchMetrics { rootState.metrics }
    private var archiveScrollHeight: CGFloat { 55 }
    private var archiveH: CGFloat { m.panelHeight + archiveScrollHeight }
    private var translateH: CGFloat { m.panelHeight + TranslationPanelModel.shared.bodyHeight }
    private var p: CGFloat { rootState.progress }

    /// How tall the panel is once this route has finished opening.
    private var routeH: CGFloat {
        rootState.route == .translate ? translateH : archiveH
    }

    /// The window is as tall as the tallest route, and every shorter one is
    /// simply drawn at the top of it. Sizing the window per route would mean
    /// animating the frame on every transition, which is exactly what the
    /// progress-driven morph exists to avoid.
    private var windowH: CGFloat {
        max(archiveH, m.panelHeight + NotchTranslateView.maxBodyHeight)
    }

    /// What the morph shape has to grow beyond the archive to reach this
    /// route's height. Negative for a translation shorter than an archive row,
    /// which is the common case for a sentence.
    private var extraH: CGFloat { routeH - archiveH }

    /// Carries the panel between two routes that are both fully open.
    ///
    /// Named rather than written twice: the notch shape animates `extraH` and
    /// the notch-less ones animate `routeH`, but it is one movement and the
    /// two must not drift apart. They already had — only the notch branch ever
    /// had a spring, so on a notch-less screen archive ⇄ Translator snapped.
    private static let routeHeightSpring = Animation.spring(response: 0.38,
                                                            dampingFraction: 0.88)

    /// The panel is showing the wait rather than any route.
    private var isTranslating: Bool { rootState.translatingStripVisible }

    var body: some View {
        // Notch style on a notch-less screen renders the whole panel at its 34pt
        // design size, then scales it uniformly (shape, buttons, fonts, paddings)
        // to fit the menu bar. The window frame is scaled to match in the
        // controller's frame* helpers. Real notch / rounded use panelScale == 1
        // and the unscaled path — no behaviour change.
        let s = m.panelScale
        if s == 1 {
            panelStack
        } else {
            GeometryReader { geo in
                panelStack
                    .frame(width: geo.size.width / s, height: geo.size.height / s, alignment: .top)
                    .scaleEffect(s, anchor: .topLeading)
            }
        }
    }

    private var panelStack: some View {
        // Panel content height at the current morph progress (Main → Archive).
        // Drives the no-notch background height and clips the archive content so its
        // lower rows are revealed in step with the growing panel — not before it
        // has opened.
        let revealH = m.panelHeight + p * (routeH - m.panelHeight)
        return ZStack(alignment: .top) {
            // Owns the translation session for the whole app. Draws nothing and
            // takes no space — it is here because a `TranslationSession` can
            // only be obtained from a view modifier, and this root is the one
            // view that is mounted for as long as the panel exists.
            TranslationHost()

            // Background. Only the real notch uses the morphing notch keyframes
            // (its viewBox flares blend into the physical notch). Notch-less
            // screens use fixed-radius shapes that grow in height with the archive
            // morph — so corners never distort the way the 536-wide keyframes do
            // when squished onto a narrow panel:
            //   • notch style: pinned to the top edge → square top corners flush
            //     with the screen edge, rounded bottom corners (a clean "tab").
            //   • rounded style: a full rounded rectangle below the menu bar.
            if isTranslating {
                // Fixed radii, drawn at whatever width the strip is. The morph
                // keyframes are an X-scaled 536-wide viewBox, and at the
                // strip's width their corners come out half as wide as they
                // are tall — the same distortion the no-notch styles avoid.
                //
                // Which shape, though, is the same question the resting panel
                // answers below: a tab where the panel meets the screen edge, a
                // rounded rectangle where it floats. Drawing the tab either way
                // put tapered shoulders on a pill for as long as a translation
                // was loading, so the panel changed shape and changed back.
                Group {
                    if m.pinnedToTopEdge {
                        NotchTabShape().fill(Color.black)
                    } else {
                        RoundedRectangle(cornerRadius: m.panelRadius, style: .continuous)
                            .fill(Color.black)
                    }
                }
                .frame(height: m.panelHeight)
                .frame(height: windowH, alignment: .top)
            } else if m.hasNotch {
                PanelMorphShape(progress: p, pixel: m.pixel, extraHeight: extraH)
                    .fill(Color.black)
                    .compositingGroup()
                    .frame(height: windowH, alignment: .top)
                    // Height is animated in its own right, not carried by the
                    // morph: archive and translator are both at progress 1, so
                    // between them there is no progress left to animate — and a
                    // translation that resizes to fit its text has to travel
                    // too. The corners ride along, they never stretch.
                    .animation(Self.routeHeightSpring, value: extraH)
            } else {
                Group {
                    if m.pinnedToTopEdge {
                        // Notch tab with the notch's tapering bottom shoulders.
                        NotchTabShape()
                            .fill(Color.black)
                    } else {
                        RoundedRectangle(cornerRadius: m.panelRadius, style: .continuous)
                            .fill(Color.black)
                    }
                }
                .frame(height: revealH)
                .frame(height: routeH, alignment: .top)
                // Same movement the notch shape gets from its own spring: at
                // progress 1 there is no progress left to animate, so archive ⇄
                // Translator is a pure change of height and nothing else would
                // carry it.
                .animation(Self.routeHeightSpring, value: routeH)
            }

            // Main — visible only in the last ~60% of the morph; hidden during countdown
            NotchPanelView(
                metrics: m,
                interaction: interaction,
                model: model,
                isArchiveOpen: rootState.route == .archive,
                onClose: onClose,
                onCapture: onCapture,
                onToggleArchive: onToggleArchive,
                onPickColor: onPickColor,
                onScan: onScan,
                onModeDelayChanged: onModeDelayChanged
            )
            // The Translator is never opened *from* Main — it is reached from
            // the wait, from the archive, or from nothing at all. Main is
            // therefore not the thing being left behind, and showing it while
            // the panel grows put a row of buttons on screen that flashed once
            // and left: nobody had been looking at them, and nobody asked for
            // them. Every other route still fades Main out as it opens over it.
            // Held back by the strip's geometry, not by its opacity. The
            // glyphs dissolve first and the route flips only once they are
            // gone — so a factor tied to the fading opacity climbs back to 1
            // during that gap and let Main through it, capture button and all.
            // The geometry flag spans the whole handoff and clears in the same
            // update that sets the route, leaving no frame in between.
            .opacity(max(0.0, min(1.0, (0.6 - p) / 0.6))
                     * (1.0 - rootState.countdownVisible)
                     * (rootState.translatingStripVisible ? 0.0 : 1.0)
                     * (rootState.route == .translate ? 0.0 : 1.0))
            .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.countdownVisible)
            .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.translatingStripVisible)
            .allowsHitTesting(p < 0.5 && rootState.countdownVisible < 0.5
                              && !rootState.translatingStripVisible
                              && rootState.route != .translate)

            // Countdown — crossfades over Main without resizing the panel
            CountdownView(
                metrics: m,
                interaction: interaction,
                secondsRemaining: rootState.countdownSeconds,
                totalSeconds: rootState.countdownTotal,
                onStop: onStopCountdown,
                onCaptureNow: onCaptureNow
            )
            .opacity(rootState.countdownVisible)
            .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.countdownVisible)
            .allowsHitTesting(rootState.countdownVisible >= 0.5)
            .frame(height: m.panelHeight)

            // The wait — same crossfade, same strip, no morph.
            TranslatingView(metrics: m, interaction: interaction)
                .opacity(rootState.translatingVisible)
                .animation(.easeOut(duration: PanelTiming.crossfade), value: rootState.translatingVisible)
                .frame(height: m.panelHeight)

            // Archive — appears as p→1; content is pre-faded via routeContentVisible.
            // Two separate opacity modifiers: SwiftUI tracks them independently so
            // the progress animation does not "drag" routeContentVisible along with it.
            NotchArchiveView(
                metrics: m,
                archiveModel: archiveModel,
                expansion: archiveExpansion,
                selection: archiveSelection,
                shareAnchor: shareAnchor,
                isPinned: rootState.isArchivePinned,
                // Both halves are needed, and the route is the load-bearing one.
                // `routeContentVisible` is an animation value that a close
                // pre-fades to 0 and then puts back to 1 while the panel is
                // still going away — "reset for next open". On its own it told
                // the archive it was on screen again a beat after it left, and
                // a cell still reporting a hover (the window vanished under the
                // pointer, so no mouse-exit ever arrived) re-armed Space for a
                // panel the user had just closed.
                isContentVisible: rootState.routeContentVisible > 0.5
                    && rootState.route == .archive,
                onBack: onBack,
                onHidePanel: onHidePanel,
                onTogglePin: onTogglePin,
                onPreviewText: onPreviewText
            )
            .opacity(rootState.routeContentVisible)
            .opacity(rootState.route == .archive ? p : 0)
            .allowsHitTesting(rootState.route == .archive && p >= 0.5)
            // Reveal the archive content in step with the growing panel: clip it to
            // the current panel height so the lower rows don't show before the
            // background has expanded to cover them. revealH is a hair shorter
            // than the notch morph, so content reveals just behind the shape edge
            // (safe) rather than ahead of it. At rest (p=1) revealH == archiveH.
            .mask(
                Color.black
                    .frame(height: revealH)
                    .frame(height: routeH, alignment: .top)
            )

            // Translator — the same reveal as the archive, on the taller shape.
            NotchTranslateView(
                metrics: m,
                model: TranslationPanelModel.shared,
                isPinned: rootState.isArchivePinned,
                onBack: onLeaveTranslate,
                onPickLanguage: onPickLanguage,
                onTogglePin: onTogglePin
            )
            // Not tied to the morph. The archive's cells fade in with the
            // shape and read as one motion; a paragraph doing that is legible
            // long before it has a panel under it. So the body stays at zero
            // for the whole morph and dissolves in once the shape has arrived
            // — `routeContentVisible` is driven by the transition, both ways.
            .opacity(rootState.route == .translate ? rootState.routeContentVisible : 0)
            .allowsHitTesting(rootState.route == .translate && p >= 0.5)
            .mask(
                Color.black
                    .frame(height: revealH)
                    .frame(height: routeH, alignment: .top)
            )

            // Notch close zone — always topmost, width = notchGap, height = panelHeight.
            // Lets the user close the panel by tapping the notch pill even when the archive
            // is open and NotchPanelView hit-testing is disabled.
            if m.hasNotch {
                Color.clear
                    .frame(width: m.notchGap, height: m.panelHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { onClose() }
            }
        }
        .frame(height: windowH, alignment: .top)
        .allowsHitTesting(interaction.isEnabled)
        // The pointer being parked on the panel is what makes claiming Tab
        // acceptable — the same rule Space is held under, and for the same
        // reason. A registered hotkey takes the key from every app on the
        // machine, and the panel can be pinned open for hours.
        .onHover { inside in
            isPointerInside = inside
            updateCycleHotkeys()
        }
        .onChange(of: rootState.route) { _, _ in updateCycleHotkeys() }
        .onChange(of: cycleEnabled) { _, _ in updateCycleHotkeys() }
        .onDisappear {
            isPointerInside = false
            updateCycleHotkeys()
        }
    }

    /// Holds ⇥ and ⇧⇥ exactly while there is something on screen for them to
    /// step through and the pointer is on it.
    private func updateCycleHotkeys() {
        if let tabToken { TransientHotkeyCenter.tab.remove(tabToken) }
        if let shiftTabToken { TransientHotkeyCenter.shiftTab.remove(shiftTabToken) }
        tabToken = nil
        shiftTabToken = nil

        guard cycleEnabled, isPointerInside,
              rootState.route == .archive || rootState.route == .translate
        else { return }

        tabToken = TransientHotkeyCenter.tab.push { onCycleHeader(false) }
        shiftTabToken = TransientHotkeyCenter.shiftTab.push { onCycleHeader(true) }
    }
}

// MARK: - Panel controller

final class NotchPanelController: NSObject {
    // MARK: Private (main-file only)
    private var panel: NSPanel?
    private let interactionState = NotchPanelInteractionState()
    private var isMenuTracking: Bool = false
    /// True between `.sharePickerDidOpen` and `.sharePickerDidClose` (see
    /// SharePicker.swift). The share sheet is its own window, so the panel it
    /// was opened from must not slide away underneath it.
    private var isSharePickerOpen: Bool = false
    /// Where `leaveTranslate` goes — set when the Translator is raised, so a
    /// preview opened over the archive returns to it instead of to Main.
    private(set) var translateReturnRoute: NotchPanelRoute = .main
    /// True while the Quick Look panel is up (see QuickLookPresenter) — the
    /// preview is anchored to nothing, so the panel behind it must stay put.
    private var isQuickLookOpen: Bool = false
    /// Anchor for every share sheet opened from the archive — the selection's
    /// Share and the Share Last Screenshot hotkey. Owned here rather than by
    /// the view so the hotkey can reach it without the archive being on screen
    /// first.
    private let archiveShareAnchor = SharePickerAnchor()
    /// Toast for hotkeys that have nothing to act on; a silent global shortcut
    /// reads as broken (same reasoning as PinnedScreenshotController).
    private let feedbackHUD = TextCaptureHUD()

    /// Authoritative panel state. All transitions go through here; the
    /// older isExpanded / archiveTransitionInFlight flags were folded in.
    /// Note: setter is not `private(set)` because the countdown extension
    /// in NotchPanelCapture.swift needs to write to it. Only this file
    /// and its extensions should mutate `state`.
    var state: PanelState = .hidden {
        didSet {
            postMascotNotification()
            syncEscapeHotkey()
        }
    }
    /// Token in TransientHotkeyCenter.escape while the panel is on screen; Esc closes it.
    private var escToken: UUID?
    private var notificationObservers: [NSObjectProtocol] = []

    /// True после sleep/wake/display-change/Space-switch, пока панель не была
    /// показана заново с принудительной перепривязкой к активному Space.
    /// Читается из NotchHoverController чтобы не уходить в «закрыть невидимую панель».
    /// Computed from `state == .stale(_)` after PR 3 refactor.
    var needsSpaceRebind: Bool { state.isStale }

    /// Монотонно возрастающий счётчик анимационных фаз. Каждая новая анимация
    /// фиксирует текущее значение; устаревшие completion handler'ы сравнивают
    /// с ним и завершаются без изменения состояния. Это предотвращает «мёртвые
    /// состояния» панели при быстрых открытие→закрытие или sleep прямо
    /// во время анимации.
    /// Сохраняется как defensive guard: `PanelState` обеспечивает основные
    /// инварианты, но stale completion'ы NSAnimation могут выстрелить уже
    /// после перехода в новое состояние; generation matching ловит этот случай.
    private let transitionCoordinator = PanelTransitionCoordinator()
    private var animationGeneration: Int { transitionCoordinator.generation }
    private var panelBindingID: UUID { transitionCoordinator.bindingID }
    @discardableResult
    private func bumpGeneration() -> Int {
        transitionCoordinator.bumpGeneration()
    }

    /// Captures the current panel lifecycle identity for delayed UI work.
    /// Callers must take the token after the transition they want to wait for
    /// has been started, because starting a morph intentionally advances the
    /// generation.
    @discardableResult
    func makePanelTransitionToken() -> PanelTransitionToken {
        transitionCoordinator.currentToken()
    }

    func animationGenerationMatches(_ token: PanelTransitionToken) -> Bool {
        transitionCoordinator.matches(token)
            && !needsSpaceRebind
    }

    /// Invalidates delayed panel actions without otherwise changing the route.
    /// Overlay cancellation and environment changes use this before returning
    /// to `.hidden`/`.stale` so an old selection cannot capture later.
    func invalidatePanelTransitionActions() {
        transitionCoordinator.invalidate()
    }

    /// Schedules a MainActor panel action guarded by both the transition token
    /// and the current visible lifecycle. `requiresVisible == false` is only
    /// for overlay work whose window has already been ordered out; its caller
    /// still validates the expected state inside the action.
    func schedulePanelAction(after delay: TimeInterval,
                             token: PanelTransitionToken,
                             requiresVisible: Bool = true,
                             action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  self.transitionCoordinator.matches(token),
                  !self.needsSpaceRebind
            else { return }

            if requiresVisible {
                guard self.panel?.isVisible == true else { return }
                switch self.state {
                case .hidden, .hiding, .preSelection, .stale:
                    return
                default:
                    break
                }
            }
            action()
        }
    }

    /// Caller completion for the hide currently in flight. Capture/OCR/color
    /// flows hide the panel and start their overlay from this closure, so it
    /// must survive a Space switch that tears the panel down mid-hide (the
    /// animation completions die on the closed window and would drop it).
    /// Single point of truth: every path delivers via
    /// `firePendingHideCompletion()`, never by calling a captured closure.
    private var pendingHideCompletion: (() -> Void)?

    private func firePendingHideCompletion() {
        let completion = pendingHideCompletion
        pendingHideCompletion = nil
        completion?()
    }

    // MARK: - Mascot notifications

    /// Pending work item that posts .sleeping after a short debounce delay.
    /// Cancelled whenever a non-sleep state arrives, so transient .hidden states
    /// (e.g. panel hiding before a capture overlay starts) never reach the mascot.
    private var pendingSleepWorkItem: DispatchWorkItem?

    /// Single funnel for all mascot state posts.
    /// .sleeping is debounced by 150 ms so a rapid .hidden → .preSelection
    /// transition doesn't flash the mascot to sleep and back.
    func postMascotState(_ mascot: MascotState) {
        pendingSleepWorkItem?.cancel()
        pendingSleepWorkItem = nil
        if case .sleeping = mascot {
            let item = DispatchWorkItem {
                NotificationCenter.default.post(name: .mascotStateChanged, object: MascotState.sleeping)
            }
            pendingSleepWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
        } else {
            NotificationCenter.default.post(name: .mascotStateChanged, object: mascot)
        }
    }

    private func postMascotNotification() {
        switch state {
        case .countdown:                             postMascotState(.countdown)
        case .main, .archive, .showing, .preSelection: postMascotState(.awake)
        case .hidden:                               postMascotState(.sleeping)
        default:                                    break
        }
    }

    // MARK: - Debug trace

    func trace(_ event: String) {
        DebugTrace.add(
            "\(event) " +
            "state=\(state) route=\(route) " +
            "needsRebind=\(needsSpaceRebind) suppress=\(suppressesGlobalAutoHide) " +
            "gen=\(animationGeneration) " +
            "panel={\(PanelTrace.panelSummary(panel))} " +
            "screen={\(PanelTrace.screenSummary(currentScreen))} " +
            "\(PanelTrace.mouseSummary())"
        )
    }

    // MARK: Internal (accessible from extension files)
    var currentScreen: NSScreen?
    let rootState = NotchPanelRootState()
    let model = NotchPanelModel()
    let archiveModel = NotchArchiveModel()
    /// Lives here rather than inside the archive view so the Esc handler can see
    /// (and clear) an open accordion — see `PanelState.escapeAction`.
    let archiveExpansion = ArchiveExpansionState()
    /// Lives here for the same reason, and one layer further out: Esc unwinds
    /// an expanded stack, then the selection mode, then the panel.
    let archiveSelection = ArchiveSelectionState()
    let screenshot = ScreenshotService()
    let colorPicker = ColorPickingCoordinator()
    let scanCapture = ScanCaptureCoordinator()

    enum CaptureTarget {
        case screen
        case rect(CGRect)
        case windowID(CGWindowID)
    }

    /// Active countdown session, if any. Replaces the three legacy fields
    /// (timer / target / screen) that used to live separately on the
    /// controller. `nil` ⇔ no countdown in progress.
    var activeCountdown: CountdownSession?

    let selectionOverlay = SelectionOverlay()
    let windowPickerOverlay = WindowPickerOverlay()

    /// True ⇔ `state` is `.preSelection(_)`. Kept as a helper so call sites
    /// don't need to repeat the pattern match. Replaces the
    /// preSelectionInFlight flag from PR 2.
    var isInPreSelection: Bool {
        if case .preSelection = state { return true }
        return false
    }

    var metrics = NotchMetrics.fallback() {
        didSet { rootState.metrics = metrics }
    }

    var route: NotchPanelRoute {
        get { rootState.route }
        set { rootState.route = newValue }
    }

    // MARK: - Init

    override init() {
        super.init()
        // The archive is the app's list of colours, and the decor inspector
        // paints from it. Handed over here because the archive is owned here;
        // the editor only ever sees the two members of `PresentationColorShelf`.
        EditorWindowController.shared.colorShelf = archiveModel
        colorPicker.hidePanel = { [weak self] completion in self?.hideAnimated(reason: .colorPickerStart, completion: completion) }
        colorPicker.addColor  = { [weak self] color in self?.archiveModel.add(color: color) }
        colorPicker.resetRoute = { [weak self] in
            self?.route = .main
            self?.rootState.progress = 0.0
        }
        colorPicker.hideCursorBeforeHide = { CursorOverlay.hideCursorAfterMenuCloses() }
        colorPicker.onFlightChanged = { [weak self] inFlight in
            // Only post .sleeping when flight ends via cancellation.
            // The confirmed path posts .celebrating via onPickConfirmed instead.
            self?.postMascotState(inFlight ? .colorPicking(.leftCenter) : .sleeping)
        }
        colorPicker.onPickConfirmed = { [weak self] in
            self?.postMascotState(.celebrating)
        }
        colorPicker.onCursorMoved = { point in
            NotificationCenter.default.post(name: .mascotCursorMoved, object: NSValue(point: point))
        }
        scanCapture.addText = { [weak self] text, isCode in
            self?.archiveModel.add(text: text, isCodePayload: isCode)
        }
        scanCapture.translate = { [weak self] text, language in
            guard let self else { return }
            // `language` is nil unless ⇥ named one on the overlay, and nil is
            // what makes this the ordinary automatic route.
            ArchiveTranslate.run(text, to: language,
                                 archiveModel: self.archiveModel, on: self.currentScreen)
        }
        screenshot.onCaptured = { [weak self] url in
            self?.archiveModel.add(screenshotURL: url)
            // Clear preSelection so the next capture attempt isn't blocked.
            if case .preSelection = self?.state { self?.state = .hidden }
            self?.postMascotState(.celebrating)
        }
        screenshot.onCancelled = { [weak self] in
            if case .preSelection = self?.state { self?.state = .hidden }
            self?.postMascotState(.sleeping)
        }
        screenshot.onThumbnailTapped = { [weak self] in
            guard let self else { return }
            // Тот же guard что в toggleAnimated: после sleep/Space-switch AppKit
            // может считать панель isVisible, хотя пользователь её не видит.
            if self.isVisible && !self.needsSpaceRebind {
                self.switchToArchive()
            } else {
                guard let screen = self.currentScreen ?? NSScreen.main else { return }
                guard let token = self.showAnimated(on: screen, forceRebind: self.needsSpaceRebind)
                else { return }
                self.schedulePanelAction(after: PanelTiming.showBeforeArchive, token: token) {
                    [weak self] in
                    self?.switchToArchive()
                }
            }
        }
        screenshot.onDelete = { [weak self] url in
            self?.archiveModel.remove(screenshotURL: url)
        }
        let t1 = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isMenuTracking = true }
        }
        let t2 = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isMenuTracking = false }
        }
        // The panel now lives in a dedicated max-level CGS space (see create()),
        // so a Space switch no longer corrupts its binding — it stays correctly
        // placed on its own. The visible-panel recreate that used to run here is
        // therefore redundant, and its orderOut+close+create was what caused the
        // brief blink at the tail of a slow swipe. A hidden panel is still torn
        // down so the next show rebuilds cleanly.
        let t3 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.trace("spaceDidChange.begin")
                if case .hiding = self.state {
                    // A close is in progress: cut the hide animation short and tear
                    // the panel down immediately (the user is mid-Space-switch and
                    // won't see the truncated animation). markPanelSpaceBindingStale
                    // delivers the pending hide completion so capture flows that
                    // wait for the panel to disappear still start.
                    self.markPanelSpaceBindingStale()
                } else if self.panel?.isVisible == true {
                    // Leave the visible panel untouched — the CGS space keeps it in
                    // place across the switch. (No recreate → no blink.)
                    self.trace("spaceDidChange.visible.noop")
                } else {
                    self.markPanelSpaceBindingStale()
                }
            }
        }

        // После сна, пробуждения или перестройки дисплеев WindowServer может
        // сохранить у старого NSPanel устаревшую Space-привязку, которую AppKit
        // не исправляет самостоятельно. Самый надёжный способ — пересоздать
        // панель при следующем показе вместо того, чтобы «лечить» старую.
        let onSleepWake: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidatePanelAfterEnvironmentChange(reason: .sleep)
            }
        }
        let onDisplayChange: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidatePanelAfterEnvironmentChange(reason: .displayChange)
            }
        }
        let t4 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t5 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t6 = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main, using: onSleepWake)
        let t7 = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main, using: onDisplayChange)
        // Edited screenshots saved from the annotation editor join the archive.
        let t8 = NotificationCenter.default.addObserver(
            forName: .editorDidSaveImage,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.archiveModel.add(screenshotURL: url)
            }
        }
        // Only when the panel is down. Raised from the archive by right-click,
        // the archive is already on screen and worth more than a spinner —
        // replacing it with one would take away what the user was looking at.
        let tTranslateStart = NotificationCenter.default.addObserver(
            forName: .translationDidStart,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard !self.isVisible, let screen = self.currentScreen
                        ?? NSScreen.main ?? NSScreen.screens.first else { return }
                self.rootState.translatingStripVisible = true
                self.rootState.translatingVisible = 1.0
                self.showAnimated(on: screen, forceRebind: self.needsSpaceRebind)
                self.state = .translating
            }
        }
        // Nowhere to send the text automatically, so it is put in front of the
        // user with the language menu instead of refused. Same presentation as
        // opening an archive entry to read — it is the same thing: a text, and
        // a header that asks where it should go.
        let tTranslatePreview = NotificationCenter.default.addObserver(
            forName: .requestTranslatePreview,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let text = note.object as? String else { return }
            MainActor.assumeIsolated {
                TranslationPanelModel.shared.present(.preview(of: text),
                                                     bodyWidth: self.translateBodyWidth)
                self.presentTranslation(on: self.currentScreen)
            }
        }
        let tTranslateEnd = NotificationCenter.default.addObserver(
            forName: .translationDidEnd,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Before the strip check, not after: a language picked from the
                // panel's menu never raises the strip, and its dimming has to
                // come back off whether or not a translation arrived.
                TranslationPanelModel.shared.endRework()
                guard self.rootState.translatingStripVisible else { return }
                // Nothing to show for it — a failed or empty translation. The
                // glyphs still leave the way they would have on success.
                self.dissolveStrip { [weak self] in
                    guard let self else { return }
                    if case .translating = self.state { self.state = .main }
                }
            }
        }

        let tTranslate = NotificationCenter.default.addObserver(
            forName: .translationDidFinish,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let result = note.object as? TranslationPanelModel.Result
            else { return }
            MainActor.assumeIsolated {
                TranslationPanelModel.shared.present(result, bodyWidth: self.translateBodyWidth)
                // Already showing: only the text changes, no morph.
                guard self.route != .translate else { return }
                guard self.rootState.translatingStripVisible else {
                    self.presentTranslation(on: self.currentScreen)
                    return
                }
                // The strip is up: let its glyphs go before the panel stops
                // being a strip. Clearing the shape flag is also what hands
                // the width back, so the morph sizes the Translator to its own
                // route rather than to the 270pt it is standing in.
                self.dissolveStrip { [weak self] in
                    guard let self else { return }
                    self.presentTranslation(on: self.currentScreen)
                }
            }
        }
        let t9 = NotificationCenter.default.addObserver(
            forName: .editorDidScan,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let entry = note.object as? ScanRecognition.ArchiveEntry else { return }
            Task { @MainActor [weak self] in
                self?.archiveModel.add(text: entry.string, isCodePayload: entry.isCode)
            }
        }
        // The editor's ⌃-armed scan, routed through the same translation the
        // panel's own scan uses — the archive lives here, not in the editor.
        let t9b = NotificationCenter.default.addObserver(
            forName: .editorDidScanForTranslation,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let payload = note.object as? EditorScanTranslation else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                ArchiveTranslate.run(payload.text, to: payload.language,
                                     archiveModel: self.archiveModel, on: self.currentScreen)
            }
        }

        // Share sheet opened from an archive context menu: hold the panel open
        // for as long as the sheet is up (the picker is not an NSMenu, so t1/t2
        // above never see it), and hand Esc back so it dismisses the sheet
        // rather than the panel the sheet is anchored to.
        let t10 = NotificationCenter.default.addObserver(
            forName: .sharePickerDidOpen,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSharePickerOpen = true
                self?.syncEscapeHotkey()
            }
        }
        let t11 = NotificationCenter.default.addObserver(
            forName: .sharePickerDidClose,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSharePickerOpen = false
                self?.syncEscapeHotkey()
            }
        }

        // Quick Look is a window of ours too: hold the panel open under it, and
        // let the presenter own Esc so the first press closes the preview.
        let t12 = NotificationCenter.default.addObserver(
            forName: .quickLookDidOpen,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isQuickLookOpen = true }
        }
        let t13 = NotificationCenter.default.addObserver(
            forName: .quickLookDidClose,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.isQuickLookOpen = false }
        }

        notificationObservers = [t1, t2, t3, t4, t5, t6, t7, t8, t9, t9b, t10, t11, t12, t13,
                                 tTranslate, tTranslateStart, tTranslateEnd, tTranslatePreview]
    }

    isolated deinit {
        // Some observers are registered on NSWorkspace.notificationCenter,
        // others on NotificationCenter.default — remove from both.
        notificationObservers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        notificationObservers.removeAll()
        removeEscMonitor()
        // Ensure the scheduled Timer can't fire into a deallocated controller.
        activeCountdown?.timer?.invalidate()
        activeCountdown = nil
    }

    /// Выводит панель на текущий активный Space.
    ///
    /// Панель создаётся с `.canJoinAllSpaces` и должна присутствовать на всех
    /// рабочих столах. Раньше здесь был трюк `.moveToActiveSpace` → orderFront →
    /// `.canJoinAllSpaces`, который ломался: `.moveToActiveSpace` переносит окно
    /// только при АКТИВАЦИИ приложения, а это `nonactivatingPanel`, выводимый
    /// через `orderFrontRegardless()` без активации. Перенос не срабатывал, зато
    /// `.canJoinAllSpaces` снимался — и окно залипало на одном Space. Поэтому
    /// просто переутверждаем `.canJoinAllSpaces` и выводим панель вперёд:
    /// окно остаётся на всех Space и появляется на том, что активен сейчас.
    /// `.stationary` (восстановлен в `f02100f`) убирает «дыру» при анимации
    /// Mission Control.
    private func orderFrontOnActiveSpace(_ panel: NSPanel) {
        if NotchSpaceManager.shared.adapter is StandardSpaceAdapter {
            panel.collectionBehavior = [
                .canJoinAllSpaces,
                .fullScreenAuxiliary,
                .moveToActiveSpace,
                .stationary
            ]
        } else {
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
        // No attach here. The panel joins the space once, when it is created,
        // and leaves it only on the way to `close()` — both detaches sit in
        // teardown paths, so a live panel is never outside it and re-attaching
        // on every show is asking the Spaces server to redo settled work.
        //
        // It is not free. This runs between `setFrame` on the hidden start
        // position and the animation that brings the panel down, and a space
        // operation landing in that gap cost the no-notch panel its entire
        // reveal: it appeared at its final position with no travel at all.
        panel.orderFrontRegardless()
    }

    /// Помечает Space-привязку панели устаревшей и немедленно уничтожает окно.
    /// Используется при переключении Space пока панель скрыта или закрывается.
    private func markPanelSpaceBindingStale() {
        trace("markStale.begin")
        // Осиротевшие completion'ы анимации скрытия не должны перезаписать
        // .stale на .hidden после того, как окно уже уничтожено.
        bumpGeneration()
        // Убираем окно из CGS-спейса ДО close(): позже windowNumber станет
        // невалидным, и панель зависла бы в Set (strong ref) до следующего create().
        if let panel { NotchSpaceManager.shared.adapter.detach(panel) }
        uninstallMouseRegionTracking()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        removeEscMonitor()
        // Сброс состояния, чтобы следующий show начался из чистого Main.
        state = .stale(reason: .spaceChange)
        interactionState.isEnabled = true
        route = .main
        rootState.progress = 0.0
        rootState.countdownVisible = 0.0
        // Если Space сменился во время скрытия — панель уже исчезла, так что
        // семантика «спрятал → продолжай» соблюдена; доставляем completion,
        // иначе capture/OCR/color-поток молча не стартует.
        firePendingHideCompletion()
    }

    /// Полностью уничтожает NSPanel после sleep/wake/display-change.
    /// Пересоздание при следующем show — единственный способ гарантированно
    /// избавиться от устаревшей WindowServer / Spaces привязки.
    private func invalidatePanelAfterEnvironmentChange(reason: StaleReason = .sleep) {
        trace("invalidateEnvironment.begin reason=\(reason)")
        bumpGeneration()
        // Overlay sessions below are cancelled outright, so a hide completion
        // waiting to start one must be dropped, not delivered (a capture
        // overlay popping up right after wake would be a surprise).
        pendingHideCompletion = nil

        // Отменяем любые активные overlay-сессии: если sleep/wake случился во время
        // выбора области, окна или цвета, preSelection / colorPicker.isInFlight
        // зависнут и через suppressesGlobalAutoHide сделают панель неуправляемой.
        selectionOverlay.cancel()
        windowPickerOverlay.cancel()
        colorPicker.cancel()
        scanCapture.cancel()
        screenshot.cancelCurrentCapture()

        activeCountdown?.timer?.invalidate()
        activeCountdown = nil
        // См. markPanelSpaceBindingStale: чистим CGS-спейс до close().
        if let panel { NotchSpaceManager.shared.adapter.detach(panel) }
        uninstallMouseRegionTracking()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        removeEscMonitor()
        // The archive's Space and ⌘A owners went with the hosting view just
        // released, and their tokens went with them — `onDisappear` is not
        // promised on a view that is deallocated rather than removed. Esc is
        // handed back by the line above because the panel holds that token
        // itself; these two have to be taken back from this side or nobody can.
        // Not `.escape.releaseAll()`: an open Quick Look panel is still on
        // screen and still needs its Esc.
        TransientHotkeyCenter.space.releaseAll()
        TransientHotkeyCenter.selectAll.releaseAll()
        // Same story, same fix: the root view held both cycle owners in its own
        // @State, and Tab left claimed is Tab taken from every app on the
        // machine.
        TransientHotkeyCenter.tab.releaseAll()
        TransientHotkeyCenter.shiftTab.releaseAll()
        state = .stale(reason: reason)
        isSharePickerOpen = false
        isQuickLookOpen = false
        interactionState.isEnabled = true
        // The selection is ephemeral by design — the archive is supposed to
        // reopen with nothing picked — but the view is what normally clears it,
        // on its way to hidden, and this path never goes there. Left alone, a
        // mode switched on before the machine slept comes back after the wake
        // with checkboxes from a session the user has already left.
        archiveSelection.clear()
        route = .main
        rootState.progress = 0.0
        rootState.countdownVisible = 0.0
        rootState.countdownSeconds = 0
        rootState.countdownTotal = 0
        rootState.routeContentVisible = 1.0
        rootState.isArchivePinned = false
    }

    // MARK: - Public API

    var suppressesGlobalAutoHide: Bool {
        !state.allowsAutoHide
            || isMenuTracking
            || isSharePickerOpen
            || isQuickLookOpen
            || colorPicker.isInFlight
            || rootState.isArchivePinned
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggleAnimated(on screen: NSScreen) {
        // После sleep/wake/Space-switch AppKit может считать панель isVisible==true,
        // хотя пользователь её не видит на текущем рабочем столе. В таком случае
        // не уходим в hideAnimated — принудительно показываем заново на активном Space.
        if isVisible && !needsSpaceRebind {
            hideAnimated(reason: .hotkeyToggle)
        } else {
            showAnimated(on: screen, forceRebind: needsSpaceRebind)
        }
    }

    /// Hotkey entry for the collect-files flow: reveal the panel straight into
    /// the archive and pin it, so the panel survives the mouse-down that starts a
    /// file drag from another app (pin feeds suppressesGlobalAutoHide). Mirrors
    /// screenshot.onThumbnailTapped's show-then-switch template; guards the
    /// route because switchToArchive() is a toggle.
    ///
    /// The hotkey itself toggles: pressing it again while already collecting
    /// (archive shown + pinned) dismisses the panel, mirroring togglePanel (⌃⌥⌘N).
    /// hideAnimated resets isArchivePinned, so the unpin comes for free.
    func openArchivePinned(on screen: NSScreen) {
        if isVisible && !needsSpaceRebind && route == .archive && rootState.isArchivePinned {
            hideAnimated(reason: .hotkeyToggle)
            return
        }
        if isVisible && !needsSpaceRebind {
            if route != .archive { switchToArchive() }
            rootState.isArchivePinned = true
        } else {
            guard let token = showAnimated(on: screen, forceRebind: needsSpaceRebind) else { return }
            schedulePanelAction(after: PanelTiming.showBeforeArchive, token: token) { [weak self] in
                guard let self else { return }
                if self.route != .archive { self.switchToArchive() }
                self.rootState.isArchivePinned = true
            }
        }
    }

    /// Hotkey entry for translating the clipboard: the user selects text
    /// anywhere, presses ⌘C, then this.
    ///
    /// The extra ⌘C is deliberate. Lifting a selection out of another app
    /// directly — whether by reading `kAXSelectedTextAttribute` or by
    /// synthesising ⌘C, which needs the same trust — costs an Accessibility
    /// grant, and Stampo is down to one system permission on purpose. Reading
    /// the pasteboard needs none, is exact where OCR is not, and works in
    /// terminals, Electron and virtual machines where the accessibility route
    /// returns nothing at all.
    ///
    /// The archive is brought up rather than translating silently: the result
    /// lands there as an entry, and the user should see it arrive.
    func translateClipboard(on screen: NSScreen) {
        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !clipboard.isEmpty else {
            feedbackHUD.show(.nothingToTranslate, on: screen)
            return
        }
        // Nothing is opened here. The result raises the Translator when it
        // arrives — bringing the archive up first was a leftover from before
        // the Translator existed, and it put a route nobody asked for on the
        // way to the one they did.
        ArchiveTranslate.run(clipboard, archiveModel: archiveModel, on: screen)
    }

    /// Fades the wait's glyphs out, then drops the strip's geometry and runs
    /// `next`. The two steps are ordered rather than simultaneous for the same
    /// reason every other body in this panel is: content never moves while the
    /// shape does.
    private func dissolveStrip(_ next: @escaping () -> Void) {
        let token = makePanelTransitionToken()
        withAnimation(.easeOut(duration: PanelTiming.contentDissolve)) {
            rootState.translatingVisible = 0.0
        }
        schedulePanelAction(after: PanelTiming.contentDissolve, token: token) { [weak self] in
            guard let self else { return }
            self.rootState.translatingStripVisible = false
            next()
        }
    }

    /// Raises the Translator, opening the panel first if it is not up.
    ///
    /// A translation can land with the panel hidden — the scan overlay hides it
    /// before capturing, and the clipboard hotkey never opened it — and
    /// `switchToTranslate` on its own only morphs a panel already on screen.
    /// Without this the route was set behind a hidden window and appeared on
    /// the next click, which is not where the user left the gesture.
    func presentTranslation(on screen: NSScreen?, returningTo source: NotchPanelRoute? = nil) {
        guard let target = screen ?? currentScreen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        // Default: back out to wherever the panel already was. Raised over a
        // hidden panel that is Main, raised from the archive that is the
        // archive — which is what a preview wants without having to say so.
        let destination = source ?? (isVisible && route == .archive ? .archive : .main)

        if isVisible && !needsSpaceRebind {
            switchToTranslate(returningTo: destination)
        } else {
            guard let token = showAnimated(on: target, forceRebind: needsSpaceRebind) else { return }
            schedulePanelAction(after: PanelTiming.showBeforeArchive, token: token) { [weak self] in
                self?.switchToTranslate(returningTo: destination)
            }
        }
    }

    /// Hotkey entry for sharing the newest archive entry — whatever it is: a
    /// capture, a picked color, recognized text, or a whole dropped stack. The
    /// archive is brought up rather than shared silently for two reasons — the
    /// sheet needs a real anchor view to hang off, and the user sees what is
    /// about to leave the machine. Empty archive → a toast, never silence.
    func shareLastArchiveItem(on screen: NSScreen) {
        guard let newest = archiveModel.items.first else {
            feedbackHUD.show(.nothingToShare, on: screen)
            return
        }
        // Colors follow the format selected in the archive header, so what gets
        // shared reads the same as what the cell shows.
        let items = NotchArchiveModel
            .payload(for: [newest], colorScheme: AppSettings.defaultColorFormat)
            .objects
        guard !items.isEmpty else {
            feedbackHUD.show(.nothingToShare, on: screen)
            return
        }
        // The anchor lives on the "⋯" button, which only reaches its final
        // position once the archive morph has finished — presenting earlier would
        // point the sheet at wherever the header was mid-animation.
        let present = { [weak self] in self?.archiveShareAnchor.present(items) }

        if isVisible && !needsSpaceRebind {
            if route == .archive {
                let token = makePanelTransitionToken()
                schedulePanelAction(after: PanelTiming.oneFrameSettle, token: token) { present() }
            } else {
                switchToArchive()
                let token = makePanelTransitionToken()
                schedulePanelAction(after: PanelTiming.archiveCloseMorph, token: token) { present() }
            }
        } else {
            guard let token = showAnimated(on: screen, forceRebind: needsSpaceRebind) else { return }
            schedulePanelAction(after: PanelTiming.showBeforeArchive, token: token) { [weak self] in
                guard let self else { return }
                if self.route != .archive { self.switchToArchive() }
                let archiveToken = self.makePanelTransitionToken()
                self.schedulePanelAction(after: PanelTiming.archiveCloseMorph,
                                         token: archiveToken) { present() }
            }
        }
    }

    /// Trigger a capture directly (e.g. from a hotkey) without going through the panel UI.
    func captureDirectly(mode: CaptureMode, on screen: NSScreen) {
        currentScreen = screen
        updateScreenMetrics(for: screen)
        if mode == .selection {
            guard !isInPreSelection else { return }
            let selectionToken = PanelTransitionToken(
                generation: bumpGeneration(),
                bindingID: panelBindingID
            )
            state = .preSelection(.selection)
            selectionOverlay.onSelected = { [weak self] rect in
                guard let self else { return }
                guard self.animationGeneration == selectionToken.generation,
                      self.panelBindingID == selectionToken.bindingID,
                      case .preSelection(.selection) = self.state
                else { return }
                self.state = .hidden
                // The overlay panel was just orderOut(nil)'d, but WindowServer
                // still has it in the framebuffer for a frame or two. Without a
                // small delay screencapture(1) fires before the dim/cursor
                // overlay is gone and the resulting image includes them.
                // Panel-mode area capture doesn't hit this because the panel's
                // hideAnimated completion provides a much longer buffer.
                self.schedulePanelAction(after: 0.1,
                                         token: selectionToken,
                                         requiresVisible: false) { [weak self] in
                    guard let self, case .hidden = self.state else { return }
                    self.screenshot.captureRect(rect, preferredScreen: screen)
                }
            }
            selectionOverlay.onCancelled = { [weak self] in
                guard let self,
                      self.animationGeneration == selectionToken.generation,
                      self.panelBindingID == selectionToken.bindingID
                else { return }
                self.invalidatePanelTransitionActions()
                self.state = .hidden
            }
            selectionOverlay.start(on: screen)
        } else if mode == .window {
            guard !isInPreSelection else { return }
            state = .preSelection(.window)
            screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
        } else {
            screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
        }
    }

    /// Trigger pick color directly (e.g. from a hotkey).
    func pickColorDirectly(on screen: NSScreen? = nil) {
        if let screen {
            currentScreen = screen
            updateScreenMetrics(for: screen)
        }
        pickColor()
    }

    @discardableResult
    func showAnimated(on screen: NSScreen, forceRebind: Bool = false) -> PanelTransitionToken? {
        trace("showAnimated.begin forceRebind=\(forceRebind) targetScreen={\(PanelTrace.screenSummary(screen))}")
        currentScreen = screen
        updateScreenMetrics(for: screen)

        model.mode  = AppSettings.defaultCaptureMode
        model.delay = AppSettings.defaultTimerDelay

        if panel == nil { create() }
        guard let panel else { return nil }

        // Environment/Space invalidation normally destroys the old NSPanel, so
        // create() above gives WindowServer a fresh Space binding. Keep orderOut
        // as a defensive fallback if a stale state ever arrives with a panel.
        if forceRebind {
            panel.orderOut(nil)
            // state.isStale is cleared automatically when we transition to
            // .showing below — no separate flag write needed.
        }

        state = .showing
        let gen = bumpGeneration()
        let transitionToken = PanelTransitionToken(generation: gen, bindingID: panelBindingID)
        // A show interrupting an in-flight hide aborts it: the panel never
        // finished disappearing, so the hide's caller completion must not fire.
        pendingHideCompletion = nil
        interactionState.isEnabled = false
        interactionState.contentVisibility = 0.0
        panel.alphaValue = 1

        // Позиционируем ДО orderFront: macOS привязывает окно к Space в момент
        // orderFront, исходя из текущего фрейма. setFrame после — окно окажется
        // на прошлом Space (особенно после долгого idle и выхода из сна).
        if metrics.hasNotch {
            panel.setFrame(frameForWidth(collapsedWidth, on: screen, height: panelWindowHeight), display: false)
        } else {
            // Reveal by descending from above the top edge — the exact reverse of
            // the close animation. The notch tab starts just the content height
            // above so the whole descent is visible (see frameNotchTabHidden);
            // the rounded style slides down at full width from fully above.
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let start = metrics.pinnedToTopEdge
                ? frameNotchTabHidden(width: w, on: screen)
                : frameNoNotchHiddenAbove(width: w, on: screen, height: panelWindowHeight)
            panel.setFrame(start, display: false)
        }

        // Lay the content out at the width it is about to be shown at, before
        // anything animates.
        //
        // `NSHostingView` sizes itself lazily — more so since the macOS 15 SDK
        // — and `create()` makes the window at `collapsedWidth`, so a panel
        // built moments ago is still laid out for that narrower frame. Left to
        // catch up on its own it did so mid-descent: the panel arrived from the
        // side with its content cut off. Only after an idle spell, because only
        // then has the panel been torn down and rebuilt (a Space switch while
        // hidden, sleep, a display change) rather than reused.
        panel.updateConstraintsIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()

        // .moveToActiveSpace перед orderFront гарантирует привязку к текущему
        // Space; .canJoinAllSpaces после — расширяет присутствие на все Desktop.
        // Подробнее — в orderFrontOnActiveSpace.
        orderFrontOnActiveSpace(panel)
        installMouseRegionTracking()
        trace("showAnimated.afterOrderFront")

        if metrics.hasNotch {
            let target = frameForWidth(clampedWidth(currentWidthForCurrentRoute, on: screen), on: screen, height: panelWindowHeight)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.openAnimation
                ctx.timingFunction = PanelTiming.decelerate

                withAnimation(PanelTiming.contentFadeIn) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGenerationMatches(transitionToken) else {
                        self?.trace("showAnimated.completion.tokenMismatch")
                        return
                    }
                    self.interactionState.isEnabled = true
                    // Only finalise to .main if nothing reassigned state during
                    // the animation (e.g. countdown overlay set .countdown).
                    if case .showing = self.state { self.state = .main }
                    self.trace("showAnimated.completion.done")
                }
            }
        } else {
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = panelWindowHeight
            let visible = frameForWidth(w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.openAnimation
                ctx.timingFunction = PanelTiming.decelerate

                withAnimation(PanelTiming.contentFadeIn) {
                    self.interactionState.contentVisibility = 1.0
                }
                panel.animator().setFrame(visible, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGenerationMatches(transitionToken) else {
                        self?.trace("showAnimated.completion.tokenMismatch")
                        return
                    }
                    self.interactionState.isEnabled = true
                    // Only finalise to .main if nothing reassigned state during
                    // the animation (e.g. countdown overlay set .countdown).
                    if case .showing = self.state { self.state = .main }
                    self.trace("showAnimated.completion.done")
                }
            }
        }
        return transitionToken
    }

    func hideAnimated(reason: PanelHideReason = .unknown, completion: (() -> Void)? = nil) {
        trace("hideAnimated.begin reason=\(reason.rawValue)")
        guard let panel, panel.isVisible else {
            trace("hideAnimated.skip reason=\(reason.rawValue)")
            // Even when AppKit says there is nothing visible to hide, a delayed
            // action may still be waiting for that old panel. Invalidate it.
            bumpGeneration()
            completion?()
            return
        }
        rootState.isArchivePinned = false
        // The panel is going away with the sheet's anchor: drop the hold so a
        // close notification that never arrives can't wedge auto-hide.
        isSharePickerOpen = false
        isQuickLookOpen = false

        // Cancel any active countdown before hiding
        if case .countdown = state {
            cancelCountdownTimer()
            activeCountdown = nil
            rootState.countdownVisible = 0.0
            rootState.countdownSeconds = 0
            rootState.countdownTotal = 0
            route = .main
        }

        // The Translator closes the same way the archive does. It used to fall
        // through to the Main path, which is built for the 34pt strip: no
        // content pre-fade and no morph, so a tall panel of text was still on
        // screen while the window resized under it — and text laid out at the
        // panel's width re-wraps line by line as that width travels.
        let wasExpanded = (route == .archive || route == .translate)
        state = .hiding
        interactionState.isEnabled = false
        bumpGeneration()
        pendingHideCompletion = completion

        guard let screen = (currentScreen ?? NSScreen.main ?? NSScreen.screens.first) else {
            panel.orderOut(nil)
            interactionState.isEnabled = true
            firePendingHideCompletion()
            return
        }

        if wasExpanded {
            hideExpandedThenMain(panel: panel, screen: screen)
        } else {
            hideMainPanel(panel: panel, screen: screen)
        }
    }

    // Closing from Archive state: reverse of the open sequence.
    // Phase 1 — content hides instantly.
    // Phase 2 — shape morphs back to Main (Y axis).
    // Phase 3 — standard Main close animation (X axis).
    /// Closing an expanded route — archive or Translator — in three phases:
    /// dissolve what is in the body, morph the shape back to the Main strip,
    /// then run the ordinary Main close.
    ///
    /// The dissolve is a real animation rather than a single frame's snap. The
    /// archive's cells could vanish outright without anyone minding — they are
    /// small, and there are several. A paragraph of text disappearing between
    /// two frames reads as a glitch, and it has to be gone before the morph
    /// starts either way: it is laid out at the panel's width, so any of it
    /// still visible while the window narrows re-wraps on the way down.
    private func hideExpandedThenMain(panel: NSPanel, screen: NSScreen) {
        let token = makePanelTransitionToken()
        let dissolveDelay = PanelTiming.contentDissolve
        let hideDelay = PanelTiming.hideAnimation
        interactionState.contentVisibility = 0.0
        withAnimation(.easeOut(duration: PanelTiming.contentDissolve)) {
            rootState.routeContentVisible = 0.0
        }

        Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .seconds(dissolveDelay))
            guard let self, let panel,
                  self.animationGenerationMatches(token)
            else { return }
            guard case .hiding = self.state else { return }

            // Phase 2: morph shape archive → main (Y axis via progress, width unchanged).
            self.route = .main
            withAnimation(PanelTiming.accelerateSwift(PanelTiming.hideAnimation)) {
                self.rootState.progress = 0.0
            }

            // Phase 3: kick off the standard main-panel close.
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .seconds(hideDelay))
                guard let self, let panel,
                      self.animationGenerationMatches(token)
                else { return }
                guard case .hiding = self.state else { return }
                self.rootState.routeContentVisible = 1.0  // reset for next open
                self.hideMainPanel(panel: panel, screen: screen)
            }
        }
    }

    private func hideMainPanel(panel: NSPanel, screen: NSScreen) {
        let token = makePanelTransitionToken()
        if metrics.hasNotch {
            let target = frameForWidth(collapsedWidth, on: screen, height: panelWindowHeight)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.hideAnimation
                ctx.timingFunction = PanelTiming.accelerate

                withAnimation(PanelTiming.contentFadeOut) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(target, display: true)
            } completionHandler: { [weak self, weak panel] in
                // Synchronously where possible, never through a bare `Task`:
                // hopping to the next runloop turn opened a gap between the
                // animation ending and the completion below. A show landing in
                // that gap clears `pendingHideCompletion` by design — "a show
                // interrupting a hide aborts it" — so a capture waiting on this
                // hide was dropped roughly once in three delayed shots, with
                // nothing to say why.
                onMainActorNow {
                    self?.uninstallMouseRegionTracking()
                    panel?.orderOut(nil)
                    guard let self else { return }
                    if self.animationGenerationMatches(token) {
                        self.state = .hidden
                        self.interactionState.isEnabled = true
                        self.route = .main
                        self.rootState.progress = 0.0
                        self.rootState.isArchivePinned = false
                        self.rootState.countdownVisible = 0.0
                        self.rootState.countdownSeconds = 0
                        self.rootState.countdownTotal = 0
                        self.trace("hideMainPanel.completion.orderOut")
                    } else {
                        self.trace("hideMainPanel.completion.genMismatch")
                    }
                    // Fires either way. A stale token means a newer transition
                    // owns how the panel looks — not that the capture this hide
                    // was started for should be thrown away.
                    self.firePendingHideCompletion()
                }
            }
        } else {
            let w = clampedWidth(currentWidthForCurrentRoute, on: screen)
            let h = panelWindowHeight
            // Mirror of the reveal: notch tab rises just the content height (so the
            // close is fully visible), rounded style slides up fully above.
            let hidden = metrics.pinnedToTopEdge
                ? frameNotchTabHidden(width: w, on: screen)
                : frameNoNotchHiddenAbove(width: w, on: screen, height: h)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.hideAnimation
                ctx.timingFunction = PanelTiming.accelerate

                withAnimation(PanelTiming.contentFadeOut) {
                    self.interactionState.contentVisibility = 0.0
                }
                panel.animator().setFrame(hidden, display: true)
            } completionHandler: { [weak self, weak panel] in
                // Synchronously where possible, never through a bare `Task`:
                // hopping to the next runloop turn opened a gap between the
                // animation ending and the completion below. A show landing in
                // that gap clears `pendingHideCompletion` by design — "a show
                // interrupting a hide aborts it" — so a capture waiting on this
                // hide was dropped roughly once in three delayed shots, with
                // nothing to say why.
                onMainActorNow {
                    self?.uninstallMouseRegionTracking()
                    panel?.orderOut(nil)
                    guard let self else { return }
                    if self.animationGenerationMatches(token) {
                        self.state = .hidden
                        self.interactionState.isEnabled = true
                        self.route = .main
                        self.rootState.progress = 0.0
                        self.rootState.isArchivePinned = false
                        self.rootState.countdownVisible = 0.0
                        self.rootState.countdownSeconds = 0
                        self.rootState.countdownTotal = 0
                        self.trace("hideMainPanel.completion.orderOut")
                    } else {
                        self.trace("hideMainPanel.completion.genMismatch")
                    }
                    // Fires either way. A stale token means a newer transition
                    // owns how the panel looks — not that the capture this hide
                    // was started for should be thrown away.
                    self.firePendingHideCompletion()
                }
            }
        }
    }

    // MARK: - Where the panel actually is

    /// The part of the panel window the panel is drawn in.
    ///
    /// The window is always `panelWindowHeight` tall whatever route is showing
    /// (see NotchPanelLayout) and everything below the content is transparent.
    /// The window frame is therefore not the panel: on a 1280×832 screen it
    /// reaches 168pt down from the top edge while Main draws 34 of them, and
    /// the frame is what both of the things below used to go on.
    var drawnContentRect: NSRect {
        guard let panel else { return .null }
        let f = panel.frame
        // The same height the root view lays the content out at: the strip
        // grows to the route's height as the morph progresses.
        let routeH = routeHeight(for: route)
        let drawn = (metrics.panelHeight + rootState.progress * (routeH - metrics.panelHeight))
            * metrics.panelScale
        let h = min(f.height, max(0, drawn))
        return NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
    }

    func isPointInsidePanel(_ point: NSPoint) -> Bool {
        drawnContentRect.contains(point)
    }

    // MARK: - Mouse region

    /// Monitors that keep `ignoresMouseEvents` in step with the pointer.
    private var mouseRegionMonitors: [Any] = []

    /// Keeps the window from taking the mouse where it draws nothing.
    ///
    /// A transparent NSWindow still owns the pointer over its empty area, and
    /// this one sits at `.statusBar` inside a max-level CGS space — above every
    /// ordinary window on screen. The settings window is the case that found
    /// this: the `.preference` toolbar centres the tab icons in its titlebar,
    /// `NSWindow.center()` lands that titlebar around y=700..745, and the
    /// panel's empty half covers y=664..832 — so with the panel open the tabs
    /// took no clicks at all, and only sometimes lit up under the pointer.
    ///
    /// A button held down means a drag may be in flight, and a file arriving
    /// from Finder is a dragging session rather than events we can see —
    /// `ignoresMouseEvents` would drop that drop too. So the pass-through is
    /// only ever armed with every button up.
    private func updateMouseRegion() {
        guard let panel, panel.isVisible else { return }
        let onContent = drawnContentRect.contains(NSEvent.mouseLocation)
        let buttonsDown = NSEvent.pressedMouseButtons != 0
        panel.ignoresMouseEvents = !(onContent || buttonsDown)
    }

    private func installMouseRegionTracking() {
        guard mouseRegionMonitors.isEmpty else { return }
        // Both halves are needed: while the pass-through is armed the pointer's
        // own events go to the window underneath, so only the global monitor
        // sees the pointer come back onto the panel.
        let types: NSEvent.EventTypeMask = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .leftMouseUp
        ]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: types, handler: { [weak self] _ in
            self?.updateMouseRegion()
        }) {
            mouseRegionMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
            self?.updateMouseRegion()
            return event
        }) {
            mouseRegionMonitors.append(l)
        }
        updateMouseRegion()   // the pointer may already be parked off the content
    }

    private func uninstallMouseRegionTracking() {
        mouseRegionMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseRegionMonitors.removeAll()
        panel?.ignoresMouseEvents = false
    }

    // MARK: - Panel lifecycle

    private func create() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: collapsedWidth, height: panelWindowHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.appearance = NSAppearance(named: .darkAqua)

        panel.contentView = NSHostingView(rootView: makeRootView().managedLocale())
        // A first pass here so the view has a size at all; `showAnimated` runs
        // another one once it knows the width the panel is opening at.
        panel.updateConstraintsIfNeeded()
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
        // A new NSPanel is a new lifecycle even when the route and generation
        // happen to be unchanged from the caller's point of view.
        transitionCoordinator.rebind()

        // Place the panel in the dedicated CGS space when the private symbols
        // are available; otherwise the adapter keeps standard AppKit Space
        // behavior. Assigning replaces any previous membership, so only the
        // current window is ever attached.
        NotchSpaceManager.shared.adapter.attach(panel)
    }

    /// Держит Esc-хоткей зарегистрированным ровно пока панель на экране.
    /// Вызывается из state.didSet и из наблюдателей шер-шита: Carbon-хоткей
    /// (в отличие от прежнего listen-only CGEventTap) съедает Esc системно,
    /// поэтому держать его можно только там, где панель реально может на него
    /// отреагировать — условие целиком в `PanelState.wantsEscapeHotkey`.
    private func syncEscapeHotkey() {
        // The cycle keys ride along here because they are held by SwiftUI
        // `@State` on the root view, and the root view is not unmounted when
        // the panel hides — the window is ordered out and the hosting view
        // kept for the next show. So `onDisappear` does not run, and a pointer
        // that was over the panel when it went away leaves `onHover` with no
        // reason to fire false. The owner would stay pushed and ⇥ would be
        // gone from every app on the machine, which is the exact shape of the
        // Space leak this file already carries a fix for.
        if !state.wantsCycleHotkey {
            TransientHotkeyCenter.tab.releaseAll()
            TransientHotkeyCenter.shiftTab.releaseAll()
        }

        let wantsEsc = state.wantsEscapeHotkey(isSharePickerOpen: isSharePickerOpen)
        if wantsEsc, escToken == nil {
            escToken = TransientHotkeyCenter.escape.push { [weak self] in
                guard let self, self.isVisible else { return }
                switch self.state.escapeAction(
                    hasExpandedStack: self.archiveExpansion.stackID != nil,
                    isSelecting: self.archiveSelection.isActive,
                    translateCameFromArchive: self.translateReturnRoute == .archive
                ) {
                case .collapseStack:
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        self.archiveExpansion.stackID = nil
                    }
                case .exitSelection:
                    withAnimation(.easeInOut(duration: 0.18)) {
                        self.archiveSelection.clear()
                    }
                case .backToArchive:
                    self.leaveTranslate()
                case .hidePanel:
                    self.hideAnimated(reason: .escKey)
                }
            }
        } else if !wantsEsc, let token = escToken {
            TransientHotkeyCenter.escape.remove(token)
            escToken = nil
        }
    }

    /// Снимает Esc-регистрацию напрямую (страховка для teardown-путей;
    /// обычно это делает syncEscapeHotkey при смене state).
    private func removeEscMonitor() {
        if let token = escToken {
            TransientHotkeyCenter.escape.remove(token)
            escToken = nil
        }
    }

    private func makeRootView() -> NotchPanelRootView {
        NotchPanelRootView(
            rootState: rootState,
            interaction: interactionState,
            model: model,
            archiveModel: archiveModel,
            archiveExpansion: archiveExpansion,
            archiveSelection: archiveSelection,
            shareAnchor: archiveShareAnchor,
            onClose: { [weak self] in self?.hideAnimated(reason: .closeButton) },
            onCapture: { [weak self] mode, delay in
                guard let self else { return }
                if delay == .off {
                    let screen = self.currentScreen ?? NSScreen.main
                    if mode == .selection {
                        guard !self.isInPreSelection else { return }
                        self.hideAnimated(reason: .captureStart) { [weak self] in
                            guard let self else { return }
                            // hideAnimated set state to .hidden; promote to
                            // .preSelection now that the overlay is taking over.
                            self.state = .preSelection(.selection)
                            let selectionToken = self.makePanelTransitionToken()
                            self.selectionOverlay.onSelected = { [weak self] rect in
                                guard let self else { return }
                                guard self.animationGenerationMatches(selectionToken),
                                      case .preSelection(.selection) = self.state
                                else { return }
                                self.state = .hidden
                                self.schedulePanelAction(after: 0.1,
                                                         token: selectionToken,
                                                         requiresVisible: false) { [weak self] in
                                    guard let self, case .hidden = self.state else { return }
                                    self.screenshot.captureRect(rect, preferredScreen: screen)
                                }
                            }
                            self.selectionOverlay.onCancelled = { [weak self] in
                                guard let self,
                                      self.animationGenerationMatches(selectionToken) else { return }
                                self.invalidatePanelTransitionActions()
                                self.state = .hidden
                            }
                            self.selectionOverlay.start(on: screen ?? NSScreen.main ?? NSScreen.screens[0])
                        }
                    } else {
                        self.hideAnimated(reason: .captureStart) { [weak self] in
                            guard let self else { return }
                            // For window mode the user still has to pick a window,
                            // so promote to .preSelection to keep the mascot awake.
                            if mode == .window {
                                self.state = .preSelection(.window)
                            }
                            self.screenshot.capture(mode: mode, delaySeconds: 0, preferredScreen: screen)
                        }
                    }
                } else if mode == .screen {
                    self.startScreenCountdown(seconds: delay.seconds)
                } else {
                    self.launchPreSelection(mode: mode, seconds: delay.seconds)
                }
            },
            onToggleArchive: { [weak self] in self?.switchToArchive() },
            onPickColor: { [weak self] in self?.pickColor() },
            onScan: { [weak self] in self?.scan() },
            onModeDelayChanged: { [weak self] in self?.updateWidthForNoNotchIfNeeded() },
            onBack: { [weak self] in self?.switchToMain() },
            onLeaveTranslate: { [weak self] in self?.leaveTranslate() },
            onPreviewText: { [weak self] text in
                guard let self else { return }
                TranslationPanelModel.shared.present(.preview(of: text),
                                                     bodyWidth: self.translateBodyWidth)
                self.presentTranslation(on: self.currentScreen, returningTo: .archive)
            },
            onPickLanguage: { [weak self] text, language in
                guard let self else { return }
                // The text on screen, into the language just chosen — and the
                // result is filed like any other translation, so a chain of
                // them leaves a copy per language in the archive.
                ArchiveTranslate.run(text, to: language,
                                     archiveModel: self.archiveModel,
                                     on: self.currentScreen)
            },
            onHidePanel: { [weak self] in self?.hideAnimated(reason: .closeButton) },
            onTogglePin: { [weak self] in self?.rootState.isArchivePinned.toggle() },
            onStopCountdown: { [weak self] in self?.stopCountdown() },
            onCaptureNow: { [weak self] in self?.captureNowFromCountdown() },
            onCycleHeader: { [weak self] backwards in
                self?.cycleHeaderSelection(backwards: backwards)
            }
        )
    }

    // MARK: - Header cycling

    /// ⇥ on the open panel: steps whatever the header offers to choose.
    ///
    /// One key for two things because they are the same thing from the user's
    /// side — the pop-up in the top-left corner of whichever surface is up.
    /// The archive's is the colour format, the translator's is the language,
    /// and neither surface has a second list to confuse it with.
    ///
    /// The two are not equally cheap, and that is deliberate rather than
    /// overlooked: cycling a colour format redraws a label, while cycling a
    /// language starts a translation and files another archive entry. The
    /// guard below is what keeps a held key from queueing a stack of them.
    func cycleHeaderSelection(backwards: Bool = false) {
        switch route {
        case .archive:
            let next = nextCase(after: AppSettings.defaultColorFormat, backwards: backwards)
            UserDefaults.standard.set(next.rawValue, forKey: AppSettings.Keys.defaultColorFormat)
        case .translate:
            let model = TranslationPanelModel.shared
            // Already fetching one: the body is dimmed saying so, and a second
            // request now would land after it and overwrite what it produced.
            guard !model.isReworking, let shown = model.result else { return }
            let languages = TranslationLanguages.shared
            guard let next = TranslationLanguages.language(after: shown.language,
                                                           in: languages.favourites,
                                                           backwards: backwards)
            else {
                // Nowhere to step: the list is down to one language, or none.
                // Returning quietly made ⇥ a key that did nothing in the one
                // place the panel was inviting it to be pressed — so it leads
                // where the missing languages are added instead.
                TranslationSetupWindowController.shared.show()
                return
            }
            model.beginRework()
            ArchiveTranslate.run(shown.text, to: next,
                                 archiveModel: archiveModel, on: currentScreen)
        default:
            // `.main` and the countdown have no header list to step through.
            break
        }
    }

    // MARK: - State routing

    /// Width the translation is laid out at: the panel less the shoulders it
    /// must stay inside, less the text's own inset. Known before the panel
    /// opens, which is what lets the body be sized before it is drawn.
    var translateBodyWidth: CGFloat {
        let skew: CGFloat = metrics.pinnedToTopEdge ? 16 : 0
        return max(1, archiveWidth
                   - 2 * (metrics.edgeSafe + skew)
                   - 2 * NotchTranslateView.textInset)
    }

    /// Height a route settles at. The Translator's follows its text, so this
    /// is asked at the moment it is needed rather than stored.
    func routeHeight(for route: NotchPanelRoute) -> CGFloat {
        route == .translate
            ? metrics.panelHeight + TranslationPanelModel.shared.bodyHeight
            : archivePanelHeight
    }

    func switchToArchive() {
        if route == .archive { switchToMain() } else { transitionBetweenStates(.archive) }
    }

    /// Brings the Translator up over whatever is showing. Unlike the archive
    /// this never toggles: it is reached by finishing a translation, and a
    /// second result arriving while it is open should replace the text, not
    /// close the panel.
    func switchToTranslate(returningTo source: NotchPanelRoute = .main) {
        guard route != .translate else { return }
        translateReturnRoute = source
        transitionBetweenStates(.translate)
    }

    /// Back out of the Translator to wherever it was opened from. A
    /// translation raised over nothing goes to Main; an archive entry opened
    /// for reading goes back to the archive it was read from.
    func leaveTranslate() {
        guard route == .translate else { return }
        let destination = translateReturnRoute
        translateReturnRoute = .main
        if destination == .archive {
            transitionBetweenStates(.archive)
        } else {
            switchToMain()
        }
    }

    func switchToMain() {
        guard route != .main else { return }
        rootState.isArchivePinned = false
        transitionBetweenStates(.main)
    }

    func transitionBetweenStates(_ targetRoute: NotchPanelRoute) {
        guard let panel else { return }
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        // Coalesce re-entrant toggles: ignore a new archive morph while one is still
        // in flight. Overlapping transitions orphan each other's completion
        // handlers (generation mismatch), which left brief half-morphed/stuck
        // states during rapid clicking. hideAnimated/showAnimated (Esc, hotkey,
        // outside-click) are not routed through here, so they can still interrupt.
        if case .transitioning = state { return }

        bumpGeneration()
        let transitionToken = makePanelTransitionToken()
        let target: TransitionTarget
        switch targetRoute {
        case .archive:   target = .archive
        case .translate: target = .translate
        default:         target = .main
        }
        state = .transitioning(to: target)
        interactionState.isEnabled = false

        // A close from the Translator has further to travel than one from the
        // archive — up to 168pt against 89 — so the same timing reads as a
        // snap. The morph is stretched in proportion to the distance rather
        // than to a fixed number, which keeps every intermediate height, and
        // the Translator's is whatever its text asked for.
        let leavingHeight = routeHeight(for: route)
        let closeStretch = min(1.5, max(1, leavingHeight / archivePanelHeight))
        let contentDissolveDelay = PanelTiming.contentDissolve
        let routeSwapDelay = PanelTiming.routeSwapMorph
        let contentRevealDuration = PanelTiming.contentReveal
        let morphTailDelay = PanelTiming.morphTail

        // Archive ⇄ Translator is neither an open nor a close: both are already
        // expanded and at full progress, so the only travel is the shape's
        // height. `route` is a discrete value with nothing to interpolate, so
        // whichever body is on screen was being snapped away and the other
        // snapped in — headers and all. Given its own phase it dissolves out,
        // the shape moves, and the arriving body dissolves in.
        let swappingExpandedRoutes = targetRoute != .main
            && (route == .archive || route == .translate)
            && route != targetRoute

        if swappingExpandedRoutes {
            withAnimation(.easeOut(duration: PanelTiming.contentDissolve)) {
                rootState.routeContentVisible = 0.0
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(contentDissolveDelay))
                guard let self, self.animationGenerationMatches(transitionToken) else { return }
                // Height only: progress is already 1 and the width is the
                // same, so the shape's own `extraHeight` spring does the work.
                self.route = targetRoute

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(routeSwapDelay))
                    guard let self, self.animationGenerationMatches(transitionToken) else { return }
                    self.state = targetRoute == .translate ? .translate : .archive
                    self.interactionState.isEnabled = true
                    withAnimation(.easeOut(duration: contentRevealDuration)) {
                        self.rootState.routeContentVisible = 1.0
                    }
                }
            }
            return
        }

        if targetRoute == .main {
            // Step 1: hide content in a separate render pass (without withAnimation).
            // Calling it together with withAnimation { progress = 0 } causes SwiftUI to
            // batch both objectWillChange notifications and apply the easeIn context to
            // both — opacity would then animate 1→0 over archiveCloseMorph instead of
            // snapping instantly.
            //
            // It matters more here than it used to: the Translator's body is
            // text laid out at the panel's width, so a body left visible
            // through the collapse re-wraps line by line on the way down.
            withAnimation(.easeOut(duration: PanelTiming.contentDissolve)) {
                rootState.routeContentVisible = 0.0
            }

            // Step 2: let the dissolve finish before the shape starts moving.
            Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .seconds(contentDissolveDelay))
                guard let self, let panel,
                      self.animationGenerationMatches(transitionToken) else { return }

                self.route = .main
                let targetFrame = self.frameForWidth(
                    self.clampedWidth(self.currentWidthForCurrentRoute, on: screen),
                    on: screen, height: self.panelWindowHeight
                )

                // X axis: panel width — NSAnimationContext. `settle`, not
                // `accelerate`: the panel stays on screen after this morph,
                // so X must land as softly as the Y-axis spring below.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = PanelTiming.archiveCloseMorph * closeStretch
                    ctx.timingFunction = PanelTiming.settle
                    panel.animator().setFrame(targetFrame, display: true)
                } completionHandler: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.animationGenerationMatches(transitionToken) else { return }
                        self.state = .main
                        self.interactionState.isEnabled = true
                        self.rootState.routeContentVisible = 1.0  // reset for next open
                    }
                }

                // Y axis: shape morph — spring settle, no abrupt stop at the seam
                withAnimation(.spring(response: 0.34 * closeStretch, dampingFraction: 0.9)) {
                    self.rootState.progress = 0.0
                }
            }
        } else {
            // Opening: spring easing
            route = targetRoute
            // The archive's cells ride the morph in, so its content is visible
            // from the start. The Translator's body waits: it is revealed by
            // the completion handler once the shape has finished travelling.
            //
            // Either way this has to be set. A rapid open→close can strand
            // routeContentVisible at 0 — the close dissolves it and its reset
            // back to 1 is generation-gated, so an interrupted close skips the
            // reset; without this the next open showed only empty background.
            rootState.routeContentVisible = targetRoute == .translate ? 0.0 : 1.0
            let targetFrame = frameForWidth(
                clampedWidth(currentWidthForCurrentRoute, on: screen),
                on: screen, height: panelWindowHeight
            )
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = PanelTiming.archiveCloseMorph
                ctx.timingFunction = PanelTiming.decelerate
                panel.animator().setFrame(targetFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.animationGenerationMatches(transitionToken) else { return }
                    self.state = targetRoute == .translate ? .translate : .archive
                    self.interactionState.isEnabled = true
                    guard targetRoute == .translate else { return }
                    // Not here, a moment later. This closure fires when the window
                    // frame animation is done, and the shape is not the frame: its
                    // height rides a SwiftUI spring, which is still easing out well
                    // after `NSAnimationContext` calls itself finished. Revealing
                    // on this signal put the text on screen while the panel was
                    // still growing under it.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(morphTailDelay))
                        guard let self,
                              self.animationGenerationMatches(transitionToken) else { return }
                        withAnimation(.easeOut(duration: contentRevealDuration)) {
                            self.rootState.routeContentVisible = 1.0
                        }
                    }
                }
            }
            Task { @MainActor [weak self] in
                guard let self, self.animationGenerationMatches(transitionToken) else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                    self.rootState.progress = 1.0
                }
            }
        }
    }

    // MARK: - Layout helpers that require panel access

    func updateScreenMetrics(for screen: NSScreen) {
        metrics = NotchMetrics.from(screen: screen)
    }

    func updateWidthForNoNotchIfNeeded() {
        guard !metrics.hasNotch else { return }
        guard let panel else { return }
        // `route` is not enough. It stays `.main` for the whole of a hide — it
        // is reset in the hide's completion — so a delay change landing mid-hide
        // used to animate the frame back to `frameForWidth`, the panel's *shown*
        // position, and `animator().setFrame` replaces the hide already in
        // flight rather than losing to it. The panel travelled back down instead
        // of leaving.
        guard case .main = state, panel.isVisible else { return }
        guard route == .main else { return }
        guard let screen = currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }

        let w = clampedWidth(expandedWidth, on: screen)
        // Keep the window at the full archive height — only the width may change here.
        // Animating height collapsed the panel vertically (it was created/shown at
        // archivePanelHeight but this used the default panelHeight).
        let target = frameForWidth(w, on: screen, height: panelWindowHeight)

        // Both halves on one duration and one curve — see `delayWidthMorph`
        // for why that curve is linear.
        //
        // This used to snap, and the comment here blamed the window animation:
        // it lagged behind content that reflowed instantly. But the content
        // only snapped because the timer cell asked it to, so snapping the
        // window too was treating the symptom.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = PanelTiming.delayWidthMorph
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().setFrame(target, display: true)
        }
    }
}

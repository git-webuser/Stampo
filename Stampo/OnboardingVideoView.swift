import AVFoundation
import SwiftUI

/// Theme-aware, silent onboarding motion rendered without playback controls.
///
/// The exported MP4s intentionally carry their own light/dark stage colors.
/// Matching the layer background prevents a flash while AVFoundation prepares
/// the first frame.
struct OnboardingVideoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var resourceName: String {
        colorScheme == .dark ? "OnboardingDark" : "OnboardingLight"
    }

    private var stageColor: NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 30.0 / 255.0,
                      green: 30.0 / 255.0,
                      blue: 30.0 / 255.0,
                      alpha: 1)
            : .white
    }

    var body: some View {
        OnboardingVideoPlayer(
            resourceName: resourceName,
            stageColor: stageColor,
            reduceMotion: reduceMotion
        )
        .aspectRatio(3.0 / 2.0, contentMode: .fit)
        .background(Color(nsColor: stageColor))
        .allowsHitTesting(false)
        // The adjacent localized tip describes the animation's meaning.
        .accessibilityHidden(true)
    }
}

private struct OnboardingVideoPlayer: NSViewRepresentable {
    let resourceName: String
    let stageColor: NSColor
    let reduceMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = context.coordinator.player
        view.setStageColor(stageColor)
        context.coordinator.configure(
            resourceName: resourceName,
            reduceMotion: reduceMotion
        )
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.setStageColor(stageColor)
        context.coordinator.configure(
            resourceName: resourceName,
            reduceMotion: reduceMotion
        )
    }

    static func dismantleNSView(
        _ nsView: PlayerContainerView,
        coordinator: Coordinator
    ) {
        coordinator.stop()
        nsView.playerLayer.player = nil
    }

    final class Coordinator {
        let player = AVQueuePlayer()

        private var looper: AVPlayerLooper?
        private var loadedResourceName: String?
        private var isReducingMotion = false

        init() {
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        func configure(resourceName: String, reduceMotion: Bool) {
            let resourceChanged = loadedResourceName != resourceName
            let motionPreferenceChanged = isReducingMotion != reduceMotion
            guard resourceChanged || motionPreferenceChanged else { return }

            isReducingMotion = reduceMotion

            if resourceChanged {
                load(resourceName: resourceName)
            }

            if reduceMotion {
                showPosterFrame()
            } else {
                if motionPreferenceChanged || resourceChanged {
                    player.seek(to: .zero)
                }
                player.play()
            }
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            loadedResourceName = nil
        }

        private func load(resourceName: String) {
            player.pause()
            looper?.disableLooping()
            looper = nil
            player.removeAllItems()
            loadedResourceName = resourceName

            guard let url = Self.resourceURL(named: resourceName) else {
                assertionFailure("Missing onboarding video resource: \(resourceName).mp4")
                return
            }

            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
        }

        private func showPosterFrame() {
            player.pause()
            // A composed overview near the end of the source timeline conveys
            // the interaction without motion when Reduce Motion is enabled.
            let posterTime = CMTime(seconds: 8, preferredTimescale: 600)
            player.seek(
                to: posterTime,
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        private static func resourceURL(named name: String) -> URL? {
            // File-system-synchronized Xcode groups normally flatten resources
            // into the bundle root. Keep the subdirectory lookup as a defensive
            // fallback if the copy behavior changes.
            Bundle.main.url(forResource: name, withExtension: "mp4")
                ?? Bundle.main.url(
                    forResource: name,
                    withExtension: "mp4",
                    subdirectory: "Resources/Onboarding"
                )
        }
    }
}

private final class PlayerContainerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func setStageColor(_ color: NSColor) {
        let cgColor = color.cgColor
        layer?.backgroundColor = cgColor
        playerLayer.backgroundColor = cgColor
    }
}

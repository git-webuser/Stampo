import AVFoundation
import SwiftUI

/// Theme-aware, silent onboarding motion rendered without playback controls.
///
/// The exported MP4s intentionally carry their own light/dark stage colors.
/// Matching the layer background prevents a flash while AVFoundation prepares
/// the first frame.
///
/// Under Reduce Motion the video is not played at all: a single frame is
/// extracted up front and shown as a still image. Seeking a paused player was
/// the obvious alternative but cannot work — `AVPlayerLooper` enqueues its
/// items asynchronously, so a seek issued right after `init` finds a nil
/// `currentItem`, completes with `false`, and leaves the player on frame zero.
struct OnboardingVideoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var posterImage: CGImage?

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
        Group {
            if reduceMotion {
                posterView
            } else {
                OnboardingVideoPlayer(
                    resourceName: resourceName,
                    stageColor: stageColor
                )
            }
        }
        // Matches the exported assets (1600×800). Changing the export means
        // changing this, or resizeAspectFill silently crops the frame.
        .aspectRatio(2.0, contentMode: .fit)
        .background(Color(nsColor: stageColor))
        .allowsHitTesting(false)
        // The animation is the only place the notch gesture is explained, so
        // it carries a spoken equivalent rather than being hidden outright.
        .accessibilityElement()
        .accessibilityLabel(
            "Click the notch — or the center of the menu bar on screens without one — to open the panel."
        )
    }

    private var posterView: some View {
        Color(nsColor: stageColor)
            .overlay {
                if let posterImage {
                    Image(decorative: posterImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .clipped()
            .task(id: resourceName) {
                posterImage = await OnboardingMotionAsset.posterFrame(
                    named: resourceName
                )
            }
    }
}

// MARK: - Asset lookup

private enum OnboardingMotionAsset {
    /// A composed overview near the end of the source timeline: it conveys the
    /// interaction in one frame, which is what Reduce Motion needs. Picked off
    /// the 15.03s exports as their calmest composed moment — the panel and the
    /// capture thumbnail are both up, and the fade-out has not started.
    static let posterTime = CMTime(seconds: 12, preferredTimescale: 600)

    static func url(named name: String) -> URL? {
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

    static func posterFrame(named name: String) async -> CGImage? {
        guard let url = url(named: name) else {
            assertionFailure("Missing onboarding video resource: \(name).mp4")
            return nil
        }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        do {
            return try await generator.image(at: posterTime).image
        } catch {
            // A missing poster leaves the stage color in place — still a valid
            // frame for the layout, so there is nothing to escalate.
            return nil
        }
    }
}

// MARK: - Player

private struct OnboardingVideoPlayer: NSViewRepresentable {
    let resourceName: String
    let stageColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = context.coordinator.player
        view.setStageColor(stageColor)
        context.coordinator.configure(resourceName: resourceName)
        return view
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        nsView.setStageColor(stageColor)
        context.coordinator.configure(resourceName: resourceName)
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

        init() {
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.preventsDisplaySleepDuringVideoPlayback = false
        }

        func configure(resourceName: String) {
            guard loadedResourceName != resourceName else { return }
            load(resourceName: resourceName)
            // Safe before the looper's item lands: the rate is retained and
            // playback starts as soon as the item is ready.
            player.play()
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

            guard let url = OnboardingMotionAsset.url(named: resourceName) else {
                assertionFailure("Missing onboarding video resource: \(resourceName).mp4")
                return
            }

            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
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

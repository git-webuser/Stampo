import AppKit
import Foundation
import Testing
@testable import Stampo

/// Deterministic process seam used to exercise the single-flight lease without
/// depending on WindowServer or the `screencapture` executable.
nonisolated private final class BlockingCaptureRunner: ScreenshotProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var isReleased = false
    private let blocks: Bool

    init(blocks: Bool) {
        self.blocks = blocks
    }

    func run(arguments: [String],
             outputURL: URL,
             shouldCancel: @escaping () -> Bool) -> ScreenshotProcessRunResult {
        lock.withLock { didStart = true }
        while blocks && !shouldCancel() && !lock.withLock({ isReleased }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard !shouldCancel() else { return .exited(status: 1) }
        try? Data("test capture".utf8).write(to: outputURL)
        return .exited(status: 0)
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<1_000 {
            if lock.withLock({ didStart }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    func release() {
        lock.withLock { isReleased = true }
    }

    func terminate() {
        // In production this is Process.terminate(); the fake uses the same
        // seam to wake a runner that is waiting before its process launch.
        release()
    }
}

@Suite struct ScreenshotCapturerConcurrencyTests {
    private let configuration = ScreenshotCaptureConfiguration(
        includeCursor: false,
        includeWindowShadow: true,
        fileFormat: "png"
    )

    @Test func concurrentRequestsAreSingleFlightAndFirstRequestWins() async {
        let runner = BlockingCaptureRunner(blocks: true)
        let capturer = ScreenshotCapturer(processRunnerFactory: { runner })

        let firstTask = Task.detached {
            capturer.captureRectToTemp(CGRect(x: 0, y: 0, width: 10, height: 10),
                                       configuration: configuration)
        }
        #expect(await runner.waitUntilStarted())

        let second = capturer.captureRectToTemp(
            CGRect(x: 0, y: 0, width: 10, height: 10), configuration: configuration
        )
        guard case .busy = second else {
            #expect(Bool(false), "second request must be rejected as busy")
            runner.release()
            _ = await firstTask.value
            return
        }

        runner.release()
        let first = await firstTask.value
        guard case .success(let url, displayID: nil) = first else {
            #expect(Bool(false), "first request should complete successfully")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func cancellationAfterRunnerStartsIsRequestScoped() async {
        let runner = BlockingCaptureRunner(blocks: true)
        let capturer = ScreenshotCapturer(processRunnerFactory: { runner })

        let task = Task.detached {
            capturer.captureRectToTemp(CGRect(x: 0, y: 0, width: 10, height: 10),
                                       configuration: configuration)
        }
        #expect(await runner.waitUntilStarted())
        capturer.terminateCurrentCapture()

        let result = await task.value
        guard case .cancelled = result else {
            #expect(Bool(false), "terminating the active request must report cancellation")
            return
        }
    }

    @Test func successfulScreenCaptureCarriesValueTypeDisplayIdentity() {
        let runner = BlockingCaptureRunner(blocks: false)
        let capturer = ScreenshotCapturer(processRunnerFactory: { runner })
        let result = capturer.captureToTemp(
            mode: .screen,
            displayID: CGDirectDisplayID(42),
            frontmostWindowID: nil,
            configuration: configuration
        )

        guard case .success(let url, let displayID) = result else {
            #expect(Bool(false), "fake screencapture should succeed")
            return
        }
        #expect(displayID == CGDirectDisplayID(42))
        try? FileManager.default.removeItem(at: url)
    }
}

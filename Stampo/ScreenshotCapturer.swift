import AppKit
import OSLog

// MARK: - ScreenshotCapturer

nonisolated struct CaptureFailure: Error, Equatable, Sendable, LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

nonisolated enum CaptureResult: Sendable {
    case success(URL, displayID: CGDirectDisplayID?)
    case cancelled
    case busy
    case failed(CaptureFailure)
}

nonisolated enum ScreenshotProcessRunResult: Sendable {
    case exited(status: Int32)
    case launchFailed(String)
}

/// Process seam for capture tests. The production implementation below owns
/// the AppKit/Foundation `Process`; tests can provide a deterministic runner
/// that creates an output file, blocks, or reports a failure without launching
/// WindowServer tooling.
nonisolated protocol ScreenshotProcessRunner: AnyObject {
    func run(arguments: [String],
             outputURL: URL,
             shouldCancel: @escaping () -> Bool) -> ScreenshotProcessRunResult
    func terminate()
}

nonisolated final class SystemScreenshotProcessRunner: ScreenshotProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func run(arguments: [String],
             outputURL: URL,
             shouldCancel: @escaping () -> Bool) -> ScreenshotProcessRunResult {
        guard !shouldCancel() else { return .exited(status: 1) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        lock.withLock { self.process = process }
        defer { lock.withLock { self.process = nil } }

        do {
            try process.run()
            if shouldCancel(), process.isRunning { process.terminate() }
            process.waitUntilExit()
            return .exited(status: process.terminationStatus)
        } catch {
            return .launchFailed(error.localizedDescription)
        }
    }

    func terminate() {
        let process = lock.withLock { self.process }
        if let process, process.isRunning { process.terminate() }
    }
}

/// Immutable capture options snapshotted on the MainActor before a worker is
/// started. AppKit objects and live settings never cross into the process
/// runner.
nonisolated struct ScreenshotCaptureConfiguration: Sendable {
    let includeCursor: Bool
    let includeWindowShadow: Bool
    let fileFormat: String

    @MainActor
    static var current: Self {
        Self(
            includeCursor: AppSettings.includeCursor,
            includeWindowShadow: AppSettings.includeWindowShadow,
            fileFormat: AppSettings.fileFormat
        )
    }
}

/// Runs the screencapture(1) process and writes output to a temp file.
/// Returns the temp URL on success, or nil on failure.
nonisolated final class ScreenshotCapturer: @unchecked Sendable {
    private let fm = FileManager.default

    // The process is intentionally owned by a small lock boundary. A capture is
    // allowed to block while screencapture(1) is running, but every state change
    // (claim, cancellation and release) is serialized and tagged with a request
    // id so a stale completion can never clear a newer request.
    private let processLock = NSLock()

    private struct ActiveCapture {
        let id: UUID
        let runner: any ScreenshotProcessRunner
        var cancellationRequested = false
    }

    private let processRunnerFactory: () -> any ScreenshotProcessRunner

    private var activeCapture: ActiveCapture?

    init(processRunnerFactory: @escaping () -> any ScreenshotProcessRunner = {
        SystemScreenshotProcessRunner()
    }) {
        self.processRunnerFactory = processRunnerFactory
    }

    /// Прерывает текущий запущенный screencapture(1).
    /// Безопасно вызывать с любого потока.
    func terminateCurrentCapture() {
        let runner = processLock.withLock { () -> (any ScreenshotProcessRunner)? in
            guard var activeCapture else { return nil }
            activeCapture.cancellationRequested = true
            self.activeCapture = activeCapture
            return activeCapture.runner
        }

        // The request may be in the small window before Process.run(). The
        // cancellation bit above covers that case; the runner only terminates
        // an actually-started process.
        runner?.terminate()
    }

    func captureToTemp(mode: CaptureMode,
                       displayID: CGDirectDisplayID?,
                       frontmostWindowID: CGWindowID?,
                       configuration: ScreenshotCaptureConfiguration) -> CaptureResult {
        let tmpURL = makeTempURL(fileFormat: configuration.fileFormat)
        var args: [String] = ["-x"]
        appendFormatFlag(to: &args, configuration: configuration)

        switch mode {
        case .selection:
            if configuration.includeCursor { args.append("-C") }
            args.append(contentsOf: ["-i", "-s"])
        case .window:
            if configuration.includeCursor        { args.append("-C") }
            if !configuration.includeWindowShadow { args.append("-o") }
            if let id = frontmostWindowID {
                args.append(contentsOf: ["-l", String(id)])
            } else {
                args.append(contentsOf: ["-i", "-w"])
            }
        case .screen:
            if configuration.includeCursor { args.append("-C") }
            if let displayID {
                args.append(contentsOf: ["-D", String(displayID)])
            }
        }

        args.append(tmpURL.path)
        let interactive = args.contains("-i")
        let result = run(args, outputURL: tmpURL)
        switch result {
        case .success:
            if fm.fileExists(atPath: tmpURL.path) {
                return .success(tmpURL, displayID: displayID)
            }
            // Interactive picker (-i) exits with status 0 when the user cancels
            // via Esc or right-click — no file is written. Treat that as a
            // cancel rather than a failure so we don't surface an error alert.
            if interactive { return .cancelled }
            return .failed(CaptureFailure(message: "screencapture produced no output file"))
        case .cancelled, .busy, .failed:
            return result
        }
    }

    func captureRectToTemp(_ rect: CGRect,
                           configuration: ScreenshotCaptureConfiguration) -> CaptureResult {
        let tmpURL = makeTempURL(fileFormat: configuration.fileFormat)
        var args = [
            "-x", "-R",
            "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        ]
        appendFormatFlag(to: &args, configuration: configuration)
        if configuration.includeCursor { args.append("-C") }
        args.append(tmpURL.path)
        let result = run(args, outputURL: tmpURL)
        switch result {
        case .success:
            return fm.fileExists(atPath: tmpURL.path)
                ? .success(tmpURL, displayID: nil)
                : .failed(CaptureFailure(message: "screencapture produced no output file"))
        case .cancelled, .busy, .failed:
            return result
        }
    }

    func captureWindowIDToTemp(_ windowID: CGWindowID,
                               configuration: ScreenshotCaptureConfiguration) -> CaptureResult {
        let tmpURL = makeTempURL(fileFormat: configuration.fileFormat)
        var args = ["-x", "-l", String(windowID)]
        appendFormatFlag(to: &args, configuration: configuration)
        if configuration.includeCursor { args.append("-C") }
        args.append(tmpURL.path)
        let result = run(args, outputURL: tmpURL)
        switch result {
        case .success:
            return fm.fileExists(atPath: tmpURL.path)
                ? .success(tmpURL, displayID: nil)
                : .failed(CaptureFailure(message: "screencapture produced no output file"))
        case .cancelled, .busy, .failed:
            return result
        }
    }

    // MARK: - Private

    private func makeTempURL(fileFormat: String) -> URL {
        fm.temporaryDirectory.appendingPathComponent("stampo-\(UUID().uuidString).\(fileExtension(for: fileFormat))")
    }

    private func run(_ arguments: [String], outputURL: URL) -> CaptureResult {
        let captureID = UUID()
        let runner = processRunnerFactory()
        let claimed = processLock.withLock { () -> Bool in
            guard activeCapture == nil else { return false }
            activeCapture = ActiveCapture(id: captureID, runner: runner)
            return true
        }

        guard claimed else {
            Log.capture.warning("screencapture: ignored concurrent launch — already running")
            return .busy
        }

        let processResult = runner.run(
            arguments: arguments,
            outputURL: outputURL,
            shouldCancel: { [weak self] in
                guard let self else { return true }
                return self.processLock.withLock {
                    self.activeCapture?.id == captureID
                        && self.activeCapture?.cancellationRequested == true
                }
            }
        )

        let wasCancelled = processLock.withLock { () -> Bool in
            guard let activeCapture, activeCapture.id == captureID else {
                // Only the owner normally clears its lease. If a future runner
                // implementation releases it early, fail closed as cancel.
                return true
            }
            self.activeCapture = nil
            return activeCapture.cancellationRequested
        }

        if wasCancelled { return .cancelled }

        switch processResult {
        case .exited(let status) where status == 0:
            return .success(outputURL, displayID: nil)
        case .exited(let status):
            Log.capture.error("screencapture exited \(status), args: \(arguments)")
            return .failed(CaptureFailure(message: "screencapture exited with status \(status)"))
        case .launchFailed(let reason):
            Log.capture.error("screencapture launch failed: \(reason), args: \(arguments)")
            return .failed(CaptureFailure(message: reason))
        }
    }

    private func appendFormatFlag(to args: inout [String],
                                  configuration: ScreenshotCaptureConfiguration) {
        args.append(contentsOf: ["-t", configuration.fileFormat])
    }

    private func fileExtension(for format: String) -> String {
        let fmt = format
        return fmt == "jpg" ? "jpg" : (fmt == "tiff" ? "tiff" : "png")
    }
}

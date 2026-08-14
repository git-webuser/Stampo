import Foundation
import Testing
@testable import Stampo

nonisolated private final class SaveResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var urls: [URL] = []
    private(set) var errors: [Error] = []

    func append(url: URL) {
        lock.withLock { urls.append(url) }
    }

    func append(error: Error) {
        lock.withLock { errors.append(error) }
    }
}

@Suite struct ScreenshotSaveCoordinatorTests {
    @Test func parallelEncodedSavesAllocateDistinctDestinations() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stampo-save-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ScreenshotFileStore(destinationDirectory: root)
        let results = SaveResults()
        let data = Data("encoded screenshot".utf8)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                results.append(url: try store.saveEncodedImage(data, format: "png"))
            } catch {
                results.append(error: error)
            }
        }

        #expect(results.errors.isEmpty)
        #expect(results.urls.count == 64)
        #expect(Set(results.urls).count == 64)
        #expect((try? FileManager.default.contentsOfDirectory(at: root,
                                                               includingPropertiesForKeys: nil))?.count == 64)
    }

    @Test func destinationCoordinatorDoesNotOverlapCriticalSections() {
        let coordinator = ScreenshotSaveCoordinator()
        let state = SaveCriticalSectionState()

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            coordinator.withDestinationSection {
                state.enter()
                state.leave()
            }
        }

        #expect(state.maxConcurrent == 1)
    }
}

nonisolated private final class SaveCriticalSectionState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var active = 0
    private(set) var maxConcurrent = 0

    func enter() {
        lock.withLock {
            active += 1
            maxConcurrent = max(maxConcurrent, active)
        }
    }

    func leave() {
        lock.withLock { active -= 1 }
    }
}

import Testing
@testable import Stampo

nonisolated private struct MissingCGSSymbols: CGSSymbolResolver {
    func symbol(named: String) -> UnsafeMutableRawPointer? { nil }
}

@MainActor
@Suite struct CGSSpaceFallbackTests {
    @Test func missingPrivateSymbolsMakeCGSSpaceUnavailable() {
        #expect(CGSSpace(level: 0, resolver: MissingCGSSymbols()) == nil)
    }

    @Test func unavailableCGSAdapterIsNonFatal() {
        let adapter = CGSSpaceAdapter(symbolResolver: MissingCGSSymbols())
        #expect(!adapter.isAvailable)
        adapter.tearDown()
    }
}

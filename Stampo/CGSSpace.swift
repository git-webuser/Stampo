//
//  CGSSpace.swift
//  Stampo
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Original source: https://github.com/avaidyam/Parrot/
// Adapted (via TheBoredTeam/boring.notch) for Stampo.
//
// NOTE: This file uses private CoreGraphics/SkyLight ("CGS") symbols. It is the
// ONLY MPL-2.0 file in this otherwise-MIT project; keep this header intact.

import AppKit
import Darwin

/// Small wrapper around the private Spaces ("CGS") API.
///
/// A `CGSSpace` is a dedicated, app-owned Space at an absolute window level.
/// Windows added to it are composited **independently of the normal user
/// Spaces**: they don't slide during a Space swipe and aren't drawn inside the
/// Mission Control canvas (so the inter-Space band can't cross them).
nonisolated protocol CGSSymbolResolver {
    func symbol(named name: String) -> UnsafeMutableRawPointer?
}

nonisolated struct DynamicCGSSymbolResolver: CGSSymbolResolver {
    func symbol(named name: String) -> UnsafeMutableRawPointer? {
        // Darwin exposes RTLD_DEFAULT as an unavailable C macro in Swift;
        // -2 is its documented default-handle value.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
}

@MainActor
final class CGSSpace {
    private let identifier: CGSSpaceID
    private let symbols: CGSSpaceSymbols

    /// Windows currently placed in this space. Assigning diffs against the
    /// previous set and adds/removes the changed windows by window number.
    public var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(windows)
            let add = windows.subtracting(oldValue)

            let connection = symbols.defaultConnection()
            symbols.removeWindows(connection,
                                   remove.map { $0.windowNumber } as NSArray,
                                   [identifier] as NSArray)
            symbols.addWindows(connection,
                                add.map { $0.windowNumber } as NSArray,
                                [identifier] as NSArray)
        }
    }

    /// An initialized `CGSSpace` MUST live until app exit (its `deinit` tears
    /// the space down). Create it once via a long-lived owner.
    public convenience init?(level: Int = 0) {
        self.init(level: level, resolver: DynamicCGSSymbolResolver())
    }

    /// Injectable initializer used by the fallback tests. Keeping symbol
    /// lookup outside the wrapper makes an unavailable/private API an ordinary
    /// configuration state instead of a process crash.
    init?(level: Int, resolver: any CGSSymbolResolver) {
        guard let symbols = CGSSpaceSymbols(resolver: resolver) else { return nil }
        // This flag MUST be 1, otherwise Finder draws desktop icons into it.
        let flag = 0x1
        let connection = symbols.defaultConnection()
        let identifier = symbols.createSpace(connection, flag, nil)
        guard identifier != 0 else { return nil }

        self.identifier = identifier
        self.symbols = symbols
        symbols.setAbsoluteLevel(connection, identifier, level)
        symbols.showSpaces(connection, [identifier] as NSArray)
    }

    deinit {
        let connection = symbols.defaultConnection()
        symbols.hideSpaces(connection, [identifier] as NSArray)
        symbols.destroySpace(connection, identifier)
    }
}

// MARK: - Private CGS symbols

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

nonisolated private struct CGSSpaceSymbols {
    typealias DefaultConnection = @convention(c) () -> CGSConnectionID
    typealias CreateSpace = @convention(c) (CGSConnectionID, Int, NSDictionary?) -> CGSSpaceID
    typealias DestroySpace = @convention(c) (CGSConnectionID, CGSSpaceID) -> Void
    typealias SetAbsoluteLevel = @convention(c) (CGSConnectionID, CGSSpaceID, Int) -> Void
    typealias WindowsOperation = @convention(c) (CGSConnectionID, NSArray, NSArray) -> Void
    typealias SpacesOperation = @convention(c) (CGSConnectionID, NSArray) -> Void

    let defaultConnection: DefaultConnection
    let createSpace: CreateSpace
    let destroySpace: DestroySpace
    let setAbsoluteLevel: SetAbsoluteLevel
    let addWindows: WindowsOperation
    let removeWindows: WindowsOperation
    let hideSpaces: SpacesOperation
    let showSpaces: SpacesOperation

    init?(resolver: any CGSSymbolResolver) {
        guard let defaultConnection = resolver.symbol(named: "_CGSDefaultConnection"),
              let createSpace = resolver.symbol(named: "CGSSpaceCreate"),
              let destroySpace = resolver.symbol(named: "CGSSpaceDestroy"),
              let setAbsoluteLevel = resolver.symbol(named: "CGSSpaceSetAbsoluteLevel"),
              let addWindows = resolver.symbol(named: "CGSAddWindowsToSpaces"),
              let removeWindows = resolver.symbol(named: "CGSRemoveWindowsFromSpaces"),
              let hideSpaces = resolver.symbol(named: "CGSHideSpaces"),
              let showSpaces = resolver.symbol(named: "CGSShowSpaces")
        else { return nil }

        self.defaultConnection = unsafeBitCast(defaultConnection, to: DefaultConnection.self)
        self.createSpace = unsafeBitCast(createSpace, to: CreateSpace.self)
        self.destroySpace = unsafeBitCast(destroySpace, to: DestroySpace.self)
        self.setAbsoluteLevel = unsafeBitCast(setAbsoluteLevel, to: SetAbsoluteLevel.self)
        self.addWindows = unsafeBitCast(addWindows, to: WindowsOperation.self)
        self.removeWindows = unsafeBitCast(removeWindows, to: WindowsOperation.self)
        self.hideSpaces = unsafeBitCast(hideSpaces, to: SpacesOperation.self)
        self.showSpaces = unsafeBitCast(showSpaces, to: SpacesOperation.self)
    }
}

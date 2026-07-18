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

/// Small wrapper around the private Spaces ("CGS") API.
///
/// A `CGSSpace` is a dedicated, app-owned Space at an absolute window level.
/// Windows added to it are composited **independently of the normal user
/// Spaces**: they don't slide during a Space swipe and aren't drawn inside the
/// Mission Control canvas (so the inter-Space band can't cross them).
public final class CGSSpace {
    private let identifier: CGSSpaceID

    /// Windows currently placed in this space. Assigning diffs against the
    /// previous set and adds/removes the changed windows by window number.
    public var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(windows)
            let add = windows.subtracting(oldValue)

            CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(),
                                       remove.map { $0.windowNumber } as NSArray,
                                       [identifier])
            CGSAddWindowsToSpaces(_CGSDefaultConnection(),
                                  add.map { $0.windowNumber } as NSArray,
                                  [identifier])
        }
    }

    /// An initialized `CGSSpace` MUST live until app exit (its `deinit` tears
    /// the space down). Create it once via a long-lived owner.
    public init(level: Int = 0) {
        // This flag MUST be 1, otherwise Finder draws desktop icons into it.
        let flag = 0x1
        identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [identifier])
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [identifier])
        CGSSpaceDestroy(_CGSDefaultConnection(), identifier)
    }
}

// MARK: - Private CGS symbols

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)

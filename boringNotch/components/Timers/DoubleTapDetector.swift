//
//  DoubleTapDetector.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Recognises a modifier key (⌘, ⌥ or ⌃) being tapped twice in a row. A tap is a
//  short press with nothing else happening meanwhile — no other key, no click,
//  no second modifier — so ⌘C, ⌘-click or ⌘⇧ never count. Pure logic, no AppKit.
//

import Foundation

struct DoubleTapDetector {
    /// Longest time the key may stay down for a press to still be a "tap".
    var maxHold: TimeInterval = 0.30
    /// Longest pause between the end of the first tap and the start of the second.
    var maxGap: TimeInterval = 0.35

    private var downAt: TimeInterval?
    /// Something else was pressed while the key was down.
    private var tainted = false
    private var firstTapEnd: TimeInterval?

    /// Feed every change of the modifier keys.
    /// - Parameters:
    ///   - watchedDown: the watched key is held.
    ///   - othersDown: some other modifier (⇧ ⌃ ⌥ ⌘ besides the watched one) is held too.
    ///   - time: when it happened, in seconds (any steady clock).
    /// - Returns: true when this change completes a double tap.
    mutating func modifiersChanged(watchedDown: Bool, othersDown: Bool, at time: TimeInterval) -> Bool {
        if othersDown {
            reset()
            return false
        }
        if watchedDown {
            if downAt == nil {
                downAt = time
                tainted = false
            }
            return false
        }

        // The key came up.
        guard let start = downAt else { return false }
        downAt = nil
        guard !tainted, time - start <= maxHold else {
            firstTapEnd = nil
            return false
        }
        if let first = firstTapEnd, start - first <= maxGap {
            firstTapEnd = nil
            return true
        }
        firstTapEnd = time
        return false
    }

    /// Feed every key press and mouse click: any of them spoils the taps in progress.
    mutating func otherInput() {
        tainted = true
        firstTapEnd = nil
    }

    mutating func reset() {
        downAt = nil
        tainted = false
        firstTapEnd = nil
    }
}

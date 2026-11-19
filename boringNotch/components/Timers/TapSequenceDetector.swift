//
//  TapSequenceDetector.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Recognises a modifier key (⌘, ⌥ or ⌃) being tapped two or three times in a
//  row. A tap is a short press with nothing else happening meanwhile — no other
//  key, no click, no second modifier — so ⌘C, ⌘-click or ⌘⇧ never count.
//
//  Two taps can't be told from the start of three, so the second tap only
//  reports "double pending": the caller waits `maxGap` and then asks
//  `confirmDouble()`, which says yes unless a third tap began in the meantime.
//  Pure logic, no AppKit.
//

import Foundation

struct TapSequenceDetector {
    enum Outcome: Equatable {
        case none
        /// Two taps are in. It's a double tap unless a third follows within `maxGap`.
        case doublePending
        /// Three taps in a row.
        case triple
    }

    /// Longest time the key may stay down for a press to still be a "tap".
    var maxHold: TimeInterval = 0.30
    /// Longest pause between the end of one tap and the start of the next.
    var maxGap: TimeInterval = 0.35

    private var downAt: TimeInterval?
    /// Something else was pressed while the key was down.
    private var tainted = false
    private var taps = 0
    private var lastTapEnd: TimeInterval = 0
    private var awaitingThird = false

    /// Feed every change of the modifier keys.
    /// - Parameters:
    ///   - watchedDown: the watched key is held.
    ///   - othersDown: some other modifier (⇧ ⌃ ⌥ ⌘ besides the watched one) is held too.
    ///   - time: when it happened, in seconds (any steady clock).
    mutating func modifiersChanged(watchedDown: Bool, othersDown: Bool, at time: TimeInterval) -> Outcome {
        if othersDown {
            reset()
            return .none
        }
        if watchedDown {
            if downAt == nil {
                downAt = time
                tainted = false
                // A third tap has begun: the pair is not a double tap any more.
                if awaitingThird, time - lastTapEnd <= maxGap { awaitingThird = false }
            }
            return .none
        }

        // The key came up.
        guard let start = downAt else { return .none }
        downAt = nil
        guard !tainted, time - start <= maxHold else {
            taps = 0
            awaitingThird = false
            return .none
        }
        // Too long since the last tap: this one starts a new sequence.
        if taps > 0, start - lastTapEnd > maxGap { taps = 0; awaitingThird = false }

        taps += 1
        lastTapEnd = time
        switch taps {
        case 2:
            awaitingThird = true
            return .doublePending
        case 3...:
            taps = 0
            awaitingThird = false
            return .triple
        default:
            return .none
        }
    }

    /// Call `maxGap` after a `.doublePending`. True if it really was a double tap.
    mutating func confirmDouble() -> Bool {
        guard awaitingThird else { return false }
        awaitingThird = false
        taps = 0
        return true
    }

    /// Feed every key press and mouse click: any of them spoils the taps in progress.
    mutating func otherInput() {
        tainted = true
        taps = 0
        awaitingThird = false
    }

    mutating func reset() {
        downAt = nil
        tainted = false
        taps = 0
        awaitingThird = false
    }
}

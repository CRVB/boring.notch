//
//  DotMatrixLoader.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A small "loading" indicator made of a 5×5 grid of dots. The dots form a
//  diamond and brighten in a ripple that runs from the centre outwards.
//  Inspired by the dot-matrix loaders on dotmatrix.zzzzshawn.cloud (a React
//  library, so it can't be used in a native app as it is); this is an
//  independent SwiftUI drawing, no code taken from there.
//

import SwiftUI

struct DotMatrixLoader: View {
    /// Width and height of the whole grid, in points.
    var size: CGFloat = 16
    var color: Color = .white
    /// Seconds for one ripple to travel out and back.
    var period: Double = 1.1

    private let columns = 5
    private let dimOpacity = 0.14

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { graphics, canvasSize in
                let time = context.date.timeIntervalSinceReferenceDate
                let cell = canvasSize.width / CGFloat(columns)
                let dot = cell * 0.66
                let centre = columns / 2

                for row in 0..<columns {
                    for column in 0..<columns {
                        // Distance from the centre in "steps": a diamond of radius 2.
                        let steps = abs(row - centre) + abs(column - centre)
                        guard steps <= 2 else { continue }

                        // Each ring starts a little later than the one inside it.
                        let phase = time / period - Double(steps) * 0.17
                        let wave = (sin(phase * 2 * .pi) + 1) / 2
                        let brightness = dimOpacity + (1 - dimOpacity) * pow(wave, 2.2)

                        let rect = CGRect(
                            x: CGFloat(column) * cell + (cell - dot) / 2,
                            y: CGFloat(row) * cell + (cell - dot) / 2,
                            width: dot, height: dot)
                        graphics.fill(Path(ellipseIn: rect), with: .color(color.opacity(brightness)))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

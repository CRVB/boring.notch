//
//  ClosedNotchTimerPeeks.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Rows that hang under the closed notch, in the same spot as the
//  song-change sneak peek: the running countdown, and alerts that wait
//  for a "Done".
//

import Defaults
import SwiftUI

/// The running (or paused) countdown, shown while the notch is closed.
/// Centered under the notch: a small progress ring and the time left.
struct CountdownPeekRow: View {
    /// Width of the closed notch the row is centered under.
    let width: CGFloat
    @ObservedObject private var timer = CountdownTimerManager.shared

    var body: some View {
        TimelineView(.periodic(from: .now, by: timer.isRunning ? 0.5 : 60)) { context in
            let left = timer.remaining(at: context.date)
            let final = timer.isRunning && left <= 10
            let tint: Color = final ? .orange : (timer.isRunning ? .effectiveAccent : .gray)

            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: timer.progress(at: context.date))
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: left)
                    if !timer.isRunning {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 5, weight: .bold))
                            .foregroundStyle(.gray)
                    }
                }
                .frame(width: 13, height: 13)

                Text(left.countdownString)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(final ? Color.orange : .white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.smooth(duration: 0.3), value: Int(left.rounded(.up)))
            }
            .scaleEffect(final ? 1.06 : 1)
            .animation(.smooth, value: final)
            .frame(width: width)
            .padding(.top, 1)
            .padding(.bottom, 9)
        }
    }
}

/// An alert under the closed notch that stays until it's answered.
struct NotchAlertRow: View {
    let alert: NotchAlert
    /// Width of the closed notch; the "Time's up" row matches it, like the song-change peek.
    var notchWidth: CGFloat? = nil
    @ObservedObject private var center = NotchAlertCenter.shared

    var body: some View {
        Group {
            if case .countdownFinished = alert, let notchWidth {
                compactCountdownRow(width: notchWidth)
            } else if case .screenshotCopied(let region, let shelved, let upload) = alert, let notchWidth {
                screenshotRow(region: region, shelved: shelved, upload: upload, width: notchWidth)
            } else if case .cloudUploaded(let target) = alert, let notchWidth {
                cloudUploadedRow(target: target, width: notchWidth)
            } else {
                fullRow
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { center.hold() } else { center.release() }
        }
        .onDisappear { center.release() }
    }

    /// "Time's up" squeezed into the notch's own width.
    private func compactCountdownRow(width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .symbolEffect(.bounce, options: .repeat(2), value: alert.id)
            Text("Time's up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: { withAnimation(.smooth) { center.secondary() } }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Restart")
            Button(action: { withAnimation(.smooth) { center.confirm() } }) {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(Color.effectiveAccent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
        .frame(width: width)
    }

    /// "Region copied" / "Screen copied", the width of the notch.
    private func cloudUploadedRow(target: String, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.effectiveAccent)
                .symbolEffect(.bounce, value: alert.id)
            Text("Uploaded to \(target)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .frame(width: width)
        .padding(.top, 1)
        .padding(.bottom, 9)
    }

    private func screenshotRow(region: Bool, shelved: Bool, upload: ScreenshotUploadState?, width: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
                .symbolEffect(.bounce, value: alert.id)
            Text(region ? "Region copied" : "Screen copied")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if shelved {
                // Also saved to the Shelf.
                Image(systemName: "tray.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.effectiveAccent)
            }
            if let upload {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 1, height: 12)
                uploadStatus(upload)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.smooth(duration: 0.25), value: upload)
        .padding(.horizontal, 10)
        // Wider than the notch while there is an upload status to show.
        .frame(width: upload == nil ? width : max(width, 290))
        .padding(.top, 1)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private func uploadStatus(_ state: ScreenshotUploadState) -> some View {
        switch state {
        case .uploading:
            HStack(spacing: 6) {
                DotMatrixLoader(size: 15, color: Color.effectiveAccent)
                Text("Uploading")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
        case .uploaded:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.effectiveAccent)
                Text("Uploaded")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        case .failed:
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.orange)
                Text("Upload failed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var fullRow: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22)
                .symbolEffect(.bounce, options: .repeat(2), value: alert.id)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if center.queue.count > 1 {
                Text("+\(center.queue.count - 1)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.gray)
            }

            Button(action: { withAnimation(.smooth) { center.secondary() } }) {
                Text(secondaryTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Button(action: { withAnimation(.smooth) { center.confirm() } }) {
                Text("Done")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.effectiveAccent))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: 360)
    }

    private var icon: String {
        switch alert {
        case .reminder: return "bell.fill"
        case .countdownFinished: return "timer"
        case .screenshotCopied: return "camera.viewfinder"
        case .cloudUploaded: return "checkmark.icloud.fill"
        }
    }

    private var iconColor: Color {
        switch alert {
        case .reminder(let item): return item.color.map { Color(cgColor: $0) } ?? .orange
        case .countdownFinished, .screenshotCopied, .cloudUploaded: return .orange
        }
    }

    private var title: String {
        switch alert {
        case .reminder(let item): return item.title
        case .countdownFinished: return String(localized: "Time's up")
        case .screenshotCopied(let region, _, _): return region ? String(localized: "Region copied") : String(localized: "Screen copied")
        case .cloudUploaded(let target): return String(localized: "Uploaded to \(target)")
        }
    }

    private var subtitle: String {
        switch alert {
        case .reminder(let item):
            let time = item.dueDate?.formatted(date: .omitted, time: .shortened) ?? ""
            return item.listTitle.isEmpty ? time : "\(item.listTitle) · \(time)"
        case .countdownFinished(let duration):
            return String(localized: "\(duration.countdownString) countdown finished")
        case .screenshotCopied:
            return String(localized: "Copied to the clipboard")
        case .cloudUploaded:
            return ""
        }
    }

    private var secondaryTitle: LocalizedStringKey {
        switch alert {
        case .reminder: return "Snooze \(Defaults[.reminderSnoozeMinutes]) min"
        case .countdownFinished, .screenshotCopied, .cloudUploaded: return "Restart"
        }
    }
}

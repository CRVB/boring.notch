//
//  FileShareView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// A file on its way into the tile (Little Boring Notch's Cloudreve animation).
private struct FileFlight: Identifiable {
    let id = UUID()
    /// Where it was dropped, in the tile's coordinates.
    let start: CGPoint
    let icon: NSImage?
    let count: Int
}

struct FileShareView: View {
    let dropInteraction: DropInteractionState
    @StateObject private var quickShare = QuickShareService.shared
    @ObservedObject private var uploads = UploadQueue.shared
    @Default(.quickShareProvider) var quickShareProvider: String

    @State private var hostView: NSView?
    @State private var interactionNonce: UUID = .init()
    @State private var isProcessing = false

    @State private var flights: [FileFlight] = []
    @State private var tileSize: CGSize = .zero
    @State private var lastDropFlight = Date.distantPast
    /// The tile's icon swells for a moment when a file lands in it.
    @State private var landingBump = false

    private static let dropTypes: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]

    private var selectedProvider: QuickShareProvider {
        quickShare.availableProviders.first(where: { $0.id == quickShareProvider }) ?? .systemShareMenu
    }

    private var isCloudreve: Bool { selectedProvider.id == QuickShareProvider.cloudreveId }

    /// What the Cloudreve tile reports; always idle for any other share target.
    private var cloudStatus: ShareStatus { isCloudreve ? uploads.shareStatus : .idle }

    var body: some View {
        dropArea
            .background(NSViewHost(view: $hostView))
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { tileSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in tileSize = size }
                }
            )
            .onDrop(of: Self.dropTypes, delegate: TileDropDelegate(interaction: dropInteraction) { providers, location in
                interactionNonce = .init()
                dropInteraction.dropEvent = true
                Task { await dropped(providers, at: location) }
            })
            .onTapGesture {
                Task {
                    await handleClick()
                }
            }
            // Files queued without a drop (the file picker): the flight comes in from the top edge.
            .onReceive(NotificationCenter.default.publisher(for: .cloudreveFilesQueued)) { note in
                guard isCloudreve, Date.now.timeIntervalSince(lastDropFlight) > 1.2 else { return }
                startFlight(from: CGPoint(x: tileSize.width / 2, y: 6), icon: nil, count: note.object as? Int ?? 1)
            }
    }

    private var dropArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            dropInteraction.dropZoneTargeting
                                ? Color.accentColor.opacity(0.9)
                                : Color.white.opacity(0.1),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 6, x: 0, y: 2)

            // Content
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(
                            dropInteraction.dropZoneTargeting ? 0.11 : 0.09
                        ))
                        .frame(width: 55, height: 55)
                    tileIcon
                        .frame(width: 34, height: 34)
                        .scaleEffect(landingBump ? 1.2 : 1.0)
                }

                tileLabel
            }
            .padding(18)

            // Loading overlay (not for Cloudreve: its tile shows the upload itself)
            if (isProcessing && !isCloudreve) || quickShare.isPickerOpen {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.black.opacity(0.3))
                    .overlay(
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    )
            }

            // Files flying into the tile
            GeometryReader { geometry in
                ForEach(flights) { flight in
                    FlyingFileChip(
                        flight: flight,
                        target: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2 - 8),
                        onLanded: { landed() },
                        onDone: { flights.removeAll { $0.id == flight.id } }
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Icon and label

    @ViewBuilder
    private var tileIcon: some View {
        switch cloudStatus {
        case .uploading:
            DotMatrixLoader(size: 30, color: Color.effectiveAccent)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        case .uploaded:
            Image(systemName: "checkmark.icloud.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Color.effectiveAccent)
                .symbolEffect(.bounce, value: cloudStatus)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill")
                .resizable().scaledToFit()
                .foregroundStyle(Color.orange)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        case .idle:
            Group {
                if let icon = quickShare.icon(for: selectedProvider.id, size: 34) {
                    Image(nsImage: icon)
                        .resizable().scaledToFit()
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .foregroundStyle(
                dropInteraction.dropZoneTargeting ? Color.accentColor : Color.gray
            )
            .scaleEffect(
                dropInteraction.dropZoneTargeting ? 1.06 : 1.0
            )
            .animation(.spring(response: 0.36, dampingFraction: 0.7), value: dropInteraction.dropZoneTargeting)
            .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    @ViewBuilder
    private var tileLabel: some View {
        VStack(spacing: 5) {
            switch cloudStatus {
            case .uploading:
                Text("Uploading").foregroundColor(.white.opacity(0.9))
            case .uploaded:
                Text("Uploaded").foregroundColor(.white.opacity(0.9))
            case .failed:
                Text("Upload failed").foregroundColor(Color.orange.opacity(0.95))
            case .idle:
                Text(quickShare.displayName(for: selectedProvider.id))
                    .foregroundColor(.white.opacity(0.8))
            }

            if cloudStatus == .idle, isCloudreve, uploads.pendingCount > 0 {
                // Files still waiting to go up (offline, or the server can't be reached).
                Label("\(uploads.pendingCount)", systemImage: uploads.failedCount > 0 ? "exclamationmark.icloud" : "icloud.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(uploads.failedCount > 0 ? Color.orange : Color.gray)
            }
        }
        .font(.system(.headline, design: .rounded))
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
        .animation(.smooth(duration: 0.25), value: cloudStatus)
    }

    // MARK: - Actions

    private func dropped(_ providers: [NSItemProvider], at location: CGPoint) async {
        if isCloudreve {
            lastDropFlight = .now
            var icon: NSImage?
            for provider in providers {
                if let url = await provider.extractItem() {
                    icon = NSWorkspace.shared.icon(forFile: url.path)
                    break
                }
            }
            startFlight(from: location, icon: icon, count: providers.count)
        }
        await handleDrop(providers)
    }

    private func startFlight(from start: CGPoint, icon: NSImage?, count: Int) {
        flights.append(FileFlight(start: start, icon: icon, count: max(1, count)))
    }

    private func landed() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { landingBump = true }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { landingBump = false }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) async {
        isProcessing = true
        defer { isProcessing = false }
        await quickShare.shareDroppedFiles(providers, using: selectedProvider, from: hostView)
    }

    private func handleClick() async {
        await quickShare.showFilePicker(for: selectedProvider, from: hostView)
    }
}

// MARK: - Drop handling (the delegate form tells us where the drop happened)

private struct TileDropDelegate: DropDelegate {
    let interaction: DropInteractionState
    let onDrop: ([NSItemProvider], CGPoint) -> Void

    private static let types: [UTType] = [.fileURL, .url, .utf8PlainText, .plainText, .data, .image]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        interaction.dropZoneTargeting = true
    }

    func dropExited(info: DropInfo) {
        interaction.dropZoneTargeting = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        interaction.dropZoneTargeting = false
        let providers = info.itemProviders(for: Self.types)
        guard !providers.isEmpty else { return false }
        onDrop(providers, info.location)
        return true
    }
}

// MARK: - The flying file

/// A file icon that shrinks and flies from where it was dropped into the tile's icon.
private struct FlyingFileChip: View {
    let flight: FileFlight
    let target: CGPoint
    let onLanded: () -> Void
    let onDone: () -> Void

    @State private var arrived = false
    @State private var fading = false

    private let flightTime = 0.55

    var body: some View {
        chip
            .scaleEffect(arrived ? 0.12 : 1)
            .position(arrived ? target : flight.start)
            .opacity(fading ? 0 : 1)
            .onAppear {
                // Slow start, quick finish — like being pulled in.
                withAnimation(.timingCurve(0.5, 0, 0.85, 0.55, duration: flightTime)) { arrived = true }
                withAnimation(.easeIn(duration: 0.18).delay(flightTime - 0.2)) { fading = true }
                Task {
                    try? await Task.sleep(for: .seconds(flightTime - 0.05))
                    onLanded()
                    try? await Task.sleep(for: .seconds(0.15))
                    onDone()
                }
            }
    }

    private var chip: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                )
                .frame(width: 42, height: 42)
                .overlay {
                    if let icon = flight.icon {
                        Image(nsImage: icon)
                            .resizable().scaledToFit()
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            if flight.count > 1 {
                Text("\(flight.count)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Capsule().fill(Color.effectiveAccent))
                    .offset(x: 6, y: -6)
            }
        }
    }
}

// MARK: - Host NSView extractor for anchoring share sheet

private struct NSViewHost: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { self.view = v }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.view = nsView }
    }
}

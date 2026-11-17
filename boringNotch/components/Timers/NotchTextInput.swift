//
//  NotchTextInput.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  A one-line text field that works inside the notch. The notch window only
//  accepts keyboard focus while this field asks for it, so the notch never
//  steals focus otherwise, and it stays open while you type.
//

import SwiftUI

struct NotchTextInput<Accessory: View>: View {
    let placeholder: LocalizedStringKey
    @Binding var text: String
    var icon: String = "plus.circle.fill"
    /// Take keyboard focus as soon as the field appears.
    var autoFocus = false
    /// Called when editing ends without submitting (Esc, or focus moves away).
    var onCancel: (() -> Void)? = nil
    let onSubmit: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    @EnvironmentObject private var vm: BoringViewModel
    @State private var window: BoringNotchSkyLightWindow?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.effectiveAccent)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($focused)
                .onSubmit(submit)
                .onExitCommand {
                    endEditing()
                    onCancel?()
                }

            accessory()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .background(NotchWindowReader(window: $window))
        .contentShape(Capsule())
        // Simultaneous so the text field still receives the click that focuses it.
        .simultaneousGesture(TapGesture().onEnded { beginEditing() })
        .onChange(of: focused) { _, isFocused in
            if !isFocused {
                endEditing()
                onCancel?()
            }
        }
        .task {
            guard autoFocus else { return }
            // Give the window reader a moment to find the notch window.
            try? await Task.sleep(for: .milliseconds(60))
            beginEditing()
        }
        .onChange(of: vm.notchState) { _, state in
            if state == .closed { endEditing() }
        }
        .onDisappear { endEditing() }
    }

    private func beginEditing() {
        window?.wantsKeyForTextInput = true
        // Keep the notch open while the pointer wanders off to type.
        vm.isPopoverActive = true
        focused = true
    }

    private func endEditing() {
        focused = false
        window?.wantsKeyForTextInput = false
        if vm.isPopoverActive {
            vm.isPopoverActive = false
        }
    }

    /// The field keeps focus afterwards, so several entries can be typed in a row.
    private func submit() {
        onSubmit()
    }
}

extension NotchTextInput where Accessory == EmptyView {
    init(
        placeholder: LocalizedStringKey,
        text: Binding<String>,
        icon: String = "plus.circle.fill",
        autoFocus: Bool = false,
        onCancel: (() -> Void)? = nil,
        onSubmit: @escaping () -> Void
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.autoFocus = autoFocus
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        self.accessory = { EmptyView() }
    }
}

/// Hands the hosting notch window to SwiftUI.
struct NotchWindowReader: NSViewRepresentable {
    @Binding var window: BoringNotchSkyLightWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            window = view.window as? BoringNotchSkyLightWindow
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil, let found = nsView.window as? BoringNotchSkyLightWindow {
            DispatchQueue.main.async { window = found }
        }
    }
}

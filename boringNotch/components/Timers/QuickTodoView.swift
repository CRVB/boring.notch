//
//  QuickTodoView.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The Quick Todo tab: projects in a row along the top, the selected
//  project's tasks below, and a field for new tasks at the bottom.
//

import SwiftUI

struct QuickTodoView: View {
    @ObservedObject private var store = QuickTodoStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProjectColumn()
                .frame(width: 180)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 4)

            if let project = store.selectedProject {
                ProjectDetail(project: project)
                    .id(project.id)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.system(size: 22))
                        .foregroundStyle(.gray)
                    Text("Create a project with + to start a list")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Projects

/// Projects stacked down the left; scrolls when there are more than fit.
/// The + at the bottom turns into a field right there in the list.
private struct ProjectColumn: View {
    @ObservedObject private var store = QuickTodoStore.shared
    @State private var isAdding = false
    @State private var newName = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(store.projects) { project in
                        ProjectChip(project: project, selected: project.id == store.selectedProjectID)
                            .id(project.id)
                    }

                    if isAdding {
                        NotchTextInput(
                            placeholder: "Project name",
                            text: $newName,
                            icon: "folder.badge.plus",
                            autoFocus: true,
                            onCancel: { stopAdding() },
                            onSubmit: {
                                if let project = store.addProject(named: newName) {
                                    newName = ""
                                    stopAdding()
                                    withAnimation(.smooth) { proxy.scrollTo(project.id, anchor: .bottom) }
                                }
                            }
                        )
                        .id("add")
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                    } else {
                        Button {
                            withAnimation(.smooth(duration: 0.2)) { isAdding = true }
                            DispatchQueue.main.async {
                                withAnimation(.smooth) { proxy.scrollTo("add", anchor: .bottom) }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                Text("New project")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.gray)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                Capsule().strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4]))
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id("add")
                    }
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func stopAdding() {
        guard isAdding else { return }
        withAnimation(.smooth(duration: 0.2)) { isAdding = false }
    }
}

private struct ProjectChip: View {
    let project: TodoProject
    let selected: Bool
    @ObservedObject private var store = QuickTodoStore.shared
    @State private var isHovering = false
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 7) {
            if confirmingDelete {
                Text("Delete?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                chipButton("xmark", help: "Cancel") {
                    withAnimation(.smooth(duration: 0.2)) { confirmingDelete = false }
                }
                chipButton("trash.fill", tint: .red, help: "Delete project") {
                    withAnimation(.smooth) { store.deleteProject(project.id) }
                }
            } else {
                Text(project.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .gray)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ProgressRing(value: project.progress, complete: project.countedItems > 0 && project.progress >= 1)
                Text("\(project.doneCount)/\(project.countedItems)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.gray)
                if isHovering {
                    chipButton("xmark", help: "Delete project") {
                        withAnimation(.smooth(duration: 0.2)) { confirmingDelete = true }
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            Capsule().fill(Color.white.opacity(selected ? 0.14 : (isHovering ? 0.08 : 0.05)))
        )
        .overlay(
            Capsule().strokeBorder(confirmingDelete ? Color.red.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard !confirmingDelete else { return }
            withAnimation(.smooth(duration: 0.2)) { store.selectedProjectID = project.id }
        }
        .onHover { hovering in
            withAnimation(.smooth(duration: 0.15)) { isHovering = hovering }
            if !hovering { confirmingDelete = false }
        }
    }

    private func chipButton(_ systemName: String, tint: Color = .gray, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct ProgressRing: View {
    let value: Double
    var complete = false

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: value)
                .stroke(complete ? Color.green : Color.effectiveAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .animation(.smooth, value: value)
    }
}

// MARK: - Project detail

private struct ProjectDetail: View {
    let project: TodoProject
    @ObservedObject private var store = QuickTodoStore.shared
    @State private var newItem = ""
    /// Task whose status picker is open.
    @State private var pickingFor: TodoItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if project.items.isEmpty {
                Text("No tasks yet — add the first one below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(project.sortedItems) { item in
                            TodoRow(item: item, isPicking: pickingFor?.id == item.id) {
                                withAnimation(.smooth(duration: 0.18)) {
                                    pickingFor = pickingFor?.id == item.id ? nil : item
                                }
                            } onDelete: {
                                withAnimation(.smooth(duration: 0.2)) {
                                    store.deleteItem(item.id, in: project.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: .infinity)
            }

            NotchTextInput(placeholder: "New task", text: $newItem) {
                store.addItem(newItem, to: project.id)
                newItem = ""
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The picker is drawn inside the notch: a system menu can't open from it.
        .overlay {
            if let item = pickingFor {
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.35)
                        .contentShape(Rectangle())
                        .onTapGesture { closePicker() }
                    StatusPicker(current: item.state) { status in
                        withAnimation(.smooth(duration: 0.25)) {
                            store.setStatus(status, for: item.id, in: project.id)
                        }
                        closePicker()
                    }
                    .padding(.leading, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .topLeading)))
                }
                .transition(.opacity)
            }
        }
        .onChange(of: project.items.map(\.id)) { _, ids in
            if let picking = pickingFor, !ids.contains(picking.id) { pickingFor = nil }
        }
    }

    private func closePicker() {
        withAnimation(.smooth(duration: 0.18)) { pickingFor = nil }
    }
}

/// The five statuses, styled like a context menu but drawn in the notch.
private struct StatusPicker: View {
    let current: TodoStatus
    let onPick: (TodoStatus) -> Void

    var body: some View {
        VStack(spacing: 1) {
            ForEach(Array(TodoStatus.allCases.enumerated()), id: \.element) { index, status in
                StatusPickerRow(status: status, number: index + 1, selected: status == current) {
                    onPick(status)
                }
            }
        }
        .padding(4)
        .frame(width: 190)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.13))
                .shadow(color: .black.opacity(0.6), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct StatusPickerRow: View {
    let status: TodoStatus
    let number: Int
    let selected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: status.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(status.tint)
                    .frame(width: 16)
                Text(status.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("\(number)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(isHovering || selected ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Tasks

extension TodoStatus {
    var symbol: String {
        switch self {
        case .backlog: "circle.dotted"
        case .planned: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark.circle.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .backlog: .orange
        case .planned: Color(white: 0.75)
        case .inProgress: .yellow
        case .completed: Color(red: 0.42, green: 0.42, blue: 0.95)
        case .canceled: .gray
        }
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let isPicking: Bool
    let onPickStatus: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Button(action: onPickStatus) {
                Image(systemName: item.state.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.state.tint)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.white.opacity(isPicking ? 0.15 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Change status")

            Text(item.title)
                .font(.system(size: 11))
                .strikethrough(item.state.isClosed, color: .gray)
                .foregroundStyle(item.state.isClosed ? Color.gray : .white)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.gray)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

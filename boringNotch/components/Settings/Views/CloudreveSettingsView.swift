//
//  CloudreveSettingsView.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//

import Defaults
import SwiftUI

struct CloudreveSettingsView: View {
    @ObservedObject private var uploads = UploadQueue.shared
    @ObservedObject private var quickShare = QuickShareService.shared

    @Default(.cloudreveEnabled) private var enabled
    @Default(.cloudreveDisplayName) private var displayName
    @Default(.cloudreveServerURL) private var serverURL
    @Default(.cloudreveUsername) private var username
    @Default(.cloudreveSharedFolder) private var sharedFolder
    @Default(.cloudreveScreenshotFolder) private var screenshotFolder
    @Default(.quickShareProvider) private var quickShareProvider

    /// Typed here, stored in the keychain when saved; never kept in preferences.
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var testState: TestState = .idle
    @State private var clearingKind: UploadKind?

    private enum TestState: Equatable {
        case idle
        case testing
        case success
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Upload to Cloudreve", isOn: $enabled)
            } footer: {
                Text("Adds your Cloudreve storage as a Quick Share target on the Shelf, and can send every screenshot there. Files wait in a queue while you're offline or the server can't be reached, and upload on their own later.")
            }
            .onChange(of: enabled) { _, isOn in applyEnabled(isOn) }

            Section {
                TextField("Name on the Shelf", text: $displayName, prompt: Text("Cloudreve"))
                TextField("Server address", text: $serverURL, prompt: Text("https://depo.example.com"))
                    .textContentType(.URL)
                TextField("WebDAV user name", text: $username)
                SecureField("WebDAV password", text: $password,
                            prompt: Text(hasSavedPassword ? "Saved in the keychain" : "Password"))

                HStack {
                    Button("Save and test connection") { saveAndTest() }
                        .disabled(serverURL.trimmingCharacters(in: .whitespaces).isEmpty || username.isEmpty
                                  || (password.isEmpty && !hasSavedPassword) || testState == .testing)
                    statusView
                }
            } header: {
                Text("Server")
            } footer: {
                Text("In Cloudreve, open your account settings, switch on WebDAV and create a WebDAV account. Use the user name and password you set there — the server address is just your Cloudreve address (…/dav is added for you).")
            }
            .disabled(!enabled)

            Section {
                TextField("Shared files folder", text: $sharedFolder, prompt: Text("/Shared"))
                Defaults.Toggle(key: .cloudreveUploadScreenshots) {
                    Text("Upload screenshots automatically")
                }
                TextField("Screenshots folder", text: $screenshotFolder, prompt: Text("/Screenshots"))
            } header: {
                Text("Folders")
            } footer: {
                Text("Folders are relative to the root of your WebDAV account and are created if they don't exist. A file that has the same name as an existing one gets a number added instead of replacing it.")
            }
            .disabled(!enabled)

            queueSections
                .disabled(!enabled)
        }
        .formStyle(.grouped)
        .accentColor(.effectiveAccent)
        .navigationTitle("Cloudreve")
        .task(id: username) {
            hasSavedPassword = await KeychainPassword.readAsync(account: username) != nil
        }
        .confirmationDialog(
            clearingKind == .screenshot ? "Cancel all waiting screenshot uploads?" : "Cancel all waiting file uploads?",
            isPresented: Binding(get: { clearingKind != nil }, set: { if !$0 { clearingKind = nil } })
        ) {
            Button(clearingKind == .screenshot ? "Cancel and delete screenshots" : "Cancel uploads", role: .destructive) {
                if let kind = clearingKind {
                    for job in uploads.jobs(of: kind) { uploads.cancel(job) }
                }
                clearingKind = nil
            }
        } message: {
            Text(clearingKind == .screenshot
                 ? "They aren't on the server yet. Cancelling also removes them from the Shelf and from this Mac."
                 : "They aren't on the server yet. Your original files are not touched.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var statusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var queueSections: some View {
        let files = uploads.jobs(of: .file)
        let screenshots = uploads.jobs(of: .screenshot)

        if files.isEmpty && screenshots.isEmpty {
            Section {
                HStack {
                    Image(systemName: uploads.isOnline ? "checkmark.icloud" : "icloud.slash")
                        .foregroundStyle(.secondary)
                    Text(uploads.isOnline ? "Nothing is waiting to upload." : "Offline — nothing is waiting.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Upload queue")
            }
        } else {
            if !files.isEmpty {
                queueSection(title: "Files", jobs: files, kind: .file)
            }
            if !screenshots.isEmpty {
                queueSection(title: "Screenshots", jobs: screenshots, kind: .screenshot)
            }
            Section {
                Button("Retry now") { uploads.retryNow() }
            } footer: {
                Text(uploads.isOnline
                     ? "Uploads are retried automatically, a little later each time they fail."
                     : "You're offline. Waiting files go up by themselves when the connection is back.")
            }
        }
    }

    private func queueSection(title: LocalizedStringKey, jobs: [UploadJob], kind: UploadKind) -> some View {
        Section {
            ForEach(jobs) { job in
                UploadJobRow(job: job, isUploading: uploads.currentJobID == job.id, isOnline: uploads.isOnline) {
                    withAnimation(.smooth(duration: 0.2)) { uploads.cancel(job) }
                }
            }
        } header: {
            HStack {
                Text(title)
                Text("\(jobs.count)").foregroundStyle(.secondary)
                Spacer()
                if jobs.count > 1 {
                    Button("Cancel all…") { clearingKind = kind }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        } footer: {
            if kind == .screenshot {
                Text("Cancelling a screenshot also removes it from the Shelf and from this Mac.")
            }
        }
    }

    // MARK: - Actions

    /// Switching Cloudreve on makes it the Quick Share target; off again returns to the system default.
    private func applyEnabled(_ isOn: Bool) {
        quickShare.refreshCloudreveProvider()
        if isOn {
            quickShareProvider = QuickShareProvider.cloudreveId
            uploads.configurationChanged()
        } else if quickShareProvider == QuickShareProvider.cloudreveId {
            quickShareProvider = QuickShareProvider.defaultProvider.id
        }
    }

    private func saveAndTest() {
        let account = username
        if !password.isEmpty {
            hasSavedPassword = KeychainPassword.save(password, account: account)
            password = ""
        }
        testState = .testing
        let folder = CloudreveConfig.current().screenshotFolder
        Task {
            let config = CloudreveConfig.current()
            guard let client = config.client else {
                testState = .failure(String(localized: "Check the address, user name and password"))
                return
            }
            do {
                try await client.testConnection(folder: UploadQueue.normalizedFolder(folder))
                testState = .success
                uploads.configurationChanged()
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}

private struct UploadJobRow: View {
    let job: UploadJob
    let isUploading: Bool
    let isOnline: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(job.fileName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: job.size, countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                statusText
                    .font(.caption)
            }
            if isUploading {
                ProgressView().controlSize(.small)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .help(job.kind == .screenshot ? "Cancel the upload and delete the screenshot" : "Cancel the upload")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if isUploading {
            Text("Uploading…").foregroundStyle(Color.accentColor)
        } else if let error = job.lastError {
            Text("\(error) — trying again").foregroundStyle(Color.orange)
        } else {
            Text(isOnline ? "Waiting to upload" : "Waiting for a connection").foregroundStyle(.secondary)
        }
    }
}

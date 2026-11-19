//
//  CloudreveConfig.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Where uploads go: a Cloudreve server, reached over WebDAV. The password
//  lives in the macOS keychain, everything else in the app's preferences.
//

import Defaults
import Foundation
import Security

struct CloudreveConfig {
    var baseURL: URL?
    var username: String
    var password: String
    var sharedFolder: String
    var screenshotFolder: String
    var displayName: String

    var isConfigured: Bool {
        baseURL != nil && !username.isEmpty && !password.isEmpty
    }

    var client: WebDAVClient? {
        guard isConfigured, let baseURL else { return nil }
        return WebDAVClient(baseURL: baseURL, username: username, password: password)
    }

    static func current() -> CloudreveConfig {
        let username = Defaults[.cloudreveUsername]
        let name = Defaults[.cloudreveDisplayName].trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudreveConfig(
            baseURL: normalizedBaseURL(Defaults[.cloudreveServerURL]),
            username: username,
            password: KeychainPassword.read(account: username) ?? "",
            sharedFolder: Defaults[.cloudreveSharedFolder],
            screenshotFolder: Defaults[.cloudreveScreenshotFolder],
            displayName: name.isEmpty ? "Cloudreve" : name
        )
    }

    /// Accepts "depo.example.com", "https://depo.example.com" or the full
    /// ".../dav" address; Cloudreve serves WebDAV under /dav.
    static func normalizedBaseURL(_ text: String) -> URL? {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.contains("://") { string = "https://" + string }
        guard var components = URLComponents(string: string), components.host?.isEmpty == false else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.isEmpty { path = "/dav" }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

extension Notification.Name {
    /// The WebDAV password has been read from the keychain.
    static let cloudrevePasswordLoaded = Notification.Name("LittleBoringNotch.cloudrevePasswordLoaded")
}

/// The WebDAV password, kept in the (file-based) login keychain.
///
/// Reading it can take a long time: after an update macOS may ask the user to
/// allow the new build to use the item, and the call waits for the answer. So
/// the keychain is only ever touched off the main thread, and the result is
/// remembered in memory — the app never freezes behind that dialog.
enum KeychainPassword {
    private static let service = "com.crvb.littleboringnotch.cloudreve"

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        /// account → password; a nil value means "looked, there is none". No entry: not read yet.
        private var values: [String: String?] = [:]
        private var loading: Set<String> = []

        func lookup(_ account: String) -> (known: Bool, value: String?) {
            lock.lock(); defer { lock.unlock() }
            if let entry = values[account] { return (true, entry) }
            return (false, nil)
        }

        func store(_ value: String?, for account: String) {
            lock.lock(); defer { lock.unlock() }
            values[account] = .some(value)
        }

        /// True for the caller that should start the read.
        func beginLoading(_ account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return loading.insert(account).inserted
        }

        func endLoading(_ account: String) {
            lock.lock(); defer { lock.unlock() }
            loading.remove(account)
        }
    }

    private static let cache = Cache()

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// The password if it has been read already; otherwise nil, and a read starts
    /// in the background (`.cloudrevePasswordLoaded` is posted when it is done).
    static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let cached = cache.lookup(account)
        if cached.known { return cached.value }
        if cache.beginLoading(account) {
            DispatchQueue.global(qos: .utility).async {
                let value = readFromKeychain(account: account)
                cache.store(value, for: account)
                cache.endLoading(account)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .cloudrevePasswordLoaded, object: nil)
                }
            }
        }
        return nil
    }

    /// Like `read`, but waits for the keychain (without blocking any thread that matters).
    static func readAsync(account: String) async -> String? {
        guard !account.isEmpty else { return nil }
        let cached = cache.lookup(account)
        if cached.known { return cached.value }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let value = readFromKeychain(account: account)
                cache.store(value, for: account)
                continuation.resume(returning: value)
            }
        }
    }

    private static func readFromKeychain(account: String) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remembers the password right away and writes it to the keychain in the background.
    @discardableResult
    static func save(_ password: String, account: String) -> Bool {
        guard !account.isEmpty else { return false }
        cache.store(password, for: account)
        DispatchQueue.global(qos: .utility).async {
            SecItemDelete(query(account) as CFDictionary)
            var item = query(account)
            item[kSecValueData as String] = Data(password.utf8)
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess {
                Log.shelf.error("Saving the Cloudreve password to the keychain failed (\(status))")
            }
        }
        return true
    }

    static func delete(account: String) {
        guard !account.isEmpty else { return }
        cache.store(nil, for: account)
        DispatchQueue.global(qos: .utility).async {
            SecItemDelete(query(account) as CFDictionary)
        }
    }
}

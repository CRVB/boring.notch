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

/// The WebDAV password, kept in the (file-based) login keychain.
enum KeychainPassword {
    private static let service = "com.crvb.littleboringnotch.cloudreve"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ password: String, account: String) -> Bool {
        guard !account.isEmpty else { return false }
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

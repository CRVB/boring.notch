//
//  WebDAVClient.swift
//  Little Boring Notch
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  The few WebDAV calls an upload needs: look a path up, make folders, PUT a
//  file. Cloudreve (v3 and v4) speaks this under /dav with HTTP Basic auth.
//

import Foundation

struct WebDAVClient {
    let baseURL: URL
    let username: String
    let password: String

    enum Failure: LocalizedError, Equatable {
        case unauthorized
        case server(Int)
        case transport(String)
        /// The server didn't finish in time (the short first attempt of a screenshot).
        case timeout

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return String(localized: "The server refused the user name or password")
            case .server(let code):
                return String(localized: "The server answered with HTTP \(code)")
            case .transport(let message):
                return message
            case .timeout:
                return String(localized: "The server did not answer in time")
            }
        }

        /// A wrong password won't fix itself, so retries wait much longer.
        var isAuthentication: Bool { self == .unauthorized }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func url(for remotePath: String) -> URL {
        var url = baseURL
        for component in remotePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func request(_ method: String, _ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func statusCode(of request: URLRequest) async throws -> Int {
        do {
            let (_, response) = try await Self.session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// Whether a file or folder exists at `remotePath`.
    func exists(_ remotePath: String) async throws -> Bool {
        var request = request("PROPFIND", url(for: remotePath))
        request.setValue("0", forHTTPHeaderField: "Depth")
        switch try await statusCode(of: request) {
        case 200, 207: return true
        case 404: return false
        case 401, 403: throw Failure.unauthorized
        case let code: throw Failure.server(code)
        }
    }

    /// Creates `remotePath` and any missing parents.
    func ensureFolder(_ remotePath: String) async throws {
        var current = ""
        for component in remotePath.split(separator: "/") {
            current += "/" + component
            if try await exists(current) { continue }
            switch try await statusCode(of: request("MKCOL", url(for: current))) {
            case 200, 201, 204, 405: continue // 405: it was created in the meantime
            case 401, 403: throw Failure.unauthorized
            case let code: throw Failure.server(code)
            }
        }
    }

    func upload(file: URL, to remotePath: String) async throws {
        let request = request("PUT", url(for: remotePath))
        do {
            let (_, response) = try await Self.session.upload(for: request, fromFile: file)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200, 201, 204: return
            case 401, 403: throw Failure.unauthorized
            case let code: throw Failure.server(code)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error.localizedDescription)
        }
    }

    /// Logs in and makes sure `folder` exists — what "Save and test" runs.
    func testConnection(folder: String) async throws {
        try await ensureFolder(folder)
    }
}

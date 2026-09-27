import Foundation

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let headers: [String: String]

    public var text: String { String(decoding: body, as: UTF8.self) }
    public var isSuccess: Bool { (200..<300).contains(status) }
}

public enum HTTPError: LocalizedError {
    case transport(String)
    case status(Int, provider: String, detail: String)
    case decoding(String, provider: String)

    public var errorDescription: String? {
        switch self {
        case .transport(let message):
            return "Network error: \(message)"
        case .status(let code, let provider, let detail):
            switch code {
            case 401:
                return "\(provider) rejected the token (HTTP 401). Check that it is valid and has read/write scope. \(detail)"
            case 403:
                // A 403 is just as often a quota or a permission on one action as it is a
                // bad token, and the provider's own code says which. Lead with that.
                let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return "\(provider) refused the request (HTTP 403). The token may lack write access."
                }
                return "\(provider) refused the request: \(trimmed)"
            case 404:
                return "\(provider) could not find that resource (HTTP 404). \(detail)"
            case 429:
                return "\(provider) is rate limiting Codex Remote (HTTP 429). Try again shortly."
            default:
                return "\(provider) returned HTTP \(code). \(detail)"
            }
        case .decoding(let message, let provider):
            return "Could not read the \(provider) response: \(message)"
        }
    }
}

/// One shared JSON-over-HTTP client for every provider. Providers supply their own
/// auth header and base URL; retry/backoff and error shaping live here so each new
/// provider gets them for free.
public struct HTTPClient: Sendable {
    public let providerName: String
    public let baseURL: URL
    public let defaultHeaders: [String: String]
    private let session: URLSession
    private let maxAttempts: Int

    public init(providerName: String, baseURL: URL, defaultHeaders: [String: String] = [:],
                session: URLSession = .shared, maxAttempts: Int = 3) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.defaultHeaders = defaultHeaders
        self.session = session
        self.maxAttempts = maxAttempts
    }

    public func request(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path),
            resolvingAgainstBaseURL: false
        ) else {
            throw HTTPError.transport("Malformed URL for \(path)")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw HTTPError.transport("Malformed URL for \(path)") }

        var attempt = 0
        var lastError: Error = HTTPError.transport("unknown")
        while attempt < maxAttempts {
            attempt += 1
            var request = URLRequest(url: url, timeoutInterval: 45)
            request.httpMethod = method
            for (key, value) in defaultHeaders { request.setValue(value, forHTTPHeaderField: key) }
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if let body {
                request.httpBody = body
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                }
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPError.transport("Non-HTTP response")
                }
                var headerMap: [String: String] = [:]
                for (key, value) in http.allHeaderFields {
                    if let k = key as? String, let v = value as? String { headerMap[k] = v }
                }
                let result = HTTPResponse(status: http.statusCode, body: data, headers: headerMap)
                // 429 and 5xx are worth another go; everything else is the caller's problem.
                if result.status == 429 || result.status >= 500, attempt < maxAttempts {
                    let backoff = pow(2.0, Double(attempt - 1)) * 0.75
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    lastError = HTTPError.status(result.status, provider: providerName,
                                                 detail: summarize(result))
                    continue
                }
                return result
            } catch let error as HTTPError {
                lastError = error
                if attempt >= maxAttempts { throw error }
            } catch {
                lastError = HTTPError.transport(error.localizedDescription)
                if attempt >= maxAttempts { throw lastError }
                try? await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt - 1)) * 750_000_000))
            }
        }
        throw lastError
    }

    public func json<T: Decodable>(
        _ type: T.Type,
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Encodable? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        var payload: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(AnyEncodable(body))
        }
        let response = try await request(method, path, query: query, body: payload, headers: headers)
        guard response.isSuccess else {
            throw HTTPError.status(response.status, provider: providerName, detail: summarize(response))
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw HTTPError.decoding(String(describing: error), provider: providerName)
        }
    }

    /// Pull a short, human-usable message out of whatever error envelope the provider used.
    private func summarize(_ response: HTTPResponse) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            let raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(raw.prefix(300))
        }
        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? ""
            let code = error["code"] as? String ?? ""
            return [code, message].filter { !$0.isEmpty }.joined(separator: ": ")
        }
        if let message = object["message"] as? String { return message }
        if let id = object["id"] as? String, let message = object["message"] as? String {
            return "\(id): \(message)"
        }
        return String(response.text.prefix(300))
    }
}

public struct EmptyResponse: Codable, Sendable { public init() {} }

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { encodeImpl = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}

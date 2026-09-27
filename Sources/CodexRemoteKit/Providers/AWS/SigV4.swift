import Foundation
import CryptoKit

/// Minimal AWS Signature Version 4 signer for the EC2 Query API. Codex Remote only ever makes
/// POST-with-form-body calls, which keeps the canonical request short and testable.
public struct SigV4Signer: Sendable {
    public let accessKeyID: String
    public let secretAccessKey: Secret
    public let sessionToken: String?
    public let region: String
    public let service: String

    public init(accessKeyID: String, secretAccessKey: Secret, sessionToken: String? = nil,
                region: String, service: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.region = region
        self.service = service
    }

    /// Returns the headers to attach to a signed request.
    ///
    /// `canonicalQuery` must already be RFC 3986 encoded and sorted; Codex Remote always puts
    /// its parameters in the body, so it is empty in practice and exists so the signer
    /// can be checked against AWS's published test vectors.
    public func sign(method: String = "POST", host: String, path: String = "/",
                     canonicalQuery: String = "", body: Data, now: Date = Date()) -> [String: String] {
        let amzDate = Self.amzDateFormatter.string(from: now)
        let dateStamp = String(amzDate.prefix(8))
        let payloadHash = Self.hexSHA256(body)

        var headers: [String: String] = ["host": host, "x-amz-date": amzDate]
        if !body.isEmpty {
            headers["content-type"] = "application/x-www-form-urlencoded; charset=utf-8"
        }
        if let sessionToken { headers["x-amz-security-token"] = sessionToken }

        let sortedKeys = headers.keys.sorted()
        let canonicalHeaders = sortedKeys
            .map { "\($0):\(headers[$0]!.trimmingCharacters(in: .whitespaces))\n" }
            .joined()
        let signedHeaders = sortedKeys.joined(separator: ";")

        let canonicalRequest = [
            method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256", amzDate, scope, Self.hexSHA256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey.raw)".utf8))
        for element in [dateStamp, region, service, "aws4_request"] {
            let mac = HMAC<SHA256>.authenticationCode(for: Data(element.utf8), using: key)
            key = SymmetricKey(data: Data(mac))
        }
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
            .map { String(format: "%02x", $0) }.joined()

        headers["Authorization"] = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        return headers
    }

    static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let amzDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// AWS wants RFC 3986 encoding, which differs from `addingPercentEncoding` defaults.
    public static func encode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    public static func formBody(_ parameters: [String: String]) -> Data {
        let encoded = parameters.keys.sorted()
            .map { "\(encode($0))=\(encode(parameters[$0]!))" }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }
}

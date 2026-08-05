import Foundation

struct KimiUsageClient: Sendable {
    /// The Kimi Code subscription's quota endpoint. It answers for a Kimi Code API key and for the
    /// CLI's OAuth access token alike; this app only ever sends the API key.
    static let usagesURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// Session and overall quota windows. The only call this provider makes.
    func fetchUsages(apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usagesURL,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum KimiUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        }
    }
}

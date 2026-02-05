import Foundation

enum BackendError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid backend URL."
        case .invalidResponse:
            return "Invalid response from backend."
        case let .httpError(code, message):
            return "Backend error \(code): \(message)"
        }
    }
}

struct BackendClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func health() async throws -> Health {
        try await request(path: "/health", method: "GET", body: Optional<Int>.none)
    }

    func createOrOpenProject(name: String, rootPath: String) async throws -> Project {
        struct Payload: Encodable {
            let name: String
            let rootPath: String
        }
        return try await request(path: "/v1/projects", method: "POST", body: Payload(name: name, rootPath: rootPath))
    }

    func listConversations(projectID: String) async throws -> [Conversation] {
        try await request(path: "/v1/projects/\(projectID)/conversations", method: "GET", body: Optional<Int>.none)
    }

    func createConversation(projectID: String, title: String) async throws -> Conversation {
        struct Payload: Encodable {
            let title: String
            let startMode: String
        }
        return try await request(
            path: "/v1/projects/\(projectID)/conversations",
            method: "POST",
            body: Payload(title: title, startMode: "manual")
        )
    }

    func listMessages(projectID: String, conversationID: String) async throws -> [Message] {
        try await request(
            path: "/v1/projects/\(projectID)/conversations/\(conversationID)/messages",
            method: "GET",
            body: Optional<Int>.none
        )
    }

    func sendMessage(
        projectID: String,
        conversationID: String,
        content: String,
        parts: [[String: String]],
        startRun: Bool,
        mode: String
    ) async throws -> TaskStatus {
        struct Payload: Encodable {
            let role: String
            let content: String
            let parts: [[String: String]]
            let startRun: Bool
            let mode: String
        }

        return try await request(
            path: "/v1/projects/\(projectID)/conversations/\(conversationID)/messages",
            method: "POST",
            body: Payload(role: "user", content: content, parts: parts, startRun: startRun, mode: mode)
        )
    }

    func run(projectID: String, runID: String) async throws -> RunDetail {
        try await request(path: "/v1/projects/\(projectID)/runs/\(runID)", method: "GET", body: Optional<Int>.none)
    }

    func triggerIndex(projectID: String, fullScan: Bool = true) async throws {
        struct Payload: Encodable {
            let fullScan: Bool
        }
        struct Empty: Decodable {}
        _ = try await request(
            path: "/v1/projects/\(projectID)/index",
            method: "POST",
            body: Payload(fullScan: fullScan)
        ) as Empty
    }

    func search(projectID: String, query: String, limit: Int = 5) async throws -> SearchResponse {
        struct Payload: Encodable {
            let query: String
            let limit: Int
        }
        return try await request(
            path: "/v1/projects/\(projectID)/search",
            method: "POST",
            body: Payload(query: query, limit: limit)
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw BackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let apiError = try? decoder.decode(APIErrorResponse.self, from: data)
            throw BackendError.httpError(code: http.statusCode, message: apiError?.detail ?? "Unknown server error")
        }

        return try decoder.decode(Response.self, from: data)
    }
}

import Foundation

enum OverlayBackendError: LocalizedError {
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

struct OverlayProject: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let rootPath: String
    let createdAt: String?
    let lastOpenedAt: String?
    let activeConversationId: String?
}

struct OverlayConversation: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let title: String
    let status: String
    let pinned: Bool
    let createdAt: String
    let lastMessageAt: String?
    let summary: String?
}

struct OverlayMessage: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let conversationId: String
    let role: String
    let content: String
    let parentMessageId: String?
    let sequenceNo: Int
    let createdAt: String
}

struct OverlayRunDetail: Decodable {
    let id: String
    let projectId: String
    let conversationId: String
    let triggerMessageId: String
    let status: String
    let mode: String
    let outputSummary: String?
    let error: String?
}

struct OverlayTaskStatus: Decodable {
    let messageId: String
    let runId: String?
    let status: String
}

private struct OverlayAPIErrorResponse: Decodable {
    let detail: String
}

final class BackendClient {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL? = nil) {
        if let baseURL {
            self.baseURL = baseURL
        } else {
            let defaultURL = ProcessInfo.processInfo.environment["STASH_BACKEND_URL"] ?? "http://127.0.0.1:8765"
            self.baseURL = URL(string: defaultURL) ?? URL(string: "http://127.0.0.1:8765")!
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        self.encoder = encoder
    }

    func listProjects() async throws -> [OverlayProject] {
        try await request(path: "/v1/projects", method: "GET", body: Optional<Int>.none)
    }

    func createOrOpenProject(name: String, rootPath: String) async throws -> OverlayProject {
        struct Payload: Encodable {
            let name: String
            let rootPath: String
        }
        return try await request(path: "/v1/projects", method: "POST", body: Payload(name: name, rootPath: rootPath))
    }

    func listConversations(projectID: String) async throws -> [OverlayConversation] {
        try await request(path: "/v1/projects/\(projectID)/conversations", method: "GET", body: Optional<Int>.none)
    }

    func createConversation(projectID: String, title: String) async throws -> OverlayConversation {
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

    func listMessages(projectID: String, conversationID: String) async throws -> [OverlayMessage] {
        try await request(
            path: "/v1/projects/\(projectID)/conversations/\(conversationID)/messages",
            method: "GET",
            body: Optional<Int>.none
        )
    }

    func sendMessage(projectID: String, conversationID: String, content: String) async throws -> OverlayTaskStatus {
        struct Payload: Encodable {
            let role: String
            let content: String
            let startRun: Bool
            let mode: String
        }
        return try await request(
            path: "/v1/projects/\(projectID)/conversations/\(conversationID)/messages",
            method: "POST",
            body: Payload(role: "user", content: content, startRun: true, mode: "manual")
        )
    }

    func run(projectID: String, runID: String) async throws -> OverlayRunDetail {
        try await request(path: "/v1/projects/\(projectID)/runs/\(runID)", method: "GET", body: Optional<Int>.none)
    }

    func ensureDefaultProject() async throws -> OverlayProject {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("StashDefaultProject", isDirectory: true)
        return try await createOrOpenProject(name: "Default Project", rootPath: root.path)
    }

    func ensureProjectSelection(preferredProjectID: String?) async throws -> OverlayProject {
        let projects = try await listProjects()
        if let preferredProjectID,
           let preferred = projects.first(where: { $0.id == preferredProjectID })
        {
            return preferred
        }

        if let latest = projects.max(by: { ($0.lastOpenedAt ?? "") < ($1.lastOpenedAt ?? "") }) {
            return latest
        }

        return try await ensureDefaultProject()
    }

    func registerAssets(urls: [URL], preferredProjectID: String?) async throws -> OverlayProject {
        let project = try await ensureProjectSelection(preferredProjectID: preferredProjectID)
        try await registerAssets(urls: urls, projectID: project.id)
        return project
    }

    func registerAssets(urls: [URL], projectID: String) async throws {
        struct Payload: Encodable {
            let kind: String
            let pathOrUrl: String
            let autoIndex: Bool
        }
        struct EmptyResponse: Decodable {}

        for url in urls {
            _ = try await request(
                path: "/v1/projects/\(projectID)/assets",
                method: "POST",
                body: Payload(kind: "file", pathOrUrl: url.path, autoIndex: true)
            ) as EmptyResponse
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw OverlayBackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OverlayBackendError.invalidResponse
        }

        guard (200 ..< 300).contains(http.statusCode) else {
            let apiError = try? decoder.decode(OverlayAPIErrorResponse.self, from: data)
            throw OverlayBackendError.httpError(code: http.statusCode, message: apiError?.detail ?? "Unknown server error")
        }

        return try decoder.decode(Response.self, from: data)
    }
}

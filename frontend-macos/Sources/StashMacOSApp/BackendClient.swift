import Foundation

enum BackendError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(code: Int, message: String)
    case requestTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid backend URL."
        case .invalidResponse:
            return "Invalid response from backend."
        case let .httpError(code, message):
            return "Backend error \(code): \(message)"
        case .requestTimedOut:
            return "The request timed out."
        }
    }
}

struct BackendClient {
    private let baseURL: URL
    private let session: URLSession
    private let streamSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 180
        self.session = URLSession(configuration: config)

        let streamConfig = URLSessionConfiguration.default
        streamConfig.timeoutIntervalForRequest = 8 * 60 * 60
        streamConfig.timeoutIntervalForResource = 8 * 60 * 60
        self.streamSession = URLSession(configuration: streamConfig)

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

    func runtimeConfig() async throws -> RuntimeConfigPayload {
        try await request(path: "/v1/runtime/config", method: "GET", body: Optional<Int>.none)
    }

    func runtimeSetupStatus() async throws -> RuntimeSetupStatus {
        try await request(path: "/v1/runtime/setup-status", method: "GET", body: Optional<Int>.none)
    }

    func updateRuntimeConfig(
        plannerBackend: String,
        codexMode: String,
        codexBin: String,
        codexPlannerModel: String,
        plannerCmd: String?,
        clearPlannerCmd: Bool,
        plannerTimeoutSeconds: Int,
        openaiAPIKey: String?,
        clearOpenAIAPIKey: Bool,
        openaiModel: String,
        openaiBaseURL: String,
        openaiTimeoutSeconds: Int
    ) async throws -> RuntimeConfigPayload {
        struct Payload: Encodable {
            let plannerBackend: String
            let codexMode: String
            let codexBin: String
            let codexPlannerModel: String
            let plannerCmd: String?
            let clearPlannerCmd: Bool
            let plannerTimeoutSeconds: Int
            let openaiApiKey: String?
            let clearOpenaiApiKey: Bool
            let openaiModel: String
            let openaiBaseUrl: String
            let openaiTimeoutSeconds: Int
        }

        return try await request(
            path: "/v1/runtime/config",
            method: "PATCH",
            body: Payload(
                plannerBackend: plannerBackend,
                codexMode: codexMode,
                codexBin: codexBin,
                codexPlannerModel: codexPlannerModel,
                plannerCmd: plannerCmd,
                clearPlannerCmd: clearPlannerCmd,
                plannerTimeoutSeconds: plannerTimeoutSeconds,
                openaiApiKey: openaiAPIKey,
                clearOpenaiApiKey: clearOpenAIAPIKey,
                openaiModel: openaiModel,
                openaiBaseUrl: openaiBaseURL,
                openaiTimeoutSeconds: openaiTimeoutSeconds
            )
        )
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
            path: "/v1/projects/\(projectID)/conversations/\(conversationID)/messages?limit=120",
            method: "GET",
            body: Optional<Int>.none,
            timeout: 90,
            retriesOnTimeout: 1
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
        try await request(
            path: "/v1/projects/\(projectID)/runs/\(runID)?include_output=false",
            method: "GET",
            body: Optional<Int>.none,
            timeout: 30
        )
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

    func streamEvents(
        projectID: String,
        conversationID: String,
        sinceID: Int,
        onEvent: @escaping @Sendable (ProjectEvent) -> Void
    ) async throws {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/projects/\(projectID)/events/stream"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "conversation_id", value: conversationID),
            URLQueryItem(name: "since_id", value: String(sinceID)),
        ]
        guard let url = components?.url else {
            throw BackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8 * 60 * 60

        let (bytes, response) = try await streamSession.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw BackendError.httpError(code: http.statusCode, message: "Could not open event stream")
        }

        var eventDataLines: [String] = []
        var eventType: String?
        var eventID: Int?

        for try await line in bytes.lines {
            if Task.isCancelled {
                throw CancellationError()
            }
            if line.isEmpty {
                if !eventDataLines.isEmpty {
                    let payloadText = eventDataLines.joined(separator: "\n")
                    if let payloadData = payloadText.data(using: .utf8),
                       var parsed = try? decoder.decode(ProjectEvent.self, from: payloadData)
                    {
                        if let eventID {
                            parsed = ProjectEvent(
                                id: eventID,
                                type: parsed.type,
                                projectId: parsed.projectId,
                                conversationId: parsed.conversationId,
                                runId: parsed.runId,
                                ts: parsed.ts,
                                payload: parsed.payload
                            )
                        } else if let decodedID = parsed.payload["id"]?.intValue {
                            parsed = ProjectEvent(
                                id: decodedID,
                                type: parsed.type,
                                projectId: parsed.projectId,
                                conversationId: parsed.conversationId,
                                runId: parsed.runId,
                                ts: parsed.ts,
                                payload: parsed.payload
                            )
                        }
                        if let eventType, !eventType.isEmpty {
                            parsed = ProjectEvent(
                                id: parsed.id,
                                type: eventType,
                                projectId: parsed.projectId,
                                conversationId: parsed.conversationId,
                                runId: parsed.runId,
                                ts: parsed.ts,
                                payload: parsed.payload
                            )
                        }
                        onEvent(parsed)
                    }
                }
                eventDataLines.removeAll(keepingCapacity: true)
                eventType = nil
                eventID = nil
                continue
            }

            if line.hasPrefix(":") {
                continue
            }

            if line.hasPrefix("id:") {
                let raw = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                eventID = Int(raw)
                continue
            }

            if line.hasPrefix("event:") {
                eventType = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if line.hasPrefix("data:") {
                let chunk = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                eventDataLines.append(chunk)
            }
        }
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil,
        retriesOnTimeout: Int = 0
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw BackendError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeout {
            request.timeoutInterval = timeout
        }

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        var attempts = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)

                guard let http = response as? HTTPURLResponse else {
                    throw BackendError.invalidResponse
                }

                guard (200 ..< 300).contains(http.statusCode) else {
                    let apiError = try? decoder.decode(APIErrorResponse.self, from: data)
                    throw BackendError.httpError(code: http.statusCode, message: apiError?.detail ?? "Unknown server error")
                }

                return try decoder.decode(Response.self, from: data)
            } catch let urlError as URLError where urlError.code == .timedOut {
                if attempts < retriesOnTimeout {
                    attempts += 1
                    continue
                }
                throw BackendError.requestTimedOut
            } catch {
                throw error
            }
        }
    }
}

import Foundation

struct Project: Decodable, Identifiable {
    let id: String
    let name: String
    let rootPath: String
    let createdAt: String?
    let lastOpenedAt: String?
    let activeConversationId: String?
}

struct Conversation: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let title: String
    let status: String
    let pinned: Bool
    let createdAt: String
    let lastMessageAt: String?
    let summary: String?
}

struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let conversationId: String
    let role: String
    let content: String
    let parentMessageId: String?
    let sequenceNo: Int
    let createdAt: String
}

enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var stringValue: String? {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(value)
        case let .bool(value):
            return String(value)
        default:
            return nil
        }
    }
}

struct RunStep: Decodable, Identifiable {
    let id: String
    let runId: String
    let stepIndex: Int
    let stepType: String
    let status: String
    let input: [String: JSONValue]
    let output: [String: JSONValue]
    let error: String?
    let startedAt: String
    let finishedAt: String?
}

struct RunDetail: Decodable {
    let id: String
    let projectId: String
    let conversationId: String
    let triggerMessageId: String
    let status: String
    let mode: String
    let outputSummary: String?
    let error: String?
    let steps: [RunStep]?
}

struct RunTodo: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
}

struct TaskStatus: Decodable {
    let messageId: String
    let runId: String?
    let status: String
}

struct SearchResponse: Decodable {
    let query: String
    let hits: [SearchHit]
}

struct SearchHit: Decodable, Identifiable {
    let assetId: String
    let chunkId: String
    let score: Double
    let text: String
    let title: String?
    let pathOrUrl: String?

    var id: String { chunkId }
}

struct Health: Decodable {
    let ok: Bool
}

struct APIErrorResponse: Decodable {
    let detail: String
}

struct RuntimeConfigPayload: Decodable {
    let plannerBackend: String
    let codexMode: String
    let codexBin: String
    let codexPlannerModel: String
    let plannerCmd: String?
    let plannerTimeoutSeconds: Int
    let openaiApiKeySet: Bool
    let openaiModel: String
    let openaiBaseUrl: String
    let openaiTimeoutSeconds: Int
    let configPath: String
}

struct RuntimeSetupStatus: Decodable {
    let plannerBackend: String
    let codexMode: String
    let codexBin: String
    let codexBinResolved: String?
    let codexAvailable: Bool
    let loginChecked: Bool
    let loginOk: Bool?
    let detail: String?
    let plannerCmdConfigured: Bool
    let codexPlannerModel: String
    let openaiApiKeySet: Bool
    let openaiPlannerConfigured: Bool
    let openaiModel: String
    let openaiBaseUrl: String
    let codexPlannerReady: Bool
    let openaiPlannerReady: Bool
    let gptViaCodexCliPossible: Bool
    let plannerReady: Bool
    let requiredBlockers: [String]
    let recommendations: [String]
    let blockers: [String]
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let relativePath: String
    let name: String
    let depth: Int
    let isDirectory: Bool
}

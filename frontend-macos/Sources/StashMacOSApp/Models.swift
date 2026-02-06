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

struct CSVCellChange: Decodable, Hashable, Identifiable {
    let row: Int
    let column: Int
    let old: String
    let new: String

    var id: String {
        "\(row):\(column):\(old)->\(new)"
    }
}

struct MessagePart: Decodable, Hashable, Identifiable {
    let type: String
    let path: String?
    let fromPath: String?
    let sourcePath: String?
    let summary: String?
    let diff: String?
    let csvCellChanges: [CSVCellChange]

    var id: String {
        let base = path ?? fromPath ?? summary ?? type
        let detail = (summary ?? "") + "|" + String((diff ?? "").prefix(80))
        return "\(type):\(base):\(detail)"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case path
        case fromPath
        case sourcePath
        case summary
        case diff
        case csvCellChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        fromPath = try container.decodeIfPresent(String.self, forKey: .fromPath)
        sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        diff = try container.decodeIfPresent(String.self, forKey: .diff)
        csvCellChanges = try container.decodeIfPresent([CSVCellChange].self, forKey: .csvCellChanges) ?? []
    }
}

struct Message: Decodable, Identifiable, Hashable {
    let id: String
    let projectId: String
    let conversationId: String
    let role: String
    let content: String
    let parts: [MessagePart]
    let parentMessageId: String?
    let sequenceNo: Int
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case conversationId
        case role
        case content
        case parts
        case parentMessageId
        case sequenceNo
        case createdAt
    }

    init(
        id: String,
        projectId: String,
        conversationId: String,
        role: String,
        content: String,
        parts: [MessagePart],
        parentMessageId: String?,
        sequenceNo: Int,
        createdAt: String
    ) {
        self.id = id
        self.projectId = projectId
        self.conversationId = conversationId
        self.role = role
        self.content = content
        self.parts = parts
        self.parentMessageId = parentMessageId
        self.sequenceNo = sequenceNo
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        conversationId = try container.decode(String.self, forKey: .conversationId)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        parts = try container.decodeIfPresent([MessagePart].self, forKey: .parts) ?? []
        parentMessageId = try container.decodeIfPresent(String.self, forKey: .parentMessageId)
        sequenceNo = try container.decode(Int.self, forKey: .sequenceNo)
        createdAt = try container.decode(String.self, forKey: .createdAt)
    }
}

enum MessageArtifactChipKind: String, Hashable {
    case output
    case edit
    case delete
    case rename

    var iconName: String {
        switch self {
        case .output:
            return "doc"
        case .edit:
            return "pencil"
        case .delete:
            return "trash"
        case .rename:
            return "arrow.left.arrow.right"
        }
    }
}

struct MessageArtifactChip: Identifiable, Hashable {
    let kind: MessageArtifactChipKind
    let label: String
    let path: String?
    let summary: String?

    var id: String {
        "\(kind.rawValue):\((path ?? label).lowercased())"
    }

    var isOpenAction: Bool {
        kind == .output && path != nil
    }
}

private enum MessageTimestampFormatter {
    static let sourceWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let sourceDefault = ISO8601DateFormatter()

    static let shortTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func display(from rawISOText: String) -> String {
        let trimmed = rawISOText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawISOText }
        if let parsed = sourceWithFractional.date(from: trimmed) ?? sourceDefault.date(from: trimmed) {
            return shortTime.string(from: parsed)
        }
        return rawISOText
    }

    static func relative(from rawISOText: String) -> String? {
        let trimmed = rawISOText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = sourceWithFractional.date(from: trimmed) ?? sourceDefault.date(from: trimmed) else {
            return nil
        }
        return relativeFormatter.localizedString(for: parsed, relativeTo: Date())
    }
}

extension Message {
    var displayTimestamp: String {
        MessageTimestampFormatter.display(from: createdAt)
    }

    var displayRelativeTimestamp: String? {
        MessageTimestampFormatter.relative(from: createdAt)
    }

    var compactMetadataLabel: String {
        let roleLabel = role.lowercased() == "user" ? "You" : "Stash"
        if let relative = displayRelativeTimestamp, !relative.isEmpty {
            return "\(roleLabel) • \(relative)"
        }
        return "\(roleLabel) • \(displayTimestamp)"
    }

    var renderedAssistantContent: String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role.lowercased() != "user" else {
            return trimmed
        }

        let noFileTags = MessageContentSanitizer.stripStashFileTags(from: trimmed)
        let sanitized = MessageContentSanitizer.stripCodexCommandBlocks(from: noFileTags)
        guard !sanitized.isEmpty else { return trimmed }

        if let summaryRange = sanitized.range(of: "Execution summary:") {
            let beforeSummary = String(sanitized[..<summaryRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !beforeSummary.isEmpty {
                return sanitized
            }
            let summary = String(sanitized[summaryRange.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !summary.isEmpty {
                return summary
            }
        }
        return sanitized
    }

    var artifactChips: [MessageArtifactChip] {
        guard role.lowercased() != "user" else {
            return []
        }

        var ordered: [MessageArtifactChip] = []
        var seen = Set<String>()

        func appendChip(_ chip: MessageArtifactChip) {
            let key = chip.id.lowercased()
            if seen.contains(key) {
                return
            }
            seen.insert(key)
            ordered.append(chip)
        }

        for part in parts {
            let type = part.type.lowercased()
            switch type {
            case "edit_file":
                guard let path = part.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
                appendChip(MessageArtifactChip(kind: .edit, label: path, path: path, summary: part.summary))
            case "delete_file":
                guard let path = part.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
                appendChip(MessageArtifactChip(kind: .delete, label: path, path: path, summary: part.summary))
            case "rename_file":
                let from = part.fromPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let to = part.path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let label = !from.isEmpty && !to.isEmpty ? "\(from) -> \(to)" : (to.isEmpty ? from : to)
                guard !label.isEmpty else { continue }
                appendChip(MessageArtifactChip(kind: .rename, label: label, path: to.isEmpty ? nil : to, summary: part.summary))
            case "output_file":
                guard let path = part.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
                appendChip(MessageArtifactChip(kind: .output, label: path, path: path, summary: part.summary))
            default:
                continue
            }
        }

        for path in MessageContentSanitizer.extractStashFileTags(from: content) {
            appendChip(MessageArtifactChip(kind: .output, label: path, path: path, summary: nil))
        }
        return ordered
    }
}

private enum MessageContentSanitizer {
    static func stripCodexCommandBlocks(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<codex_cmd(?:\\s+[^>]*)?>[\\s\\S]*?<\\/codex_cmd>",
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: nsRange, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractStashFileTags(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: "<stash_file>\\s*([^<]+?)\\s*<\\/stash_file>",
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        var paths: [String] = []
        var seen = Set<String>()
        for match in matches where match.numberOfRanges > 1 {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = value.lowercased()
            if value.isEmpty || seen.contains(lowered) { continue }
            seen.insert(lowered)
            paths.append(value)
        }
        return paths
    }

    static func stripStashFileTags(from text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "(?im)^\\s*[-*]?\\s*<stash_file>\\s*[^<]+?\\s*<\\/stash_file>\\s*$",
            options: [.caseInsensitive]
        ) else {
            return text
        }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: nsRange, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
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

    var intValue: Int? {
        switch self {
        case let .number(value):
            return Int(value)
        case let .string(value):
            return Int(value)
        case let .bool(value):
            return value ? 1 : 0
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value):
            return value
        case let .string(value):
            let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lowered == "true" {
                return true
            }
            if lowered == "false" {
                return false
            }
            return nil
        case let .number(value):
            return value != 0
        default:
            return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(value) = self {
            return value
        }
        return nil
    }

    var stringArrayValue: [String]? {
        guard case let .array(values) = self else {
            return nil
        }
        return values.compactMap(\.stringValue)
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
    let runOutcomeKind: String?
    let requiresConfirmation: Bool?
    let changeSetId: String?
    let changes: [MessagePart]
    let steps: [RunStep]?

    private enum CodingKeys: String, CodingKey {
        case id
        case projectId
        case conversationId
        case triggerMessageId
        case status
        case mode
        case outputSummary
        case error
        case runOutcomeKind
        case requiresConfirmation
        case changeSetId
        case changes
        case steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        conversationId = try container.decode(String.self, forKey: .conversationId)
        triggerMessageId = try container.decode(String.self, forKey: .triggerMessageId)
        status = try container.decode(String.self, forKey: .status)
        mode = try container.decode(String.self, forKey: .mode)
        outputSummary = try container.decodeIfPresent(String.self, forKey: .outputSummary)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        runOutcomeKind = try container.decodeIfPresent(String.self, forKey: .runOutcomeKind)
        requiresConfirmation = try container.decodeIfPresent(Bool.self, forKey: .requiresConfirmation)
        changeSetId = try container.decodeIfPresent(String.self, forKey: .changeSetId)
        changes = try container.decodeIfPresent([MessagePart].self, forKey: .changes) ?? []
        steps = try container.decodeIfPresent([RunStep].self, forKey: .steps)
    }
}

struct RunTodo: Identifiable, Hashable {
    let id: String
    let title: String
    let status: String
}

struct RunFeedbackEvent: Identifiable, Hashable {
    let id: String
    let type: String
    let title: String
    let detail: String?
    let timestamp: String
}

struct ProjectEvent: Decodable, Identifiable {
    let id: Int
    let type: String
    let projectId: String
    let conversationId: String?
    let runId: String?
    let ts: String
    let payload: [String: JSONValue]
}

struct RunProgressPayload: Hashable {
    let currentStep: Int
    let totalSteps: Int
    let completedSteps: Int
    let failedSteps: Int
    let activeStepLabel: String?
    let durationMs: Int?
}

extension ProjectEvent {
    var runPhaseName: String? {
        payload["phase"]?.stringValue
    }

    var runPhaseLabel: String? {
        payload["label"]?.stringValue
    }

    var runPhaseIndex: Int? {
        payload["progress_index"]?.intValue
    }

    var runPhaseTotal: Int? {
        payload["progress_total"]?.intValue
    }

    var runProgressPayload: RunProgressPayload? {
        guard let totalSteps = payload["total_steps"]?.intValue else {
            return nil
        }
        return RunProgressPayload(
            currentStep: payload["current_step"]?.intValue ?? 0,
            totalSteps: totalSteps,
            completedSteps: payload["completed_steps"]?.intValue ?? 0,
            failedSteps: payload["failed_steps"]?.intValue ?? 0,
            activeStepLabel: payload["active_step_label"]?.stringValue,
            durationMs: payload["duration_ms"]?.intValue
        )
    }

    var runNoteKind: String? {
        payload["kind"]?.stringValue
    }

    var runNoteText: String? {
        payload["text"]?.stringValue
    }
}

struct TaskStatus: Decodable {
    let messageId: String
    let runId: String?
    let status: String
}

struct IndexJobResponse: Decodable {
    let jobId: String
    let projectId: String
    let status: String
    let startedAt: String
    let finishedAt: String?
    let detail: [String: JSONValue]
}

struct QuickActionItemPayload: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let prompt: String
    let category: String
    let confidence: Double
    let reason: String?
}

struct QuickActionsPayload: Decodable {
    let projectId: String
    let actions: [QuickActionItemPayload]
    let source: String
    let indexedFileCount: Int
    let generatedAt: String
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
    let activeProjectId: String?
    let openaiApiKeySet: Bool
    let openaiModel: String
    let openaiBaseUrl: String
    let openaiTimeoutSeconds: Int
    let configPath: String
}

struct ActiveProjectPayload: Decodable {
    let activeProjectId: String?
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
    let needsOpenaiKey: Bool?
    let requiredBlockers: [String]
    let recommendations: [String]
    let blockers: [String]
}

enum ExplorerMode: String, CaseIterable, Codable, Hashable {
    case tree
    case folders

    var title: String {
        switch self {
        case .tree:
            return "Tree"
        case .folders:
            return "Folders"
        }
    }
}

enum FileOpenMode: String, Codable, Hashable {
    case preview
    case pinned
}

enum FileKind: String, Codable, Hashable {
    case markdown
    case text
    case csv
    case code
    case json
    case yaml
    case xml
    case image
    case pdf
    case office
    case binary
    case unknown

    var isEditable: Bool {
        switch self {
        case .markdown, .text, .csv, .code, .json, .yaml, .xml:
            return true
        case .image, .pdf, .office, .binary, .unknown:
            return false
        }
    }

    var supportsQuickLook: Bool {
        switch self {
        case .image, .pdf, .office:
            return true
        case .markdown, .text, .csv, .code, .json, .yaml, .xml, .binary, .unknown:
            return false
        }
    }
}

struct WorkspaceTab: Identifiable, Hashable, Codable {
    let id: String
    let relativePath: String
    let title: String
    let fileKind: FileKind
    var isPreview: Bool
    var isPinned: Bool

    static func make(relativePath: String, fileKind: FileKind, isPreview: Bool, isPinned: Bool) -> WorkspaceTab {
        WorkspaceTab(
            id: UUID().uuidString,
            relativePath: relativePath,
            title: URL(fileURLWithPath: relativePath).lastPathComponent,
            fileKind: fileKind,
            isPreview: isPreview,
            isPinned: isPinned
        )
    }
}

struct DocumentBuffer: Hashable {
    let relativePath: String
    let fileKind: FileKind
    var content: String
    var lastSavedContent: String
    var isDirty: Bool
    var isBinary: Bool
    var fileSizeBytes: Int64?
    var modifiedAt: Date?
}

struct FileItem: Identifiable, Hashable {
    let id: String
    let relativePath: String
    let name: String
    let depth: Int
    let isDirectory: Bool
    let parentRelativePath: String
    let pathExtension: String
    let fileSizeBytes: Int64?
    let modifiedAt: Date?
}

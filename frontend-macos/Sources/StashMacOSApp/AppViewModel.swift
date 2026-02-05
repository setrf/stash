import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    struct CodexModelPreset: Identifiable, Hashable {
        let value: String
        let label: String
        let hint: String

        var id: String {
            value.isEmpty ? "__default__" : value
        }
    }

    @Published var backendConnected = false
    @Published var backendStatusText = "Backend offline"

    @Published var project: Project?
    @Published var projectRootURL: URL?
    @Published var conversations: [Conversation] = []
    @Published var selectedConversationID: String?
    @Published var messages: [Message] = []

    @Published var files: [FileItem] = []
    @Published var fileQuery = ""

    @Published var composerText = ""
    @Published var isSending = false
    @Published var runStatusText: String?
    @Published var runInProgress = false
    @Published var indexingStatusText: String?
    @Published var runThinkingText: String?
    @Published var runPlanningText: String?
    @Published var runPlannerPreview: String?
    @Published var runTodos: [RunTodo] = []
    @Published var runFeedbackEvents: [RunFeedbackEvent] = []
    @Published var mentionSuggestions: [FileItem] = []
    @Published var mentionedFilePaths: [String] = []
    @Published var setupStatus: RuntimeSetupStatus?
    @Published var runtimeConfig: RuntimeConfigPayload?
    @Published var setupSheetPresented = false
    @Published var setupSaving = false
    @Published var setupPlannerBackend = "auto"
    @Published var setupCodexMode = "cli"
    @Published var setupCodexBin = "codex"
    @Published var setupCodexPlannerModel = "gpt-5.3-codex"
    @Published var setupPlannerCmd = ""
    @Published var setupPlannerTimeoutSeconds = "60"
    @Published var setupOpenAIAPIKey = ""
    @Published var setupOpenAIModel = "gpt-5"
    @Published var setupOpenAIBaseURL = "https://api.openai.com/v1"
    @Published var setupOpenAITimeoutSeconds = "60"
    @Published var setupStatusText: String?
    @Published var onboardingActive = false

    @Published var errorText: String?

    private var runPollTask: Task<Void, Never>?
    private var runEventStreamTask: Task<Void, Never>?
    private var filePollTask: Task<Void, Never>?
    private var indexStatusClearTask: Task<Void, Never>?
    private var lastFileSignature: Int?
    private var lastFileChangeIndexRequestAt = Date.distantPast
    private var didBootstrap = false
    private var isPresentingProjectPicker = false
    private let filePollInterval: Duration = .seconds(2)
    private let changeIndexCooldownSeconds: TimeInterval = 4
    private let maxMentionedFiles = 6
    private let maxMentionExcerptChars = 3500
    private let feedbackSourceFormatter = ISO8601DateFormatter()
    private let feedbackClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let defaults = UserDefaults.standard
    private let lastProjectPathKey = "stash.lastProjectPath"
    private let lastProjectBookmarkKey = "stash.lastProjectFolderBookmark"
    private let onboardingCompletedKey = "stash.onboardingCompletedV1"
    private let recommendedCodexModel = "gpt-5.3-codex"
    private let initialProjectRootURL: URL?
    private var activeSecurityScopedProjectURL: URL?
    private var activeRunID: String?
    private var lastRunEventID = 0
    private var client: BackendClient
    private let baseCodexModelPresets: [CodexModelPreset] = [
        CodexModelPreset(value: "gpt-5.3-codex", label: "GPT-5.3 Codex (medium)", hint: "Recommended default"),
        CodexModelPreset(value: "gpt-5.3-codex-low", label: "GPT-5.3 Codex (low)", hint: "Fastest"),
        CodexModelPreset(value: "gpt-5.3-codex-high", label: "GPT-5.3 Codex (high)", hint: "Best quality"),
        CodexModelPreset(value: "", label: "CLI default (latest)", hint: "Use your Codex CLI default"),
    ]

    init(initialProjectRootURL: URL? = nil) {
        self.initialProjectRootURL = initialProjectRootURL
        let defaultURL = ProcessInfo.processInfo.environment["STASH_BACKEND_URL"] ?? "http://127.0.0.1:8765"
        client = BackendClient(baseURL: URL(string: defaultURL) ?? URL(string: "http://127.0.0.1:8765")!)
    }

    deinit {
        runPollTask?.cancel()
        runEventStreamTask?.cancel()
        filePollTask?.cancel()
        indexStatusClearTask?.cancel()
        if let activeSecurityScopedProjectURL {
            activeSecurityScopedProjectURL.stopAccessingSecurityScopedResource()
        }
    }

    var selectedConversation: Conversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    var aiSetupReady: Bool {
        setupStatus?.plannerReady == true
    }

    var onboardingReadyToFinish: Bool {
        backendConnected && aiSetupReady && project != nil
    }

    var aiSetupBadgeText: String {
        if setupStatus?.plannerReady == true {
            return "AI Ready"
        }
        return "Setup Required"
    }

    var filteredFiles: [FileItem] {
        let trimmed = fileQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.relativePath.localizedCaseInsensitiveContains(trimmed) ||
                $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var visibleMessages: [Message] {
        messages.filter {
            let role = $0.role.lowercased()
            return role == "user" || role == "assistant"
        }
    }

    var codexModelPresets: [CodexModelPreset] {
        var presets = baseCodexModelPresets
        let current = setupCodexPlannerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !presets.contains(where: { $0.value.caseInsensitiveCompare(current) == .orderedSame }) {
            presets.append(CodexModelPreset(value: current, label: "Custom: \(current)", hint: "Persisted custom value"))
        }
        return presets
    }

    func composerDidChange() {
        refreshMentionState()
    }

    func applyMentionSuggestion(_ item: FileItem) {
        guard !item.isDirectory else { return }

        let replacement = "@\(item.relativePath) "
        if let range = composerText.range(of: "@[^\\s]*$", options: .regularExpression) {
            composerText.replaceSubrange(range, with: replacement)
        } else {
            composerText = composerText + (composerText.hasSuffix(" ") || composerText.isEmpty ? "" : " ") + replacement
        }
        refreshMentionState()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        await pingBackend()
        if backendConnected {
            await refreshRuntimeSetup()
        }

        let onboardingCompleted = defaults.bool(forKey: onboardingCompletedKey)
        if !onboardingCompleted {
            onboardingActive = true
            setupSheetPresented = true
            if setupStatusText == nil {
                setupStatusText = "Welcome to Stash. Complete the first-run setup checklist."
            }
        }

        if let bookmarkData = defaults.data(forKey: lastProjectBookmarkKey),
           let restored = resolveBookmarkedProjectURL(from: bookmarkData),
           FileManager.default.fileExists(atPath: restored.url.path)
        {
            await openProject(url: restored.url, bookmarkData: restored.bookmarkData)
            return
        }

        if let initialProjectRootURL {
            await openProject(url: initialProjectRootURL)
            return
        }

        if let lastPath = defaults.string(forKey: lastProjectPathKey),
           FileManager.default.fileExists(atPath: lastPath)
        {
            errorText = "Re-select your project folder once so macOS can grant persistent access."
        }
    }

    func pingBackend() async {
        do {
            _ = try await client.health()
            backendConnected = true
            backendStatusText = "Connected"
            errorText = nil
        } catch {
            backendConnected = false
            backendStatusText = "Offline"
            errorText = error.localizedDescription
        }
    }

    func openSetupSheet() {
        setupSheetPresented = true
        Task { await refreshRuntimeSetup() }
    }

    func finishOnboarding() {
        if !onboardingReadyToFinish {
            setupStatusText = "Complete all required onboarding steps before finishing."
            return
        }
        defaults.set(true, forKey: onboardingCompletedKey)
        onboardingActive = false
        setupSheetPresented = false
        setupStatusText = "Setup complete."
    }

    func refreshRuntimeSetup() async {
        guard backendConnected else { return }
        do {
            let config = try await client.runtimeConfig()
            let status = try await client.runtimeSetupStatus()
            runtimeConfig = config
            setupStatus = status
            setupPlannerBackend = config.plannerBackend
            setupCodexMode = config.codexMode
            setupCodexBin = status.codexBinResolved ?? config.codexBin
            setupCodexPlannerModel = suggestedCodexPlannerModel(config.codexPlannerModel)
            setupPlannerCmd = config.plannerCmd ?? ""
            setupPlannerTimeoutSeconds = String(config.plannerTimeoutSeconds)
            setupOpenAIModel = config.openaiModel
            setupOpenAIBaseURL = config.openaiBaseUrl
            setupOpenAITimeoutSeconds = String(config.openaiTimeoutSeconds)
            if onboardingActive {
                if status.plannerReady {
                    setupStatusText = "AI setup is ready. Select a project folder, then finish onboarding."
                } else if status.needsOpenaiKey == true {
                    setupStatusText = "Add an OpenAI API key, or sign in to Codex CLI."
                } else {
                    setupStatusText = "Sign in to Codex CLI to continue."
                }
            } else {
                if status.plannerReady {
                    setupStatusText = "AI setup is ready."
                } else if status.needsOpenaiKey == true {
                    setupStatusText = "Add an OpenAI API key, or sign in to Codex CLI."
                } else {
                    setupStatusText = "Sign in to Codex CLI to run AI tasks."
                }
            }
        } catch {
            setupStatusText = "Could not load setup status: \(setupErrorMessage(from: error))"
        }
    }

    func saveRuntimeSetup() async {
        guard backendConnected else {
            setupStatusText = "Backend is offline."
            return
        }
        setupSaving = true
        defer { setupSaving = false }

        let openAIKeyTrimmed = setupOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexModelTrimmed = setupCodexPlannerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexModelToPersist = normalizedLegacyCodexPlannerModel(codexModelTrimmed)

        do {
            _ = try await client.updateRuntimeConfig(
                plannerBackend: "auto",
                codexMode: "cli",
                codexBin: setupCodexBin.isEmpty ? "codex" : setupCodexBin,
                codexPlannerModel: codexModelToPersist,
                plannerCmd: nil,
                clearPlannerCmd: true,
                plannerTimeoutSeconds: 60,
                openaiAPIKey: openAIKeyTrimmed.isEmpty ? nil : openAIKeyTrimmed,
                clearOpenAIAPIKey: false,
                openaiModel: "gpt-5",
                openaiBaseURL: "https://api.openai.com/v1",
                openaiTimeoutSeconds: 60
            )
            setupOpenAIAPIKey = ""
            await refreshRuntimeSetup()
            if !onboardingActive && aiSetupReady {
                setupSheetPresented = false
                errorText = nil
            }
            if onboardingActive, aiSetupReady {
                setupStatusText = "AI setup is ready. Select a project folder, then finish onboarding."
            }
        } catch {
            setupStatusText = "Could not save setup: \(setupErrorMessage(from: error))"
        }
    }

    private func suggestedCodexPlannerModel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return recommendedCodexModel
        }
        return normalizedLegacyCodexPlannerModel(trimmed)
    }

    private func normalizedLegacyCodexPlannerModel(_ value: String) -> String {
        if value.caseInsensitiveCompare("gpt-5") == .orderedSame {
            return recommendedCodexModel
        }
        if value.caseInsensitiveCompare("gpt-5-codex") == .orderedSame {
            return recommendedCodexModel
        }
        return value
    }

    private func setupErrorMessage(from error: Error) -> String {
        if case let BackendError.httpError(code, _) = error, code == 404 {
            return "Backend API route not found (404). Restart backend with ./scripts/run_backend.sh, then relaunch the app."
        }
        return error.localizedDescription
    }
    func presentProjectPicker() {
        guard !isPresentingProjectPicker else { return }
        isPresentingProjectPicker = true
        defer { isPresentingProjectPicker = false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Grant Access"
        panel.message = "Choose a project folder for Stash. This grants macOS folder access and saves it for future launches."
        panel.directoryURL = projectRootURL

        if panel.runModal() == .OK, let url = panel.url {
            let bookmarkData = createProjectBookmark(for: url)
            Task { await openProject(url: url, bookmarkData: bookmarkData) }
        } else if project == nil {
            errorText = "No project selected. Pick a folder to start using Stash."
        }
    }

    func openProject(url: URL, bookmarkData: Data? = nil) async {
        guard let prepared = prepareProjectAccess(url: url, bookmarkData: bookmarkData) else {
            errorText = "Could not access this folder. Re-select it and grant macOS access."
            return
        }

        do {
            let opened = try await client.createOrOpenProject(
                name: prepared.url.lastPathComponent,
                rootPath: prepared.url.path
            )
            project = opened
            projectRootURL = prepared.url
            runPollTask?.cancel()
            stopRunEventStream()
            activeRunID = nil
            resetRunFeedback(clearEvents: true)
            rememberProjectSelection(url: prepared.url, bookmarkData: prepared.bookmarkData)
            activatePreparedAccess(prepared)

            await refreshFiles(force: true, triggerChangeIndex: false)
            refreshMentionState()
            startFilePolling()
            await refreshConversations()
            await autoIndexCurrentProject()
            await pingBackend()
            if backendConnected {
                await refreshRuntimeSetup()
                if onboardingActive, onboardingReadyToFinish {
                    setupStatusText = "All required steps are complete. Finish onboarding."
                }
            }
            errorText = nil
        } catch {
            releasePreparedAccessOnFailure(prepared)
            errorText = "Could not open project: \(error.localizedDescription)"
        }
    }

    func handleFileDrop(providers: [NSItemProvider], toRelativeDirectory relativeDirectory: String?) -> Bool {
        guard projectRootURL != nil else { return false }
        let acceptsFiles = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard acceptsFiles else { return false }

        Task { await processDroppedFiles(providers: providers, toRelativeDirectory: relativeDirectory) }
        return true
    }

    func openFileItemInOS(_ item: FileItem) {
        guard let projectRootURL else {
            errorText = "Open a project folder first."
            return
        }

        let itemURL = projectRootURL
            .appendingPathComponent(item.relativePath)
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: itemURL.path) else {
            errorText = "File no longer exists: \(item.relativePath)"
            return
        }

        if !NSWorkspace.shared.open(itemURL) {
            errorText = "Could not open in macOS: \(item.relativePath)"
        }
    }

    func openTaggedOutputPathInOS(_ rawPath: String) {
        guard let projectRootURL else {
            errorText = "Open a project folder first."
            return
        }

        let cleaned = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let expanded = NSString(string: cleaned).expandingTildeInPath
        let root = projectRootURL.standardizedFileURL
        let targetURL: URL
        if expanded.hasPrefix("/") {
            targetURL = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            targetURL = root.appendingPathComponent(cleaned).standardizedFileURL
        }

        guard isInsideProject(targetURL, root: root) else {
            errorText = "Blocked opening path outside project: \(cleaned)"
            return
        }
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            errorText = "Output file not found: \(cleaned)"
            return
        }
        if !NSWorkspace.shared.open(targetURL) {
            errorText = "Could not open output file: \(cleaned)"
        }
    }

    private struct PreparedProjectAccess {
        let url: URL
        let bookmarkData: Data?
        let startedSecurityScope: Bool
        let previousSecurityScopedURL: URL?
    }

    private func createProjectBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            errorText = "Could not save folder permission bookmark: \(error.localizedDescription)"
            return nil
        }
    }

    private func resolveBookmarkedProjectURL(from bookmarkData: Data) -> (url: URL, bookmarkData: Data?)? {
        do {
            var stale = false
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ).standardizedFileURL

            if stale {
                let refreshed = createProjectBookmark(for: resolvedURL)
                return (resolvedURL, refreshed)
            }
            return (resolvedURL, bookmarkData)
        } catch {
            defaults.removeObject(forKey: lastProjectBookmarkKey)
            return nil
        }
    }

    private func prepareProjectAccess(url: URL, bookmarkData: Data?) -> PreparedProjectAccess? {
        let standardizedURL = url.standardizedFileURL
        var resolvedURL = standardizedURL
        var effectiveBookmark = bookmarkData

        if let bookmarkData, let restored = resolveBookmarkedProjectURL(from: bookmarkData) {
            resolvedURL = restored.url
            effectiveBookmark = restored.bookmarkData
        } else if bookmarkData == nil {
            effectiveBookmark = createProjectBookmark(for: standardizedURL)
        }

        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            return nil
        }

        let previous = activeSecurityScopedProjectURL
        let startedSecurityScope: Bool
        if previous?.standardizedFileURL == resolvedURL.standardizedFileURL {
            startedSecurityScope = false
        } else {
            startedSecurityScope = resolvedURL.startAccessingSecurityScopedResource()
        }

        return PreparedProjectAccess(
            url: resolvedURL,
            bookmarkData: effectiveBookmark,
            startedSecurityScope: startedSecurityScope,
            previousSecurityScopedURL: previous
        )
    }

    private func activatePreparedAccess(_ prepared: PreparedProjectAccess) {
        if let previous = prepared.previousSecurityScopedURL, previous != prepared.url {
            previous.stopAccessingSecurityScopedResource()
        }

        if prepared.startedSecurityScope {
            activeSecurityScopedProjectURL = prepared.url
        } else if prepared.previousSecurityScopedURL?.standardizedFileURL != prepared.url.standardizedFileURL {
            activeSecurityScopedProjectURL = nil
        }
    }

    private func releasePreparedAccessOnFailure(_ prepared: PreparedProjectAccess) {
        if prepared.startedSecurityScope {
            prepared.url.stopAccessingSecurityScopedResource()
        }
    }

    private func rememberProjectSelection(url: URL, bookmarkData: Data?) {
        defaults.set(url.path, forKey: lastProjectPathKey)
        if let bookmarkData {
            defaults.set(bookmarkData, forKey: lastProjectBookmarkKey)
        } else {
            defaults.removeObject(forKey: lastProjectBookmarkKey)
        }
    }

    private func processDroppedFiles(providers: [NSItemProvider], toRelativeDirectory relativeDirectory: String?) async {
        guard let root = projectRootURL?.standardizedFileURL else { return }
        let droppedURLs = await loadDroppedFileURLs(from: providers)
        if droppedURLs.isEmpty {
            errorText = "Could not read dropped items. Try dropping files from Finder again."
            return
        }

        let targetDir = normalizedDropDirectory(relativeDirectory)
        let destinationBase = targetDir.isEmpty ? root : root.appendingPathComponent(targetDir, isDirectory: true)
        guard isInsideProject(destinationBase, root: root) else {
            errorText = "Drop target is outside the active project folder."
            return
        }

        do {
            try FileManager.default.createDirectory(at: destinationBase, withIntermediateDirectories: true)
        } catch {
            errorText = "Could not create destination folder: \(error.localizedDescription)"
            return
        }

        var importedCount = 0
        var movedCount = 0
        var failures: [String] = []

        for source in droppedURLs {
            do {
                let op = try transferDroppedItem(from: source, to: destinationBase, projectRoot: root)
                if op == .moved {
                    movedCount += 1
                } else {
                    importedCount += 1
                }
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        await refreshFiles(force: true, triggerChangeIndex: false)
        await autoIndexCurrentProject(fullScan: false, statusText: "Files changed. Re-indexing...")

        if !failures.isEmpty {
            let sample = failures.prefix(2).joined(separator: " | ")
            errorText = "Dropped \(importedCount + movedCount) item(s), \(failures.count) failed. \(sample)"
            return
        }

        if movedCount > 0 && importedCount > 0 {
            runStatusText = "Moved \(movedCount), imported \(importedCount)"
        } else if movedCount > 0 {
            runStatusText = "Moved \(movedCount) item(s)"
        } else {
            runStatusText = "Imported \(importedCount) item(s)"
        }
    }

    private enum DropTransferOp {
        case copied
        case moved
    }

    private func transferDroppedItem(from sourceURL: URL, to destinationBase: URL, projectRoot: URL) throws -> DropTransferOp {
        let fm = FileManager.default
        let source = sourceURL.standardizedFileURL
        let sourceAccess = source.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        guard fm.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let desiredDestination = destinationBase.appendingPathComponent(source.lastPathComponent)
        let destination = uniqueDestinationURL(for: desiredDestination)

        guard isInsideProject(destination, root: projectRoot) else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let sourceInsideProject = isInsideProject(source, root: projectRoot)
        if sourceInsideProject {
            if source.standardizedFileURL == destination.standardizedFileURL {
                return .moved
            }

            if isDescendant(destination, of: source) {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFeatureUnsupportedError,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot move a folder into itself."]
                )
            }
            try fm.moveItem(at: source, to: destination)
            return .moved
        }

        try fm.copyItem(at: source, to: destination)
        return .copied
    }

    private func uniqueDestinationURL(for requested: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: requested.path) {
            return requested
        }

        let ext = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        let parent = requested.deletingLastPathComponent()

        for index in 1 ... 999 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(stem)-\(index)"
            } else {
                candidateName = "\(stem)-\(index).\(ext)"
            }
            let candidate = parent.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return parent.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
    }

    private func normalizedDropDirectory(_ relativeDirectory: String?) -> String {
        guard let relativeDirectory else { return "" }
        let trimmed = relativeDirectory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed == "." {
            return ""
        }
        return trimmed
    }

    private func isInsideProject(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        return candidatePath == ancestorPath || candidatePath.hasPrefix(ancestorPath + "/")
    }

    private func loadDroppedFileURLs(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            if let url = await loadSingleDroppedFileURL(from: provider) {
                urls.append(url.standardizedFileURL)
            }
        }
        var uniqueByPath: [String: URL] = [:]
        for url in urls {
            uniqueByPath[url.path] = url
        }
        return uniqueByPath.values.sorted { $0.path < $1.path }
    }

    private func loadSingleDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _error in
                if let data = item as? Data,
                   let url = NSURL(absoluteURLWithDataRepresentation: data, relativeTo: nil) as URL?
                {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string)
                {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    func refreshConversations() async {
        guard let projectID = project?.id else { return }

        do {
            let loaded = try await client.listConversations(projectID: projectID)
            if loaded.isEmpty {
                let conversation = try await client.createConversation(projectID: projectID, title: "General")
                conversations = [conversation]
                selectedConversationID = conversation.id
                await loadMessages(conversationID: conversation.id)
                return
            }

            conversations = loaded
            if let selectedConversationID, loaded.contains(where: { $0.id == selectedConversationID }) {
                await loadMessages(conversationID: selectedConversationID)
            } else {
                let preferred = project?.activeConversationId
                selectedConversationID = loaded.first(where: { $0.id == preferred })?.id ?? loaded.first?.id
                if let selectedConversationID {
                    await loadMessages(conversationID: selectedConversationID)
                } else {
                    messages = []
                }
            }
        } catch {
            errorText = "Could not load conversations: \(error.localizedDescription)"
        }
    }

    func createConversation() async {
        guard let projectID = project?.id else {
            errorText = "Open a project before creating a conversation"
            return
        }

        detachRunTrackingFromCurrentConversation()
        let title = "Session \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
        do {
            let conv = try await client.createConversation(projectID: projectID, title: title)
            conversations.insert(conv, at: 0)
            selectedConversationID = conv.id
            messages = []
            errorText = nil
        } catch {
            errorText = "Could not create conversation: \(error.localizedDescription)"
        }
    }

    func selectConversation(id: String) async {
        detachRunTrackingFromCurrentConversation()
        selectedConversationID = id
        await loadMessages(conversationID: id)
    }

    func loadMessages(conversationID: String) async {
        guard let projectID = project?.id else { return }
        do {
            let loaded = try await client.listMessages(projectID: projectID, conversationID: conversationID)
            guard selectedConversationID == conversationID else { return }
            messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
            errorText = nil
        } catch BackendError.requestTimedOut {
            guard selectedConversationID == conversationID else { return }
            errorText = "Could not load messages in time. Retrying..."
            do {
                let loaded = try await client.listMessages(projectID: projectID, conversationID: conversationID)
                guard selectedConversationID == conversationID else { return }
                messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
                errorText = nil
            } catch {
                guard selectedConversationID == conversationID else { return }
                errorText = "Could not load messages: \(error.localizedDescription)"
            }
        } catch {
            guard selectedConversationID == conversationID else { return }
            errorText = "Could not load messages: \(error.localizedDescription)"
        }
    }

    func refreshFiles() async {
        await refreshFiles(force: false, triggerChangeIndex: false)
    }

    private func refreshFiles(force: Bool, triggerChangeIndex: Bool) async {
        guard let projectRootURL else {
            files = []
            lastFileSignature = nil
            return
        }

        let scanned = await Task.detached(priority: .utility) {
            FileScanner.scan(rootURL: projectRootURL)
        }.value

        let signature = FileScanner.signature(for: scanned)
        let changed = force || signature != lastFileSignature
        let hadPreviousSnapshot = lastFileSignature != nil
        guard changed else { return }

        files = scanned
        lastFileSignature = signature
        refreshMentionState()

        guard triggerChangeIndex, hadPreviousSnapshot else { return }
        await autoIndexCurrentProject(fullScan: false, statusText: "New files detected. Re-indexing...")
    }

    func autoIndexCurrentProject(fullScan: Bool = true, statusText: String = "Auto-indexing project...") async {
        guard let projectID = project?.id else {
            return
        }

        if !fullScan {
            let now = Date()
            if now.timeIntervalSince(lastFileChangeIndexRequestAt) < changeIndexCooldownSeconds {
                return
            }
            lastFileChangeIndexRequestAt = now
        }

        indexingStatusText = statusText
        do {
            try await client.triggerIndex(projectID: projectID, fullScan: fullScan)
            indexingStatusText = fullScan ? "Indexing started" : "Change index started"
            scheduleIndexStatusClear()
        } catch {
            indexingStatusText = nil
            errorText = "Could not auto-index project: \(error.localizedDescription)"
        }
    }

    private func startFilePolling() {
        filePollTask?.cancel()
        filePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshFiles(force: false, triggerChangeIndex: true)
                try? await Task.sleep(for: self.filePollInterval)
            }
        }
    }

    private func scheduleIndexStatusClear() {
        indexStatusClearTask?.cancel()
        indexStatusClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.indexingStatusText = nil
        }
    }

    private func refreshMentionState() {
        let mentioned = resolveMentionedFiles(from: composerText)
        mentionedFilePaths = mentioned.map(\.relativePath)

        guard let query = currentMentionQuery(from: composerText) else {
            mentionSuggestions = []
            return
        }

        let normalized = query.lowercased()
        mentionSuggestions = files
            .filter { !$0.isDirectory }
            .filter {
                $0.relativePath.lowercased().contains(normalized) ||
                    $0.name.lowercased().contains(normalized)
            }
            .prefix(8)
            .map { $0 }
    }

    private func currentMentionQuery(from text: String) -> String? {
        guard let token = text.split(whereSeparator: \.isWhitespace).last else {
            return nil
        }
        let last = String(token)
        guard last.hasPrefix("@"), last.count > 1 else {
            return nil
        }
        return String(last.dropFirst())
    }

    private func extractMentionTokens(from text: String) -> [String] {
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let regex = try? NSRegularExpression(pattern: "@([A-Za-z0-9_./\\-]+)") else {
            return []
        }
        return regex.matches(in: text, options: [], range: nsRange).compactMap {
            guard $0.numberOfRanges > 1, let range = Range($0.range(at: 1), in: text) else {
                return nil
            }
            return String(text[range])
        }
    }

    private func resolveMentionedFiles(from text: String) -> [FileItem] {
        var ordered: [FileItem] = []
        var seen = Set<String>()
        let tokens = extractMentionTokens(from: text)

        for token in tokens {
            let exactPath = files.first { !$0.isDirectory && $0.relativePath == token }
            let resolved: FileItem?

            if let exactPath {
                resolved = exactPath
            } else {
                let byName = files.filter { !$0.isDirectory && $0.name == token }
                if byName.count == 1 {
                    resolved = byName[0]
                } else {
                    let suffixMatches = files.filter {
                        !$0.isDirectory &&
                            ($0.relativePath.hasSuffix("/" + token) || $0.relativePath == token)
                    }
                    resolved = suffixMatches.count == 1 ? suffixMatches[0] : nil
                }
            }

            if let resolved, !seen.contains(resolved.relativePath) {
                ordered.append(resolved)
                seen.insert(resolved.relativePath)
            }
        }
        return Array(ordered.prefix(maxMentionedFiles))
    }

    private func buildMentionParts(from text: String) -> [[String: String]] {
        guard let projectRootURL else {
            return []
        }

        let mentionedFiles = resolveMentionedFiles(from: text)
        guard !mentionedFiles.isEmpty else {
            return []
        }

        var parts: [[String: String]] = []
        for item in mentionedFiles {
            let fileURL = projectRootURL.appendingPathComponent(item.relativePath)
            guard let data = try? Data(contentsOf: fileURL) else {
                continue
            }
            if data.contains(0) {
                parts.append(
                    [
                        "type": "file_context",
                        "path": item.relativePath,
                        "excerpt": "[binary file omitted]",
                    ]
                )
                continue
            }
            var textContent = String(decoding: data, as: UTF8.self)
            if textContent.count > maxMentionExcerptChars {
                textContent = String(textContent.prefix(maxMentionExcerptChars)) + "\n... (truncated)"
            }
            parts.append(
                [
                    "type": "file_context",
                    "path": item.relativePath,
                    "excerpt": textContent,
                ]
            )
        }
        return parts
    }

    private func updateRunFeedback(run: RunDetail) {
        let steps = run.steps ?? []
        let status = run.status.lowercased()
        if status == "running" {
            if runThinkingText == nil {
                runThinkingText = "Thinking and planning..."
            }
            if runPlanningText == nil {
                runPlanningText = steps.isEmpty ? "Planning next actions..." : "Executing planned steps..."
            }
        } else if ["done", "failed", "cancelled"].contains(status) {
            runThinkingText = nil
        }

        if steps.isEmpty {
            if status != "running", runTodos.isEmpty {
                runPlanningText = nil
            }
            return
        }

        runTodos = steps.map { step in
            let command = step.input["cmd"]?.stringValue ?? step.stepType
            return RunTodo(id: step.id, title: command, status: step.status)
        }
        if status == "running" {
            runPlanningText = "Planned \(steps.count) step(s)"
        }
    }

    private func resetRunFeedback(clearEvents: Bool) {
        runThinkingText = nil
        runPlanningText = nil
        runPlannerPreview = nil
        runTodos = []
        if clearEvents {
            runFeedbackEvents = []
            lastRunEventID = 0
        }
    }

    private func appendRunFeedbackEvent(
        type: String,
        title: String,
        detail: String? = nil,
        timestampISO: String? = nil
    ) {
        let isoText = timestampISO ?? ISO8601DateFormatter().string(from: Date())
        let displayTime: String
        if let parsed = feedbackSourceFormatter.date(from: isoText) {
            displayTime = feedbackClockFormatter.string(from: parsed)
        } else {
            displayTime = isoText
        }

        let event = RunFeedbackEvent(
            id: "event-\(lastRunEventID)-\(runFeedbackEvents.count + 1)-\(UUID().uuidString)",
            type: type,
            title: title,
            detail: detail,
            timestamp: displayTime
        )
        runFeedbackEvents.append(event)
        if runFeedbackEvents.count > 120 {
            runFeedbackEvents.removeFirst(runFeedbackEvents.count - 120)
        }
    }

    private func sanitizePlannerPreview(_ raw: String) -> String {
        guard !raw.isEmpty else {
            return ""
        }
        guard let regex = try? NSRegularExpression(
            pattern: "<codex_cmd(?:\\s+[^>]*)?>[\\s\\S]*?<\\/codex_cmd>",
            options: [.caseInsensitive]
        ) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nsRange = NSRange(raw.startIndex ..< raw.endIndex, in: raw)
        let stripped = regex.stringByReplacingMatches(in: raw, options: [], range: nsRange, withTemplate: "")
        return stripped
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateTodoStatus(stepIndex: Int, status: String, fallbackTitle: String? = nil) {
        guard stepIndex > 0 else { return }
        let index = stepIndex - 1
        if index < runTodos.count {
            let existing = runTodos[index]
            runTodos[index] = RunTodo(id: existing.id, title: existing.title, status: status)
            return
        }
        let title = fallbackTitle ?? "Step \(stepIndex)"
        runTodos.append(RunTodo(id: "step-\(stepIndex)", title: title, status: status))
    }

    private func applyRunEvent(_ event: ProjectEvent, expectedRunID: String) {
        lastRunEventID = max(lastRunEventID, event.id)

        guard activeRunID == expectedRunID else { return }
        guard event.runId == nil || event.runId == expectedRunID else { return }

        switch event.type {
        case "run_started":
            runThinkingText = "Thinking and planning..."
            runPlanningText = "Gathering indexed context..."
            appendRunFeedbackEvent(
                type: "status",
                title: "Run started",
                detail: nil,
                timestampISO: event.ts
            )

        case "run_planned":
            let commandCount = event.payload["command_count"]?.intValue ?? 0
            let ragHitCount = event.payload["rag_hit_count"]?.intValue ?? 0
            let plannerPreview = sanitizePlannerPreview(event.payload["planner_preview"]?.stringValue ?? "")
            runPlannerPreview = plannerPreview.isEmpty ? nil : plannerPreview
            if let commands = event.payload["commands"]?.stringArrayValue, !commands.isEmpty {
                runTodos = commands.enumerated().map { index, command in
                    RunTodo(id: "planned-\(index + 1)", title: command, status: "pending")
                }
            }
            runThinkingText = "Plan generated"
            runPlanningText = commandCount > 0 ? "Executing \(commandCount) planned step(s)..." : "No runnable steps in plan."
            appendRunFeedbackEvent(
                type: "planning",
                title: "Plan ready",
                detail: "Commands: \(max(commandCount, runTodos.count)) • Indexed hits: \(ragHitCount)",
                timestampISO: event.ts
            )

        case "run_step_started":
            let stepIndex = event.payload["step_index"]?.intValue ?? 0
            if stepIndex > 0 {
                updateTodoStatus(stepIndex: stepIndex, status: "running")
            }
            let stepTitle: String?
            if stepIndex > 0, stepIndex - 1 < runTodos.count {
                stepTitle = runTodos[stepIndex - 1].title
            } else {
                stepTitle = nil
            }
            appendRunFeedbackEvent(
                type: "execution",
                title: stepIndex > 0 ? "Step \(stepIndex) started" : "Step started",
                detail: stepTitle,
                timestampISO: event.ts
            )

        case "run_step_completed":
            let stepIndex = event.payload["step_index"]?.intValue ?? 0
            let status = (event.payload["status"]?.stringValue ?? "completed").lowercased()
            if stepIndex > 0 {
                updateTodoStatus(stepIndex: stepIndex, status: status)
            }
            let errorDetail = event.payload["error"]?.stringValue
            let runtimeDetail = event.payload["detail"]?.stringValue
            let exitCode = event.payload["exit_code"]?.intValue
            let detail = errorDetail ?? runtimeDetail ?? (exitCode != nil ? "exit_code=\(exitCode ?? 0)" : nil)
            appendRunFeedbackEvent(
                type: status == "failed" ? "error" : "execution",
                title: stepIndex > 0 ? "Step \(stepIndex) \(status)" : "Step \(status)",
                detail: detail,
                timestampISO: event.ts
            )

        case "run_completed":
            runThinkingText = nil
            runPlanningText = "Run completed."
            appendRunFeedbackEvent(type: "status", title: "Run completed", detail: nil, timestampISO: event.ts)

        case "run_failed":
            runThinkingText = nil
            runPlanningText = "Run failed."
            let failures = event.payload["failures"]?.intValue
            let detail = failures != nil ? "\(failures ?? 0) step(s) failed" : nil
            appendRunFeedbackEvent(type: "error", title: "Run failed", detail: detail, timestampISO: event.ts)

        case "run_cancelled":
            runThinkingText = nil
            runPlanningText = "Run cancelled."
            appendRunFeedbackEvent(type: "status", title: "Run cancelled", detail: nil, timestampISO: event.ts)

        default:
            break
        }
    }

    private func startRunEventStream(projectID: String, conversationID: String, runID: String) {
        runEventStreamTask?.cancel()
        runEventStreamTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled, self.activeRunID == runID {
                do {
                    try await self.client.streamEvents(
                        projectID: projectID,
                        conversationID: conversationID,
                        sinceID: self.lastRunEventID
                    ) { event in
                        Task { @MainActor [weak self] in
                            self?.applyRunEvent(event, expectedRunID: runID)
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard self.activeRunID == runID, self.runInProgress else {
                        return
                    }
                    self.appendRunFeedbackEvent(
                        type: "status",
                        title: "Live feed reconnecting...",
                        detail: error.localizedDescription
                    )
                    try? await Task.sleep(for: .seconds(1))
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopRunEventStream() {
        runEventStreamTask?.cancel()
        runEventStreamTask = nil
    }

    private func detachRunTrackingFromCurrentConversation() {
        runPollTask?.cancel()
        runPollTask = nil
        stopRunEventStream()
        activeRunID = nil
        runInProgress = false
        runStatusText = nil
        resetRunFeedback(clearEvents: true)
    }

    func sendComposerMessage() async {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if !aiSetupReady {
            errorText = "AI setup is required before running tasks."
            setupSheetPresented = true
            return
        }

        guard let projectID = project?.id else {
            errorText = "Open a project first"
            return
        }

        isSending = true
        defer { isSending = false }

        if selectedConversationID == nil {
            await createConversation()
        }

        guard let conversationID = selectedConversationID else {
            errorText = "No active conversation"
            return
        }

        let mentionParts = buildMentionParts(from: content)
        resetRunFeedback(clearEvents: true)
        runThinkingText = "Thinking and planning..."
        runPlanningText = "Waiting for planner..."
        appendRunFeedbackEvent(type: "status", title: "Prompt sent", detail: "Starting run...")
        let optimisticID = "local-\(UUID().uuidString)"
        let optimisticMessage = Message(
            id: optimisticID,
            projectId: projectID,
            conversationId: conversationID,
            role: "user",
            content: content,
            parentMessageId: nil,
            sequenceNo: (messages.last?.sequenceNo ?? 0) + 1,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
        messages.append(optimisticMessage)

        do {
            composerText = ""
            refreshMentionState()
            let status = try await client.sendMessage(
                projectID: projectID,
                conversationID: conversationID,
                content: content,
                parts: mentionParts,
                startRun: true,
                mode: "manual"
            )

            await loadMessages(conversationID: conversationID)

            if let runID = status.runId {
                await pollRun(projectID: projectID, conversationID: conversationID, runID: runID)
            }
            await refreshConversations()
            errorText = nil
        } catch {
            messages.removeAll { $0.id == optimisticID }
            composerText = content
            refreshMentionState()
            errorText = "Could not send message: \(error.localizedDescription)"
        }
    }

    private func pollRun(projectID: String, conversationID: String, runID: String) async {
        runPollTask?.cancel()
        stopRunEventStream()
        activeRunID = runID
        lastRunEventID = 0
        runInProgress = true
        runStatusText = "Running..."
        startRunEventStream(projectID: projectID, conversationID: conversationID, runID: runID)

        runPollTask = Task {
            defer {
                Task { @MainActor in
                    self.runInProgress = false
                    self.stopRunEventStream()
                    self.activeRunID = nil
                }
            }

            for _ in 0 ..< 180 {
                if Task.isCancelled { return }

                do {
                    let run = try await self.client.run(projectID: projectID, runID: runID)
                    await MainActor.run {
                        self.runStatusText = "Run \(run.status)"
                        self.updateRunFeedback(run: run)
                    }

                    if ["done", "failed", "cancelled"].contains(run.status.lowercased()) {
                        await MainActor.run {
                            self.runStatusText = run.status.uppercased() + (run.error.map { ": \($0)" } ?? "")
                        }
                        if self.selectedConversationID == conversationID {
                            await self.loadMessages(conversationID: conversationID)
                        }
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.runThinkingText = nil
                        self.runPlanningText = "Run polling failed."
                        self.appendRunFeedbackEvent(type: "error", title: "Run polling failed", detail: error.localizedDescription)
                        self.errorText = "Run polling failed: \(error.localizedDescription)"
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(600))
            }

            await MainActor.run {
                self.runStatusText = "Run timed out"
                self.runThinkingText = nil
                self.runPlanningText = "Run timed out."
                self.appendRunFeedbackEvent(type: "error", title: "Run timed out", detail: nil)
            }
        }
    }
}

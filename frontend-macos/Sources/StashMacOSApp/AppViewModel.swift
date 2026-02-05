import AppKit
import Foundation

@MainActor
final class AppViewModel: ObservableObject {
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
    @Published var runTodos: [RunTodo] = []
    @Published var mentionSuggestions: [FileItem] = []
    @Published var mentionedFilePaths: [String] = []
    @Published var setupStatus: RuntimeSetupStatus?
    @Published var runtimeConfig: RuntimeConfigPayload?
    @Published var setupSheetPresented = false
    @Published var setupSaving = false
    @Published var setupPlannerBackend = "auto"
    @Published var setupCodexMode = "cli"
    @Published var setupCodexBin = "codex"
    @Published var setupCodexPlannerModel = "gpt-5-mini"
    @Published var setupPlannerCmd = ""
    @Published var setupPlannerTimeoutSeconds = "150"
    @Published var setupOpenAIAPIKey = ""
    @Published var setupOpenAIModel = "gpt-5-mini"
    @Published var setupOpenAIBaseURL = "https://api.openai.com/v1"
    @Published var setupOpenAITimeoutSeconds = "60"
    @Published var setupStatusText: String?
    @Published var onboardingActive = false

    @Published var errorText: String?

    private var runPollTask: Task<Void, Never>?
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
    private let defaults = UserDefaults.standard
    private let lastProjectPathKey = "stash.lastProjectPath"
    private let onboardingCompletedKey = "stash.onboardingCompletedV1"
    private var client: BackendClient

    init() {
        client = BackendClient(baseURL: URL(string: "http://127.0.0.1:8765")!)
    }

    deinit {
        runPollTask?.cancel()
        filePollTask?.cancel()
        indexStatusClearTask?.cancel()
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

        if let lastPath = defaults.string(forKey: lastProjectPathKey),
           FileManager.default.fileExists(atPath: lastPath)
        {
            await openProject(url: URL(fileURLWithPath: lastPath))
            return
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
            setupCodexBin = config.codexBin
            setupCodexPlannerModel = config.codexPlannerModel
            setupPlannerCmd = config.plannerCmd ?? ""
            setupPlannerTimeoutSeconds = String(config.plannerTimeoutSeconds)
            setupOpenAIModel = config.openaiModel
            setupOpenAIBaseURL = config.openaiBaseUrl
            setupOpenAITimeoutSeconds = String(config.openaiTimeoutSeconds)
            if onboardingActive {
                setupStatusText = status.plannerReady
                    ? "AI setup is ready. Select a project folder, then finish onboarding."
                    : "Complete setup to continue onboarding."
            } else {
                setupStatusText = status.plannerReady ? "AI setup is ready." : "Complete setup to run AI tasks."
            }
        } catch {
            setupStatusText = "Could not load setup status: \(error.localizedDescription)"
        }
    }

    func saveRuntimeSetup() async {
        guard backendConnected else {
            setupStatusText = "Backend is offline."
            return
        }
        setupSaving = true
        defer { setupSaving = false }

        let plannerCmdTrimmed = setupPlannerCmd.trimmingCharacters(in: .whitespacesAndNewlines)
        let openAIKeyTrimmed = setupOpenAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let plannerTimeout = Int(setupPlannerTimeoutSeconds) ?? 150
        let openAITimeout = Int(setupOpenAITimeoutSeconds) ?? 60

        do {
            _ = try await client.updateRuntimeConfig(
                plannerBackend: setupPlannerBackend,
                codexMode: setupCodexMode,
                codexBin: setupCodexBin,
                codexPlannerModel: setupCodexPlannerModel,
                plannerCmd: plannerCmdTrimmed.isEmpty ? nil : plannerCmdTrimmed,
                clearPlannerCmd: plannerCmdTrimmed.isEmpty,
                plannerTimeoutSeconds: plannerTimeout,
                openaiAPIKey: openAIKeyTrimmed.isEmpty ? nil : openAIKeyTrimmed,
                clearOpenAIAPIKey: false,
                openaiModel: setupOpenAIModel,
                openaiBaseURL: setupOpenAIBaseURL,
                openaiTimeoutSeconds: openAITimeout
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
            setupStatusText = "Could not save setup: \(error.localizedDescription)"
        }
    }

    func presentProjectPicker() {
        guard !isPresentingProjectPicker else { return }
        isPresentingProjectPicker = true
        defer { isPresentingProjectPicker = false }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a project folder for Stash"

        if panel.runModal() == .OK, let url = panel.url {
            Task { await openProject(url: url) }
        } else if project == nil {
            errorText = "No project selected. Pick a folder to start using Stash."
        }
    }

    func openProject(url: URL) async {
        do {
            let opened = try await client.createOrOpenProject(name: url.lastPathComponent, rootPath: url.path)
            project = opened
            projectRootURL = url
            runThinkingText = nil
            runPlanningText = nil
            runTodos = []
            defaults.set(url.path, forKey: lastProjectPathKey)

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
            errorText = "Could not open project: \(error.localizedDescription)"
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
        selectedConversationID = id
        await loadMessages(conversationID: id)
    }

    func loadMessages(conversationID: String) async {
        guard let projectID = project?.id else { return }
        do {
            let loaded = try await client.listMessages(projectID: projectID, conversationID: conversationID)
            messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
            errorText = nil
        } catch BackendError.requestTimedOut {
            errorText = "Could not load messages in time. Retrying..."
            do {
                let loaded = try await client.listMessages(projectID: projectID, conversationID: conversationID)
                messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
                errorText = nil
            } catch {
                errorText = "Could not load messages: \(error.localizedDescription)"
            }
        } catch {
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
        if run.status.lowercased() == "running" {
            runThinkingText = "Thinking and planning..."
        } else if ["done", "failed", "cancelled"].contains(run.status.lowercased()) {
            runThinkingText = nil
        }

        if steps.isEmpty {
            runPlanningText = run.status.lowercased() == "running" ? "Planning next actions..." : nil
            runTodos = []
            return
        }

        runPlanningText = "Planned \(steps.count) step(s)"
        runTodos = steps.map { step in
            let command = step.input["cmd"]?.stringValue ?? step.stepType
            return RunTodo(id: step.id, title: command, status: step.status)
        }
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
        runThinkingText = "Thinking and planning..."
        runPlanningText = "Planning next actions..."
        runTodos = []
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
        runInProgress = true
        runStatusText = "Running..."

        runPollTask = Task {
            defer {
                Task { @MainActor in
                    self.runInProgress = false
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
                        await self.loadMessages(conversationID: conversationID)
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.runThinkingText = nil
                        self.runPlanningText = nil
                        self.runTodos = []
                        self.errorText = "Run polling failed: \(error.localizedDescription)"
                    }
                    return
                }

                try? await Task.sleep(for: .milliseconds(600))
            }

            await MainActor.run {
                self.runStatusText = "Run timed out"
                self.runThinkingText = nil
            }
        }
    }
}

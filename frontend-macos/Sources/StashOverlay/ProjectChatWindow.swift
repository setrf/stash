import AppKit
import SwiftUI

@MainActor
final class ProjectChatViewModel: ObservableObject {
    @Published var project: OverlayProject
    @Published var conversations: [OverlayConversation] = []
    @Published var selectedConversationID: String?
    @Published var messages: [OverlayMessage] = []
    @Published var composerText = ""
    @Published var isSending = false
    @Published var runStatusText: String?
    @Published var runInProgress = false
    @Published var errorText: String?

    private let backendClient: BackendClient
    private var runPollTask: Task<Void, Never>?

    init(project: OverlayProject, backendClient: BackendClient) {
        self.project = project
        self.backendClient = backendClient
    }

    deinit {
        runPollTask?.cancel()
    }

    var selectedConversation: OverlayConversation? {
        conversations.first { $0.id == selectedConversationID }
    }

    func bootstrap() async {
        await refreshConversations()
    }

    func refreshConversations() async {
        do {
            let loaded = try await backendClient.listConversations(projectID: project.id)
            if loaded.isEmpty {
                let general = try await backendClient.createConversation(projectID: project.id, title: "General")
                conversations = [general]
                selectedConversationID = general.id
                await loadMessages(conversationID: general.id)
                return
            }

            conversations = loaded.sorted(by: sortConversations(lhs:rhs:))
            let activeConversationID = selectedConversationID ?? project.activeConversationId
            if let activeConversationID,
               conversations.contains(where: { $0.id == activeConversationID })
            {
                selectedConversationID = activeConversationID
            } else {
                selectedConversationID = conversations.first?.id
            }

            if let selectedConversationID {
                await loadMessages(conversationID: selectedConversationID)
            } else {
                messages = []
            }

            errorText = nil
        } catch {
            errorText = "Could not load conversations: \(error.localizedDescription)"
        }
    }

    func createConversation() async {
        let title = "Session \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
        do {
            let created = try await backendClient.createConversation(projectID: project.id, title: title)
            conversations.insert(created, at: 0)
            selectedConversationID = created.id
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
        do {
            let loaded = try await backendClient.listMessages(projectID: project.id, conversationID: conversationID)
            messages = loaded.sorted { $0.sequenceNo < $1.sequenceNo }
            errorText = nil
        } catch {
            errorText = "Could not load messages: \(error.localizedDescription)"
        }
    }

    func sendComposerMessage() async {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if selectedConversationID == nil {
            await createConversation()
        }

        guard let conversationID = selectedConversationID else {
            errorText = "No active conversation"
            return
        }

        isSending = true
        defer { isSending = false }

        do {
            composerText = ""
            let status = try await backendClient.sendMessage(projectID: project.id, conversationID: conversationID, content: content)
            await loadMessages(conversationID: conversationID)
            await refreshConversations()

            if let runID = status.runId {
                startRunPolling(conversationID: conversationID, runID: runID)
            } else {
                runStatusText = nil
            }
            errorText = nil
        } catch {
            errorText = "Could not send message: \(error.localizedDescription)"
        }
    }

    private func startRunPolling(conversationID: String, runID: String) {
        runPollTask?.cancel()
        runInProgress = true
        runStatusText = "Running..."

        runPollTask = Task { [weak self] in
            await self?.pollRunLoop(conversationID: conversationID, runID: runID)
        }
    }

    private func pollRunLoop(conversationID: String, runID: String) async {
        defer {
            runInProgress = false
        }

        for _ in 0 ..< 180 {
            if Task.isCancelled { return }

            do {
                let run = try await backendClient.run(projectID: project.id, runID: runID)
                runStatusText = "Run \(run.status)"

                if ["done", "failed", "cancelled"].contains(run.status.lowercased()) {
                    runStatusText = run.status.uppercased() + (run.error.map { ": \($0)" } ?? "")
                    await loadMessages(conversationID: conversationID)
                    return
                }
            } catch {
                errorText = "Run polling failed: \(error.localizedDescription)"
                return
            }

            try? await Task.sleep(for: .milliseconds(600))
        }

        runStatusText = "Run timed out"
    }

    private func sortConversations(lhs: OverlayConversation, rhs: OverlayConversation) -> Bool {
        let lhsDate = lhs.lastMessageAt ?? lhs.createdAt
        let rhsDate = rhs.lastMessageAt ?? rhs.createdAt
        if lhsDate == rhsDate {
            return lhs.createdAt > rhs.createdAt
        }
        return lhsDate > rhsDate
    }
}

struct ProjectChatRootView: View {
    @StateObject private var viewModel: ProjectChatViewModel

    init(viewModel: ProjectChatViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            if viewModel.messages.isEmpty {
                VStack(spacing: 8) {
                    Text("Start a conversation for \(viewModel.project.name)")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Backend context for this project will be used automatically.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProjectMessageTimeline(messages: viewModel.messages)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            Divider()

            composer
                .padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            await viewModel.bootstrap()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.project.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(viewModel.project.rootPath)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if let runStatusText = viewModel.runStatusText {
                Text(runStatusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(viewModel.runInProgress ? .accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    )
            }

            Menu {
                ForEach(viewModel.conversations) { conversation in
                    Button(conversation.title) {
                        Task { await viewModel.selectConversation(id: conversation.id) }
                    }
                }
                Divider()
                Button("New Chat") {
                    Task { await viewModel.createConversation() }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.selectedConversation?.title ?? "Conversation")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            TextEditor(text: $viewModel.composerText)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .frame(minHeight: 88, maxHeight: 150)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            HStack {
                Text(viewModel.runInProgress ? "Running..." : "Ready")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(viewModel.runInProgress ? .accentColor : .secondary)

                Spacer()

                Button("Run") {
                    Task { await viewModel.sendComposerMessage() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSending)
            }
        }
    }
}

private struct ProjectMessageTimeline: View {
    let messages: [OverlayMessage]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        ProjectMessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: messages.count) { _ in
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct ProjectMessageRow: View {
    let message: OverlayMessage

    private var isUser: Bool {
        message.role.lowercased() == "user"
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 80) }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(message.role.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(message.createdAt)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text(message.content)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: 860, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isUser ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )

            if !isUser { Spacer(minLength: 80) }
        }
    }
}

final class ProjectChatWindowController: NSWindowController, NSWindowDelegate {
    let projectID: String
    var onWindowClosed: ((String) -> Void)?

    init(project: OverlayProject, backendClient: BackendClient) {
        projectID = project.id

        let rootView = ProjectChatRootView(
            viewModel: ProjectChatViewModel(project: project, backendClient: backendClient)
        )
        let hostingController = NSHostingController(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash Chat - \(project.name)"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?(projectID)
    }
}

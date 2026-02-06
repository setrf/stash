import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @StateObject private var viewModel: AppViewModel

    public init(initialProjectRootPath: String? = nil, initialBackendURL: URL? = nil) {
        if let initialProjectRootPath {
            _viewModel = StateObject(
                wrappedValue: AppViewModel(
                    initialProjectRootURL: URL(fileURLWithPath: initialProjectRootPath, isDirectory: true),
                    initialBackendURL: initialBackendURL
                )
            )
        } else {
            _viewModel = StateObject(wrappedValue: AppViewModel(initialBackendURL: initialBackendURL))
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceTopBar(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(CodexTheme.panel)

            Divider()

            if viewModel.project == nil {
                EmptyProjectView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CodexTheme.canvas)
            } else {
                HStack(spacing: 0) {
                    ExplorerPanel(viewModel: viewModel)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                        .background(CodexTheme.panel)

                    Divider()

                    WorkspacePanel(viewModel: viewModel)
                        .frame(minWidth: 420, idealWidth: 640, maxWidth: .infinity)
                        .background(CodexTheme.canvas)

                    Divider()

                    ChatPanel(viewModel: viewModel)
                        .frame(minWidth: 360, idealWidth: 430, maxWidth: 520, maxHeight: .infinity)
                        .background(CodexTheme.canvas)
                }
            }

            Divider()

            WorkspaceUtilityBar(viewModel: viewModel)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(CodexTheme.panel)
        }
        .background(CodexTheme.canvas)
        .task {
            await viewModel.bootstrap()
        }
        .sheet(isPresented: $viewModel.setupSheetPresented) {
            RuntimeSetupSheet(viewModel: viewModel)
                .interactiveDismissDisabled(false)
        }
    }
}

private struct WorkspaceTopBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 10) {
            Text("Stash")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            if let projectName = viewModel.project?.name, !projectName.isEmpty {
                Text(projectName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.white)
                    )
                    .overlay(
                        Capsule()
                            .stroke(CodexTheme.border, lineWidth: 1)
                    )
            }

            Spacer()

            Button {
                viewModel.openSetupSheet()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(CodexTheme.border, lineWidth: 1)
            )
            .help("AI setup")
        }
    }
}

private struct WorkspaceUtilityBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            utilityPill(
                icon: viewModel.backendConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                text: viewModel.backendConnected ? "Backend" : "Backend Offline",
                color: viewModel.backendConnected ? CodexTheme.success : CodexTheme.warning
            )

            utilityPill(
                icon: viewModel.aiSetupReady ? "sparkles" : "sparkles.slash",
                text: viewModel.aiSetupReady ? "AI Ready" : "AI Setup",
                color: viewModel.aiSetupReady ? CodexTheme.success : CodexTheme.warning
            )

            if let indexingStatusText = viewModel.indexingStatusText {
                utilityPill(icon: "arrow.triangle.2.circlepath", text: indexingStatusText, color: CodexTheme.accent)
            }

            if let runStatusText = viewModel.runStatusText {
                utilityPill(
                    icon: viewModel.runInProgress ? "play.circle.fill" : "checkmark.circle",
                    text: runStatusText,
                    color: viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary
                )
            }

            Spacer()

            Text("⌘↩ Send")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)
        }
    }

    private func utilityPill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color.white)
        )
        .overlay(
            Capsule()
                .stroke(CodexTheme.border.opacity(0.85), lineWidth: 1)
        )
    }
}

private struct EmptyProjectView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 14) {
            Text("Choose a project folder to start")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            Text("Stash will automatically index the folder when you open it.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            Button("Pick Folder") {
                viewModel.presentProjectPicker()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Open AI Setup") {
                viewModel.openSetupSheet()
            }
            .buttonStyle(.bordered)

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.danger)
                    .padding(.top, 6)
            }
        }
        .padding(32)
    }
}

private struct FilesPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var rootDropIsTargeted = false
    @State private var rowDropTargetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Folder Structure")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            TextField("Filter files", text: $viewModel.fileQuery)
                .textFieldStyle(.roundedBorder)

            List(viewModel.filteredFiles) { item in
                let targetDirectory = dropTargetDirectory(for: item)
                fileRow(item: item)
                .help(item.relativePath)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowDropTargetID == item.id ? CodexTheme.accent.opacity(0.16) : Color.clear)
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
                .onDrop(
                    of: [UTType.fileURL, UTType.folder],
                    isTargeted: Binding(
                        get: { rowDropTargetID == item.id },
                        set: { targeted in
                            if targeted {
                                rowDropTargetID = item.id
                            } else if rowDropTargetID == item.id {
                                rowDropTargetID = nil
                            }
                        }
                    )
                ) { providers in
                    viewModel.handleFileDrop(providers: providers, toRelativeDirectory: targetDirectory)
                }
                .onTapGesture(count: 2) {
                    viewModel.openFileItemInOS(item)
                }
            }
            .listStyle(.inset)
            .onDrop(of: [UTType.fileURL, UTType.folder], isTargeted: $rootDropIsTargeted) { providers in
                viewModel.handleFileDrop(providers: providers, toRelativeDirectory: nil)
            }
            .overlay(alignment: .bottomLeading) {
                if rootDropIsTargeted {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill")
                        Text("Drop to import into project root")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.95))
                    )
                    .overlay(
                        Capsule().stroke(CodexTheme.accent.opacity(0.5), lineWidth: 1)
                    )
                    .padding(8)
                }
            }
        }
        .padding(14)
    }

    private func fileRow(item: FileItem) -> some View {
        HStack(spacing: 8) {
            if item.isDirectory {
                Button {
                    viewModel.toggleDirectoryExpanded(item)
                } label: {
                    Image(systemName: viewModel.isDirectoryExpanded(item) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 12, alignment: .center)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 12, height: 12)
            }
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(item.isDirectory ? CodexTheme.accent : CodexTheme.textSecondary)
            Text(item.name)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
        }
        .padding(.leading, CGFloat(item.depth) * 14)
    }

    private func dropTargetDirectory(for item: FileItem) -> String {
        if item.isDirectory {
            return item.relativePath
        }
        let parts = item.relativePath.split(separator: "/")
        if parts.count <= 1 {
            return ""
        }
        return parts.dropLast().joined(separator: "/")
    }
}

private struct ChatPanel: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)

                Spacer()

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
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CodexTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CodexTheme.border, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(CodexTheme.panel)

            Divider()

            if viewModel.visibleMessages.isEmpty {
                VStack(spacing: 10) {
                    Text("Ask Stash to work on your files")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text("Type what you want done and run it.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageTimeline(
                    messages: viewModel.visibleMessages,
                    onOpenTaggedFile: { path in
                        viewModel.openTaggedOutputPathInOS(path)
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if viewModel.runInProgress ||
                viewModel.runThinkingText != nil ||
                viewModel.runPlanningText != nil ||
                viewModel.runPlannerPreview != nil ||
                !viewModel.runTodos.isEmpty ||
                !viewModel.runFeedbackEvents.isEmpty
            {
                RunFeedbackCard(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if viewModel.hasPendingRunConfirmation {
                PendingRunChangesCard(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if !viewModel.aiSetupReady {
                SetupRequiredCard(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
            }

            Divider()

            VStack(spacing: 10) {
                if !viewModel.mentionedFilePaths.isEmpty {
                    MentionedFilesStrip(paths: viewModel.mentionedFilePaths)
                }

                if !viewModel.mentionSuggestions.isEmpty {
                    MentionSuggestionsList(viewModel: viewModel)
                }

                TextEditor(text: $viewModel.composerText)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .frame(minHeight: 96, maxHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(CodexTheme.border, lineWidth: 1))
                    .onChange(of: viewModel.composerText) {
                        viewModel.composerDidChange()
                    }

                HStack {
                    Text(viewModel.runInProgress ? "Running..." : "Ready")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary)
                    Text("⌘↩ Send")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Spacer()
                    Button("Send") {
                        Task { await viewModel.sendComposerMessage() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("Send message (⌘↩)")
                    .disabled(viewModel.isSending || viewModel.project == nil || !viewModel.aiSetupReady)
                }
            }
            .padding(18)
            .background(CodexTheme.panel)
        }
    }
}

private struct RunFeedbackCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var reasoningExpanded = true
    @State private var todosExpanded = true
    @State private var feedExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Run")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                if let runStatusText = viewModel.runStatusText {
                    Text(runStatusText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
            }

            if viewModel.runThinkingText != nil || viewModel.runPlanningText != nil || viewModel.runPlannerPreview != nil {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let runThinkingText = viewModel.runThinkingText {
                            HStack(spacing: 8) {
                                if viewModel.runInProgress {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(CodexTheme.accent)
                                }
                                Text(runThinkingText)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(CodexTheme.textPrimary)
                            }
                        }

                        if let runPlanningText = viewModel.runPlanningText {
                            Text(runPlanningText)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(CodexTheme.textSecondary)
                        }

                        if let preview = viewModel.runPlannerPreview, !preview.isEmpty {
                            ScrollView {
                                Text(preview)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(CodexTheme.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(maxHeight: 160)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(CodexTheme.canvas.opacity(0.8))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(CodexTheme.border.opacity(0.8), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    sectionHeader(title: "Thinking & Planning", count: nil)
                }
            }

            if !viewModel.runTodos.isEmpty {
                DisclosureGroup(isExpanded: $todosExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.runTodos) { todo in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: todoIcon(for: todo.status))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(todoColor(for: todo.status))
                                Text(todo.title)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(CodexTheme.textPrimary)
                                    .lineLimit(2)
                                    .strikethrough(todo.status.lowercased() == "completed", color: CodexTheme.textSecondary)
                            }
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    sectionHeader(title: "Todos", count: viewModel.runTodos.count)
                }
            }

            if !viewModel.runFeedbackEvents.isEmpty {
                DisclosureGroup(isExpanded: $feedExpanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.runFeedbackEvents) { event in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: eventIcon(for: event.type))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(eventColor(for: event.type))
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(event.timestamp)
                                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                                .foregroundStyle(CodexTheme.textSecondary)
                                            Text(event.title)
                                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .foregroundStyle(CodexTheme.textPrimary)
                                        }
                                        if let detail = event.detail, !detail.isEmpty {
                                            Text(detail)
                                                .font(.system(size: 11, weight: .regular, design: .rounded))
                                                .foregroundStyle(CodexTheme.textSecondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                    .padding(.top, 6)
                } label: {
                    sectionHeader(title: "Live Feed", count: viewModel.runFeedbackEvents.count)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
        )
    }

    private func sectionHeader(title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(CodexTheme.canvas)
                    )
            }
        }
    }

    private func todoIcon(for status: String) -> String {
        switch status.lowercased() {
        case "completed":
            return "checkmark.circle.fill"
        case "running":
            return "clock.fill"
        case "failed":
            return "xmark.circle.fill"
        default:
            return "circle"
        }
    }

    private func todoColor(for status: String) -> Color {
        switch status.lowercased() {
        case "completed":
            return CodexTheme.success
        case "running":
            return CodexTheme.accent
        case "failed":
            return CodexTheme.danger
        default:
            return CodexTheme.textSecondary
        }
    }

    private func eventIcon(for type: String) -> String {
        switch type.lowercased() {
        case "planning":
            return "brain.head.profile"
        case "execution":
            return "terminal"
        case "error":
            return "xmark.octagon.fill"
        default:
            return "waveform.path.ecg"
        }
    }

    private func eventColor(for type: String) -> Color {
        switch type.lowercased() {
        case "planning":
            return CodexTheme.accent
        case "execution":
            return CodexTheme.textPrimary
        case "error":
            return CodexTheme.danger
        default:
            return CodexTheme.textSecondary
        }
    }
}

private struct PendingRunChangesCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pending Changes")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
                Spacer()
                if let outcome = viewModel.pendingRunOutcomeKind, !outcome.isEmpty {
                    Text(outcome.replacingOccurrences(of: "_", with: " "))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(viewModel.pendingRunChanges.prefix(8))) { change in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: change.type))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(color(for: change.type))
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(for: change))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(CodexTheme.textPrimary)
                            if let summary = change.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(.system(size: 11, weight: .regular, design: .rounded))
                                    .foregroundStyle(CodexTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Discard") {
                    Task { await viewModel.discardPendingRunChanges() }
                }
                .buttonStyle(.bordered)

                Button("Apply") {
                    Task { await viewModel.applyPendingRunChanges() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
        )
    }

    private func icon(for type: String) -> String {
        switch type.lowercased() {
        case "edit_file":
            return "pencil"
        case "output_file":
            return "doc.badge.plus"
        case "delete_file":
            return "trash"
        case "rename_file":
            return "arrow.left.arrow.right"
        default:
            return "doc"
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "delete_file":
            return CodexTheme.danger
        case "output_file":
            return CodexTheme.accent
        default:
            return CodexTheme.textSecondary
        }
    }

    private func label(for change: MessagePart) -> String {
        switch change.type.lowercased() {
        case "rename_file":
            if let fromPath = change.fromPath, let path = change.path {
                return "\(fromPath) -> \(path)"
            }
        default:
            break
        }
        return change.path ?? change.fromPath ?? change.type
    }
}

private struct SetupRequiredCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Setup Needed")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            Text("Stash keeps setup minimal. Usually you only need Codex CLI logged in.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            if let blockers = viewModel.setupStatus?.blockers, !blockers.isEmpty {
                ForEach(blockers, id: \.self) { blocker in
                    Text("• \(blocker)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.warning)
                }
            }

            Button("Open AI Setup") {
                viewModel.openSetupSheet()
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
        )
    }
}

private struct RuntimeSetupSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var attemptedAutoSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.onboardingActive ? "Quick Start" : "AI Setup")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            Text(viewModel.onboardingActive
                ? "Only two things are needed: AI ready and a project folder."
                : "Only essential setup is shown.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)

                OnboardingRow(title: "Backend connected", done: viewModel.backendConnected)
                OnboardingRow(title: "AI runtime ready", done: viewModel.aiSetupReady)
                OnboardingRow(title: "Project folder selected", done: viewModel.project != nil)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
            )

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Codex model")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)

                    Picker("Model", selection: $viewModel.setupCodexPlannerModel) {
                        ForEach(viewModel.codexModelPresets) { preset in
                            Text("\(preset.label) • \(preset.hint)")
                                .tag(preset.value)
                        }
                    }
                    .pickerStyle(.menu)

                    if let resolved = viewModel.setupStatus?.codexBinResolved, !resolved.isEmpty {
                        Text("Codex binary: \(resolved)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(CodexTheme.textSecondary)
                    }

                    if viewModel.setupStatus?.needsOpenaiKey == true {
                        SecureField("OpenAI API key (only if Codex is unavailable)", text: $viewModel.setupOpenAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced settings")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
            )

            if let setupStatus = viewModel.setupStatus {
                HStack(spacing: 10) {
                    Text(setupStatus.plannerReady ? "Ready" : "Not ready")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(setupStatus.plannerReady ? CodexTheme.success : CodexTheme.warning)
                    Text(setupStatus.detail ?? "")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .lineLimit(2)
                }
            }

            if let required = viewModel.setupStatus?.requiredBlockers, !required.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Required fixes:")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CodexTheme.warning)
                    ForEach(required, id: \.self) { item in
                        Text("• \(item)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(CodexTheme.warning)
                    }
                }
            }

            if let setupStatusText = viewModel.setupStatusText {
                Text(setupStatusText)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)
            }

            HStack {
                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                if viewModel.onboardingActive {
                    Button("Choose Folder") {
                        viewModel.presentProjectPicker()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Refresh Checks") {
                    Task { await viewModel.refreshRuntimeSetup() }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Fix Automatically") {
                    Task {
                        await viewModel.saveRuntimeSetup()
                        if !viewModel.onboardingActive, viewModel.aiSetupReady {
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.setupSaving)

                if viewModel.onboardingActive {
                    Button("Continue") {
                        viewModel.finishOnboarding()
                        if !viewModel.onboardingActive {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.onboardingReadyToFinish)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 460)
        .task {
            await viewModel.refreshRuntimeSetup()
            if viewModel.onboardingActive, !viewModel.aiSetupReady, !attemptedAutoSetup {
                attemptedAutoSetup = true
                await viewModel.saveRuntimeSetup()
            }
        }
    }
}

private struct OnboardingRow: View {
    let title: String
    let done: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? CodexTheme.success : CodexTheme.textSecondary)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
            Spacer()
        }
    }
}

private struct MentionedFilesStrip: View {
    let paths: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(paths, id: \.self) { path in
                    Text("@\(path)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CodexTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(CodexTheme.accent.opacity(0.12))
                        )
                        .overlay(
                            Capsule().stroke(CodexTheme.accent.opacity(0.35), lineWidth: 1)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MentionSuggestionsList: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mention a file")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            ForEach(viewModel.mentionSuggestions.prefix(6)) { suggestion in
                Button {
                    viewModel.applyMentionSuggestion(suggestion)
                } label: {
                    HStack {
                        Image(systemName: "at")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CodexTheme.accent)
                        Text(suggestion.relativePath)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(CodexTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CodexTheme.border.opacity(0.8), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageTimeline: View {
    let messages: [Message]
    let onOpenTaggedFile: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageRow(message: message, onOpenTaggedFile: onOpenTaggedFile)
                            .id(message.id)
                    }
                }
                .padding(18)
            }
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message
    let onOpenTaggedFile: (String) -> Void

    private var isUser: Bool {
        message.role.lowercased() == "user"
    }

    private var roleLabel: String {
        isUser ? "YOU" : "STASH"
    }

    private var renderedContent: String {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isUser else { return content }

        let noFileTags = stripStashFileTags(from: content)
        let sanitized = stripCodexCommandBlocks(from: noFileTags)
        if !sanitized.isEmpty {
            if let summaryRange = sanitized.range(of: "Execution summary:") {
                let beforeSummary = String(sanitized[..<summaryRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return content
    }

    private var taggedOutputFiles: [String] {
        guard !isUser else { return [] }
        return extractStashFileTags(from: message.content)
    }

    private var structuredOutputFiles: [String] {
        guard !isUser else { return [] }
        var ordered: [String] = []
        var seen = Set<String>()
        for part in message.parts where part.type.lowercased() == "output_file" {
            guard let path = part.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { continue }
            let lowered = path.lowercased()
            if seen.contains(lowered) { continue }
            seen.insert(lowered)
            ordered.append(path)
        }
        return ordered
    }

    private var changedFileParts: [MessagePart] {
        guard !isUser else { return [] }
        return message.parts.filter { part in
            let type = part.type.lowercased()
            return type == "edit_file" || type == "delete_file" || type == "rename_file"
        }
    }

    private var allOutputFiles: [String] {
        var ordered: [String] = []
        var seen = Set<String>()
        for path in structuredOutputFiles + taggedOutputFiles {
            let lowered = path.lowercased()
            if seen.contains(lowered) { continue }
            seen.insert(lowered)
            ordered.append(path)
        }
        return ordered
    }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(roleLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                    Text(message.createdAt)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                }

                Text(renderedContent)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !changedFileParts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Changed Files")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(CodexTheme.textSecondary)
                        ForEach(changedFileParts) { change in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Image(systemName: icon(for: change.type))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(color(for: change.type))
                                    Text(changeLabel(change))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(CodexTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                if let summary = change.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.system(size: 11, weight: .regular, design: .rounded))
                                        .foregroundStyle(CodexTheme.textSecondary)
                                        .lineLimit(2)
                                }
                                if let diff = change.diff, !diff.isEmpty {
                                    Text(diff)
                                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                                        .foregroundStyle(CodexTheme.textSecondary)
                                        .lineLimit(5)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(CodexTheme.canvas.opacity(0.95))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.top, 2)
                }

                if !allOutputFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output Files")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(CodexTheme.textSecondary)
                        ForEach(allOutputFiles, id: \.self) { path in
                            Button {
                                onOpenTaggedFile(path)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CodexTheme.accent)
                                    Text(path)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(CodexTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("Open")
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundStyle(CodexTheme.accent)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(CodexTheme.canvas.opacity(0.95))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isUser ? CodexTheme.userBubble : CodexTheme.assistantBubble)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(CodexTheme.border.opacity(0.7), lineWidth: 1)
            )
            .frame(maxWidth: 780, alignment: .leading)

            if !isUser { Spacer(minLength: 60) }
        }
    }

    private func icon(for type: String) -> String {
        switch type.lowercased() {
        case "edit_file":
            return "pencil"
        case "delete_file":
            return "trash"
        case "rename_file":
            return "arrow.left.arrow.right"
        default:
            return "doc"
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "delete_file":
            return CodexTheme.danger
        case "edit_file":
            return CodexTheme.accent
        default:
            return CodexTheme.textSecondary
        }
    }

    private func changeLabel(_ change: MessagePart) -> String {
        if change.type.lowercased() == "rename_file",
           let fromPath = change.fromPath,
           let path = change.path
        {
            return "\(fromPath) -> \(path)"
        }
        return change.path ?? change.fromPath ?? change.type
    }

    private func stripCodexCommandBlocks(from text: String) -> String {
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

    private func extractStashFileTags(from text: String) -> [String] {
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

    private func stripStashFileTags(from text: String) -> String {
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

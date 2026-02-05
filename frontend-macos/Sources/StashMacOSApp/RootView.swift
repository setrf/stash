import SwiftUI
import UniformTypeIdentifiers

public struct RootView: View {
    @StateObject private var viewModel: AppViewModel

    public init(initialProjectRootPath: String? = nil) {
        if let initialProjectRootPath {
            _viewModel = StateObject(
                wrappedValue: AppViewModel(
                    initialProjectRootURL: URL(fileURLWithPath: initialProjectRootPath, isDirectory: true)
                )
            )
        } else {
            _viewModel = StateObject(wrappedValue: AppViewModel())
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            MinimalTopBar(viewModel: viewModel)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(CodexTheme.panel)

            Divider()

            if viewModel.project == nil {
                EmptyProjectView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CodexTheme.canvas)
            } else {
                HStack(spacing: 0) {
                    FilesPanel(viewModel: viewModel)
                        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
                        .background(CodexTheme.panel)

                    Divider()

                    ChatPanel(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(CodexTheme.canvas)
                }
            }
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

private struct MinimalTopBar: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            Text("Stash")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            Spacer()

            Button {
                viewModel.presentProjectPicker()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(viewModel.project?.name ?? "Choose Project Folder")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(CodexTheme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                viewModel.openSetupSheet()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text("AI Setup")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(CodexTheme.border, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            StatusBadge(
                text: viewModel.backendConnected ? "Backend Connected" : "Backend Offline",
                color: viewModel.backendConnected ? CodexTheme.success : CodexTheme.warning
            )

            StatusBadge(
                text: viewModel.aiSetupBadgeText,
                color: viewModel.aiSetupReady ? CodexTheme.success : CodexTheme.warning
            )

            if let indexingStatusText = viewModel.indexingStatusText {
                StatusBadge(text: indexingStatusText, color: CodexTheme.accent)
            }

            if let runStatusText = viewModel.runStatusText {
                StatusBadge(text: runStatusText, color: viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary)
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white)
            )
            .overlay(
                Capsule()
                    .stroke(CodexTheme.border.opacity(0.9), lineWidth: 1)
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
                HStack(spacing: 8) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc.text")
                        .foregroundStyle(item.isDirectory ? CodexTheme.accent : CodexTheme.textSecondary)
                    Text(item.name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                        .padding(.leading, CGFloat(item.depth) * 8)
                    Spacer()
                }
                .help(item.relativePath)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(rowDropTargetID == item.id ? CodexTheme.accent.opacity(0.16) : Color.clear)
                )
                .onDrop(
                    of: [UTType.fileURL],
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
            .onDrop(of: [UTType.fileURL], isTargeted: $rootDropIsTargeted) { providers in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.onboardingActive ? "Welcome To Stash" : "AI Runtime Setup")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)

            Text(viewModel.onboardingActive
                ? "Only blocking setup steps are shown here."
                : "Only essential blocking setup is shown here.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            if viewModel.onboardingActive {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Required Checklist")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
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
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Planner: Codex CLI (GPT-5.3 Codex medium default)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)

                Picker("Model", selection: $viewModel.setupCodexPlannerModel) {
                    ForEach(viewModel.codexModelPresets) { preset in
                        Text("\(preset.label) • \(preset.hint)")
                            .tag(preset.value)
                    }
                }
                .pickerStyle(.menu)

                Text("Choose a faster model for lower latency, or keep Default for best compatibility.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)

                if let resolved = viewModel.setupStatus?.codexBinResolved, !resolved.isEmpty {
                    Text("Codex binary: \(resolved)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                }

                if viewModel.setupStatus?.needsOpenaiKey == true {
                    SecureField("OpenAI API key (only required if Codex is unavailable)", text: $viewModel.setupOpenAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
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
                    Button("Choose Project Folder") {
                        viewModel.presentProjectPicker()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Refresh Checks") {
                    Task { await viewModel.refreshRuntimeSetup() }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(viewModel.setupStatus?.needsOpenaiKey == true ? "Save API Key" : "Apply Defaults") {
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
                    Button("Finish Onboarding") {
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
        .frame(minWidth: 620, minHeight: 560)
        .task {
            await viewModel.refreshRuntimeSetup()
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

                if !taggedOutputFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output Files")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(CodexTheme.textSecondary)
                        ForEach(taggedOutputFiles, id: \.self) { path in
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

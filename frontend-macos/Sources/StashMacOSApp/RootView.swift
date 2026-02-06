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
    @State private var runDetailsExpanded = false
    @State private var hideDoneInline = false
    @State private var doneRowGeneration = 0
    @FocusState private var composerFocused: Bool

    private var shouldShowInlineRunRow: Bool {
        switch viewModel.runInlineState {
        case .idle:
            return false
        case .done:
            return !hideDoneInline
        case .running, .awaitingConfirmation, .failed:
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat")
                    .font(.system(size: 15, weight: .semibold))
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
                            .font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(CodexTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius).fill(Color.white))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
                    )
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(CodexTheme.panel)

            Divider()

            if viewModel.visibleMessages.isEmpty {
                VStack(spacing: 14) {
                    VStack(spacing: 10) {
                        Text("Ask Stash to work on your files")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(CodexTheme.textPrimary)
                        Text("Type what you want done and run it.")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                    QuickActionButtonRow(viewModel: viewModel)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageTimeline(
                    messages: viewModel.visibleMessages,
                    onOpenTaggedFile: { path in
                        viewModel.openTaggedOutputPathInPreview(path)
                    }
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if shouldShowInlineRunRow {
                RunInlineStatusRow(
                    viewModel: viewModel,
                    detailsExpanded: $runDetailsExpanded
                )
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if runDetailsExpanded, viewModel.hasRunDetails {
                RunDetailsDrawer(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }

            if !viewModel.aiSetupReady {
                SetupRequiredCard(viewModel: viewModel)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .opacity(0.92)
            }

            if let errorText = viewModel.errorText {
                Text(errorText)
                    .font(.system(size: 11, weight: .medium))
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
                    .font(CodexTheme.chatBodyFont)
                    .frame(minHeight: 96, maxHeight: 140)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: CodexTheme.chatComposerRadius).fill(Color.white))
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.chatComposerRadius)
                            .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
                    )
                    .onChange(of: viewModel.composerText) {
                        viewModel.composerDidChange()
                    }
                    .focused($composerFocused)

                HStack {
                    Text(viewModel.runInProgress ? "Running..." : "Ready")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(viewModel.runInProgress ? CodexTheme.accent : CodexTheme.textSecondary)
                    Text("⌘↩ Send")
                        .font(.system(size: 11, weight: .medium))
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
            .background(CodexTheme.panelSubtle)
        }
        .onChange(of: viewModel.runInlineState) {
            if viewModel.runInlineState == .done {
                hideDoneInline = false
                doneRowGeneration += 1
                let generation = doneRowGeneration
                Task {
                    try? await Task.sleep(nanoseconds: 2_800_000_000)
                    await MainActor.run {
                        if generation == doneRowGeneration, viewModel.runInlineState == .done {
                            hideDoneInline = true
                        }
                    }
                }
            } else {
                hideDoneInline = false
            }

            if viewModel.runInlineState == .idle {
                runDetailsExpanded = false
            }
        }
        .onChange(of: viewModel.composerFocusToken) {
            composerFocused = true
        }
    }
}

private struct QuickActionButtonRow: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.quickActionsForDisplay.prefix(3)) { action in
                Button {
                    viewModel.applyQuickAction(action)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: iconName(for: action.category))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CodexTheme.accent)
                        Text(action.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(CodexTheme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
                    )
                }
                .buttonStyle(.plain)
            }

            if viewModel.quickActionsLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(CodexTheme.accent)
            }
        }
        .frame(maxWidth: 360)
    }

    private func iconName(for category: String) -> String {
        switch category {
        case "legal":
            return "doc.text"
        case "accounting_hr_tax":
            return "tray.full"
        case "markets_finance":
            return "chart.bar"
        case "personal_budget":
            return "creditcard"
        default:
            return "sparkles"
        }
    }
}

private struct RunInlineStatusRow: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var detailsExpanded: Bool

    var body: some View {
        HStack(spacing: 8) {
            leadingStateIndicator

            Text(viewModel.runInlineSummaryText)
                .font(CodexTheme.chatStatusFont)
                .foregroundStyle(summaryColor)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let progressBadge = viewModel.runProgressBadgeText, viewModel.runInlineState == .running {
                Text(progressBadge)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CodexTheme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .fill(CodexTheme.panelSubtle)
                    )
            }

            if viewModel.runInlineState == .awaitingConfirmation {
                Button("Discard") {
                    Task { await viewModel.discardPendingRunChanges() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Accept Changes") {
                    Task { await viewModel.applyPendingRunChanges() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if viewModel.hasRunDetails {
                Button(detailsExpanded ? "Hide Details" : "Details") {
                    detailsExpanded.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
        )
    }

    @ViewBuilder
    private var leadingStateIndicator: some View {
        switch viewModel.runInlineState {
        case .running:
            if viewModel.runInProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(CodexTheme.accent)
            } else {
                Image(systemName: "waveform.path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.accent)
            }
        case .awaitingConfirmation:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.warning)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.danger)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.success)
        case .idle:
            Image(systemName: "circle")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(CodexTheme.textSecondary)
        }
    }

    private var summaryColor: Color {
        switch viewModel.runInlineState {
        case .failed:
            return CodexTheme.danger
        case .awaitingConfirmation:
            return CodexTheme.warning
        case .running:
            return CodexTheme.textPrimary
        case .done, .idle:
            return CodexTheme.textSecondary
        }
    }
}

private struct RunDetailsDrawer: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let milestones = viewModel.runFeedbackEvents.filter {
                let type = $0.type.lowercased()
                return type == "note" || type == "error" || type == "status" || type == "planning"
            }
            if !milestones.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Milestones")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexTheme.textSecondary)
                    ForEach(milestones.suffix(8)) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(event.timestamp)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(CodexTheme.textSecondary)
                                Text(event.title)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(CodexTheme.textPrimary)
                                    .lineLimit(1)
                            }
                            if let detail = event.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(CodexTheme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else {
                Text("No milestones yet.")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(CodexTheme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
        )
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
                LazyVStack(alignment: .leading, spacing: CodexTheme.chatRowSpacing) {
                    ForEach(messages) { message in
                        MessageRow(message: message, onOpenTaggedFile: onOpenTaggedFile)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @State private var showMeta = false

    private var isUser: Bool {
        message.role.lowercased() == "user"
    }

    private var renderedContent: String {
        if isUser {
            return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return message.renderedAssistantContent
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 44) }

            VStack(alignment: .leading, spacing: 6) {
                if showMeta || isUser {
                    HStack(spacing: 6) {
                        Text(isUser ? "You" : "Stash")
                            .font(CodexTheme.chatMetaFont)
                            .foregroundStyle(isUser ? CodexTheme.accent : CodexTheme.textSecondary)
                        Text("•")
                            .font(CodexTheme.chatMetaFont)
                            .foregroundStyle(CodexTheme.textSecondary.opacity(0.65))
                        Text(message.displayRelativeTimestamp ?? message.displayTimestamp)
                            .font(CodexTheme.chatMetaFont)
                            .foregroundStyle(CodexTheme.textSecondary)
                    }
                }

                if !renderedContent.isEmpty {
                    Text(renderedContent)
                        .font(CodexTheme.chatBodyFont)
                        .foregroundStyle(CodexTheme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !message.artifactChips.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], spacing: 6) {
                        ForEach(message.artifactChips) { chip in
                            if chip.isOpenAction, let path = chip.path {
                                Button {
                                    onOpenTaggedFile(path)
                                } label: {
                                    chipLabel(chip, showOpenCallout: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                chipLabel(chip, showOpenCallout: false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, isUser ? 10 : 0)
            .padding(.vertical, isUser ? 8 : 2)
            .background(
                Group {
                    if isUser {
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .fill(CodexTheme.accent.opacity(0.09))
                    } else {
                        Color.clear
                    }
                }
            )
            .overlay(
                Group {
                    if isUser {
                        RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                            .stroke(CodexTheme.accent.opacity(0.25), lineWidth: CodexTheme.chatBorderLineWidth)
                    } else {
                        Color.clear
                    }
                }
            )
            .frame(maxWidth: isUser ? CodexTheme.chatMaxColumnWidth * 0.86 : CodexTheme.chatMaxColumnWidth, alignment: .leading)

            if !isUser { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                showMeta = hovering
            }
        }
    }

    private func chipLabel(_ chip: MessageArtifactChip, showOpenCallout: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: chip.kind.iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(chipTint(chip.kind))
            Text(chip.label)
                .font(CodexTheme.chatChipFont)
                .foregroundStyle(CodexTheme.textPrimary)
                .lineLimit(1)
            if showOpenCallout {
                Spacer(minLength: 4)
                Text("Open")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CodexTheme.accent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CodexTheme.chatInlineRadius)
                .stroke(CodexTheme.borderSoft, lineWidth: CodexTheme.chatBorderLineWidth)
        )
        .help(chip.summary ?? chip.label)
    }

    private func chipTint(_ kind: MessageArtifactChipKind) -> Color {
        switch kind {
        case .output:
            return CodexTheme.accent
        case .delete:
            return CodexTheme.danger
        case .edit:
            return CodexTheme.textPrimary
        case .rename:
            return CodexTheme.textSecondary
        }
    }
}

import SwiftUI

@MainActor
final class ProjectPickerViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var projects: [OverlayProject] = []
    @Published var errorText: String?
    @Published var isCreatingProject = false
    @Published var isCreatingProjectComposerVisible = false
    @Published var newProjectName = ""

    private let client: BackendClient
    private let selectedProjectID: String?
    private let minVisibleRows = 3
    private let maxVisibleRows = 8
    private let rowHeight: CGFloat = 56
    private let popoverWidth: CGFloat = 360
    var onProjectSelected: ((OverlayProject) -> Void)?
    var onPreferredPopoverSizeChange: ((CGSize) -> Void)?

    init(client: BackendClient, selectedProjectID: String?) {
        self.client = client
        self.selectedProjectID = selectedProjectID
    }

    var preferredPopoverSize: CGSize {
        if isLoading {
            return CGSize(width: popoverWidth, height: isCreatingProjectComposerVisible ? 232 : 176)
        }

        if errorText != nil {
            return CGSize(width: popoverWidth, height: isCreatingProjectComposerVisible ? 248 : 196)
        }

        if projects.isEmpty {
            return CGSize(width: popoverWidth, height: isCreatingProjectComposerVisible ? 232 : 176)
        }

        let visibleRows = min(max(projects.count, minVisibleRows), maxVisibleRows)
        let contentHeight = 102 + (CGFloat(visibleRows) * rowHeight) + (isCreatingProjectComposerVisible ? 58 : 0)
        return CGSize(width: popoverWidth, height: contentHeight)
    }

    var listViewportHeight: CGFloat {
        let visibleRows = min(max(projects.count, minVisibleRows), maxVisibleRows)
        return CGFloat(visibleRows) * rowHeight
    }

    func loadProjects() async {
        isLoading = true
        errorText = nil
        suggestPopoverSize()

        do {
            var loaded = try await client.listProjects()
            if loaded.isEmpty {
                let created = try await client.ensureDefaultProject()
                loaded = [created]
            }
            projects = loaded.sorted(by: sortProjects(lhs:rhs:))
        } catch {
            errorText = error.localizedDescription
            projects = []
        }

        isLoading = false
        suggestPopoverSize()
    }

    func selectProject(_ project: OverlayProject) {
        onProjectSelected?(project)
    }

    func beginProjectCreation() {
        errorText = nil
        newProjectName = ""
        isCreatingProjectComposerVisible = true
        suggestPopoverSize()
    }

    func cancelProjectCreation() {
        isCreatingProject = false
        isCreatingProjectComposerVisible = false
        newProjectName = ""
        suggestPopoverSize()
    }

    func createProjectFromComposer() async {
        let trimmedName = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorText = "Enter a project name."
            return
        }

        isCreatingProject = true
        errorText = nil

        do {
            let rootPath = suggestedRootPath(for: trimmedName)
            let project = try await client.createOrOpenProject(name: trimmedName, rootPath: rootPath)
            if let index = projects.firstIndex(where: { $0.id == project.id }) {
                projects[index] = project
            } else {
                projects.append(project)
            }
            projects = projects.sorted(by: sortProjects(lhs:rhs:))
            isCreatingProject = false
            isCreatingProjectComposerVisible = false
            newProjectName = ""
            suggestPopoverSize()
            selectProject(project)
        } catch {
            isCreatingProject = false
            errorText = error.localizedDescription
            suggestPopoverSize()
        }
    }

    func isSelected(_ project: OverlayProject) -> Bool {
        project.id == selectedProjectID
    }

    private func sortProjects(lhs: OverlayProject, rhs: OverlayProject) -> Bool {
        let lhsDate = lhs.lastOpenedAt ?? ""
        let rhsDate = rhs.lastOpenedAt ?? ""
        if lhsDate == rhsDate {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhsDate > rhsDate
    }

    private func suggestPopoverSize() {
        onPreferredPopoverSizeChange?(preferredPopoverSize)
    }

    private func suggestedRootPath(for projectName: String) -> String {
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("StashProjects", isDirectory: true)
        let slug = projectFolderSlug(for: projectName)
        return baseDirectory.appendingPathComponent(slug, isDirectory: true).path
    }

    private func projectFolderSlug(for name: String) -> String {
        let parts = name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "project" : parts.joined(separator: "-")
    }
}

struct ProjectPickerView: View {
    @ObservedObject var viewModel: ProjectPickerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Projects")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)

            content
            footer
        }
        .padding(12)
        .frame(width: viewModel.preferredPopoverSize.width)
        .task {
            await viewModel.loadProjects()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            loadingView
        } else if let errorText = viewModel.errorText {
            errorView(errorText)
        } else if viewModel.projects.isEmpty {
            Text("No projects available.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        } else {
            projectList
        }
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading projects...")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.red)

            Button("Retry") {
                Task { await viewModel.loadProjects() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var projectList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(viewModel.projects) { project in
                    projectButton(project)
                }
            }
        }
        .frame(height: viewModel.listViewportHeight)
    }

    @ViewBuilder
    private var footer: some View {
        if viewModel.isCreatingProjectComposerVisible {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Project name", text: $viewModel.newProjectName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await viewModel.createProjectFromComposer() }
                    }

                HStack {
                    Button("Cancel") {
                        viewModel.cancelProjectCreation()
                    }
                    .disabled(viewModel.isCreatingProject)

                    Spacer()

                    Button("Create") {
                        Task { await viewModel.createProjectFromComposer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isCreatingProject)
                }
            }
        } else {
            HStack {
                Spacer()
                Button {
                    viewModel.beginProjectCreation()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func projectButton(_ project: OverlayProject) -> some View {
        Button {
            viewModel.selectProject(project)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(project.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if viewModel.isSelected(project) {
                        Text("Current")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                }

                Text(project.rootPath)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(viewModel.isSelected(project) ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

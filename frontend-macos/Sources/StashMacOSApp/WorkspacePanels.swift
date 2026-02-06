import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExplorerPanel: View {
    private struct FolderTargetRequest: Identifiable {
        let id = UUID()
        let relativePath: String
    }

    private enum RelocateMode: String {
        case move
        case copy

        var title: String {
            switch self {
            case .move:
                return "Move"
            case .copy:
                return "Copy"
            }
        }
    }

    private struct RelocateRequest: Identifiable {
        let id = UUID()
        let item: FileItem
        let mode: RelocateMode
    }

    @ObservedObject var viewModel: AppViewModel
    @State private var rootDropIsTargeted = false
    @State private var rowDropTargetID: String?

    @State private var createFolderRequest: FolderTargetRequest?
    @State private var createFolderName = ""

    @State private var renameTarget: FileItem?
    @State private var renameText = ""

    @State private var relocateRequest: RelocateRequest?
    @State private var relocateDestination = ""

    @State private var pendingTrashItem: FileItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            projectSwitcherHeader

            HStack(spacing: 8) {
                Text("Explorer")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(CodexTheme.textSecondary)

                Spacer()

                explorerModeSwitch

                Button {
                    createFolderRequest = FolderTargetRequest(
                        relativePath: viewModel.explorerMode == .folders ? viewModel.folderViewPath : ""
                    )
                    createFolderName = ""
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(CodexTheme.border, lineWidth: 1)
                )
                .help("Create folder")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CodexTheme.textSecondary)

                TextField("Filter files", text: $viewModel.fileQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))

                if !viewModel.fileQuery.isEmpty {
                    Button {
                        viewModel.fileQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CodexTheme.textSecondary.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(CodexTheme.border, lineWidth: 1)
            )

            if viewModel.explorerMode == .tree {
                treeView
            } else {
                foldersView
            }
        }
        .padding(14)
        .sheet(item: $renameTarget) { item in
            InputPromptSheet(
                title: "Rename",
                message: "Rename \(item.name)",
                placeholder: "New name",
                actionLabel: "Rename",
                text: $renameText
            ) { value in
                viewModel.renameItem(item, to: value)
                renameTarget = nil
            } onCancel: {
                renameTarget = nil
            }
            .onAppear {
                renameText = item.name
            }
        }
        .sheet(item: $relocateRequest) { request in
            RelocateSheet(
                modeTitle: request.mode.title,
                itemName: request.item.name,
                destination: $relocateDestination,
                directories: [""] + viewModel.projectDirectories.map(\.relativePath)
            ) { destinationPath in
                if request.mode == .move {
                    viewModel.moveItem(request.item, toRelativeDirectory: destinationPath)
                } else {
                    viewModel.copyItem(request.item, toRelativeDirectory: destinationPath)
                }
                relocateRequest = nil
            } onCancel: {
                relocateRequest = nil
            }
            .onAppear {
                relocateDestination = request.item.parentRelativePath
            }
        }
        .sheet(item: $createFolderRequest) { request in
            InputPromptSheet(
                title: "New Folder",
                message: request.relativePath.isEmpty ? "Create in project root" : "Create in \(request.relativePath)",
                placeholder: "Folder name",
                actionLabel: "Create",
                text: $createFolderName
            ) { value in
                viewModel.createFolder(name: value, inRelativeDirectory: request.relativePath)
                createFolderRequest = nil
            } onCancel: {
                createFolderRequest = nil
            }
        }
        .alert("Move to Trash?", isPresented: Binding(
            get: { pendingTrashItem != nil },
            set: { if !$0 { pendingTrashItem = nil } }
        ), presenting: pendingTrashItem) { item in
            Button("Cancel", role: .cancel) {
                pendingTrashItem = nil
            }
            Button("Move to Trash", role: .destructive) {
                viewModel.trashItem(item)
                pendingTrashItem = nil
            }
        } message: { item in
            Text("\(item.name) will be moved to Trash.")
        }
    }

    private var projectSwitcherHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CodexTheme.accent)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(CodexTheme.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.project?.name ?? "No Project")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                        .lineLimit(1)
                    Text(viewModel.projectRootURL?.path ?? "")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(CodexTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                sidebarIconButton(icon: "arrow.left.arrow.right") {
                    viewModel.presentProjectPicker()
                }
                .help("Switch project")

                sidebarIconButton(icon: "plus") {
                    viewModel.presentProjectCreator()
                }
                .help("Create / open project")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }

    private var explorerModeSwitch: some View {
        HStack(spacing: 2) {
            modeSwitchButton(icon: "list.bullet.indent", mode: .tree)
            modeSwitchButton(icon: "square.grid.2x2", mode: .folders)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }

    private func modeSwitchButton(icon: String, mode: ExplorerMode) -> some View {
        let selected = viewModel.explorerMode == mode
        return Button {
            viewModel.setExplorerMode(mode)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? CodexTheme.textPrimary : CodexTheme.textSecondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? CodexTheme.canvas : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func sidebarIconButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CodexTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(CodexTheme.panel)
                )
        }
        .buttonStyle(.plain)
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
    }

    private var treeView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.filteredFiles) { item in
                    let targetDirectory = dropTargetDirectory(for: item)
                    explorerRow(item: item)
                        .help(item.relativePath)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(rowBackgroundColor(for: item))
                        )
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
                        .onDrag {
                            dragProvider(for: item)
                        }
                        .contextMenu {
                            contextMenu(for: item)
                        }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .onDrop(of: [UTType.fileURL, UTType.folder], isTargeted: $rootDropIsTargeted) { providers in
            viewModel.handleFileDrop(providers: providers, toRelativeDirectory: nil)
        }
        .overlay(alignment: .bottomLeading) {
            if rootDropIsTargeted {
                dropHint(text: "Drop to move/copy into project root")
            }
        }
    }

    private var foldersView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(viewModel.folderBreadcrumbs) { crumb in
                        Button(crumb.title) {
                            viewModel.navigateFolder(to: crumb.relativePath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(viewModel.currentFolderItems) { item in
                        folderTile(item: item)
                            .onDrop(of: [UTType.fileURL, UTType.folder], isTargeted: Binding(
                                get: { rowDropTargetID == item.id },
                                set: { targeted in
                                    if targeted {
                                        rowDropTargetID = item.id
                                    } else if rowDropTargetID == item.id {
                                        rowDropTargetID = nil
                                    }
                                }
                            )) { providers in
                                let destination = item.isDirectory ? item.relativePath : item.parentRelativePath
                                return viewModel.handleFileDrop(providers: providers, toRelativeDirectory: destination)
                            }
                            .onDrag {
                                dragProvider(for: item)
                            }
                            .contextMenu {
                                contextMenu(for: item)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onDrop(of: [UTType.fileURL, UTType.folder], isTargeted: $rootDropIsTargeted) { providers in
                viewModel.handleFileDrop(providers: providers, toRelativeDirectory: viewModel.folderViewPath)
            }
            .overlay(alignment: .bottomLeading) {
                if rootDropIsTargeted {
                    let scope = viewModel.folderViewPath.isEmpty ? "project root" : viewModel.folderViewPath
                    dropHint(text: "Drop to move/copy into \(scope)")
                }
            }
        }
    }

    private func explorerRow(item: FileItem) -> some View {
        Button {
            viewModel.handleExplorerTreePrimaryClick(item)
        } label: {
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

                Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item))
                    .foregroundStyle(item.isDirectory ? CodexTheme.accent : CodexTheme.textSecondary)
                Text(item.name)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(CodexTheme.textPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, CGFloat(item.depth) * 14)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func folderTile(item: FileItem) -> some View {
        VStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(for: item))
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(item.isDirectory ? CodexTheme.accent : CodexTheme.textSecondary)
            Text(item.name)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .frame(minHeight: 86)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(rowDropTargetID == item.id ? CodexTheme.accent.opacity(0.16) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(CodexTheme.border, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            if item.isDirectory {
                viewModel.navigateFolder(to: item.relativePath)
            } else {
                viewModel.openFile(item, mode: .pinned)
            }
        }
        .onTapGesture {
            if item.isDirectory {
                viewModel.navigateFolder(to: item.relativePath)
            } else {
                viewModel.openFile(item, mode: .preview)
            }
        }
    }

    private func contextMenu(for item: FileItem) -> some View {
        Group {
            if !item.isDirectory {
                Button("Open Preview") {
                    viewModel.openFile(item, mode: .preview)
                }
                Button("Open Pinned") {
                    viewModel.openFile(item, mode: .pinned)
                }
                Divider()
            }

            Button("Rename") {
                renameTarget = item
            }
            Button("Move To...") {
                relocateRequest = RelocateRequest(item: item, mode: .move)
            }
            Button("Copy To...") {
                relocateRequest = RelocateRequest(item: item, mode: .copy)
            }
            Button("Move to Trash", role: .destructive) {
                pendingTrashItem = item
            }

            Divider()

            Button("Open in macOS") {
                viewModel.openFileItemInOS(item)
            }
            Button("Reveal in Finder") {
                viewModel.revealItemInFinder(item)
            }
            if item.isDirectory {
                Button("New Folder Here") {
                    createFolderRequest = FolderTargetRequest(relativePath: item.relativePath)
                    createFolderName = ""
                }
            }
        }
    }

    private func dropHint(text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down.fill")
            Text(text)
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

    private func dragProvider(for item: FileItem) -> NSItemProvider {
        guard let root = viewModel.projectRootURL else {
            return NSItemProvider(object: item.relativePath as NSString)
        }
        let itemURL = root.appendingPathComponent(item.relativePath).standardizedFileURL
        return NSItemProvider(object: itemURL as NSURL)
    }

    private func dropTargetDirectory(for item: FileItem) -> String {
        if item.isDirectory {
            return item.relativePath
        }
        return item.parentRelativePath
    }

    private func fileIcon(for item: FileItem) -> String {
        let kind = FileKindDetector.detect(pathExtension: item.pathExtension, isBinary: false)
        switch kind {
        case .markdown:
            return "doc.richtext"
        case .csv:
            return "tablecells"
        case .json, .yaml, .xml:
            return "curlybraces"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .image:
            return "photo"
        case .pdf:
            return "doc.text.image"
        case .office:
            return "doc.fill"
        case .binary:
            return "shippingbox"
        case .text, .unknown:
            return "doc.text"
        }
    }

    private func rowBackgroundColor(for item: FileItem) -> Color {
        if rowDropTargetID == item.id {
            return CodexTheme.accent.opacity(0.16)
        }
        if viewModel.selectedExplorerPath == item.relativePath {
            return CodexTheme.accent.opacity(0.08)
        }
        return Color.clear
    }
}

struct WorkspacePanel: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var markdownPreviewPaths: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            tabBar

            Divider()

            if let activeTab = viewModel.activeTab {
                documentHeader(tab: activeTab)
                Divider()
                documentBody(tab: activeTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Text("Open a file to preview")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(CodexTheme.textPrimary)
                    Text("Single-click opens a preview tab. Double-click pins a tab.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(CodexTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(viewModel.workspaceTabs) { tab in
                    let isActive = viewModel.activeTabID == tab.id
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: tab.fileKind))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isActive ? CodexTheme.textPrimary : CodexTheme.textSecondary)

                        Text(tab.title)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(isActive ? CodexTheme.textPrimary : CodexTheme.textSecondary)

                        if viewModel.documentBuffers[tab.relativePath]?.isDirty == true {
                            Circle()
                                .fill(CodexTheme.warning)
                                .frame(width: 7, height: 7)
                        }

                        if tab.isPreview, !tab.isPinned {
                            Text("preview")
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(CodexTheme.textSecondary)
                        }

                        Button {
                            viewModel.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CodexTheme.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isActive ? Color.white : CodexTheme.panel)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(CodexTheme.border, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture {
                        viewModel.activateTab(tab.id)
                    }
                    .onTapGesture(count: 2) {
                        viewModel.activateTab(tab.id)
                        viewModel.markActiveTabPinned()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(CodexTheme.panel)
    }

    private func documentHeader(tab: WorkspaceTab) -> some View {
        HStack(spacing: 10) {
            Text(tab.relativePath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CodexTheme.textSecondary)
                .lineLimit(1)

            Spacer()

            if tab.fileKind == .markdown {
                Picker("Mode", selection: Binding(
                    get: { markdownPreviewPaths.contains(tab.relativePath) },
                    set: { preview in
                        if preview {
                            markdownPreviewPaths.insert(tab.relativePath)
                        } else {
                            markdownPreviewPaths.remove(tab.relativePath)
                        }
                    }
                )) {
                    Text("Edit").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            Button("Open in macOS") {
                viewModel.openRelativePathInOS(tab.relativePath)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Reveal") {
                if let item = viewModel.files.first(where: { $0.relativePath == tab.relativePath }) {
                    viewModel.revealItemInFinder(item)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CodexTheme.panel)
    }

    @ViewBuilder
    private func documentBody(tab: WorkspaceTab) -> some View {
        if tab.fileKind == .markdown, markdownPreviewPaths.contains(tab.relativePath) {
            markdownPreview(relativePath: tab.relativePath)
        } else if tab.fileKind == .csv {
            csvGrid(relativePath: tab.relativePath)
        } else if tab.fileKind.isEditable {
            textEditor(relativePath: tab.relativePath)
        } else if tab.fileKind.supportsQuickLook {
            quickLookPreview(relativePath: tab.relativePath)
        } else {
            unsupportedPreview(tab: tab)
        }
    }

    private func textEditor(relativePath: String) -> some View {
        TextEditor(text: Binding(
            get: { viewModel.documentBuffers[relativePath]?.content ?? "" },
            set: { viewModel.updateDocumentContent(relativePath: relativePath, content: $0) }
        ))
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .padding(8)
        .background(Color.white)
    }

    private func markdownPreview(relativePath: String) -> some View {
        ScrollView {
            Text(.init(viewModel.documentBuffers[relativePath]?.content ?? ""))
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .background(Color.white)
    }

    private func csvGrid(relativePath: String) -> some View {
        let rows = viewModel.csvRowsForDisplay(relativePath: relativePath)
        let maxColumns = max(rows.map(\.count).max() ?? 0, 1)

        return ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    HStack(spacing: 0) {
                        ForEach(0 ..< maxColumns, id: \.self) { columnIndex in
                            TextField(
                                "",
                                text: Binding(
                                    get: {
                                        guard rowIndex < rows.count, columnIndex < rows[rowIndex].count else {
                                            return ""
                                        }
                                        return rows[rowIndex][columnIndex]
                                    },
                                    set: { value in
                                        viewModel.updateCSVCell(
                                            relativePath: relativePath,
                                            row: rowIndex,
                                            column: columnIndex,
                                            value: value
                                        )
                                    }
                                )
                            )
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(minWidth: 130, alignment: .leading)
                            .background(Color.white)
                            .overlay(
                                Rectangle()
                                    .stroke(CodexTheme.border.opacity(0.6), lineWidth: 0.5)
                            )
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(CodexTheme.canvas)
    }

    @ViewBuilder
    private func quickLookPreview(relativePath: String) -> some View {
        if let root = viewModel.projectRootURL {
            QuickLookPreview(url: root.appendingPathComponent(relativePath).standardizedFileURL)
                .background(Color.white)
        } else {
            unsupportedMessage(text: "No project is open.")
        }
    }

    private func unsupportedPreview(tab: WorkspaceTab) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.badge.ellipsis")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(CodexTheme.textSecondary)
            Text("Preview unavailable for this format")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
            Text(tab.relativePath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CodexTheme.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CodexTheme.canvas)
    }

    private func unsupportedMessage(text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(CodexTheme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func icon(for kind: FileKind) -> String {
        switch kind {
        case .markdown:
            return "doc.richtext"
        case .csv:
            return "tablecells"
        case .json, .yaml, .xml:
            return "curlybraces"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .image:
            return "photo"
        case .pdf:
            return "doc.text.image"
        case .office:
            return "doc.fill"
        case .binary:
            return "shippingbox"
        case .text, .unknown:
            return "doc.text"
        }
    }
}

private struct InputPromptSheet: View {
    let title: String
    let message: String
    let placeholder: String
    let actionLabel: String
    @Binding var text: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
            Text(message)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(actionLabel) {
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !value.isEmpty else { return }
                    onSubmit(value)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 170)
    }
}

private struct RelocateSheet: View {
    let modeTitle: String
    let itemName: String
    @Binding var destination: String
    let directories: [String]
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(modeTitle) Item")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(CodexTheme.textPrimary)
            Text("\(modeTitle) \(itemName) to folder")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(CodexTheme.textSecondary)

            TextField("Destination folder (relative path, empty = root)", text: $destination)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(directories, id: \.self) { dir in
                        Button {
                            destination = dir
                        } label: {
                            Text(dir.isEmpty ? "(project root)" : dir)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(CodexTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                    }
                }
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(CodexTheme.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(CodexTheme.border, lineWidth: 1)
            )

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(modeTitle) {
                    onSubmit(destination)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 260)
    }
}

import Foundation
import XCTest
@testable import StashMacOSCore

final class WorkspaceCoreTests: XCTestCase {
    func testFileKindDetection() {
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "md", isBinary: false), .markdown)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "csv", isBinary: false), .csv)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "swift", isBinary: false), .code)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "json", isBinary: false), .json)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "png", isBinary: false), .image)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "pdf", isBinary: false), .pdf)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "docx", isBinary: false), .office)
        XCTAssertEqual(FileKindDetector.detect(pathExtension: "bin", isBinary: true), .binary)
    }

    func testCSVRoundTrip() {
        let rows = [["name", "notes"], ["alpha", "hello, world"], ["beta", "line1\nline2"], ["gamma", "quote \"inside\""]]
        let encoded = CSVCodec.encode(rows)
        let decoded = CSVCodec.parse(encoded)
        XCTAssertEqual(decoded, rows)
    }

    func testWorkspacePathValidator() {
        let root = URL(fileURLWithPath: "/tmp/stash-root", isDirectory: true)
        let inside = root.appendingPathComponent("docs/notes.md")
        let outside = URL(fileURLWithPath: "/tmp/stash-root-outside/docs.md")

        XCTAssertTrue(WorkspacePathValidator.isInsideProject(candidate: inside, root: root))
        XCTAssertFalse(WorkspacePathValidator.isInsideProject(candidate: outside, root: root))
        XCTAssertTrue(WorkspacePathValidator.isDescendant(inside, of: root))
        XCTAssertFalse(WorkspacePathValidator.isDescendant(root, of: inside))
    }

    func testExplorerClickResolverDoubleClick() {
        let t0 = Date()
        let tFast = t0.addingTimeInterval(0.1)
        let tSlow = t0.addingTimeInterval(0.4)

        XCTAssertTrue(
            ExplorerClickResolver.isDoubleClick(
                currentPath: "docs/a.md",
                previousPath: "docs/a.md",
                previousTapAt: t0,
                currentTapAt: tFast
            )
        )

        XCTAssertFalse(
            ExplorerClickResolver.isDoubleClick(
                currentPath: "docs/a.md",
                previousPath: "docs/b.md",
                previousTapAt: t0,
                currentTapAt: tFast
            )
        )

        XCTAssertFalse(
            ExplorerClickResolver.isDoubleClick(
                currentPath: "docs/a.md",
                previousPath: "docs/a.md",
                previousTapAt: t0,
                currentTapAt: tSlow
            )
        )
    }

    func testTextFileDecoderUTF16CSV() {
        let csv = "h1,h2\nv1,v2\nv3,v4"
        let data = csv.data(using: .utf16LittleEndian) ?? Data()
        let decoded = TextFileDecoder.decode(data: data, forceText: true)
        XCTAssertFalse(decoded.isBinary)
        XCTAssertTrue(decoded.text.contains("v1,v2"))
        XCTAssertTrue(decoded.text.contains("v3,v4"))
    }

    @MainActor
    func testPreviewTabReplacementAndPinning() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        try "alpha".write(to: temp.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "bravo".write(to: temp.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj", name: "proj", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)

        viewModel.openFile(relativePath: "a.txt", mode: .preview)
        XCTAssertEqual(viewModel.workspaceTabs.count, 1)
        XCTAssertEqual(viewModel.workspaceTabs.first?.relativePath, "a.txt")
        XCTAssertTrue(viewModel.workspaceTabs.first?.isPreview == true)

        viewModel.openFile(relativePath: "b.txt", mode: .preview)
        XCTAssertEqual(viewModel.workspaceTabs.count, 1)
        XCTAssertEqual(viewModel.workspaceTabs.first?.relativePath, "b.txt")

        viewModel.openFile(relativePath: "b.txt", mode: .pinned)
        XCTAssertTrue(viewModel.workspaceTabs.first?.isPinned == true)
        XCTAssertTrue(viewModel.workspaceTabs.first?.isPreview == false)

        viewModel.openFile(relativePath: "a.txt", mode: .preview)
        XCTAssertEqual(viewModel.workspaceTabs.count, 2)
        XCTAssertEqual(viewModel.activeTab?.relativePath, "a.txt")
    }

    @MainActor
    func testAutosaveStateTransition() async throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let fileURL = temp.appendingPathComponent("notes.md")
        try "initial".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj2", name: "proj2", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)

        viewModel.openFile(relativePath: "notes.md", mode: .pinned)
        viewModel.updateDocumentContent(relativePath: "notes.md", content: "changed")

        XCTAssertEqual(viewModel.documentBuffers["notes.md"]?.isDirty, true)

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let diskText = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(diskText, "changed")
        XCTAssertEqual(viewModel.documentBuffers["notes.md"]?.isDirty, false)
    }

    @MainActor
    func testCSVRowsForDisplayRecoversFromCollapsedBuffer() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let csvPath = "data.csv"
        let csvText = "date,amount\n2026-01-01,12.50\n2026-01-02,22.00"
        try csvText.write(to: temp.appendingPathComponent(csvPath), atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj-csv", name: "proj-csv", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)
        viewModel.openFile(relativePath: csvPath, mode: .preview)

        var collapsed = viewModel.documentBuffers[csvPath]
        collapsed?.content = "date,amount"
        collapsed?.lastSavedContent = "date,amount"
        if let collapsed {
            viewModel.documentBuffers[csvPath] = collapsed
        }

        let rows = viewModel.csvRowsForDisplay(relativePath: csvPath)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["2026-01-01", "12.50"])
        XCTAssertTrue(viewModel.documentBuffers[csvPath]?.content.contains("2026-01-02,22.00") == true)
    }

    @MainActor
    func testRunInlineStateMapping() {
        let viewModel = AppViewModel()
        XCTAssertEqual(viewModel.runInlineState, .idle)

        viewModel.runInProgress = true
        XCTAssertEqual(viewModel.runInlineState, .running)
        viewModel.runInProgress = false

        viewModel.pendingRunConfirmationID = "run-123"
        XCTAssertEqual(viewModel.runInlineState, .awaitingConfirmation)
        viewModel.pendingRunConfirmationID = nil

        viewModel.runStatusText = "FAILED: step 2"
        XCTAssertEqual(viewModel.runInlineState, .failed)
        viewModel.runStatusText = nil

        viewModel.runFeedbackEvents = [
            RunFeedbackEvent(id: "event-1", type: "status", title: "Run completed", detail: nil, timestamp: "12:00:00")
        ]
        XCTAssertEqual(viewModel.runInlineState, .done)
    }

    @MainActor
    func testPendingConfirmationVisibleWithoutChangesList() {
        let viewModel = AppViewModel()
        viewModel.pendingRunConfirmationID = "run-awaiting"
        viewModel.pendingRunChanges = []

        XCTAssertTrue(viewModel.hasPendingRunConfirmation)
        XCTAssertEqual(viewModel.runInlineState, .awaitingConfirmation)
        XCTAssertTrue(viewModel.runInlineSummaryText.contains("Review pending changes"))
    }

    func testMessageTimestampFormatting() {
        let message = Message(
            id: "m1",
            projectId: "p1",
            conversationId: "c1",
            role: "assistant",
            content: "Done.",
            parts: [],
            parentMessageId: nil,
            sequenceNo: 1,
            createdAt: "2026-02-06T10:16:14+00:00"
        )

        XCTAssertFalse(message.displayTimestamp.contains("T"))
        XCTAssertFalse(message.compactMetadataLabel.contains("T10:16:14"))
    }

    func testArtifactChipExtractionDedupAndOrder() throws {
        let partsJSON = """
        [
          {"type":"edit_file","path":"README.md","summary":"Appended heading"},
          {"type":"rename_file","fromPath":"notes-old.md","path":"notes.md","summary":"rename"},
          {"type":"output_file","path":"report.md"},
          {"type":"output_file","path":"report.md"}
        ]
        """
        let message = Message(
            id: "m2",
            projectId: "p1",
            conversationId: "c1",
            role: "assistant",
            content: "<stash_file>report.md</stash_file>\n<stash_file>report_extra.md</stash_file>",
            parts: try decodeMessageParts(from: partsJSON),
            parentMessageId: nil,
            sequenceNo: 2,
            createdAt: "2026-02-06T10:20:00+00:00"
        )

        let chips = message.artifactChips
        XCTAssertEqual(chips.map(\.kind), [.edit, .rename, .output, .output])
        XCTAssertEqual(chips.map(\.label), ["README.md", "notes-old.md -> notes.md", "report.md", "report_extra.md"])
        XCTAssertEqual(chips.filter(\.isOpenAction).count, 2)
    }

    private func makeTempProject() throws -> URL {
        let base = FileManager.default.temporaryDirectory
        let url = base.appendingPathComponent("stash-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeMessageParts(from json: String) throws -> [MessagePart] {
        let data = Data(json.utf8)
        return try JSONDecoder().decode([MessagePart].self, from: data)
    }
}

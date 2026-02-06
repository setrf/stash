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

    @MainActor
    func testInlineSummaryPrefersPhaseAndProgress() {
        let viewModel = AppViewModel()
        viewModel.runInProgress = true
        viewModel.runCurrentPhase = "executing"
        viewModel.runPhaseLabel = "Executing planned steps"
        viewModel.runProgressCurrentStep = 2
        viewModel.runProgressTotalSteps = 5
        viewModel.runProgressCompletedSteps = 1
        viewModel.runThinkingText = "Thinking and planning..."

        XCTAssertEqual(viewModel.runInlineSummaryText, "Executing planned steps • Step 2/5")
        XCTAssertEqual(viewModel.runProgressBadgeText, "Step 2/5")
    }

    @MainActor
    func testRunPhaseEventUpdatesInlineState() {
        let viewModel = AppViewModel()
        viewModel.applyRunEventForTesting(
            makeEvent(
                id: 1,
                type: "run_phase",
                payload: [
                    "phase": .string("planning"),
                    "label": .string("Planning actions"),
                    "progress_index": .number(2),
                    "progress_total": .number(6),
                ]
            ),
            expectedRunID: "run-1"
        )

        XCTAssertEqual(viewModel.runCurrentPhase, "planning")
        XCTAssertEqual(viewModel.runPhaseLabel, "Planning actions")
        XCTAssertEqual(viewModel.runPhaseIndex, 2)
        XCTAssertEqual(viewModel.runPhaseTotal, 6)
    }

    @MainActor
    func testRunProgressEventUpdatesStepCounters() {
        let viewModel = AppViewModel()
        viewModel.applyRunEventForTesting(
            makeEvent(
                id: 2,
                type: "run_progress",
                payload: [
                    "current_step": .number(3),
                    "total_steps": .number(7),
                    "completed_steps": .number(2),
                    "failed_steps": .number(1),
                    "active_step_label": .string("rg --files"),
                ]
            ),
            expectedRunID: "run-2"
        )

        XCTAssertEqual(viewModel.runProgressCurrentStep, 3)
        XCTAssertEqual(viewModel.runProgressTotalSteps, 7)
        XCTAssertEqual(viewModel.runProgressCompletedSteps, 2)
    }

    @MainActor
    func testDuplicateMilestonesAreSuppressed() {
        let viewModel = AppViewModel()
        let event = makeEvent(
            id: 3,
            type: "run_note",
            payload: [
                "kind": .string("synthesis"),
                "text": .string("Compiling final response."),
            ]
        )

        viewModel.applyRunEventForTesting(event, expectedRunID: "run-3")
        viewModel.applyRunEventForTesting(event, expectedRunID: "run-3")

        XCTAssertEqual(viewModel.runFeedbackEvents.count, 1)
    }

    @MainActor
    func testConfirmationStateStillOverridesInlineProgress() {
        let viewModel = AppViewModel()
        viewModel.runCurrentPhase = "executing"
        viewModel.runPhaseLabel = "Executing planned steps"
        viewModel.runProgressCurrentStep = 4
        viewModel.runProgressTotalSteps = 10
        viewModel.pendingRunConfirmationID = "run-awaiting"
        viewModel.pendingRunChanges = []

        XCTAssertEqual(viewModel.runInlineState, .awaitingConfirmation)
        XCTAssertTrue(viewModel.runInlineSummaryText.contains("Review pending changes"))
    }

    @MainActor
    func testFastQuickActionsMapContractToLegal() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        let contractURL = temp.appendingPathComponent("contracts/master-agreement.md")
        try FileManager.default.createDirectory(at: contractURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Contract terms".write(to: contractURL, atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj-qa-1", name: "proj-qa-1", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)
        viewModel.refreshQuickActionsFast()

        let categories = viewModel.quickActionsForDisplay.map(\.category)
        XCTAssertEqual(viewModel.quickActionsForDisplay.count, 3)
        XCTAssertEqual(categories.first, "legal")
    }

    @MainActor
    func testFastQuickActionsMixedContextUsesTwoDomainPlusGeneral() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }

        try FileManager.default.createDirectory(at: temp.appendingPathComponent("contracts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp.appendingPathComponent("stocks"), withIntermediateDirectories: true)
        try "agreement".write(to: temp.appendingPathComponent("contracts/nda.txt"), atomically: true, encoding: .utf8)
        try "portfolio".write(to: temp.appendingPathComponent("stocks/portfolio_notes.md"), atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj-qa-2", name: "proj-qa-2", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)
        viewModel.refreshQuickActionsFast()

        let categories = viewModel.quickActionsForDisplay.map(\.category)
        let nonGeneral = categories.filter { $0 != "general" }
        XCTAssertEqual(viewModel.quickActionsForDisplay.count, 3)
        XCTAssertEqual(nonGeneral.count, 2)
        XCTAssertEqual(categories.filter { $0 == "general" }.count, 1)
    }

    @MainActor
    func testApplyQuickActionPrefillsComposerAndMentionState() throws {
        let temp = try makeTempProject()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fileURL = temp.appendingPathComponent("notes.md")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

        let viewModel = AppViewModel()
        viewModel.project = Project(id: "proj-qa-3", name: "proj-qa-3", rootPath: temp.path, createdAt: nil, lastOpenedAt: nil, activeConversationId: nil)
        viewModel.projectRootURL = temp
        viewModel.files = FileScanner.scan(rootURL: temp)
        let beforeFocusToken = viewModel.composerFocusToken

        let action = QuickActionItemPayload(
            id: "qa-test",
            label: "Test Action",
            prompt: "Please review @notes.md and summarize.",
            category: "general",
            confidence: 0.5,
            reason: "test"
        )
        viewModel.applyQuickAction(action)

        XCTAssertEqual(viewModel.composerText, action.prompt)
        XCTAssertEqual(viewModel.mentionedFilePaths, ["notes.md"])
        XCTAssertEqual(viewModel.composerFocusToken, beforeFocusToken + 1)
    }

    @MainActor
    func testQuickActionVisibilityTracksEmptyConversationState() {
        let viewModel = AppViewModel()
        XCTAssertTrue(viewModel.shouldShowQuickActionsInEmptyState)

        viewModel.messages = [
            Message(
                id: "m-quick-1",
                projectId: "p1",
                conversationId: "c1",
                role: "assistant",
                content: "Hello",
                parts: [],
                parentMessageId: nil,
                sequenceNo: 1,
                createdAt: "2026-02-06T10:16:14+00:00"
            )
        ]
        XCTAssertFalse(viewModel.shouldShowQuickActionsInEmptyState)
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

    private func makeEvent(id: Int, type: String, payload: [String: JSONValue], runID: String? = nil) -> ProjectEvent {
        ProjectEvent(
            id: id,
            type: type,
            projectId: "p1",
            conversationId: "c1",
            runId: runID,
            ts: "2026-02-06T12:00:00Z",
            payload: payload
        )
    }
}

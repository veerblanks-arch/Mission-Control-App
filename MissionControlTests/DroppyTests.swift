import AppKit
import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import Droppy

final class DroppyTests: XCTestCase {
    func testMusicMetadataParserPreservesSecondsAndPlaybackState() throws {
        let output = [
            "playing",
            "First Light",
            "The Artist",
            "Morning Album",
            "245.5",
            "61.25",
            "",
        ].joined(separator: MediaMetadataParser.delimiter)

        let metadata = try MediaMetadataParser.parse(output).get()

        XCTAssertEqual(metadata.title, "First Light")
        XCTAssertEqual(metadata.artist, "The Artist")
        XCTAssertEqual(metadata.album, "Morning Album")
        XCTAssertEqual(metadata.duration, 245.5, accuracy: 0.001)
        XCTAssertEqual(metadata.elapsedTime, 61.25, accuracy: 0.001)
        XCTAssertTrue(metadata.isPlaying)
    }

    func testMediaMetadataParserReportsStoppedPlayerClearly() {
        let result = MediaMetadataParser.parse(MediaMetadataParser.stoppedMarker)

        guard case let .failure(issue) = result else {
            XCTFail("Expected a stopped-player issue")
            return
        }
        XCTAssertEqual(issue.kind, .nothingPlaying)
        XCTAssertEqual(issue.title, "Nothing is playing")
    }

    func testMediaPermissionErrorIsDistinguishedFromAutomationFailure() {
        let permissionIssue = MediaIssue.automationFailure(
            status: 1,
            errorOutput:
                "Not authorized to send Apple events to Music. (-1743)"
        )
        let generalIssue = MediaIssue.automationFailure(
            status: 1,
            errorOutput: "Music got an error: connection is invalid."
        )

        XCTAssertEqual(permissionIssue.kind, .permissionDenied)
        XCTAssertEqual(generalIssue.kind, .automationFailed)
    }

    func testMediaSnapshotProgressAndSeekingAreClamped() {
        let snapshot = MediaSnapshot(
            title: "Track",
            artist: "Artist",
            artwork: nil,
            elapsedTime: 30,
            duration: 120,
            isPlaying: true
        )

        XCTAssertEqual(snapshot.progress, 0.25, accuracy: 0.001)
        XCTAssertEqual(
            snapshot.replacing(elapsedTime: 500).elapsedTime,
            120,
            accuracy: 0.001
        )
        XCTAssertEqual(
            snapshot.replacing(elapsedTime: -20).elapsedTime,
            0,
            accuracy: 0.001
        )
    }

    func testMiniMediaPlayerUsesPausedReadySnapshot() {
        let pausedSnapshot = MediaSnapshot(
            title: "Paused Track",
            artist: "Artist",
            artwork: nil,
            elapsedTime: 20,
            duration: 100,
            isPlaying: false
        )

        XCTAssertFalse(pausedSnapshot.isPlaying)
        XCTAssertNotNil(MediaDisplayState.ready(pausedSnapshot).snapshot)
        XCTAssertNil(MediaDisplayState.idle.snapshot)
        XCTAssertEqual(OverlayFeature.allCases.count, 6)
        XCTAssertFalse(OverlayFeature.allCases.map(\.rawValue).contains("media"))
        XCTAssertTrue(OverlayFeature.allCases.map(\.rawValue).contains("codex"))
        XCTAssertTrue(OverlayFeature.allCases.map(\.rawValue).contains("notion"))
    }

    @MainActor
    func testNotionConnectorPersistsAddedEditedAndRemovedShortcuts() throws {
        let suiteName = "DroppyTests.NotionConnector.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feature = NotionConnectorFeature(defaults: defaults)

        XCTAssertTrue(
            feature.addShortcut(
                title: "  School  ",
                urlString: "www.notion.so/school"
            )
        )
        let shortcut = try XCTUnwrap(feature.shortcuts.first)
        XCTAssertEqual(shortcut.title, "School")
        XCTAssertEqual(shortcut.urlString, "https://www.notion.so/school")

        XCTAssertTrue(
            feature.updateShortcut(
                id: shortcut.id,
                title: "Classes",
                urlString: "https://www.notion.so/classes"
            )
        )

        let reloaded = NotionConnectorFeature(defaults: defaults)
        XCTAssertEqual(
            reloaded.shortcuts,
            [
                NotionShortcut(
                    id: shortcut.id,
                    title: "Classes",
                    urlString: "https://www.notion.so/classes"
                ),
            ]
        )

        reloaded.removeShortcut(id: shortcut.id)
        XCTAssertTrue(NotionConnectorFeature(defaults: defaults).shortcuts.isEmpty)
    }

    @MainActor
    func testNotionConnectorRejectsUnsupportedOrIncompleteLinks() {
        XCTAssertNil(NotionConnectorFeature.normalizedURLString(""))
        XCTAssertNil(NotionConnectorFeature.normalizedURLString("file:///tmp/private"))
        XCTAssertNil(NotionConnectorFeature.normalizedURLString("https://"))
        XCTAssertEqual(
            NotionConnectorFeature.normalizedURLString("notion://www.notion.so/tasks"),
            "notion://www.notion.so/tasks"
        )
    }

    @MainActor
    func testCodexThreadStatusParsingDistinguishesRunningWaitingAndUnavailable() {
        XCTAssertEqual(
            CodexFeature.parseStatus(["type": "active", "activeFlags": []]),
            .running
        )
        XCTAssertEqual(
            CodexFeature.parseStatus([
                "type": "active",
                "activeFlags": ["waitingOnApproval"],
            ]),
            .waiting
        )
        XCTAssertEqual(CodexFeature.parseStatus(["type": "systemError"]), .failed)
        XCTAssertEqual(CodexFeature.parseStatus(["type": "notLoaded"]), .unavailable)
        XCTAssertEqual(CodexRuntimeStatus.unavailable.title, "Saved history")
        XCTAssertTrue(CodexRuntimeStatus.running.isActive)
        XCTAssertTrue(CodexRuntimeStatus.waiting.isActive)
        XCTAssertFalse(CodexRuntimeStatus.idle.isActive)
    }

    @MainActor
    func testUnmanagedCodexThreadHasNoInventedAgentRole() {
        let suiteName = "DroppyTests.CodexUnmanagedRole.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feature = CodexFeature(defaults: defaults)

        XCTAssertNil(feature.role(for: "external-thread"))
        XCTAssertFalse(feature.isDroppyManaged("external-thread"))
    }

    @MainActor
    func testPersistedCodexRoleMarksOnlyThatThreadAsDroppyManaged() throws {
        let suiteName = "DroppyTests.CodexManagedRole.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(["managed-thread": CodexAgentRole.builderA]),
            forKey: "codexThreadRoleAssignments"
        )
        let feature = CodexFeature(defaults: defaults)

        XCTAssertTrue(feature.isDroppyManaged("managed-thread"))
        XCTAssertEqual(feature.role(for: "managed-thread"), .builderA)
        XCTAssertFalse(feature.isDroppyManaged("external-thread"))
    }

    @MainActor
    func testOnlyPersistedHandedOffTasksCanBeBroughtBack() throws {
        let suiteName = "DroppyTests.CodexHandedOffRole.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(["handed-off-thread": CodexAgentRole.reviewer]),
            forKey: "codexHandedOffRoleAssignments"
        )
        let feature = CodexFeature(defaults: defaults)
        let handedOff = codexThread(id: "handed-off-thread", cwd: "/tmp", updatedAt: 1)
        let external = codexThread(id: "external-thread", cwd: "/tmp", updatedAt: 1)

        XCTAssertTrue(feature.wasHandedOffToCodex(handedOff.id))
        XCTAssertFalse(feature.isDroppyManaged(handedOff.id))
        XCTAssertEqual(feature.role(for: handedOff.id), .reviewer)
        XCTAssertTrue(feature.canBringBackToDroppy(handedOff))
        XCTAssertFalse(feature.canBringBackToDroppy(handedOff.replacing(status: .running)))
        XCTAssertFalse(feature.canBringBackToDroppy(external))
    }

    @MainActor
    func testLegacyOwnershipConflictMigratesSafelyAsHandedOff() throws {
        let suiteName = "DroppyTests.CodexOwnershipMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(["thread": CodexAgentRole.builderA]),
            forKey: "codexThreadRoleAssignments"
        )
        defaults.set(
            try JSONEncoder().encode(["thread": CodexAgentRole.reviewer]),
            forKey: "codexHandedOffRoleAssignments"
        )

        let migrated = CodexFeature(defaults: defaults)
        XCTAssertFalse(migrated.isDroppyManaged("thread"))
        XCTAssertTrue(migrated.wasHandedOffToCodex("thread"))
        XCTAssertEqual(migrated.role(for: "thread"), .reviewer)

        defaults.removeObject(forKey: "codexThreadRoleAssignments")
        defaults.removeObject(forKey: "codexHandedOffRoleAssignments")
        let reloaded = CodexFeature(defaults: defaults)
        XCTAssertFalse(reloaded.isDroppyManaged("thread"))
        XCTAssertTrue(reloaded.wasHandedOffToCodex("thread"))
        XCTAssertEqual(reloaded.role(for: "thread"), .reviewer)
    }

    @MainActor
    func testCodexLiveRepliesRequireAnIdleDroppyManagedThread() throws {
        let suiteName = "DroppyTests.CodexLiveReply.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONEncoder().encode(["managed-thread": CodexAgentRole.planner]),
            forKey: "codexThreadRoleAssignments"
        )
        let feature = CodexFeature(defaults: defaults)
        let managed = codexThread(id: "managed-thread", cwd: "/tmp", updatedAt: 1)
        let external = codexThread(id: "external-thread", cwd: "/tmp", updatedAt: 1)

        XCTAssertTrue(feature.canSendReply(to: managed))
        XCTAssertFalse(feature.canSendReply(to: managed.replacing(status: .running)))
        XCTAssertFalse(feature.canSendReply(to: managed.replacing(status: .waiting)))
        XCTAssertFalse(feature.canSendReply(to: external))
    }

    func testCodexRolesUseDistinctPetAssets() {
        XCTAssertEqual(
            CodexAgentRole.allCases.map(\.petAssetName),
            ["planner-owl", "builder-a-beaver", "builder-b-fox", "reviewer-cat"]
        )
    }

    @MainActor
    func testCodexHistoryMergePreservesLongerStreamedTextAndOptimisticMessages() {
        let history = [
            CodexChatMessage(id: "agent-1", sender: .agent, text: "Partial"),
        ]
        let live = [
            CodexChatMessage(id: "local-user", sender: .user, text: "Ship it"),
            CodexChatMessage(id: "agent-1", sender: .agent, text: "Partial response"),
        ]

        XCTAssertEqual(
            CodexFeature.mergeHistoryMessages(history, preservingLiveMessages: live),
            [
                CodexChatMessage(id: "agent-1", sender: .agent, text: "Partial response"),
                CodexChatMessage(id: "local-user", sender: .user, text: "Ship it"),
            ]
        )
    }

    @MainActor
    func testCodexTurnErrorMessageReadsNestedAndDirectErrors() {
        XCTAssertEqual(
            CodexFeature.turnErrorMessage(from: ["error": ["message": "Build failed"]]),
            "Build failed"
        )
        XCTAssertEqual(
            CodexFeature.turnErrorMessage(from: ["message": "Connection dropped"]),
            "Connection dropped"
        )
        XCTAssertNil(CodexFeature.turnErrorMessage(from: ["error": [:]]))
    }

    @MainActor
    func testCodexRequestsPinWorkspaceSandboxWithoutNetwork() {
        let thread = CodexFeature.safeThreadStartParams(cwd: "/tmp/project")
        XCTAssertEqual(thread["approvalPolicy"] as? String, "onRequest")
        XCTAssertEqual(thread["sandbox"] as? String, "workspaceWrite")

        let resume = CodexFeature.safeThreadResumeParams(
            threadID: "thread",
            cwd: "/tmp/project"
        )
        XCTAssertEqual(resume["threadId"] as? String, "thread")
        XCTAssertEqual(resume["approvalPolicy"] as? String, "onRequest")
        XCTAssertNil(resume["serviceName"])

        let turn = CodexFeature.safeTurnStartParams(
            threadID: "thread",
            cwd: "/tmp/project",
            input: [["type": "text", "text": "Build"]]
        )
        let sandbox = turn["sandboxPolicy"] as? [String: Any]
        XCTAssertEqual(turn["approvalPolicy"] as? String, "onRequest")
        XCTAssertEqual(sandbox?["type"] as? String, "workspaceWrite")
        XCTAssertEqual(sandbox?["writableRoots"] as? [String], ["/tmp/project"])
        XCTAssertEqual(sandbox?["networkAccess"] as? Bool, false)
    }

    func testCodexProtectedRequestsUseProtocolSpecificSafeRejections() {
        XCTAssertEqual(
            CodexAppServerClient.safeRejectionResult(
                for: "item/commandExecution/requestApproval"
            )?["decision"] as? String,
            "cancel"
        )
        XCTAssertNotNil(
            CodexAppServerClient.safeRejectionResult(
                for: "item/permissions/requestApproval"
            )?["permissions"] as? [String: Any]
        )
        XCTAssertEqual(
            CodexAppServerClient.safeRejectionResult(
                for: "mcpServer/elicitation/request"
            )?["action"] as? String,
            "cancel"
        )
        XCTAssertNil(CodexAppServerClient.safeRejectionResult(for: "unknown/request"))
    }

    @MainActor
    func testCodexTurnStartRequiresARealTurnID() {
        XCTAssertEqual(
            CodexFeature.turnID(fromStartPayload: ["turn": ["id": "turn-1"]]),
            "turn-1"
        )
        XCTAssertNil(CodexFeature.turnID(fromStartPayload: [:]))
        XCTAssertNil(CodexFeature.turnID(fromStartPayload: ["turn": ["id": ""]]))
    }

    @MainActor
    func testCodexThreadParsingUsesNameProjectAndRecency() throws {
        let summary = try XCTUnwrap(CodexFeature.parseThread(
            [
                "id": "thread-7",
                "name": "Ship Phase 7",
                "preview": "Build the Codex dashboard",
                "cwd": "/Users/example/Documents/Droppy Copy",
                "status": ["type": "idle"],
                "recencyAt": NSNumber(value: 1_700_000_000),
            ],
            model: "gpt-test"
        ))

        XCTAssertEqual(summary.id, "thread-7")
        XCTAssertEqual(summary.title, "Ship Phase 7")
        XCTAssertEqual(summary.projectName, "Droppy Copy")
        XCTAssertEqual(summary.status, .idle)
        XCTAssertEqual(summary.model, "gpt-test")
        XCTAssertEqual(summary.updatedAt.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    @MainActor
    func testCodexDashboardKeepsRecentProjectsAndFoldsOtherPathsIntoNormalChats() {
        let olderBitwise = codexThread(
            id: "bitwise-old",
            cwd: "/Users/veer/Documents/Obsidian Vault/bitwise",
            updatedAt: 100
        )
        let droppy = codexThread(
            id: "droppy",
            cwd: "/Users/veer/Documents/Droppy Copy",
            updatedAt: 200
        )
        let newerBitwise = codexThread(
            id: "bitwise-new",
            cwd: "/Users/veer/Codex/Bitwise",
            updatedAt: 300
        )
        let temporary = codexThread(
            id: "temporary",
            cwd: "/private/var/folders/example/BigIntegerLab4.java123",
            updatedAt: 400
        )

        let projects = CodexFeature.dashboardGroups(from: [
            olderBitwise,
            droppy,
            newerBitwise,
            temporary,
        ])

        XCTAssertEqual(projects.map(\.name), ["Bitwise", "Droppy", "Normal Chats"])
        XCTAssertEqual(projects[0].threads.map(\.id), ["bitwise-new", "bitwise-old"])
        XCTAssertEqual(projects[1].threads.map(\.id), ["droppy"])
        XCTAssertEqual(projects[2].threads.map(\.id), ["temporary"])
        XCTAssertEqual(projects[2].kind, .normalChats)
    }

    @MainActor
    func testCodexProjectSearchCanFindRecentProjectsAndNormalChatSources() {
        let threads = [
            codexThread(id: "one", cwd: "/Users/veer/Documents/Droppy Copy", updatedAt: 200),
            codexThread(id: "two", cwd: "/Users/veer/Codex/Compsci", updatedAt: 100),
        ]

        let droppyProjects = CodexFeature.dashboardGroups(from: threads, matching: "droppy")
        let normalProjects = CodexFeature.dashboardGroups(from: threads, matching: "compsci")

        XCTAssertEqual(droppyProjects.map(\.name), ["Droppy"])
        XCTAssertEqual(droppyProjects[0].threads.map(\.id), ["one"])
        XCTAssertEqual(normalProjects.map(\.name), ["Normal Chats"])
        XCTAssertEqual(normalProjects[0].threads.map(\.id), ["two"])
    }

    @MainActor
    func testCodexNewTaskOffersOnlyNamedRecentProjects() {
        let suiteName = "DroppyTests.CodexRecentProjects.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feature = CodexFeature(defaults: defaults)

        XCTAssertEqual(feature.availableProjects, [
            CodexProjectOption(
                id: "apush",
                name: "APUSH",
                path: "/Users/veer/Documents/APUSH"
            ),
            CodexProjectOption(
                id: "bitwise",
                name: "Bitwise",
                path: "/Users/veer/Codex/Bitwise"
            ),
            CodexProjectOption(
                id: "droppy",
                name: "Droppy",
                path: "/Users/veer/Documents/Droppy Copy"
            ),
        ])
    }

    @MainActor
    func testCodexUsageDisplaysRemainingPercentage() {
        XCTAssertEqual(CodexFeature.remainingPercent(fromUsedPercent: 35), 65)
        XCTAssertEqual(CodexFeature.remainingPercent(fromUsedPercent: 120), 0)
        XCTAssertEqual(CodexFeature.remainingPercent(fromUsedPercent: -5), 100)
    }

    @MainActor
    func testCodexRetriesOnlyTransientEmptyRolloutReads() {
        XCTAssertTrue(CodexFeature.isTransientEmptyThreadReadError(
            "failed to read thread: thread-store internal error: failed to read session metadata /Users/example/rollout.jsonl: rollout at /Users/example/rollout.jsonl is empty"
        ))
        XCTAssertFalse(CodexFeature.isTransientEmptyThreadReadError(
            "failed to read thread: permission denied"
        ))
        XCTAssertFalse(CodexFeature.isTransientEmptyThreadReadError(
            "thread response is empty"
        ))
    }

    private func codexThread(
        id: String,
        cwd: String,
        updatedAt: TimeInterval
    ) -> CodexThreadSummary {
        CodexThreadSummary(
            id: id,
            title: id,
            preview: "",
            cwd: cwd,
            status: .idle,
            model: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @MainActor
    func testCodexInputsSendImagesNativelyAndListOtherLocalFiles() {
        let image = CodexDraftAttachment(url: URL(fileURLWithPath: "/tmp/mockup.png"))
        let document = CodexDraftAttachment(url: URL(fileURLWithPath: "/tmp/notes.pdf"))

        let inputs = CodexFeature.userInputs(
            prompt: "Review these",
            attachments: [image, document]
        )

        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0]["type"] as? String, "text")
        XCTAssertTrue((inputs[0]["text"] as? String)?.contains("/tmp/notes.pdf") == true)
        XCTAssertEqual(inputs[1]["type"] as? String, "localImage")
        XCTAssertEqual(inputs[1]["path"] as? String, "/tmp/mockup.png")
    }

    @MainActor
    func testMediaLifecycleStartsOnceAndCanRestartAfterStop() {
        let client = MediaClientSpy()
        let feature = MediaFeature(client: client)

        feature.start()
        feature.start()
        XCTAssertEqual(client.fetchRequests.count, 1)

        let firstRequest = client.fetchRequests[0]
        feature.stop()
        XCTAssertTrue(firstRequest.isCancelled)

        feature.start()
        XCTAssertEqual(client.fetchRequests.count, 2)
        feature.stop()
    }

    @MainActor
    func testQueuedMediaTimerTickDoesNotRefreshAfterStop() {
        let client = MediaClientSpy()
        let feature = MediaFeature(client: client)

        feature.start()
        let queuedTimerTick = feature.makeRefreshTimerTick()
        XCTAssertEqual(client.fetchRequests.count, 1)

        feature.stop()
        queuedTimerTick()

        XCTAssertEqual(client.fetchRequests.count, 1)
    }

    func testMediaCancellationRunsRegisteredActionsOnce() {
        let cancellation = MediaCancellation()
        var actionCount = 0
        cancellation.add {
            actionCount += 1
        }

        cancellation.cancel()
        cancellation.cancel()
        cancellation.add {
            actionCount += 1
        }

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(actionCount, 2)
    }

    @MainActor
    func testQuietMediaRefreshDoesNotStarveAnInFlightArtworkRequest() {
        let client = MediaClientSpy()
        let feature = MediaFeature(client: client)

        feature.refresh()
        let firstRequest = client.fetchRequests[0]
        feature.refresh(quietly: true)

        XCTAssertEqual(client.fetchRequests.count, 1)
        XCTAssertFalse(firstRequest.isCancelled)

        feature.refresh()

        XCTAssertEqual(client.fetchRequests.count, 2)
        XCTAssertTrue(firstRequest.isCancelled)
    }

    @MainActor
    func testMediaControlFailurePublishesWarningWhileSnapshotStaysReady() async {
        let client = MediaClientSpy()
        let feature = MediaFeature(client: client)
        let snapshot = MediaSnapshot(
            title: "Track",
            artist: "Artist",
            artwork: nil,
            elapsedTime: 10,
            duration: 120,
            isPlaying: true
        )
        feature.start()
        client.completeLatestFetch(.success(snapshot))
        await Task.yield()

        let issue = MediaIssue.automationFailure(
            status: 1,
            errorOutput: "Apple Music rejected the command."
        )
        feature.nextTrack()
        client.completeLatestPerform(.failure(issue))
        await Task.yield()

        XCTAssertEqual(feature.controlMessage, issue.message)
        XCTAssertNotNil(feature.displayState.snapshot)
        feature.stop()
    }

    @MainActor
    func testStoppingMediaCancelsDelayedPostControlRefresh() async {
        let client = MediaClientSpy()
        let feature = MediaFeature(client: client)
        feature.start()
        client.completeLatestFetch(
            .success(
                MediaSnapshot(
                    title: "Track",
                    artist: "Artist",
                    artwork: nil,
                    elapsedTime: 10,
                    duration: 120,
                    isPlaying: true
                )
            )
        )
        await Task.yield()

        feature.togglePlayPause()
        client.completeLatestPerform(.success(()))
        await Task.yield()
        feature.stop()
        try? await Task.sleep(for: .milliseconds(450))

        XCTAssertEqual(client.fetchRequests.count, 1)

        feature.refresh()
        XCTAssertEqual(client.fetchRequests.count, 2)
    }

    func testAppleScriptArtworkDescriptorDecodesHexPayload() {
        XCTAssertEqual(
            LocalMediaClient.appleScriptDataDescriptor(
                from: "«data JPEG48656C6C6F»"
            ),
            Data("Hello".utf8)
        )
        XCTAssertNil(
            LocalMediaClient.appleScriptDataDescriptor(
                from: "not an AppleScript data descriptor"
            )
        )
    }

    func testApplicationMenuProvidesStandardEditingShortcuts() {
        let menu = ApplicationMenu.make()
        let editMenu = menu.items
            .first { $0.title == "Edit" }?
            .submenu

        let expectedActions = [
            "x": "cut:",
            "c": "copy:",
            "v": "paste:",
            "a": "selectAll:"
        ]
        for (keyEquivalent, action) in expectedActions {
            let item = editMenu?.items.first {
                $0.keyEquivalent == keyEquivalent
            }
            XCTAssertEqual(
                item?.action.map(NSStringFromSelector),
                action
            )
            XCTAssertEqual(
                item?.keyEquivalentModifierMask,
                .command
            )
        }
    }

    func testTerminalDefaultsToTheUserHomeDirectory() {
        XCTAssertEqual(
            TerminalFeature.defaultDirectoryURL,
            FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        )
    }

    func testPanelCentersBelowAnchor() {
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 900, y: 1060, width: 24, height: 24),
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056)
        )

        XCTAssertEqual(frame.midX, 912, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 1054, accuracy: 0.001)
    }

    func testPanelClampsToLeftScreenEdge() {
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 4, y: 1060, width: 24, height: 24),
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1920, height: 1056)
        )

        XCTAssertEqual(frame.minX, 0, accuracy: 0.001)
    }

    func testPanelClampsToRightScreenEdgeWithOffsetDisplay() {
        let visibleFrame = NSRect(x: 1920, y: 100, width: 1440, height: 900)
        let frame = PanelGeometry.anchoredFrame(
            size: NSSize(width: 420, height: 560),
            anchorFrame: NSRect(x: 3340, y: 1004, width: 20, height: 20),
            visibleScreenFrame: visibleFrame
        )

        XCTAssertEqual(frame.maxX, visibleFrame.maxX, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
    }

    func testPanelSizeIsClamped() {
        XCTAssertEqual(
            PanelGeometry.clampedSize(NSSize(width: 100, height: 100)),
            PanelGeometry.minimumSize
        )
        XCTAssertEqual(
            PanelGeometry.clampedSize(NSSize(width: 2000, height: 2000)),
            PanelGeometry.maximumSize
        )
    }

    func testDropZoneGeometryUsesPhysicalTopCenter() {
        let screenFrame = NSRect(x: -1440, y: 180, width: 1440, height: 900)
        let activationFrame = DropZoneGeometry.activationFrame(for: screenFrame)
        let panelFrame = DropZoneGeometry.panelFrame(for: screenFrame)

        XCTAssertEqual(activationFrame.width, 300)
        XCTAssertEqual(activationFrame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(activationFrame.maxY, screenFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(panelFrame.midX, screenFrame.midX, accuracy: 0.001)
        XCTAssertEqual(panelFrame.maxY, screenFrame.maxY - DropZoneGeometry.topInset, accuracy: 0.001)
    }

    func testShelfAddsBatchInDeterministicOrder() throws {
        let fixture = try ShelfTestFixture()
        let first = try fixture.createFile(named: "first.txt")
        let second = try fixture.createFile(named: "second.txt")
        let folder = try fixture.createFolder(named: "Folder")
        let feature = ShelfFeature(store: fixture.store)

        XCTAssertEqual(feature.add([first, second, folder], at: Date(timeIntervalSince1970: 100)), 3)
        XCTAssertEqual(feature.items.map(\.displayName), ["first.txt", "second.txt", "Folder"])
        XCTAssertEqual(feature.items.map(\.kind), [.file, .file, .folder])
    }

    func testShelfDeduplicatesNormalizedPathAndPreservesIdentity() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "same.txt")
        let feature = ShelfFeature(store: fixture.store)

        feature.add([file], at: Date(timeIntervalSince1970: 100))
        let originalID = try XCTUnwrap(feature.items.first?.id)
        feature.add(
            [file.deletingLastPathComponent().appendingPathComponent("./same.txt")],
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(feature.items.count, 1)
        XCTAssertEqual(feature.items.first?.id, originalID)
        XCTAssertEqual(feature.items.first?.addedAt, Date(timeIntervalSince1970: 200))
    }

    func testShelfPersistsAcrossRelaunch() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "persisted.txt")
        let firstFeature = ShelfFeature(store: fixture.store)
        firstFeature.add([file], at: Date(timeIntervalSince1970: 100))

        let reloadedFeature = ShelfFeature(store: ShelfStore(fileURL: fixture.storeURL))

        XCTAssertEqual(reloadedFeature.items.count, 1)
        XCTAssertEqual(reloadedFeature.items.first?.displayName, "persisted.txt")
        XCTAssertEqual(
            reloadedFeature.items.first?.resolvedURL.resolvingSymlinksInPath().path,
            file.resolvingSymlinksInPath().path
        )
    }

    func testRemovingShelfReferenceDoesNotDeleteOriginal() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "keep-me.txt")
        let feature = ShelfFeature(store: fixture.store)
        feature.add([file])

        let item = try XCTUnwrap(feature.items.first)
        feature.remove(item)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(feature.items.isEmpty)
    }

    func testMissingShelfItemRemainsVisible() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "temporary.txt")
        let feature = ShelfFeature(store: fixture.store)
        feature.add([file])
        try FileManager.default.removeItem(at: file)

        let reloadedFeature = ShelfFeature(store: ShelfStore(fileURL: fixture.storeURL))

        XCTAssertEqual(reloadedFeature.items.count, 1)
        XCTAssertFalse(try XCTUnwrap(reloadedFeature.items.first).exists)
    }

    func testShelfDragSuggestedNameLeavesExtensionForProvider() throws {
        let fixture = try ShelfTestFixture()
        let file = try fixture.createFile(named: "archive.tar.gz")
        let folder = try fixture.createFolder(named: "Folder.with.dots")

        let fileItem = ShelfItem(url: file, addedAt: Date(), order: 1)
        let folderItem = ShelfItem(url: folder, addedAt: Date(), order: 2)

        XCTAssertEqual(fileItem.dragSuggestedName, "archive.tar")
        XCTAssertEqual(folderItem.dragSuggestedName, "Folder.with.dots")
    }

    func testClipboardRetentionPreservesPinsAndRemovesExpiredItems() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expired = clipboardItem(capturedAt: now.addingTimeInterval(-604_801))
        let recent = clipboardItem(capturedAt: now.addingTimeInterval(-60))
        let pinned = clipboardItem(
            capturedAt: now.addingTimeInterval(-700_000),
            pinnedAt: now.addingTimeInterval(-700_000)
        )

        let removals = ClipboardRetentionPolicy().removalIDs(
            from: [expired, recent, pinned],
            now: now
        )

        XCTAssertTrue(removals.contains(expired.id))
        XCTAssertFalse(removals.contains(recent.id))
        XCTAssertFalse(removals.contains(pinned.id))
    }

    func testClipboardRetentionAppliesCountAndByteCapsOldestFirst() {
        let now = Date(timeIntervalSince1970: 10_000)
        let oldest = clipboardItem(capturedAt: now.addingTimeInterval(-30), bytes: 60)
        let middle = clipboardItem(capturedAt: now.addingTimeInterval(-20), bytes: 60)
        let newest = clipboardItem(capturedAt: now.addingTimeInterval(-10), bytes: 60)
        let policy = ClipboardRetentionPolicy(
            lifetime: 1_000,
            maximumUnpinnedItems: 2,
            maximumUnpinnedBytes: 100
        )

        let removals = policy.removalIDs(from: [newest, oldest, middle], now: now)

        XCTAssertEqual(removals, Set([oldest.id, middle.id]))
    }

    func testClipboardSignatureKeepsDifferentFormattingSeparate() {
        let plain = ClipboardCapture.signature(
            kind: .text,
            representations: [("public.utf8-plain-text", Data("hello".utf8))]
        )
        let rich = ClipboardCapture.signature(
            kind: .text,
            representations: [
                ("public.utf8-plain-text", Data("hello".utf8)),
                ("public.rtf", Data("{\\rtf1 hello}".utf8)),
            ]
        )

        XCTAssertNotEqual(plain, rich)
    }

    func testClipboardEncryptionRejectsTampering() throws {
        let cryptor = AESClipboardCryptor(
            key: SymmetricKey(data: Data(repeating: 7, count: 32))
        )
        let additionalData = Data("test-context".utf8)
        var encrypted = try cryptor.seal(
            Data("private clipboard text".utf8),
            authenticating: additionalData
        )
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0x01

        XCTAssertThrowsError(
            try cryptor.open(encrypted, authenticating: additionalData)
        )
    }

    func testClipboardRepositoryEncryptsIndexAndPayloadRoundTrip() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let payload = ClipboardPayload.text(
            plainText: "phase-three-secret",
            rtfData: nil,
            rtfdData: nil,
            htmlData: nil
        )
        var item = clipboardItem(capturedAt: Date())
        item.storedByteCount = try repository.savePayload(payload, id: item.payloadID)
        let archive = ClipboardArchive(items: [item])

        try repository.save(archive)

        let reloadedArchive = try repository.load()
        let reloadedItem = try XCTUnwrap(reloadedArchive.items.first)
        XCTAssertEqual(reloadedArchive.items.count, 1)
        XCTAssertEqual(reloadedItem.id, item.id)
        XCTAssertEqual(
            reloadedItem.capturedAt.timeIntervalSince1970,
            item.capturedAt.timeIntervalSince1970,
            accuracy: 0.001
        )
        XCTAssertEqual(try repository.payload(for: item), payload)

        let indexData = try Data(
            contentsOf: fixture.rootURL.appendingPathComponent("History.enc")
        )
        let payloadData = try Data(
            contentsOf: fixture.rootURL
                .appendingPathComponent("Payloads")
                .appendingPathComponent("\(item.payloadID.uuidString).enc")
        )
        XCTAssertNil(indexData.range(of: Data("phase-three-secret".utf8)))
        XCTAssertNil(payloadData.range(of: Data("phase-three-secret".utf8)))
    }

    func testClipboardCaptureSkipsSensitivePasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("DroppyTests-\(UUID().uuidString)")
        )
        pasteboard.declareTypes(
            [.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")],
            owner: nil
        )
        pasteboard.setString("do not store", forType: .string)

        XCTAssertNil(
            ClipboardCaptureReader.capture(
                from: pasteboard,
                sourceApplication: nil
            )
        )
    }

    func testAccessibilityAuthorizerChecksTrustWithoutPrompting() {
        var requestCount = 0
        let authorizer = AccessibilityPasteAuthorizer(
            isTrusted: { true },
            requestPermission: {
                requestCount += 1
                return false
            }
        )

        XCTAssertTrue(authorizer.canPostPasteEvent())
        XCTAssertTrue(authorizer.canPostPasteEvent())
        XCTAssertEqual(requestCount, 0)
    }

    func testAccessibilityAuthorizerPromptsOnlyOncePerLaunch() {
        var requestCount = 0
        let authorizer = AccessibilityPasteAuthorizer(
            isTrusted: { false },
            requestPermission: {
                requestCount += 1
                return false
            }
        )

        XCTAssertFalse(authorizer.canPostPasteEvent())
        XCTAssertFalse(authorizer.canPostPasteEvent())
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testImageRestorePublishesPNGAndTIFF() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 12, height: 8)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .image
        item.title = "Image"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("DroppyImagePasteTests-\(UUID().uuidString)")
        )

        XCTAssertTrue(manager.restoreToPasteboard(item, pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), imageData)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    @MainActor
    func testImageDragPublishesFileURLAndPNGData() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 10, height: 6)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .screenshot
        item.title = "Capture.png"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )

        var dragContent: ClipboardDragContent? = manager.dragContent(for: item)
        let pasteboardItem = try XCTUnwrap(
            dragContent?.writers.first as? NSPasteboardItem
        )
        let fileURL = try XCTUnwrap(
            pasteboardItem.string(forType: .fileURL).flatMap(URL.init(string:))
        )
        defer {
            try? FileManager.default.removeItem(
                at: fileURL.deletingLastPathComponent()
            )
        }

        XCTAssertEqual(fileURL.lastPathComponent, "Capture.png")
        XCTAssertEqual(try Data(contentsOf: fileURL), imageData)
        XCTAssertEqual(pasteboardItem.data(forType: .png), imageData)
        XCTAssertNotNil(pasteboardItem.data(forType: .tiff))

        dragContent = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func testImageItemProviderLoadsChatCompatibleFileRepresentation() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let imageData = try testPNGData(width: 9, height: 7)
        var item = clipboardItem(capturedAt: Date())
        item.kind = .image
        item.title = "Chat Image"
        item.storedByteCount = try repository.savePayload(
            .image(data: imageData, typeIdentifier: UTType.png.identifier),
            id: item.payloadID
        )
        try repository.save(ClipboardArchive(items: [item]))
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let provider = manager.itemProvider(for: item)
        let loaded = expectation(description: "Chat-compatible image file loads")

        provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
            XCTAssertNil(error)
            XCTAssertEqual(url?.lastPathComponent, "Chat Image.png")
            XCTAssertEqual(url.flatMap { try? Data(contentsOf: $0) }, imageData)
            if let url {
                try? FileManager.default.removeItem(
                    at: url.deletingLastPathComponent()
                )
            }
            loaded.fulfill()
        }

        wait(for: [loaded], timeout: 2)
    }

    func testDragExportCleanupRemovesOnlyExpiredDirectories() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DroppyDragExportTests-\(UUID().uuidString)",
                isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let now = Date()
        let currentExport = try ClipboardDragExportStore.makeExport(
            data: Data("current".utf8),
            fileName: "Current.png",
            rootURL: rootURL,
            now: now
        )
        let oldExport = try ClipboardDragExportStore.makeExport(
            data: Data("old".utf8),
            fileName: "Old.png",
            rootURL: rootURL,
            now: now.addingTimeInterval(
                -ClipboardDragExportStore.retentionDuration - 1
            )
        )

        ClipboardDragExportStore.removeExpired(in: rootURL, now: now)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldExport.directoryURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: currentExport.fileURL.path)
        )
    }

    func testScreenshotMonitorFindsDocumentsScreenshotsFolder() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let screenshotURL = screenshotFolder.appendingPathComponent("capture.png")
        try testPNGData().write(to: screenshotURL)

        let createdAt = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: createdAt],
            ofItemAtPath: screenshotURL.path
        )
        let monitor = ScreenshotMonitor(configuredRootURL: fixture.rootURL)

        let results = monitor.screenshots(
            createdAfter: createdAt.addingTimeInterval(-1),
            through: createdAt.addingTimeInterval(1)
        )

        XCTAssertEqual(results.map(\.standardizedFileURL), [screenshotURL.standardizedFileURL])
    }

    func testLegacyNumericDateClipboardArchiveMigrates() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let legacyURL = fixture.rootURL.deletingLastPathComponent()
            .appendingPathComponent("clipboard_history.json")
        let now = Date()
        let legacyJSON: [[String: Any]] = [[
            "content": "legacy text",
            "date": now.timeIntervalSinceReferenceDate,
            "sourceApp": "TextEdit",
            "type": "text",
            "isConcealed": false,
        ]]
        let data = try JSONSerialization.data(withJSONObject: legacyJSON)
        try data.write(to: legacyURL)

        let captures = repository.legacyCaptures(now: now)

        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.payload.plainText, "legacy text")
    }

    func testSnippetCaptureCommandsMatchEachMode() {
        let destination = URL(fileURLWithPath: "/tmp/snippet.png")

        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .region,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-i", "-s", "-x", "/tmp/snippet.png"]
        )
        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .window,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-i", "-w", "-x", "/tmp/snippet.png"]
        )
        XCTAssertEqual(
            SnippetCaptureCommand.arguments(
                for: .fullScreen,
                displayNumber: 2,
                destinationURL: destination
            ),
            ["-x", "-D", "2", "/tmp/snippet.png"]
        )
    }

    func testSnippetStorageUsesNestedScreenshotFolderAndAvoidsCollisions() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let storage = SnippetStorage(
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let image = try testCGImage(width: 20, height: 12)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try storage.save(image, at: date)
        let second = try storage.save(image, at: date)

        XCTAssertEqual(first.deletingLastPathComponent(), screenshotFolder)
        XCTAssertEqual(second.deletingLastPathComponent(), screenshotFolder)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.deletingPathExtension().lastPathComponent.suffix(2), " 2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    @MainActor
    func testSnippetDocumentUndoRedoAndCropRendering() throws {
        let document = SnippetDocument(
            sourceImage: try testCGImage(width: 100, height: 80)
        )
        document.selectedTool = .rectangle
        document.beginGesture(at: CGPoint(x: 0.1, y: 0.1))
        document.continueGesture(to: CGPoint(x: 0.5, y: 0.5))
        document.endGesture()

        XCTAssertEqual(document.annotations.count, 1)
        XCTAssertTrue(document.canUndo)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertTrue(document.canRedo)
        document.redo()
        XCTAssertEqual(document.annotations.count, 1)

        document.selectedTool = .crop
        document.beginGesture(at: CGPoint(x: 0.25, y: 0.25))
        document.continueGesture(to: CGPoint(x: 0.75, y: 0.75))
        document.endGesture()

        let output = try XCTUnwrap(document.renderedImage())
        XCTAssertEqual(output.width, 50)
        XCTAssertEqual(output.height, 40)
    }

    @MainActor
    func testSnippetLongStrokeCommitsAsOneUndoStep() throws {
        let document = SnippetDocument(
            sourceImage: try testCGImage(width: 200, height: 120)
        )
        document.selectedTool = .pen
        document.beginGesture(at: CGPoint(x: 0.05, y: 0.5))
        for step in 1...100 {
            document.continueGesture(
                to: CGPoint(x: 0.05 + CGFloat(step) * 0.008, y: 0.5)
            )
        }
        document.endGesture()

        XCTAssertEqual(document.annotations.count, 1)
        document.undo()
        XCTAssertTrue(document.annotations.isEmpty)
        XCTAssertFalse(document.canUndo)
    }

    func testSnippetRedactionIsFullyOpaque() throws {
        let output = try XCTUnwrap(
            SnippetRenderer.render(
                sourceImage: testCGImage(width: 20, height: 20),
                annotations: [
                    .redact(rect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
                ],
                cropRect: nil
            )
        )
        guard
            let data = output.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            return XCTFail("Missing rendered pixel data")
        }
        let bytesPerRow = output.bytesPerRow
        let offset = 10 * bytesPerRow + 10 * 4

        XCTAssertEqual(bytes[offset], 0)
        XCTAssertEqual(bytes[offset + 1], 0)
        XCTAssertEqual(bytes[offset + 2], 0)
        XCTAssertEqual(bytes[offset + 3], 255)
    }

    @MainActor
    func testSnippetIngestCreatesOneScreenshotClipboardItem() throws {
        let fixture = try ClipboardTestFixture()
        let repository = try fixture.repository()
        let manager = ClipboardManagerFeature(
            repository: repository,
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        let screenshotURL = fixture.rootURL.appendingPathComponent("Snippet.png")
        try testPNGData().write(to: screenshotURL)
        var notificationCount = 0
        manager.onScreenshotCaptured = { _, _ in
            notificationCount += 1
        }

        let item = try XCTUnwrap(manager.ingestSnippet(at: screenshotURL))

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(item.kind, .screenshot)
        XCTAssertEqual(item.sourceAppName, "Mission Control Snippet")
        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(manager.payload(for: item)?.screenshotOriginalPath, screenshotURL.path)
    }

    @MainActor
    func testSnippetIngestPreservesUnrelatedScreenshotBeforeCheckpoint() throws {
        let fixture = try ClipboardTestFixture()
        let screenshotFolder = fixture.rootURL.appendingPathComponent(
            "Screenshots",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: screenshotFolder,
            withIntermediateDirectories: true
        )
        let suiteName = "DroppySnippetTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ClipboardManagerFeature(
            repository: try fixture.repository(),
            settings: Settings(defaults: defaults),
            screenshotMonitor: ScreenshotMonitor(configuredRootURL: fixture.rootURL)
        )
        manager.start()
        defer { manager.stop() }

        let firstDate = Date().addingTimeInterval(0.1)
        let unrelatedURL = screenshotFolder.appendingPathComponent("Unrelated.png")
        let snippetURL = screenshotFolder.appendingPathComponent("Snippet.png")
        try testPNGData(width: 4, height: 4).write(to: unrelatedURL)
        try testPNGData(width: 5, height: 5).write(to: snippetURL)
        try FileManager.default.setAttributes(
            [.modificationDate: firstDate],
            ofItemAtPath: unrelatedURL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: firstDate.addingTimeInterval(0.1)],
            ofItemAtPath: snippetURL.path
        )
        var notificationCount = 0
        manager.onScreenshotCaptured = { _, _ in
            notificationCount += 1
        }

        XCTAssertNotNil(
            manager.ingestSnippet(
                at: snippetURL,
                date: firstDate.addingTimeInterval(0.2)
            )
        )

        XCTAssertEqual(manager.items.count, 2)
        XCTAssertEqual(
            Set(manager.items.map(\.title)),
            Set(["Unrelated.png", "Snippet.png"])
        )
        XCTAssertEqual(notificationCount, 2)
    }

    func testFileFinderScannerSearchesRecursivelyAndSkipsHiddenItems() throws {
        let fixture = try PhaseFiveTestFixture()
        let nested = try fixture.createFolder(named: "Projects/Nested")
        try fixture.createFile(named: "Projects/Nested/dashboard-listener.sh")
        try fixture.createFile(named: "Projects/.private-listener.sh")
        try fixture.createFile(named: "unrelated.txt")

        let results = FileFinderScanner.scan(
            rootURL: fixture.rootURL,
            query: "listener"
        )

        XCTAssertEqual(results.map(\.displayName), ["dashboard-listener.sh"])
        XCTAssertEqual(results.first?.parentPath, nested.path)
    }

    func testFileFinderScannerHonorsResultLimitAndCancellation() throws {
        let fixture = try PhaseFiveTestFixture()
        for index in 0..<8 {
            try fixture.createFile(named: "match-\(index).txt")
        }

        XCTAssertEqual(
            FileFinderScanner.scan(
                rootURL: fixture.rootURL,
                query: "match",
                maximumResults: 3
            ).count,
            3
        )
        XCTAssertTrue(
            FileFinderScanner.scan(
                rootURL: fixture.rootURL,
                query: "match",
                isCancelled: { true }
            ).isEmpty
        )
    }

    @MainActor
    func testFileFavoritesPersistAcrossRelaunch() throws {
        let fixture = try PhaseFiveTestFixture()
        let first = try fixture.createFolder(named: "First")
        let second = try fixture.createFolder(named: "Second")
        let storeURL = fixture.rootURL.appendingPathComponent("Favorites.json")
        let feature = FileFinderFeature(
            store: FileFinderStore(fileURL: storeURL),
            defaultFavorites: [first]
        )

        feature.addFavorite(second)
        let reloaded = FileFinderFeature(
            store: FileFinderStore(fileURL: storeURL),
            defaultFavorites: []
        )

        XCTAssertEqual(
            Set(reloaded.favorites.map(\.lastKnownPath)),
            Set([first.path, second.path])
        )
        XCTAssertEqual(reloaded.selectedDirectoryURL.path, second.path)
    }

    func testCorruptFileFavoritesAreNotOverwritten() throws {
        let fixture = try PhaseFiveTestFixture()
        let storeURL = fixture.rootURL.appendingPathComponent("Favorites.json")
        let original = Data("{not-json".utf8)
        try original.write(to: storeURL)
        let store = FileFinderStore(fileURL: storeURL)

        guard case .failed = store.load() else {
            return XCTFail("Expected a failed favorites load")
        }
        XCTAssertFalse(store.save(FileFinderArchive()))
        XCTAssertEqual(try Data(contentsOf: storeURL), original)
    }

    func testFavoriteBookmarkRefreshesAfterFolderMoves() throws {
        let fixture = try PhaseFiveTestFixture()
        let originalURL = try fixture.createFolder(named: "Original")
        let movedURL = fixture.rootURL.appendingPathComponent(
            "Moved",
            isDirectory: true
        )
        var favorite = FavoriteFolder(url: originalURL)

        try FileManager.default.moveItem(at: originalURL, to: movedURL)

        XCTAssertTrue(favorite.refreshResolvedReference())
        XCTAssertEqual(
            favorite.lastKnownPath,
            movedURL.standardizedFileURL.path
        )
        XCTAssertEqual(
            favorite.resolvedURL.standardizedFileURL.path,
            movedURL.standardizedFileURL.path
        )
    }

    @MainActor
    func testNotesAutosaveAndReload() throws {
        let fixture = try PhaseFiveTestFixture()
        let storeURL = fixture.rootURL.appendingPathComponent("Notes.json")
        let feature = NotesFeature(store: NotesStore(fileURL: storeURL))

        feature.createNote(at: Date(timeIntervalSince1970: 100))
        feature.updateSelectedTitle(
            "Dashboard commands",
            at: Date(timeIntervalSince1970: 110)
        )
        feature.updateSelectedBody(
            "./generator.sh\n./listener.sh",
            at: Date(timeIntervalSince1970: 120)
        )
        XCTAssertTrue(feature.flushPendingSave())
        let reloaded = NotesFeature(store: NotesStore(fileURL: storeURL))

        XCTAssertEqual(reloaded.activeNotes.count, 1)
        XCTAssertEqual(reloaded.activeNotes.first?.title, "Dashboard commands")
        XCTAssertEqual(
            reloaded.activeNotes.first?.body,
            "./generator.sh\n./listener.sh"
        )
    }

    @MainActor
    func testNotesTrashPrunesAfterThirtyDays() throws {
        let fixture = try PhaseFiveTestFixture()
        let storeURL = fixture.rootURL.appendingPathComponent("Notes.json")
        let deletedAt = Date(timeIntervalSince1970: 1_000)
        let expired = DroppyNote(
            title: "Expired",
            createdAt: deletedAt,
            deletedAt: deletedAt
        )
        let recent = DroppyNote(
            title: "Recent",
            createdAt: deletedAt,
            deletedAt: deletedAt.addingTimeInterval(10)
        )
        XCTAssertTrue(
            NotesStore(fileURL: storeURL).save(
                NotesArchive(notes: [expired, recent])
            )
        )

        let now = deletedAt.addingTimeInterval(NotesFeature.trashLifetime + 5)
        let feature = NotesFeature(
            store: NotesStore(fileURL: storeURL),
            now: now
        )

        XCTAssertEqual(feature.trashedNotes.map(\.title), ["Recent"])
    }

    @MainActor
    func testNotesSearchSelectsAVisibleResult() throws {
        let fixture = try PhaseFiveTestFixture()
        let feature = NotesFeature(
            store: NotesStore(
                fileURL: fixture.rootURL.appendingPathComponent("Notes.json")
            )
        )
        let first = feature.createNote()
        feature.updateSelectedTitle("Generator")
        feature.createNote()
        feature.updateSelectedTitle("Listener")

        feature.searchText = "Generator"

        XCTAssertEqual(feature.displayedNotes.map(\.id), [first.id])
        XCTAssertEqual(feature.selectedNoteID, first.id)
    }

    @MainActor
    func testFailedNoteRestoreStaysInTrash() throws {
        let fixture = try PhaseFiveTestFixture()
        let storeURL = fixture.rootURL.appendingPathComponent("Notes.json")
        let deletedNote = DroppyNote(
            title: "Keep in Trash",
            deletedAt: Date()
        )
        XCTAssertTrue(
            NotesStore(fileURL: storeURL).save(
                NotesArchive(notes: [deletedNote])
            )
        )
        let feature = NotesFeature(
            store: NotesStore(
                fileURL: storeURL,
                writer: { _, _ in false }
            )
        )
        feature.select(deletedNote.id)

        feature.restoreSelected()

        XCTAssertTrue(feature.isShowingTrash)
        XCTAssertNotNil(feature.selectedNote?.deletedAt)
        XCTAssertNotNil(feature.storageErrorMessage)
    }

    func testCorruptNotesAreNotOverwritten() throws {
        let fixture = try PhaseFiveTestFixture()
        let storeURL = fixture.rootURL.appendingPathComponent("Notes.json")
        let original = Data("[broken".utf8)
        try original.write(to: storeURL)
        let store = NotesStore(fileURL: storeURL)

        guard case .failed = store.load() else {
            return XCTFail("Expected a failed notes load")
        }
        XCTAssertFalse(store.save(NotesArchive()))
        XCTAssertEqual(try Data(contentsOf: storeURL), original)
    }

    func testNoteMarkdownExportUsesSafeFilename() {
        let note = DroppyNote(
            title: "Run: Dashboard/Scripts",
            body: "```sh\n./listener.sh\n```"
        )

        XCTAssertEqual(note.exportFileName, "Run- Dashboard-Scripts.md")
        XCTAssertEqual(
            note.markdown,
            "# Run: Dashboard/Scripts\n\n```sh\n./listener.sh\n```"
        )
    }

    func testUnifiedSearchRanksExactTitleBeforeMetadataMatch() {
        let exact = UnifiedSearchResult(
            id: "exact",
            source: .notes,
            target: .note(UUID()),
            title: "listener",
            subtitle: "",
            relevance: UnifiedSearchFeature.relevance(
                title: "listener",
                metadata: "",
                query: "listener"
            )
        )
        let metadata = UnifiedSearchResult(
            id: "metadata",
            source: .files,
            target: .file(URL(fileURLWithPath: "/tmp/generator.sh")),
            title: "generator.sh",
            subtitle: "/scripts/listener",
            relevance: UnifiedSearchFeature.relevance(
                title: "generator.sh",
                metadata: "/scripts/listener",
                query: "listener"
            )
        )

        XCTAssertEqual(
            UnifiedSearchFeature.sorted([metadata, exact]).map(\.id),
            ["exact", "metadata"]
        )
    }

    func testUnifiedSearchLimitsAfterRanking() {
        let weakMatches = (0..<13).map { index in
            UnifiedSearchResult(
                id: "weak-\(index)",
                source: .notes,
                target: .note(UUID()),
                title: "Note \(index)",
                subtitle: "listener metadata",
                relevance: 100
            )
        }
        let exact = UnifiedSearchResult(
            id: "exact",
            source: .notes,
            target: .note(UUID()),
            title: "listener",
            subtitle: "",
            relevance: 400
        )

        let results = UnifiedSearchFeature.topResults(
            weakMatches + [exact],
            maximum: 12
        )

        XCTAssertEqual(results.first?.id, "exact")
        XCTAssertEqual(results.count, 12)
    }

    @MainActor
    func testTerminalFeatureRetainsMultipleIndependentSessions() {
        let feature = TerminalFeature()
        let first = feature.newSession(
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        let second = feature.newSession(
            currentDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )

        XCTAssertEqual(feature.sessions.count, 2)
        XCTAssertEqual(feature.selectedSessionID, second.id)
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(second.state, .ready)

        feature.close(first)
        XCTAssertEqual(feature.sessions.map(\.id), [second.id])
    }

    @MainActor
    func testTerminalSessionStartsAndStopsPTY() async {
        let session = TerminalSessionController(
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        session.startIfNeeded()
        let processID = session.terminalView.process.shellPid
        let processIdentity = try? XCTUnwrap(
            TerminalProcessTree.identity(for: processID)
        )
        XCTAssertGreaterThan(processID, 0)
        XCTAssertTrue(TerminalProcessTree.isAlive(processID))
        let stopped = expectation(description: "PTY stopped")

        session.terminate { stoppedSuccessfully in
            XCTAssertTrue(stoppedSuccessfully)
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 3)

        XCTAssertFalse(
            processIdentity.map(TerminalProcessTree.isAlive) ?? true
        )
        guard case .exited = session.state else {
            return XCTFail("Expected the terminal session to exit")
        }
    }

    func testTerminalProcessIdentityRejectsReusedPID() throws {
        let identity = try XCTUnwrap(
            TerminalProcessTree.identity(for: getpid())
        )
        XCTAssertTrue(TerminalProcessTree.isAlive(identity))

        let differentProcess = TerminalProcessIdentity(
            pid: identity.pid,
            startSeconds: identity.startSeconds,
            startMicroseconds: identity.startMicroseconds &+ 1
        )
        XCTAssertFalse(TerminalProcessTree.isAlive(differentProcess))
    }

    func testTerminalProcessTreeStopsChildCommands() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30 & wait"]
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let deadline = Date().addingTimeInterval(1)
        while
            TerminalProcessTree.childPIDs(
                of: process.processIdentifier
            ).isEmpty,
            Date() < deadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let childProcessIDs = TerminalProcessTree.childPIDs(
            of: process.processIdentifier
        )
        XCTAssertFalse(childProcessIDs.isEmpty)
        let trackedProcessIDs = Set(
            childProcessIDs + [process.processIdentifier]
        )

        TerminalProcessTree.signal(
            processIDs: trackedProcessIDs,
            rootPID: process.processIdentifier,
            signal: SIGTERM
        )
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(
            trackedProcessIDs.contains(where: TerminalProcessTree.isAlive)
        )
        TerminalProcessTree.signal(
            processIDs: trackedProcessIDs,
            rootPID: process.processIdentifier,
            signal: SIGKILL
        )
        process.waitUntilExit()

        let exitDeadline = Date().addingTimeInterval(1)
        while
            trackedProcessIDs.contains(where: TerminalProcessTree.isAlive),
            Date() < exitDeadline
        {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(
            trackedProcessIDs.contains(where: TerminalProcessTree.isAlive)
        )
    }

    @MainActor
    func testTerminalRestartWaitsForOldProcessTree() async {
        let session = TerminalSessionController(
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        session.startIfNeeded()
        let oldTerminalView = session.terminalView
        let oldRootPID = session.terminalView.process.shellPid
        session.sendCommand("trap '' TERM; sleep 30 & wait")

        let childDeadline = Date().addingTimeInterval(4)
        while
            TerminalProcessTree.childPIDs(of: oldRootPID).isEmpty,
            Date() < childDeadline
        {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let oldProcessIdentities = TerminalProcessTree.identities(
            for: TerminalProcessTree.childPIDs(of: oldRootPID) + [oldRootPID]
        )
        XCTAssertGreaterThan(oldProcessIdentities.count, 1)

        session.restart()
        let restartDeadline = Date().addingTimeInterval(4)
        while
            (
                session.terminalView.process.shellPid == oldRootPID
                    || !session.state.isRunning
            ),
            Date() < restartDeadline
        {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(session.state.isRunning)
        XCTAssertTrue(session.terminalView.process.running)
        XCTAssertFalse(session.terminalView === oldTerminalView)
        XCTAssertNotEqual(
            session.terminalView.process.shellPid,
            oldRootPID
        )
        XCTAssertFalse(
            oldProcessIdentities.contains(
                where: TerminalProcessTree.isAlive
            )
        )
        session.processTerminated(source: oldTerminalView, exitCode: 0)
        let replacementTitle = session.title
        let replacementDirectory = session.currentDirectoryURL
        session.setTerminalTitle(
            source: oldTerminalView,
            title: "Stale terminal"
        )
        session.hostCurrentDirectoryUpdate(
            source: oldTerminalView,
            directory: "/stale/directory"
        )
        await Task.yield()
        XCTAssertTrue(session.state.isRunning)
        XCTAssertTrue(session.terminalView.process.running)
        XCTAssertEqual(session.title, replacementTitle)
        XCTAssertEqual(session.currentDirectoryURL, replacementDirectory)

        let stopped = expectation(description: "Replacement PTY stopped")
        session.terminate { stoppedSuccessfully in
            XCTAssertTrue(stoppedSuccessfully)
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 3)
    }

    @MainActor
    func testExplicitTerminateCancelsPendingRestart() async {
        let session = TerminalSessionController(
            currentDirectoryURL: URL(fileURLWithPath: "/tmp")
        )
        session.startIfNeeded()
        let oldRootPID = session.terminalView.process.shellPid
        session.sendCommand("trap '' TERM; sleep 30 & wait")

        let childDeadline = Date().addingTimeInterval(4)
        while
            TerminalProcessTree.childPIDs(of: oldRootPID).isEmpty,
            Date() < childDeadline
        {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        let oldProcessIdentities = TerminalProcessTree.identities(
            for: TerminalProcessTree.childPIDs(of: oldRootPID) + [oldRootPID]
        )
        XCTAssertGreaterThan(oldProcessIdentities.count, 1)

        session.restart()
        let stopped = expectation(description: "Restart cancelled by terminate")
        session.terminate { stoppedSuccessfully in
            XCTAssertTrue(stoppedSuccessfully)
            stopped.fulfill()
        }
        await fulfillment(of: [stopped], timeout: 4)

        guard case .exited = session.state else {
            return XCTFail("Expected explicit termination to prevent restart")
        }
        XCTAssertEqual(session.terminalView.process.shellPid, oldRootPID)
        XCTAssertFalse(
            oldProcessIdentities.contains(
                where: TerminalProcessTree.isAlive
            )
        )
    }

    private func clipboardItem(
        capturedAt: Date,
        pinnedAt: Date? = nil,
        bytes: Int64 = 10
    ) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            kind: .text,
            title: "Text",
            subtitle: "4 characters",
            sourceAppName: "Tests",
            sourceBundleIdentifier: nil,
            createdAt: capturedAt,
            capturedAt: capturedAt,
            pinnedAt: pinnedAt,
            signature: UUID().uuidString,
            payloadID: UUID(),
            storedByteCount: bytes,
            searchText: "text",
            ocrText: nil
        )
    }

    private func testPNGData(width: CGFloat = 4, height: CGFloat = 4) throws -> Data {
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.unlockFocus()
        return try XCTUnwrap(image.pngData)
    }

    private func testCGImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw NSError(domain: "DroppyTests", code: 1)
        }
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

private final class MediaClientSpy: MediaClientProtocol {
    private(set) var fetchRequests: [MediaCancellation] = []
    private var fetchCompletions:
        [(Result<MediaSnapshot, MediaIssue>) -> Void] = []
    private var performCompletions:
        [(Result<Void, MediaIssue>) -> Void] = []

    func fetch(
        completion: @escaping (Result<MediaSnapshot, MediaIssue>) -> Void
    ) -> MediaCancellation {
        let cancellation = MediaCancellation()
        fetchRequests.append(cancellation)
        fetchCompletions.append(completion)
        return cancellation
    }

    func perform(
        command: MediaCommand,
        completion: @escaping (Result<Void, MediaIssue>) -> Void
    ) -> MediaCancellation {
        performCompletions.append(completion)
        return MediaCancellation()
    }

    func completeLatestFetch(
        _ result: Result<MediaSnapshot, MediaIssue>
    ) {
        fetchCompletions.last?(result)
    }

    func completeLatestPerform(_ result: Result<Void, MediaIssue>) {
        performCompletions.last?(result)
    }
}

private final class PhaseFiveTestFixture {
    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DroppyPhaseFiveTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    @discardableResult
    func createFolder(named relativePath: String) throws -> URL {
        let url = rootURL.appendingPathComponent(
            relativePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @discardableResult
    func createFile(named relativePath: String) throws -> URL {
        let url = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("fixture".utf8).write(to: url)
        return url
    }
}

private final class ShelfTestFixture {
    let rootURL: URL
    let storeURL: URL
    let store: ShelfStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppyShelfTests-\(UUID().uuidString)", isDirectory: true)
        storeURL = rootURL.appendingPathComponent("Shelf.json")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = ShelfStore(fileURL: storeURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func createFile(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func createFolder(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class ClipboardTestFixture {
    let containerURL: URL
    let rootURL: URL

    init() throws {
        containerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroppyClipboardTests-\(UUID().uuidString)", isDirectory: true)
        rootURL = containerURL
            .appendingPathComponent("Droppy", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func repository() throws -> ClipboardRepository {
        try ClipboardRepository(
            rootURL: rootURL,
            cryptor: AESClipboardCryptor(
                key: SymmetricKey(data: Data(repeating: 3, count: 32))
            )
        )
    }
}

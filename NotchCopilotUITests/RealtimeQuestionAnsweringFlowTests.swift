import XCTest

final class RealtimeQuestionAnsweringFlowTests: XCTestCase {
    @MainActor
    func testQuestionAnswerHarnessSupportsAnswerTranscriptModeSwitching() {
        setenv("XCTDisableRuntimeIssues", "YES", 1)
        addTeardownBlock {
            unsetenv("XCTDisableRuntimeIssues")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--qa-ui-harness"]
        app.launchEnvironment["NOTCHCOPILOT_QA_UI_HARNESS"] = "1"
        app.launch()
        addTeardownBlock {
            app.terminate()
        }

        let harness = app.windows["Notchly QA UI Harness"]
        XCTAssertTrue(harness.waitForExistence(timeout: 8))
        XCTAssertTrue(anyElement(in: harness, "meeting-panel").waitForExistence(timeout: 8))
        XCTAssertTrue(anyElement(in: harness, "qa-question-title").waitForExistence(timeout: 4))

        let answerToggle = anyElement(in: harness, "qa-toggle-answer")
        let transcriptToggle = anyElement(in: harness, "qa-toggle-transcript")
        XCTAssertTrue(answerToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(transcriptToggle.waitForExistence(timeout: 3))
        XCTAssertTrue(anyElement(in: harness, "qa-question-spinner").waitForExistence(timeout: 3))
        XCTAssertFalse(anyElement(in: harness, "qa-stage-indicator").exists)

        transcriptToggle.click()
        XCTAssertTrue(anyElement(in: harness, "qa-transcript-stream").waitForExistence(timeout: 3))

        answerToggle.click()
        XCTAssertTrue(anyElement(in: harness, "qa-answer-scroll").waitForExistence(timeout: 3))

        XCTAssertFalse(anyElement(in: harness, "qa-action-copy").exists)
        XCTAssertFalse(anyElement(in: harness, "qa-action-save").exists)
        XCTAssertFalse(anyElement(in: harness, "qa-action-dismiss").exists)
        XCTAssertTrue(anyElement(in: harness, "qa-question-title").waitForExistence(timeout: 2))
    }

    @MainActor
    func testQuestionAnswerHarnessExposesTranscriptInlineActions() {
        setenv("XCTDisableRuntimeIssues", "YES", 1)
        addTeardownBlock {
            unsetenv("XCTDisableRuntimeIssues")
        }

        let app = XCUIApplication()
        app.launchArguments = ["--qa-ui-harness"]
        app.launchEnvironment["NOTCHCOPILOT_QA_UI_HARNESS"] = "1"
        app.launch()
        addTeardownBlock {
            app.terminate()
        }

        let harness = app.windows["Notchly QA UI Harness"]
        XCTAssertTrue(harness.waitForExistence(timeout: 8))
        let transcriptToggle = anyElement(in: harness, "qa-toggle-transcript")
        XCTAssertTrue(transcriptToggle.waitForExistence(timeout: 3))

        transcriptToggle.click()
        XCTAssertTrue(anyElement(in: harness, "qa-transcript-stream").waitForExistence(timeout: 3))

        let copyButton = anyElement(in: harness, "transcript-inline-copy")
        let deleteButton = anyElement(in: harness, "transcript-inline-delete")
        XCTAssertTrue(copyButton.waitForExistence(timeout: 3))
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        XCTAssertTrue(copyButton.isEnabled)
        XCTAssertTrue(deleteButton.isEnabled)

        copyButton.click()
        deleteButton.click()
    }

    @MainActor
    private func anyElement(in element: XCUIElement, _ identifier: String) -> XCUIElement {
        element.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

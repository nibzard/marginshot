import XCTest
@testable import MarginShot

final class ChatPresentationTests: XCTestCase {
    func testReadOnlySetupInspectionDoesNotMigrateKeyOrChangeDefaults() {
        let suite = "setup-inspection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("synthetic-key", forKey: "GeminiAPIKey")
        XCTAssertEqual(GeminiSetupStatus.inspect(defaults: defaults, readKey: { nil }), .ready)
        XCTAssertEqual(defaults.string(forKey: "GeminiAPIKey"), "synthetic-key")
        XCTAssertEqual(GeminiSetupStatus.inspect(defaults: defaults, readKey: { throw FixtureFailure.interrupted }), .secureStorageUnavailable)
    }

    func testSetupBlockedSubmissionPreservesDraftAndConversation() {
        let model = ChatViewModel()
        model.readiness = .setup
        model.draft = "A question I want to keep"
        model.send()
        XCTAssertEqual(model.draft, "A question I want to keep")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertFalse(model.isThinking)
    }

    @MainActor
    func testStaleApplyPreservesBytesAndRefreshRequiresReview() async throws {
        let fixture = DesignFixture(state: "stale")
        try await fixture.prepare()
        defer { try? FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent()) }
        let model = fixture.chatModel()
        let message = try XCTUnwrap(model.messages.last)
        let url = fixture.root.appendingPathComponent("daily/field-notes.md")
        let bytes = try Data(contentsOf: url)
        model.applyFileOps(for: message)
        for _ in 0..<100 where model.applyingMessageIds.contains(message.id) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.conflictingMessageIds.contains(message.id))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        model.refreshProposal(for: message)
        for _ in 0..<100 where model.isThinking { try await Task.sleep(for: .milliseconds(20)) }
        let refreshed = try XCTUnwrap(model.messages.last)
        XCTAssertTrue(model.mustReviewMessageIds.contains(refreshed.id))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        model.applyFileOps(for: refreshed)
        for _ in 0..<100 where model.applyingMessageIds.contains(refreshed.id) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.appliedMessageIds.contains(refreshed.id))
        let applied = try Data(contentsOf: url)
        model.applyFileOps(for: refreshed)
        XCTAssertEqual(try Data(contentsOf: url), applied)
    }
}

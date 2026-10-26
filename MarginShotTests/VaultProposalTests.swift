import XCTest
@testable import MarginShot

final class VaultProposalTests: XCTestCase {
    private var fixture: ReliabilityVaultFixture!
    override func setUp() async throws {
        fixture = try await ReliabilityVaultFixture()
        try await fixture.createNote()
    }
    override func tearDownWithError() throws { try fixture.remove() }

    func testEditBetweenRetrievalAndApplyLeavesNewerBytesUntouched() async throws {
        let context = await fixture.index.retrieveContextBundle(query: "Atlas")
        let proposal = try VaultProposal.bind([VaultFileOperation(action: .update, path: "daily/atlas.md", content: "stale replacement", noteMeta: nil)], to: context, userDefaults: fixture.defaults)
        try VaultFileStore.writeText("newer local edit", to: fixture.noteURL, userDefaults: fixture.defaults)
        do { _ = try await fixture.apply(proposal); XCTFail("Expected stale proposal rejection") }
        catch VaultRepositoryError.staleRevision(let path) { XCTAssertEqual(path, "daily/atlas.md") }
        XCTAssertEqual(try VaultFileStore.readText(from: fixture.noteURL, userDefaults: fixture.defaults), "newer local edit")
    }

    func testDeleteBetweenRetrievalAndApplyDoesNotRecreateNote() async throws {
        let context = await fixture.index.retrieveContextBundle(query: "Atlas")
        let proposal = try VaultProposal.bind([VaultFileOperation(action: .update, path: "daily/atlas.md", content: "stale replacement", noteMeta: nil)], to: context, userDefaults: fixture.defaults)
        try VaultRepository.removeItem(at: fixture.noteURL)
        do { _ = try await fixture.apply(proposal); XCTFail("Expected conflict") }
        catch VaultRepositoryError.staleRevision {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.noteURL.path))
    }

    func testDelayedDeletionCannotRemoveNewerNote() async throws {
        let context = await fixture.index.retrieveContextBundle(query: "Atlas")
        let proposal = try VaultProposal.bind([VaultFileOperation(action: .delete, path: "daily/atlas.md", content: nil, noteMeta: nil)], to: context, userDefaults: fixture.defaults)
        try VaultFileStore.writeText("newer local edit", to: fixture.noteURL, userDefaults: fixture.defaults)
        do { _ = try await fixture.apply(proposal); XCTFail("Expected conflict") }
        catch VaultRepositoryError.staleRevision {}
        XCTAssertEqual(try VaultFileStore.readText(from: fixture.noteURL, userDefaults: fixture.defaults), "newer local edit")
    }

    func testModelRevisionCannotOverrideRevisionCapturedWithRetrievalBody() async throws {
        let context = await fixture.index.retrieveContextBundle(query: "Atlas")
        let originalHash = VaultRepository.hash(try Data(contentsOf: fixture.noteURL))
        XCTAssertEqual(context.notes.first?.revision, .hash(originalHash))
        XCTAssertEqual(context.notes.first?.body, try VaultFileStore.readText(from: fixture.noteURL, userDefaults: fixture.defaults))
        try VaultFileStore.writeText("new bytes", to: fixture.noteURL, userDefaults: fixture.defaults)
        let modelRevision = try fixture.repository.revision(for: "daily/atlas.md")
        let proposed = VaultFileOperation(action: .update, path: "daily/atlas.md", content: "model edit", noteMeta: nil, expectedRevision: modelRevision)
        let bound = try VaultProposal.bind([proposed], to: context, userDefaults: fixture.defaults)
        XCTAssertEqual(bound.first?.expectedRevision, .hash(originalHash))
        do { _ = try await fixture.apply(bound); XCTFail("Expected conflict") }
        catch VaultRepositoryError.staleRevision {}
    }

    func testUnretrievedUpdatesRequireRefreshAndCreateChecksAbsence() async throws {
        let empty = ContextBundle(query: "", generatedAt: nil, notes: [], sources: [])
        let unknown = try VaultProposal.bind([VaultFileOperation(action: .update, path: "daily/atlas.md", content: "unseen edit", noteMeta: nil)], to: empty, userDefaults: fixture.defaults)
        do { _ = try await fixture.apply(unknown); XCTFail("Expected missing revision rejection") }
        catch VaultRepositoryError.staleRevision {}
        let create = try VaultProposal.bind([VaultFileOperation(action: .create, path: "daily/new.md", content: "model create", noteMeta: nil)], to: empty, userDefaults: fixture.defaults)
        let url = fixture.root.appendingPathComponent("daily/new.md")
        try VaultFileStore.writeText("local create", to: url, userDefaults: fixture.defaults)
        do { _ = try await fixture.apply(create); XCTFail("Expected create conflict") }
        catch VaultRepositoryError.staleRevision {}
        XCTAssertEqual(try VaultFileStore.readText(from: url, userDefaults: fixture.defaults), "local create")
    }
}

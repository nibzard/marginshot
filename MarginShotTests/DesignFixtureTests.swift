import XCTest
@testable import MarginShot

final class DesignFixtureTests: XCTestCase {
    @MainActor
    func testFixtureUsesScopedRootsDefaultsAndStore() async throws {
        #if !DEBUG
        XCTFail("Fixture tests require the Debug compilation condition")
        #endif
        let fixture = DesignFixture(state: "empty")
        let original = UserDefaults.standard.object(forKey: "privacySendImagesToLLM") as? Bool
        try await fixture.prepare()
        XCTAssertTrue(fixture.root.path.contains("design-fixture-"))
        XCTAssertFalse(fixture.defaults.bool(forKey: "privacySendImagesToLLM"))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "privacySendImagesToLLM") as? Bool, original)
        XCTAssertEqual(fixture.controller.container.persistentStoreDescriptions.first?.url?.path, "/dev/null")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("_system/INDEX.json").path))
        try FileManager.default.removeItem(at: fixture.root.deletingLastPathComponent())
    }
}

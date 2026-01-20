import XCTest
@testable import MarginShot

final class PipelineLogicTests: XCTestCase {
    func testQualityModeDefaultsToBalanced() {
        let suiteName = "PipelineLogicTestsDefaults"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.removePersistentDomain(forName: suiteName)

        let mode = ProcessingQualityMode.load(userDefaults: defaults ?? .standard)

        XCTAssertEqual(mode, .balanced)
    }

    func testQualityModeLoadsStoredValue() {
        let suiteName = "PipelineLogicTestsStored"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(ProcessingQualityMode.fast.rawValue, forKey: "processingQualityMode")

        let mode = ProcessingQualityMode.load(userDefaults: defaults ?? .standard)

        XCTAssertEqual(mode, .fast)
    }

    func testJSONResponseParserExtractsJSONFromText() throws {
        let payload = """
        Here is the output:
        {"rawTranscript":"Line 1","confidence":0.9,"uncertainSegments":[],"warnings":[]}
        Thanks!
        """

        let decoded = try JSONResponseParser.decode(TranscriptionPayload.self, from: payload)

        XCTAssertEqual(decoded.value.rawTranscript, "Line 1")
        XCTAssertEqual(decoded.value.confidence ?? 0, 0.9, accuracy: 0.001)
        XCTAssertTrue(decoded.rawJSON.hasPrefix("{"))
        XCTAssertTrue(decoded.rawJSON.hasSuffix("}"))
    }

    func testJSONResponseParserRejectsInvalidJSON() {
        XCTAssertThrowsError(try JSONResponseParser.decode(TranscriptionPayload.self, from: "not json")) { error in
            XCTAssertEqual(error as? ProcessingPipelineError, .invalidJSON)
        }
    }
}

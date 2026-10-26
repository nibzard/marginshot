import XCTest
@testable import MarginShot

final class GeminiPrivacyTests: XCTestCase {
    func testDisablingUploadsWhileFirstPageIsInFlightBlocksSecondPage() async throws {
        try await verifyRevocation(statusCode: 200)
    }

    func testDisablingUploadsBlocksRetryOfFirstPage() async throws {
        try await verifyRevocation(statusCode: 503)
    }

    private func verifyRevocation(statusCode: Int) async throws {
        let suite = "GeminiPrivacyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacySendImagesToLLM")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrivacyTestProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); PrivacyTestProtocol.handler = nil }
        let requests = RequestCounter()
        PrivacyTestProtocol.handler = { _ in
            requests.increment()
            defaults.set(false, forKey: "privacySendImagesToLLM")
            return (statusCode, Data("{\"candidates\":[]}".utf8))
        }
        let client = GeminiClient(configuration: GeminiConfiguration(
            apiKey: "fixture", model: "fixture", baseURL: URL(string: "https://fixture.invalid")!,
            timeout: 1, maxRetries: 1, minBackoff: 0, maxBackoff: 0
        ), session: session, allowsImageUploads: { defaults.bool(forKey: "privacySendImagesToLLM") })
        let contents = [GeminiMessage(role: "user", parts: [GeminiPart(inlineData: InlineData(mimeType: "image/jpeg", data: "AA=="))])]
        if statusCode == 200 {
            _ = try await client.generateContent(contents: contents)
        }
        do {
            _ = try await client.generateContent(contents: contents)
            XCTFail("Revoked image permission must pause the request")
        } catch GeminiClientError.imageUploadsDisabled {
            // The first request revokes permission before a next page or retry can start.
        } catch {
            XCTFail("Expected a privacy pause, received \(error)")
        }
        XCTAssertEqual(requests.value, 1)
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class PrivacyTestProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler!(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

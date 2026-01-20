import Foundation

enum GeminiClientError: Error, LocalizedError {
    case missingAPIKey
    case invalidURL
    case requestFailed(statusCode: Int, message: String?)
    case decodingFailed
    case emptyResponse
    case network(URLError)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing Gemini API key."
        case .invalidURL:
            return "Gemini endpoint URL is invalid."
        case .requestFailed(let statusCode, let message):
            if let message {
                return "Gemini request failed (\(statusCode)): \(message)"
            }
            return "Gemini request failed (\(statusCode))."
        case .decodingFailed:
            return "Gemini response decoding failed."
        case .emptyResponse:
            return "Gemini response was empty."
        case .network(let error):
            return "Network error: \(error.localizedDescription)"
        case .unexpectedResponse:
            return "Unexpected Gemini response."
        }
    }

    var isRetryable: Bool {
        switch self {
        case .requestFailed(let statusCode, _):
            return [408, 409, 425, 429, 500, 502, 503, 504].contains(statusCode)
        case .network(let error):
            return error.isRetryable
        default:
            return false
        }
    }
}

struct GeminiConfiguration {
    let apiKey: String
    let model: String
    let baseURL: URL
    let timeout: TimeInterval
    let maxRetries: Int
    let minBackoff: TimeInterval
    let maxBackoff: TimeInterval

    static func load(bundle: Bundle = .main, userDefaults: UserDefaults = .standard) throws -> GeminiConfiguration {
        let apiKey = userDefaults.string(forKey: "GeminiAPIKey")
            ?? bundle.object(forInfoDictionaryKey: "GeminiAPIKey") as? String
            ?? ""
        let model = userDefaults.string(forKey: "GeminiModelName")
            ?? bundle.object(forInfoDictionaryKey: "GeminiModelName") as? String
            ?? "gemini-1.5-flash"
        let baseURLString = userDefaults.string(forKey: "GeminiBaseURL")
            ?? bundle.object(forInfoDictionaryKey: "GeminiBaseURL") as? String
            ?? "https://generativelanguage.googleapis.com"

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiClientError.missingAPIKey
        }
        guard let baseURL = URL(string: baseURLString) else {
            throw GeminiClientError.invalidURL
        }

        return GeminiConfiguration(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            timeout: 60,
            maxRetries: 3,
            minBackoff: 0.5,
            maxBackoff: 8
        )
    }
}

final class GeminiClient {
    private let configuration: GeminiConfiguration
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(configuration: GeminiConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    static func makeDefault() throws -> GeminiClient {
        try GeminiClient(configuration: GeminiConfiguration.load())
    }

    func generateText(
        prompt: String,
        systemInstruction: String? = nil,
        generationConfig: GenerationConfig? = nil
    ) async throws -> GeminiTextResponse {
        let userMessage = GeminiMessage(role: "user", parts: [GeminiPart(text: prompt)])
        let systemMessage = systemInstruction.map { GeminiMessage(role: "system", parts: [GeminiPart(text: $0)]) }
        let requestBody = GenerateContentRequest(
            contents: [userMessage],
            systemInstruction: systemMessage,
            generationConfig: generationConfig
        )
        let response = try await send(requestBody)
        let text = response.extractText()
        guard !text.isEmpty else {
            throw GeminiClientError.emptyResponse
        }
        return GeminiTextResponse(text: text, raw: response)
    }

    func generateContent(
        contents: [GeminiMessage],
        systemInstruction: GeminiMessage? = nil,
        generationConfig: GenerationConfig? = nil
    ) async throws -> GenerateContentResponse {
        let requestBody = GenerateContentRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
        )
        return try await send(requestBody)
    }

    private func send(_ body: GenerateContentRequest) async throws -> GenerateContentResponse {
        var lastError: Error?
        for attempt in 0...configuration.maxRetries {
            do {
                return try await execute(body)
            } catch let error as GeminiClientError {
                lastError = error
                if error.isRetryable, attempt < configuration.maxRetries {
                    try await backoffDelay(for: attempt)
                    continue
                }
                throw error
            } catch let error as URLError {
                lastError = GeminiClientError.network(error)
                if error.isRetryable, attempt < configuration.maxRetries {
                    try await backoffDelay(for: attempt)
                    continue
                }
                throw GeminiClientError.network(error)
            } catch {
                lastError = error
                throw error
            }
        }
        throw lastError ?? GeminiClientError.unexpectedResponse
    }

    private func execute(_ body: GenerateContentRequest) async throws -> GenerateContentResponse {
        var request = try makeRequest(body: body)
        request.timeoutInterval = configuration.timeout
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiClientError.unexpectedResponse
        }

        if (200...299).contains(httpResponse.statusCode) {
            do {
                return try decoder.decode(GenerateContentResponse.self, from: data)
            } catch {
                throw GeminiClientError.decodingFailed
            }
        }

        let message = (try? decoder.decode(GeminiErrorResponse.self, from: data))?.error.message
        throw GeminiClientError.requestFailed(statusCode: httpResponse.statusCode, message: message)
    }

    private func makeRequest(body: GenerateContentRequest) throws -> URLRequest {
        let path = "v1beta/models/\(configuration.model):generateContent"
        let endpoint = configuration.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func backoffDelay(for attempt: Int) async throws {
        let jitter = Double.random(in: 0.0...0.2)
        let exponential = configuration.minBackoff * pow(2, Double(attempt))
        let delay = min(configuration.maxBackoff, exponential) * (1 + jitter)
        let nanos = UInt64(delay * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

struct GeminiTextResponse {
    let text: String
    let raw: GenerateContentResponse
}

struct GenerateContentRequest: Encodable {
    let contents: [GeminiMessage]
    let systemInstruction: GeminiMessage?
    let generationConfig: GenerationConfig?
}

struct GeminiMessage: Codable {
    let role: String
    let parts: [GeminiPart]
}

struct GeminiPart: Codable {
    let text: String
}

struct GenerationConfig: Codable {
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let maxOutputTokens: Int?
    let responseMimeType: String?

    init(
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxOutputTokens: Int? = nil,
        responseMimeType: String? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxOutputTokens = maxOutputTokens
        self.responseMimeType = responseMimeType
    }
}

struct GenerateContentResponse: Decodable {
    let candidates: [Candidate]?
    let usageMetadata: UsageMetadata?

    struct Candidate: Decodable {
        let content: Content?
        let finishReason: String?
        let safetyRatings: [SafetyRating]?
    }

    struct Content: Decodable {
        let role: String?
        let parts: [Part]?
    }

    struct Part: Decodable {
        let text: String?
    }

    struct SafetyRating: Decodable {
        let category: String?
        let probability: String?
    }

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
    }

    func extractText() -> String {
        let parts = candidates?.first?.content?.parts ?? []
        return parts.compactMap { $0.text }.joined()
    }
}

struct GeminiErrorResponse: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let code: Int?
        let message: String?
        let status: String?
    }
}

private extension URLError {
    var isRetryable: Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .cannotLoadFromNetwork,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

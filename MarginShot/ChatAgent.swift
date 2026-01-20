import Foundation

enum ChatAgentError: Error, LocalizedError {
    case emptyQuery
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "Chat query is empty."
        case .invalidResponse:
            return "Chat response could not be decoded."
        }
    }
}

struct ChatResponse: Codable, Equatable {
    let answer: String
    let grounded: Bool
    let usedSources: [ContextSource]
    let fileOps: [VaultFileOperation]
    let warnings: [String]
}

final class ChatAgent {
    static let notFoundAnswer = "Not found in notes."

    private let client: GeminiClient
    private let indexStore: VaultIndexStore
    private let maxResults: Int
    private let maxLinkedNotes: Int
    private let maxCharactersPerNote: Int

    init(
        client: GeminiClient,
        indexStore: VaultIndexStore = .shared,
        maxResults: Int = 6,
        maxLinkedNotes: Int = 4,
        maxCharactersPerNote: Int = 2000
    ) {
        self.client = client
        self.indexStore = indexStore
        self.maxResults = maxResults
        self.maxLinkedNotes = maxLinkedNotes
        self.maxCharactersPerNote = maxCharactersPerNote
    }

    static func makeDefault() throws -> ChatAgent {
        ChatAgent(client: try GeminiClient.makeDefault())
    }

    func respond(to query: String, preferredBatchId: UUID? = nil) async throws -> ChatResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChatAgentError.emptyQuery
        }

        let context = await indexStore.retrieveContextBundle(
            query: trimmed,
            preferredBatchId: preferredBatchId,
            maxResults: maxResults,
            maxLinkedNotes: maxLinkedNotes,
            maxCharactersPerNote: maxCharactersPerNote
        )

        guard !context.sources.isEmpty else {
            return fallbackResponse(warnings: ["No matching sources found in the vault."])
        }

        let systemRules = ProcessingContextLoader.load().systemRules
        let systemInstruction = ChatPrompts.systemInstruction(systemRules: systemRules)
        let prompt = ChatPrompts.userPrompt(query: trimmed, context: context)

        let response = try await client.generateText(
            prompt: prompt,
            systemInstruction: systemInstruction,
            generationConfig: GenerationConfig(
                temperature: 0.2,
                maxOutputTokens: 512,
                responseMimeType: "application/json"
            )
        )

        do {
            let decoded = try JSONResponseParser.decode(ChatResponsePayload.self, from: response.text)
            return finalizeResponse(decoded.value, context: context)
        } catch {
            throw ChatAgentError.invalidResponse
        }
    }

    private func fallbackResponse(warnings: [String]) -> ChatResponse {
        ChatResponse(
            answer: Self.notFoundAnswer,
            grounded: false,
            usedSources: [],
            fileOps: [],
            warnings: warnings
        )
    }

    private func finalizeResponse(_ payload: ChatResponsePayload, context: ContextBundle) -> ChatResponse {
        let sourceLookup = Dictionary(uniqueKeysWithValues: context.sources.map { ($0.path, $0) })
        var warnings = payload.warnings
        var usedSources: [ContextSource] = []
        var seen = Set<String>()

        for reference in payload.usedSources {
            let path = reference.path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, let source = sourceLookup[path] else { continue }
            guard seen.insert(path).inserted else { continue }
            usedSources.append(source)
        }

        let isGrounded = payload.grounded && !usedSources.isEmpty
        let answer = payload.answer.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isGrounded || answer.isEmpty {
            if payload.grounded && usedSources.isEmpty {
                warnings.append("Model response did not include valid sources.")
            }
            if answer.isEmpty {
                warnings.append("Model response did not include answer text.")
            }
            return fallbackResponse(warnings: warnings)
        }

        return ChatResponse(
            answer: answer,
            grounded: true,
            usedSources: usedSources,
            fileOps: payload.fileOps,
            warnings: warnings
        )
    }
}

private struct ChatSourceReference: Codable {
    let path: String
    let title: String?
}

private struct ChatResponsePayload: Decodable {
    let answer: String
    let grounded: Bool
    let usedSources: [ChatSourceReference]
    let fileOps: [VaultFileOperation]
    let warnings: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        answer = (try? container.decode(String.self, forKey: .answer)) ?? ""
        grounded = (try? container.decode(Bool.self, forKey: .grounded)) ?? false
        usedSources = (try? container.decode([ChatSourceReference].self, forKey: .usedSources)) ?? []
        fileOps = (try? container.decode([VaultFileOperation].self, forKey: .fileOps)) ?? []
        warnings = (try? container.decode([String].self, forKey: .warnings)) ?? []
    }
}

private enum ChatPrompts {
    static func systemInstruction(systemRules: String) -> String {
        var prompt = """
        You are the MarginShot chat assistant.
        Answer only using the provided context bundle.
        If the answer is not explicitly supported, respond with "Not found in notes." and set grounded to false.
        Always return JSON only with this schema:
        {
          "answer": "string",
          "grounded": true|false,
          "usedSources": [{"path": "string", "title": "string"}],
          "fileOps": [{
            "action": "create|update|delete",
            "path": "string",
            "content": "string",
            "noteMeta": {
              "title": "string",
              "summary": "string",
              "tags": ["string"],
              "links": ["string"]
            }
          }],
          "warnings": ["string"]
        }
        usedSources must be a subset of the provided context bundle sources and must use exact path values.
        fileOps must be an empty array when no changes are requested. Paths must be vault-relative (e.g. "01_daily/2026-01-20.md").
        fileOps content must be full file contents without diffs or Markdown fences. Do not write to _system or scans.
        """

        let trimmedRules = systemRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedRules.isEmpty {
            prompt += "\n\nSystem rules:\n\(trimmedRules)"
        }
        return prompt
    }

    static func userPrompt(query: String, context: ContextBundle) -> String {
        let contextJSON = contextJSONString(context)
        return """
        User question:
        \(query)

        Context bundle (JSON):
        \(contextJSON)
        """
    }

    private static func contextJSONString(_ context: ContextBundle) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(context),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

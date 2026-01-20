import Foundation

enum ProcessingQualityMode: String, CaseIterable {
    case fast
    case balanced
    case best

    static func load(userDefaults: UserDefaults = .standard) -> ProcessingQualityMode {
        if let raw = userDefaults.string(forKey: "processingQualityMode"),
           let mode = ProcessingQualityMode(rawValue: raw) {
            return mode
        }
        return .balanced
    }
}

struct ProcessingContextSnapshot {
    let systemRules: String
    let indexJSON: String?
    let structureText: String?
    let organizationStyle: OrganizationStyle
}

enum ProcessingContextLoader {
    static func load() -> ProcessingContextSnapshot {
        let systemRules = SystemRulesStore.loadForPrompt()
        var indexJSON: String?
        var structureText: String?
        indexJSON = readVaultText(path: "_system/INDEX.json")
        structureText = readVaultText(path: "_system/STRUCTURE.txt")
        let organizationStyle = OrganizationPreferences().style

        return ProcessingContextSnapshot(
            systemRules: systemRules,
            indexJSON: indexJSON,
            structureText: structureText,
            organizationStyle: organizationStyle
        )
    }

    private static func readVaultText(path: String, maxCharacters: Int = 8000) -> String? {
        do {
            let url = try VaultScanStore.url(for: path)
            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.count > maxCharacters {
                let endIndex = contents.index(contents.startIndex, offsetBy: maxCharacters)
                return String(contents[..<endIndex])
            }
            return contents
        } catch {
            return nil
        }
    }
}

enum ProcessingPipelineError: Error {
    case invalidImageData
    case invalidJSON
    case emptyTranscript
    case emptyMarkdown
    case missingTitle
}

struct ScanProcessingInput {
    let imageData: Data
    let mimeType: String
}

struct ScanProcessingOutput {
    let transcript: TranscriptionPayload
    let transcriptJSON: String
    let structured: StructurePayload
    let structuredJSON: String
}

struct TranscriptionPayload: Codable {
    let rawTranscript: String
    let confidence: Double?
    let uncertainSegments: [String]?
    let warnings: [String]?
}

struct StructurePayload: Codable {
    let markdown: String
    let noteMeta: NoteMeta
    let classification: Classification
    let warnings: [String]?
}

struct FastProcessingPayload: Decodable {
    let rawTranscript: String
    let confidence: Double?
    let uncertainSegments: [String]?
    let markdown: String
    let noteMeta: NoteMeta
    let classification: Classification
    let warnings: [String]?
}

struct NoteMeta: Codable, Equatable {
    let title: String
    let summary: String?
    let tags: [String]?
    let links: [String]?
}

struct Classification: Codable {
    let folder: String
    let reason: String?
}

enum ScanProcessingPipeline {
    static func process(
        input: ScanProcessingInput,
        mode: ProcessingQualityMode,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> ScanProcessingOutput {
        switch mode {
        case .fast:
            return try await processFast(input: input, client: client, context: context)
        case .balanced:
            return try await processBalanced(input: input, client: client, context: context)
        case .best:
            return try await processBest(input: input, client: client, context: context)
        }
    }

    private static func processFast(
        input: ScanProcessingInput,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> ScanProcessingOutput {
        let prompt = ProcessingPrompts.fastPrompt(
            systemRules: context.systemRules,
            organizationStyle: context.organizationStyle
        )
        let response = try await client.generateContent(
            contents: [
                GeminiMessage(
                    role: "user",
                    parts: [
                        GeminiPart(text: prompt),
                        GeminiPart(inlineData: InlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()))
                    ]
                )
            ],
            systemInstruction: nil,
            generationConfig: GenerationConfig(temperature: 0.2, responseMimeType: "application/json")
        )

        let text = response.extractText()
        let decoded = try JSONResponseParser.decode(FastProcessingPayload.self, from: text)
        try validateTranscript(decoded.value.rawTranscript)
        try validateMarkdown(decoded.value.markdown, title: decoded.value.noteMeta.title)
        try validateClassification(decoded.value.classification)

        let transcript = TranscriptionPayload(
            rawTranscript: decoded.value.rawTranscript,
            confidence: decoded.value.confidence,
            uncertainSegments: decoded.value.uncertainSegments,
            warnings: decoded.value.warnings
        )
        let structured = StructurePayload(
            markdown: decoded.value.markdown,
            noteMeta: decoded.value.noteMeta,
            classification: decoded.value.classification,
            warnings: decoded.value.warnings
        )

        return ScanProcessingOutput(
            transcript: transcript,
            transcriptJSON: decoded.rawJSON,
            structured: structured,
            structuredJSON: decoded.rawJSON
        )
    }

    private static func processBalanced(
        input: ScanProcessingInput,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> ScanProcessingOutput {
        let transcriptResponse = try await transcribe(input: input, client: client)
        try validateTranscript(transcriptResponse.value.rawTranscript)

        let structuredResponse = try await structure(
            transcript: transcriptResponse.value.rawTranscript,
            client: client,
            context: context
        )
        try validateMarkdown(structuredResponse.value.markdown, title: structuredResponse.value.noteMeta.title)
        try validateClassification(structuredResponse.value.classification)

        return ScanProcessingOutput(
            transcript: transcriptResponse.value,
            transcriptJSON: transcriptResponse.rawJSON,
            structured: structuredResponse.value,
            structuredJSON: structuredResponse.rawJSON
        )
    }

    private static func processBest(
        input: ScanProcessingInput,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> ScanProcessingOutput {
        let transcriptResponse = try await transcribe(input: input, client: client)
        try validateTranscript(transcriptResponse.value.rawTranscript)

        let structuredResponse = try await structure(
            transcript: transcriptResponse.value.rawTranscript,
            client: client,
            context: context
        )
        try validateMarkdown(structuredResponse.value.markdown, title: structuredResponse.value.noteMeta.title)
        try validateClassification(structuredResponse.value.classification)

        let refinedResponse = try await refine(
            structuredJSON: structuredResponse.rawJSON,
            client: client,
            context: context
        )
        try validateMarkdown(refinedResponse.value.markdown, title: refinedResponse.value.noteMeta.title)
        try validateClassification(refinedResponse.value.classification)

        return ScanProcessingOutput(
            transcript: transcriptResponse.value,
            transcriptJSON: transcriptResponse.rawJSON,
            structured: refinedResponse.value,
            structuredJSON: refinedResponse.rawJSON
        )
    }

    private static func transcribe(
        input: ScanProcessingInput,
        client: GeminiClient
    ) async throws -> JSONResponseParser.Decoded<TranscriptionPayload> {
        let prompt = ProcessingPrompts.transcriptionPrompt()
        let response = try await client.generateContent(
            contents: [
                GeminiMessage(
                    role: "user",
                    parts: [
                        GeminiPart(text: prompt),
                        GeminiPart(inlineData: InlineData(mimeType: input.mimeType, data: input.imageData.base64EncodedString()))
                    ]
                )
            ],
            systemInstruction: nil,
            generationConfig: GenerationConfig(temperature: 0.1, responseMimeType: "application/json")
        )
        let text = response.extractText()
        return try JSONResponseParser.decode(TranscriptionPayload.self, from: text)
    }

    private static func structure(
        transcript: String,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> JSONResponseParser.Decoded<StructurePayload> {
        let prompt = ProcessingPrompts.structurePrompt(
            transcript: transcript,
            systemRules: context.systemRules,
            indexJSON: context.indexJSON,
            structureText: context.structureText,
            organizationStyle: context.organizationStyle
        )
        let response = try await client.generateText(
            prompt: prompt,
            systemInstruction: nil,
            generationConfig: GenerationConfig(temperature: 0.2, responseMimeType: "application/json")
        )
        return try JSONResponseParser.decode(StructurePayload.self, from: response.text)
    }

    private static func refine(
        structuredJSON: String,
        client: GeminiClient,
        context: ProcessingContextSnapshot
    ) async throws -> JSONResponseParser.Decoded<StructurePayload> {
        let prompt = ProcessingPrompts.refinePrompt(
            structuredJSON: structuredJSON,
            systemRules: context.systemRules,
            indexJSON: context.indexJSON,
            structureText: context.structureText,
            organizationStyle: context.organizationStyle
        )
        let response = try await client.generateText(
            prompt: prompt,
            systemInstruction: nil,
            generationConfig: GenerationConfig(temperature: 0.15, responseMimeType: "application/json")
        )
        return try JSONResponseParser.decode(StructurePayload.self, from: response.text)
    }

    private static func validateTranscript(_ transcript: String) throws {
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProcessingPipelineError.emptyTranscript
        }
    }

    private static func validateMarkdown(_ markdown: String, title: String) throws {
        if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProcessingPipelineError.emptyMarkdown
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProcessingPipelineError.missingTitle
        }
    }

    private static func validateClassification(_ classification: Classification) throws {
        guard VaultFolder.fromClassification(classification.folder) != nil else {
            throw ProcessingPipelineError.invalidJSON
        }
    }
}

enum JSONResponseParser {
    struct Decoded<T> {
        let value: T
        let rawJSON: String
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> Decoded<T> {
        let jsonString = try extractJSON(from: text)
        guard let data = jsonString.data(using: .utf8) else {
            throw ProcessingPipelineError.invalidJSON
        }
        let decoder = JSONDecoder()
        do {
            let value = try decoder.decode(T.self, from: data)
            return Decoded(value: value, rawJSON: jsonString)
        } catch {
            throw ProcessingPipelineError.invalidJSON
        }
    }

    private static func extractJSON(from text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}") else {
            throw ProcessingPipelineError.invalidJSON
        }
        let json = String(trimmed[start...end])
        guard !json.isEmpty else {
            throw ProcessingPipelineError.invalidJSON
        }
        return json
    }
}

enum ProcessingPrompts {
    static func transcriptionPrompt() -> String {
        """
        You are transcribing a notebook page image.
        Return JSON only with this schema:
        {
          "rawTranscript": "string",
          "confidence": 0.0,
          "uncertainSegments": ["string"],
          "warnings": ["string"]
        }
        Rules:
        - rawTranscript must preserve the page text without interpretation.
        - Keep line breaks when they help readability.
        - If unsure, include the text snippet in uncertainSegments.
        - Do not include markdown fences or extra keys.
        """
    }

    static func structurePrompt(
        transcript: String,
        systemRules: String,
        indexJSON: String?,
        structureText: String?,
        organizationStyle: OrganizationStyle
    ) -> String {
        let folderOptions = VaultFolder.promptList(style: organizationStyle)
        var prompt = """
        You will structure a transcript into Markdown notes and classify it.
        Use the transcript below. Return JSON only with this schema:
        {
          "markdown": "string",
          "noteMeta": {
            "title": "string",
            "summary": "string",
            "tags": ["string"],
            "links": ["string"]
          },
          "classification": {
            "folder": "\(folderOptions)",
            "reason": "string"
          },
          "warnings": ["string"]
        }
        Rules:
        - markdown must be a clean note with sections when appropriate.
        - noteMeta.title must be present.
        - classification.folder must be one of the listed folders.
        - Use [[Wiki Link]] syntax for entities or projects mentioned in markdown.
        - List each unique wiki-link title (without brackets) in noteMeta.links.
        - Do not include markdown fences or extra keys.
        """

        prompt += "\n\nSystem rules:\n\(systemRules)"
        if let indexJSON {
            prompt += "\n\nIndex snapshot (JSON):\n\(indexJSON)"
        }
        if let structureText {
            prompt += "\n\nVault structure:\n\(structureText)"
        }
        prompt += "\n\nTranscript:\n\(transcript)"
        return prompt
    }

    static func refinePrompt(
        structuredJSON: String,
        systemRules: String,
        indexJSON: String?,
        structureText: String?,
        organizationStyle: OrganizationStyle
    ) -> String {
        let folderOptions = VaultFolder.promptList(style: organizationStyle)
        var prompt = """
        You will refine a structured note using system rules and the vault context.
        Return JSON only with this schema:
        {
          "markdown": "string",
          "noteMeta": {
            "title": "string",
            "summary": "string",
            "tags": ["string"],
            "links": ["string"]
          },
          "classification": {
            "folder": "\(folderOptions)",
            "reason": "string"
          },
          "warnings": ["string"]
        }
        Rules:
        - Keep meaning unchanged; only improve structure, links, and classification.
        - Use [[Wiki Link]] syntax for entities or projects mentioned in markdown.
        - List each unique wiki-link title (without brackets) in noteMeta.links.
        - Do not include markdown fences or extra keys.
        """

        prompt += "\n\nSystem rules:\n\(systemRules)"
        if let indexJSON {
            prompt += "\n\nIndex snapshot (JSON):\n\(indexJSON)"
        }
        if let structureText {
            prompt += "\n\nVault structure:\n\(structureText)"
        }
        prompt += "\n\nCurrent structured JSON:\n\(structuredJSON)"
        return prompt
    }

    static func fastPrompt(systemRules: String, organizationStyle: OrganizationStyle) -> String {
        let folderOptions = VaultFolder.promptList(style: organizationStyle)
        var prompt = """
        You are transcribing and structuring a notebook page image in one pass.
        Return JSON only with this schema:
        {
          "rawTranscript": "string",
          "confidence": 0.0,
          "uncertainSegments": ["string"],
          "markdown": "string",
          "noteMeta": {
            "title": "string",
            "summary": "string",
            "tags": ["string"],
            "links": ["string"]
          },
          "classification": {
            "folder": "\(folderOptions)",
            "reason": "string"
          },
          "warnings": ["string"]
        }
        Rules:
        - rawTranscript must preserve the page text without interpretation.
        - markdown must be a clean note with sections when appropriate.
        - noteMeta.title must be present.
        - classification.folder must be one of the listed folders.
        - Use [[Wiki Link]] syntax for entities or projects mentioned in markdown.
        - List each unique wiki-link title (without brackets) in noteMeta.links.
        - Do not include markdown fences or extra keys.
        """
        prompt += "\n\nSystem rules:\n\(systemRules)"
        return prompt
    }
}

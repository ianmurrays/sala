import Foundation
import FoundationModels
import NaturalLanguage

/// Translate and summarize one message or post, where the user chose (Settings → AI).
/// Off by default. Never runs on its own: only on a tap. Never falls back to another option.
enum AI {
    enum Provider: String, CaseIterable, Identifiable, Sendable {
        // ponytail: no Private Cloud Compute: it needs Apple's managed entitlement
        // com.apple.developer.private-cloud-compute and crashes without it (while reporting itself available).
        case off, device, openAI, anthropic
        var id: String { rawValue }
        var title: String {
            switch self {
            case .off: "Off"
            case .device: "On this iPhone"
            case .openAI: "OpenAI-compatible endpoint"
            case .anthropic: "Anthropic (Claude)"
            }
        }
    }

    enum Action: String, Sendable { case translate, summarize }

    struct Failure: LocalizedError { let errorDescription: String? }

    // MARK: Settings (keys in the Keychain, the rest in UserDefaults)

    private static var d: UserDefaults { .standard }
    static var provider: Provider {
        get { d.string(forKey: "ai.provider").flatMap(Provider.init) ?? .off }
        set { d.set(newValue.rawValue, forKey: "ai.provider") }
    }
    /// Base URL of an OpenAI-compatible API, e.g. `https://api.openai.com/v1`; `/chat/completions` is added.
    static var endpoint: String {
        get { d.string(forKey: "ai.endpoint") ?? "" }
        set { d.set(newValue, forKey: "ai.endpoint") }
    }
    static var openAIModel: String {
        get { d.string(forKey: "ai.openAIModel") ?? "" }
        set { d.set(newValue, forKey: "ai.openAIModel") }
    }
    static var anthropicModel: String {
        get { d.string(forKey: "ai.anthropicModel") ?? "" }
        set { d.set(newValue, forKey: "ai.anthropicModel") }
    }
    static let defaultAnthropicModel = "claude-opus-5-5"
    static var openAIKey: String {
        get { Keychain.string("ai.openAIKey") ?? "" }
        set { if newValue.isEmpty { Keychain.delete("ai.openAIKey") } else { Keychain.write(Data(newValue.utf8), "ai.openAIKey") } }
    }
    static var anthropicKey: String {
        get { Keychain.string("ai.anthropicKey") ?? "" }
        set { if newValue.isEmpty { Keychain.delete("ai.anthropicKey") } else { Keychain.write(Data(newValue.utf8), "ai.anthropicKey") } }
    }
    /// The user's prompt for `action`; empty means the default. `{lang}` becomes the reader's language.
    static func customPrompt(_ action: Action) -> String { d.string(forKey: "ai.prompt.\(action.rawValue)") ?? "" }
    static func setCustomPrompt(_ action: Action, _ text: String) { d.set(text, forKey: "ai.prompt.\(action.rawValue)") }

    // Adapted from the old server's prompt (git show 222c162:server/sala/translate.py), one text per call.
    static func defaultPrompt(_ action: Action) -> String {
        switch action {
        case .translate:
            "You translate a message or post from a Danish school or kindergarten app into natural {lang}, as a parent would want to read it. Translate all of it. Keep names of people, places and groups, line breaks, URLs, e-mail addresses and phone numbers exactly. Do not add notes. If the text is already in {lang}, return it unchanged. Reply with only the translation."
        case .summarize:
            "You summarize a message or post from a Danish school or kindergarten app for a busy parent, in {lang}. In one to three short sentences, say what it is about and anything the parent must do, bring or remember, with dates and times. Keep names of people, places and groups exactly. Do not add notes. Reply with only the summary."
        }
    }

    static func prompt(_ action: Action, language: String) -> String {
        let custom = customPrompt(action).trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom.isEmpty ? defaultPrompt(action) : custom).replacingOccurrences(of: "{lang}", with: language)
    }

    // MARK: Availability

    /// Why `provider` can't run right now, or nil when it can.
    static func unavailableReason(_ provider: Provider = provider) -> String? {
        switch provider {
        case .off:
            return "AI is off."
        case .device:
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.deviceNotEligible): return "This iPhone doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in the Settings app."
            case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable: return "Apple Intelligence isn't available."
            }
        case .openAI:
            if URL(string: endpoint)?.host == nil { return "Set the endpoint's URL." }
            if openAIModel.trimmingCharacters(in: .whitespaces).isEmpty { return "Set the model." }
            return nil
        case .anthropic:
            return anthropicKey.isEmpty ? "Set your Anthropic API key." : nil
        }
    }

    static var isOn: Bool { unavailableReason() == nil }

    /// The model the chosen option uses, for cache keys. Apple's models change with iOS updates.
    static var model: String {
        switch provider {
        case .off: ""
        case .device: ProcessInfo.processInfo.operatingSystemVersionString
        case .openAI: openAIModel
        case .anthropic: anthropicModel.isEmpty ? defaultAnthropicModel : anthropicModel
        }
    }

    // MARK: Languages

    /// The reader's language: the first one in the iPhone's language list.
    static var readerLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// The language's name in English ("Danish"), for prompts and labels.
    static func name(_ language: Locale.Language) -> String {
        language.languageCode.flatMap { Locale(identifier: "en").localizedString(forLanguageCode: $0.identifier) } ?? "English"
    }

    /// The text's language, or nil when unsure (too short, mixed).
    static func language(of text: String) -> Locale.Language? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.6 else { return nil }
        return Locale.Language(identifier: lang.rawValue)
    }

    static func isForeign(_ text: String) -> Bool {
        guard let lang = language(of: text)?.languageCode else { return false }
        return lang != readerLanguage.languageCode
    }

    /// ponytail: a fixed length; a short message is its own summary.
    static let summaryMinLength = 280

    // MARK: Running

    /// The translation or summary of `text` in the reader's language.
    static func run(_ action: Action, _ text: String) async throws -> String {
        let provider = provider
        if let reason = unavailableReason(provider) { throw Failure(errorDescription: reason) }
        let instructions = prompt(action, language: name(readerLanguage))
        // Translations go in chunks of paragraphs: the on-device context window is small (about 4 000 tokens,
        // ~2.7 Danish characters per token). A summary needs the whole text.
        let parts = action == .translate ? chunks(text) : [text]
        var out: [String] = []
        for part in parts {
            out.append(try await call(provider, instructions: instructions, text: part))
        }
        let result = out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { throw Failure(errorDescription: "The model gave no answer. Try again.") }
        return result
    }

    static let chunkChars = 1_500

    /// Consecutive paragraphs of about `chunkChars`; a longer paragraph goes alone.
    static func chunks(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for p in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + p.count > chunkChars {
                out.append(current)
                current = ""
            }
            current += current.isEmpty ? p : "\n\n" + p
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func call(_ provider: Provider, instructions: String, text: String) async throws -> String {
        do {
            switch provider {
            case .off:
                throw Failure(errorDescription: "AI is off.")
            case .device:
                return try await LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions).respond(to: text).content
            case .openAI:
                let req = try openAIRequest(endpoint: endpoint, key: openAIKey, model: openAIModel, instructions: instructions, text: text)
                return try openAIText(try await send(req))
            case .anthropic:
                let model = anthropicModel.trimmingCharacters(in: .whitespaces)
                let req = anthropicRequest(key: anthropicKey, model: model.isEmpty ? defaultAnthropicModel : model, instructions: instructions, text: text)
                return try anthropicText(try await send(req))
            }
        } catch let e as LanguageModelError {
            switch e {
            case .contextSizeExceeded: throw Failure(errorDescription: "Too long for Apple's model.")
            case .guardrailViolation, .refusal: throw Failure(errorDescription: "Apple's model declined this text.")
            case .unsupportedLanguageOrLocale: throw Failure(errorDescription: "Apple's model doesn't support this language.")
            case .rateLimited: throw Failure(errorDescription: "Apple's model is busy. Try again in a moment.")
            default: throw Failure(errorDescription: e.localizedDescription)
            }
        }
    }

    // MARK: HTTP (own provider)

    static func openAIRequest(endpoint: String, key: String, model: String, instructions: String, text: String) throws -> URLRequest {
        let base = endpoint.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), url.host != nil else { throw Failure(errorDescription: "The endpoint's URL isn't valid.") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        if !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.trimmingCharacters(in: .whitespaces),
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": text]],
        ])
        return r
    }

    static func openAIText(_ data: Data) throws -> String {
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((j?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        guard let text = message?["content"] as? String else { throw Failure(errorDescription: "The endpoint's answer had no text.") }
        return text
    }

    static func anthropicRequest(key: String, model: String, instructions: String, text: String) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        r.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 16000,
            "system": instructions,
            "messages": [["role": "user", "content": text]],
            "output_config": ["effort": "low"],
        ] as [String: Any])
        return r
    }

    static func anthropicText(_ data: Data) throws -> String {
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch j?["stop_reason"] as? String {
        case "end_turn": break
        case "refusal": throw Failure(errorDescription: "Claude declined this text.")
        case "max_tokens": throw Failure(errorDescription: "Claude's answer was cut off.")
        default: throw Failure(errorDescription: "Claude's answer was incomplete.")
        }
        let text = (j?["content"] as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        guard let text, !text.isEmpty else { throw Failure(errorDescription: "Claude's answer had no text.") }
        return text
    }

    /// The provider's models (`GET /models`), sorted, for the model picker. Empty for Apple's models.
    static func models(_ provider: Provider) async throws -> [String] {
        var r: URLRequest
        switch provider {
        case .openAI:
            let base = endpoint.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: base + "/models"), url.host != nil else { throw Failure(errorDescription: "Set the endpoint's URL.") }
            r = URLRequest(url: url)
            if !openAIKey.isEmpty { r.setValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            guard !anthropicKey.isEmpty else { throw Failure(errorDescription: "Set your Anthropic API key.") }
            r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
            r.setValue(anthropicKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        case .off, .device:
            return []
        }
        return try modelIDs(try await send(r))
    }

    /// `{"data":[{"id":"..."}]}`, the shape of both OpenAI's and Anthropic's model lists.
    static func modelIDs(_ data: Data) throws -> [String] {
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = j?["data"] as? [[String: Any]] else { throw Failure(errorDescription: "The model list had an unknown shape.") }
        return list.compactMap { $0["id"] as? String }.sorted()
    }

    /// Never logs the text or the key: errors carry only the status.
    private static func send(_ request: URLRequest) async throws -> Data {
        var r = request
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(errorDescription: status == 401 || status == 403 ? "The API key was refused (HTTP \(status))." : "The AI request failed (HTTP \(status)).")
        }
        return data
    }
}

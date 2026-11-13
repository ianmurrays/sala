import Foundation
import XCTest

/// AI.swift's pure parts: chunking, prompts, and the own-provider requests and answers.
final class AITests: XCTestCase {
    func testChunksKeepParagraphsAndOrder() {
        let p = String(repeating: "a", count: 600)
        let text = [p, p, p, "kort"].joined(separator: "\n\n")
        let chunks = AI.chunks(text)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.joined(separator: "\n\n"), text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= AI.chunkChars })
        XCTAssertEqual(AI.chunks("Hej"), ["Hej"])
        XCTAssertEqual(AI.chunks(String(repeating: "b", count: 4000)).count, 1, "a long paragraph goes alone")
    }

    func testPromptFillsLanguage() {
        // The default prompt, not AI.prompt: that reads the simulator's saved custom prompt.
        let p = AI.defaultPrompt(.translate).replacingOccurrences(of: "{lang}", with: "English")
        XCTAssertTrue(p.contains("into natural English"))
    }

    func testCacheKeyCoversWhatChangesTheAnswer() {
        let base = AI.cacheKey(.translate, "Hej", provider: .openAI, endpoint: "https://a.example/v1", model: "m", prompt: "p")
        XCTAssertEqual(base, AI.cacheKey(.translate, "Hej", provider: .openAI, endpoint: "https://a.example/v1", model: "m", prompt: "p"))
        XCTAssertNotEqual(base, AI.cacheKey(.translate, "Hej", provider: .openAI, endpoint: "https://b.example/v1", model: "m", prompt: "p"), "another server")
        XCTAssertNotEqual(base, AI.cacheKey(.summarize, "Hej", provider: .openAI, endpoint: "https://a.example/v1", model: "m", prompt: "p"))
        XCTAssertNotEqual(base, AI.cacheKey(.translate, "Hej", provider: .openAI, endpoint: "https://a.example/v1", model: "n", prompt: "p"))
        XCTAssertNotEqual(base, AI.cacheKey(.translate, "Hej", provider: .openAI, endpoint: "https://a.example/v1", model: "m", prompt: "q"))
        XCTAssertNotEqual(base, AI.cacheKey(.translate, "Hej", provider: .anthropic, endpoint: "https://a.example/v1", model: "m", prompt: "p"))
    }

    func testOpenAIRequestAndAnswer() throws {
        let r = try AI.openAIRequest(endpoint: "https://example.com/v1/", key: "k", model: " m ", instructions: "sys", text: "Hej")
        XCTAssertEqual(r.url?.absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual((body["messages"] as? [[String: String]])?.map { $0["role"] }, ["system", "user"])

        let noKey = try AI.openAIRequest(endpoint: "http://localhost:11434/v1", key: "", model: "m", instructions: "", text: "")
        XCTAssertNil(noKey.value(forHTTPHeaderField: "Authorization"))
        XCTAssertThrowsError(try AI.openAIRequest(endpoint: "nope", key: "", model: "m", instructions: "", text: ""))

        XCTAssertEqual(try AI.openAIText(Data(#"{"choices":[{"message":{"role":"assistant","content":"Hi"}}]}"#.utf8)), "Hi")
        XCTAssertThrowsError(try AI.openAIText(Data(#"{"error":{"message":"bad"}}"#.utf8)))
        XCTAssertThrowsError(try AI.openAIText(Data(#"{"choices":[{"finish_reason":"length","message":{"content":"Hal"}}]}"#.utf8)), "cut off")
    }

    func testAnthropicRequestAndAnswer() throws {
        let r = AI.anthropicRequest(key: "k", model: "claude-opus-5-5", instructions: "sys", text: "Hej")
        XCTAssertEqual(r.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: r.httpBody!) as? [String: Any])
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertNil(body["temperature"], "a 400 on 2026-10-21")
        XCTAssertNil(body["output_config"], "effort is a 400 on some models the picker offers")

        let ok = #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"Hi"}]}"#
        XCTAssertEqual(try AI.anthropicText(Data(ok.utf8)), "Hi")
        XCTAssertThrowsError(try AI.anthropicText(Data(#"{"stop_reason":"refusal","content":[]}"#.utf8)))
        XCTAssertThrowsError(try AI.anthropicText(Data(#"{"stop_reason":"max_tokens","content":[{"type":"text","text":"Hi"}]}"#.utf8)))
    }

    func testModelIDs() throws {
        XCTAssertEqual(try AI.modelIDs(Data(#"{"data":[{"id":"b","display_name":"B"},{"id":"a"}],"has_more":false}"#.utf8)), ["a", "b"])
        XCTAssertThrowsError(try AI.modelIDs(Data(#"{"models":[]}"#.utf8)))
    }

    func testLanguageDetection() {
        XCTAssertEqual(AI.language(of: "Husk madpakke og regntøj på torsdag, vi skal på tur til skoven.")?.languageCode, "da")
        XCTAssertNil(AI.language(of: "ok"), "too short to tell")
    }
}

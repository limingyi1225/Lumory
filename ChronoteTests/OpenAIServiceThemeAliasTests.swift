//
//  OpenAIServiceThemeAliasTests.swift
//  ChronoteTests
//
//  Wire-level tests for ThemeAlias AI JSON parsing.
//

import XCTest
@testable import Lumory

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIServiceThemeAliasTests: XCTestCase {
    private var service: OpenAIService!

    override func setUp() async throws {
        try await super.setUp()
        service = OpenAIService(session: MockURLProtocol.makeSession(), appSharedSecret: "test-secret")
    }

    override func tearDown() async throws {
        MockURLProtocol.reset()
        service = nil
        try await super.tearDown()
    }

    func testJudgeThemeAliases_dropsLowAndUnknownConfidence() async {
        MockURLProtocol.requestHandler = Self.chatHandler(content: #"""
        {"matches":[
          {"new":"宝贝","canonical":"Abby","confidence":"low","reason":"weak"},
          {"new":"老婆","canonical":"Abby","confidence":"weird","reason":"bad"},
          {"new":"Tokyo","canonical":"东京","confidence":"high","reason":"translation"}
        ]}
        """#)

        let matches = await service.judgeThemeAliases(
            newTags: ["宝贝", "老婆", "Tokyo"],
            inventory: [
                ThemeAliasJudgeCandidate(tag: "Abby", count: 5, sampleSnippet: nil),
                ThemeAliasJudgeCandidate(tag: "东京", count: 2, sampleSnippet: nil)
            ]
        )

        XCTAssertEqual(matches.map(\.newTag), ["Tokyo"])
        XCTAssertEqual(matches.first?.confidence, .high)
    }

    func testScanThemeAliasGroups_dropsLowAndUnknownConfidence() async throws {
        MockURLProtocol.requestHandler = Self.chatHandler(content: #"""
        {"groups":[
          {"canonical":"Abby","aliases":["宝贝"],"confidence":"low","reason":"weak"},
          {"canonical":"Tokyo","aliases":["东京"],"confidence":"unknown","reason":"bad"},
          {"canonical":"Mom","aliases":["妈妈"],"confidence":"medium","reason":"translation"}
        ]}
        """#)

        let groups = try await service.scanThemeAliasGroups(candidates: [
            ThemeAliasJudgeCandidate(tag: "Abby", count: 5, sampleSnippet: nil),
            ThemeAliasJudgeCandidate(tag: "宝贝", count: 1, sampleSnippet: nil),
            ThemeAliasJudgeCandidate(tag: "Tokyo", count: 3, sampleSnippet: nil),
            ThemeAliasJudgeCandidate(tag: "东京", count: 2, sampleSnippet: nil),
            ThemeAliasJudgeCandidate(tag: "Mom", count: 4, sampleSnippet: nil),
            ThemeAliasJudgeCandidate(tag: "妈妈", count: 2, sampleSnippet: nil)
        ])

        XCTAssertEqual(groups.map(\.canonical), ["Mom"])
        XCTAssertEqual(groups.first?.confidence, .medium)
    }

    private static func chatHandler(content: String) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, chatResponse(content: content))
        }
    }

    private static func chatResponse(content: String) -> Data {
        struct Response: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let role: String
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        return try! JSONEncoder().encode(Response(
            choices: [
                .init(message: .init(role: "assistant", content: content))
            ]
        ))
    }
}

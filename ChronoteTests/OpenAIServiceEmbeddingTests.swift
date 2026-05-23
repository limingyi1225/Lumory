//
//  OpenAIServiceEmbeddingTests.swift
//  ChronoteTests
//
//  Wire-level tests for embedding response validation.
//

import XCTest
@testable import Lumory

@available(iOS 15.0, macOS 12.0, *)
final class OpenAIServiceEmbeddingTests: XCTestCase {
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

    func testEmbed_emptyVectorReturnsNil() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, #"{"data":[{"embedding":[]}]}"#.data(using: .utf8)!)
        }

        let vector = await service.embed(text: "hello")

        XCTAssertNil(vector)
    }
}

import Foundation
import NIOCore
import Testing
@testable import YoHTTP

@Suite("Server wire responses", .serialized)
struct ServerResponseTests {
    @Test func writesAuthoritativeHeadersAndCustomReasonPhrase() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, reuseAddress: false, serverName: "configured"),
            handler: { _ in
                Response(
                    status: Status(299, reasonPhrase: "Custom"),
                    headers: ["Content-Length": "999", "Transfer-Encoding": "chunked", "Server": "application"],
                    body: "hello"
                )
            }
        ) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port)))
            #expect(response.statusCode == 299)
            #expect(response.reasonPhrase == "Custom")
            #expect(response.header("content-length") == "5")
            #expect(response.header("transfer-encoding") == nil)
            #expect(response.header("server") == "application")
            #expect(response.header("connection") == "close")
        }
    }

    @Test func serverHeaderCanBeConfiguredOrDisabled() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, serverName: nil),
            handler: { _ in .text("ok") }
        ) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port)))
            #expect(response.header("server") == nil)
        }

        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, serverName: "custom"),
            handler: { _ in .text("ok") }
        ) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port)))
            #expect(response.header("server") == "custom")
        }
    }

    @Test func suppressesBodiesForHeadAndBodylessStatuses() async throws {
        try await withServer(handler: { request in
            switch request.path {
            case "/no-content": return Response(status: .noContent, body: "forbidden")
            case "/not-modified": return Response(status: .notModified, body: "forbidden")
            case "/informational": return Response(status: .continue, body: "invalid final response")
            default: return .text("representation")
            }
        }) { _, address in
            let port = try #require(address.port)

            let headData = try await exchangeRawHTTP(port: port, request: rawRequest(port: port, method: "HEAD"))
            let head = try parseSingleResponse(headData, bodyIsSuppressed: true)
            #expect(head.statusCode == 200)
            #expect(head.header("content-length") == "14")
            #expect(headData.suffix(4) == Data("\r\n\r\n".utf8))

            for target in ["/no-content", "/not-modified"] {
                let data = try await exchangeRawHTTP(port: port, request: rawRequest(port: port, target: target))
                let response = try parseSingleResponse(data, bodyIsSuppressed: true)
                #expect(response.header("content-length") == nil)
                #expect(data.suffix(4) == Data("\r\n\r\n".utf8))
            }

            let informational = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                request: rawRequest(port: port, target: "/informational")
            ))
            #expect(informational.statusCode == 500)
            #expect(String(decoding: informational.body, as: UTF8.self) == "Internal Server Error")
        }
    }

    @Test func supportsKeepAlivePipeliningInOrder() async throws {
        try await withServer(handler: { request in .text(request.path) }) { _, address in
            let port = try #require(address.port)
            let first = rawRequest(port: port, target: "/first", close: false)
            let second = rawRequest(port: port, target: "/second", close: true)
            let responses = try parseResponses(await exchangeRawHTTP(port: port, request: first + second))

            #expect(responses.count == 2)
            #expect(String(decoding: responses[0].body, as: UTF8.self) == "/first")
            #expect(String(decoding: responses[1].body, as: UTF8.self) == "/second")
            #expect(responses[0].header("connection") == nil)
            #expect(responses[1].header("connection") == "close")
        }
    }

    @Test func closesHTTP10ConnectionsByDefault() async throws {
        try await withServer(handler: { _ in .text("old") }) { _, address in
            let port = try #require(address.port)
            let request = rawRequest(port: port, version: "HTTP/1.0", close: false)
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: request))
            #expect(response.statusCode == 200)
            #expect(response.header("connection") == "close")
            #expect(String(decoding: response.body, as: UTF8.self) == "old")
        }
    }

    @Test func streamsUnknownLengthBodiesWithChunkedFraming() async throws {
        let chunks = AsyncStream<ByteBuffer> { continuation in
            continuation.yield(ByteBuffer(string: "hello"))
            continuation.yield(ByteBuffer(string: " world"))
            continuation.finish()
        }
        try await withServer(handler: { _ in Response(body: Body(chunks)) }) { _, address in
            let port = try #require(address.port)
            let data = try await exchangeRawHTTP(port: port, request: rawRequest(port: port))
            let response = try parseSingleResponse(data)
            #expect(response.header("transfer-encoding") == "chunked")
            #expect(response.header("content-length") == nil)
            #expect(String(decoding: response.body, as: UTF8.self) == "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        }
    }
}

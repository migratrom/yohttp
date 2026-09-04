import Foundation
import NIOCore
import Synchronization
import Testing
import NIOHTTP1
@testable import YoHTTP

private struct TestHTTPError: HTTPError {
    let status: Status = .conflict
    let headers: Headers = ["X-Error": "custom"]
    let body: Body = Body("controlled")
}

private struct UnexpectedTestError: Error {}

@Suite("Server request handling", .serialized)
struct ServerRequestTests {
    @Test func convertsWireRequestToOwnedValues() async throws {
        struct Snapshot: Sendable {
            let method: YoHTTP.Method
            let uri: String
            let headerValues: [String]
            let body: String?
            let remoteAddress: YoHTTP.SocketAddress?
        }
        let snapshot = Mutex<Snapshot?>(nil)

        try await withServer(handler: { request in
            let body = try await request.body.string()
            snapshot.withLock {
                $0 = Snapshot(
                    method: request.method,
                    uri: request.uri,
                    headerValues: request.headers.values(for: "x-repeat"),
                    body: body,
                    remoteAddress: request.remoteAddress
                )
            }
            return .text("received")
        }) { _, address in
            let port = try #require(address.port)
            let request = rawRequest(
                port: port, method: "POST", target: "/echo?q=one",
                headers: [("X-Repeat", "one"), ("X-Repeat", "two")], body: "hello"
            )
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: request))
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "received")
        }

        let value = try #require(snapshot.withLock { $0 })
        #expect(value.method == YoHTTP.Method.POST)
        #expect(value.uri == "/echo?q=one")
        #expect(value.headerValues == ["one", "two"])
        #expect(value.body == "hello")
        #expect(value.remoteAddress?.port != nil)
    }

    @Test func mapsControlledUnexpectedAndTimeoutErrors() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, requestTimeout: .milliseconds(20)),
            handler: { request in
                switch request.path {
                case "/controlled": throw TestHTTPError()
                case "/unexpected": throw UnexpectedTestError()
                case "/timeout":
                    try await Task.sleep(for: .seconds(1))
                    return .text("late")
                default: return .text("fast")
                }
            }
        ) { _, address in
            let port = try #require(address.port)

            let controlled = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port, target: "/controlled")))
            #expect(controlled.statusCode == 409)
            #expect(controlled.header("x-error") == "custom")
            #expect(String(decoding: controlled.body, as: UTF8.self) == "controlled")

            let unexpected = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port, target: "/unexpected")))
            #expect(unexpected.statusCode == 500)
            #expect(String(decoding: unexpected.body, as: UTF8.self) == "Internal Server Error")

            let timeout = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port, target: "/timeout")))
            #expect(timeout.statusCode == 408)
            #expect(String(decoding: timeout.body, as: UTF8.self) == "Request Timeout")

            let fast = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port, target: "/fast")))
            #expect(fast.statusCode == 200)
            #expect(String(decoding: fast.body, as: UTF8.self) == "fast")
        }
    }

    @Test func enforcesBodyLimitAtTheExactBoundary() async throws {
        let calls = Mutex(0)
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, maxRequestBodySize: 4),
            handler: { request in
                calls.withLock { $0 += 1 }
                return .text(try await request.body.string() ?? "")
            }
        ) { _, address in
            let port = try #require(address.port)
            let exact = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                request: rawRequest(port: port, method: "POST", body: "1234")
            ))
            #expect(exact.statusCode == 200)
            #expect(String(decoding: exact.body, as: UTF8.self) == "1234")

            let oversized = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                request: rawRequest(port: port, method: "POST", body: "12345")
            ))
            #expect(oversized.statusCode == 413)
            #expect(oversized.header("connection") == "close")
            #expect(String(decoding: oversized.body, as: UTF8.self) == "Content Too Large")
        }
        // Streaming handlers begin at the request head; the oversized request is
        // cancelled after its body crosses the configured limit.
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func closesWhenAHandlerLeavesRequestBytesUnread() async throws {
        try await withServer(handler: { _ in .text("declined") }) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                request: rawRequest(port: port, method: "POST", body: "upload", close: false)
            ))
            #expect(response.statusCode == 200)
            #expect(response.header("connection") == "close")
            #expect(String(decoding: response.body, as: UTF8.self) == "declined")
        }
    }

    @Test func canStreamARequestBodyStraightIntoTheResponse() async throws {
        try await withServer(handler: { request in Response(body: request.body) }) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                request: rawRequest(port: port, method: "POST", body: "forward", close: true)
            ))
            #expect(response.header("transfer-encoding") == "chunked")
            #expect(response.header("connection") == "close")
            #expect(String(decoding: response.body, as: UTF8.self) == "7\r\nforward\r\n0\r\n\r\n")
        }
    }

    @Test func writesAnEarlyNonstreamingResponseBeforeReceivingTheBody() async throws {
        try await withServer(handler: { _ in .text("early") }) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                requestParts: [
                    "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 4\r\nConnection: close\r\n\r\n",
                    "body",
                ],
                pauseBetweenParts: 20_000
            ))
            #expect(response.statusCode == 200)
            #expect(response.header("connection") == "close")
            #expect(String(decoding: response.body, as: UTF8.self) == "early")
        }
    }

    @Test func beginsWritingAStreamingResponseAsBodyChunksArrive() async throws {
        try await withServer(handler: { request in Response(body: request.body) }) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                requestParts: [
                    "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                    "4\r\ntest\r\n0\r\n\r\n",
                ],
                pauseBetweenParts: 20_000
            ))
            #expect(response.statusCode == 200)
            #expect(response.header("transfer-encoding") == "chunked")
            #expect(String(decoding: response.body, as: UTF8.self) == "4\r\ntest\r\n0\r\n\r\n")
        }
    }

    @Test func continuesToTheNextRequestAfterAnEarlyStreamingResponse() async throws {
        try await withServer(handler: { request in
            request.path == "/stream" ? Response(body: request.body) : .text("next")
        }) { _, address in
            let port = try #require(address.port)
            let response = String(decoding: try await exchangeRawHTTP(
                port: port,
                requestParts: [
                    "POST /stream HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\n\r\n",
                    "1\r\nx\r\n0\r\n\r\nGET /next HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n",
                ],
                pauseBetweenParts: 20_000
            ), as: UTF8.self)
            #expect(response.components(separatedBy: "HTTP/1.1 200").count == 3)
            #expect(response.contains("next"))
        }
    }

    @Test func resumesAWaitingRequestBodyReaderWhenTheRequestEnds() async throws {
        try await withServer(handler: { request in
            .text(try await request.body.string() ?? "empty")
        }) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                requestParts: [
                    "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                    "0\r\n\r\n",
                ],
                pauseBetweenParts: 20_000
            ))
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "")
        }
    }

    @Test func appliesBackpressureToChunkedRequestBodies() async throws {
        try await withServer(handler: { request in
            try await Task.sleep(for: .milliseconds(20))
            return .text(try await request.body.string() ?? "")
        }) { _, address in
            let port = try #require(address.port)
            let chunks = (0..<9).map { _ in "1\r\nx\r\n" }.joined() + "0\r\n\r\n"
            let response = try parseSingleResponse(await exchangeRawHTTP(
                port: port,
                requestParts: [
                    "POST / HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                    chunks,
                ],
                pauseBetweenParts: 5_000
            ))
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "xxxxxxxxx")
        }
    }

    @Test func requestBodyChannelHonorsCancellationForReadersAndWriters() async throws {
        let readerChannel = RequestBodyChannel()
        let reader = Task { try await readerChannel.nextChunk() }
        try await Task.sleep(for: .milliseconds(20))
        await readerChannel.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await reader.value
        }
        await #expect(throws: CancellationError.self) {
            try await readerChannel.send(ByteBuffer())
        }
        await readerChannel.cancel()

        let writerChannel = RequestBodyChannel()
        for _ in 0..<8 {
            try await writerChannel.send(ByteBuffer(string: "x"))
        }
        let writer = Task { try await writerChannel.send(ByteBuffer(string: "x")) }
        try await Task.sleep(for: .milliseconds(20))
        await writerChannel.cancel()
        await #expect(throws: CancellationError.self) {
            try await writer.value
        }

        let finished = RequestBodyChannel()
        await finished.finish()
        await finished.finish()
    }

    @Test func identifiesRequestBodiesFromTransferEncodingAndContentLength() {
        func request(with headers: HTTPHeaders) -> HTTPRequestHead {
            HTTPRequestHead(version: .http1_1, method: .POST, uri: "/", headers: headers)
        }

        #expect(YoHTTPServer.requestHasBody(request(with: ["Transfer-Encoding": "chunked"])))
        #expect(YoHTTPServer.requestHasBody(request(with: ["Content-Length": "1"])))
        #expect(!YoHTTPServer.requestHasBody(request(with: ["Content-Length": "0"])))
        #expect(!YoHTTPServer.requestHasBody(request(with: ["Content-Length": "invalid"])))
    }

    @Test func servesConnectionsConcurrently() async throws {
        struct Counts: Sendable { var active = 0; var maximum = 0 }
        let counts = Mutex(Counts())
        try await withServer(handler: { _ in
            counts.withLock { value in
                value.active += 1
                value.maximum = max(value.maximum, value.active)
            }
            try await Task.sleep(for: .milliseconds(20))
            counts.withLock { $0.active -= 1 }
            return .text("ok")
        }) { _, address in
            let port = try #require(address.port)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    group.addTask {
                        let data = try await exchangeRawHTTP(port: port, request: rawRequest(port: port))
                        #expect(try parseSingleResponse(data).statusCode == 200)
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(counts.withLock { $0.maximum } > 1)
    }

    @Test func aMalformedConnectionDoesNotStopTheListener() async throws {
        try await withServer(handler: { _ in .text("healthy") }) { _, address in
            let port = try #require(address.port)
            try await openAndCloseRawConnection(port: port)
            try await Task.sleep(for: .milliseconds(5))
            _ = try? await exchangeRawHTTP(port: port, request: "not-http\r\n\r\n")
            let response = try parseSingleResponse(await exchangeRawHTTP(port: port, request: rawRequest(port: port)))
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "healthy")
        }
    }
}

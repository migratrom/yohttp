import Testing
@testable import YoHTTP

@Route(.GET, "/")
private struct LifecycleEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("ok") }
}

@Suite("Server lifecycle", .serialized)
struct ServerLifecycleTests {
    @Test func errorDescriptionsAreStable() {
        #expect(ServerError.alreadyListening.description == "This server is already listening")
        #expect(ServerError.noHandler.description == "Register a handler before listening")
        #expect(ServerError.invalidConfiguration("bad").description == "Invalid server configuration: bad")
    }

    @Test func listeningRequiresAHandler() async {
        let server = YoHTTPServer()
        do {
            try await server.listen(ServerConfiguration(port: 0))
            Issue.record("Expected no-handler error")
        } catch let error as ServerError {
            #expect(error == .noHandler)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsEveryInvalidConfiguration() async {
        let configurations = [
            ServerConfiguration(hostname: "", port: 0),
            ServerConfiguration(port: -1),
            ServerConfiguration(port: 65_536),
            ServerConfiguration(port: 0, backlog: 0),
            ServerConfiguration(port: 0, backlog: -1),
            ServerConfiguration(port: 0, maxRequestBodySize: -1),
            ServerConfiguration(port: 0, tls: TLS(key: "", cert: TLSFixtures.cert)),
            ServerConfiguration(port: 0, tls: TLS(key: TLSFixtures.key, cert: "")),
            ServerConfiguration(port: 0, tls: TLS(key: "   ", cert: TLSFixtures.cert)),
        ]
        for configuration in configurations {
            let server = YoHTTPServer()
            server.handler { _ in .text("unused") }
            do {
                try await server.listen(configuration)
                Issue.record("Expected invalid configuration")
            } catch is ServerError {
                // Expected.
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func rejectsASecondListenAndShutdownIsIdempotent() async throws {
        try await withServer(handler: { _ in .text("ok") }) { server, _ in
            do {
                try await server.listen(ServerConfiguration(port: 0))
                Issue.record("Expected already-listening error")
            } catch let error as ServerError {
                #expect(error == .alreadyListening)
            }
            try await server.shutdown()
            try await server.shutdown()
        }
    }

    @Test func convenienceListenOverloadPublishesAndClearsAddress() async throws {
        let server = YoHTTPServer()
        let router = YoHTTPRouter()
        router.register(LifecycleEndpoint.self)
        server.handler(router)
        let listening = Task { try await server.listen("127.0.0.1", 0) }
        _ = try await waitForAddress(of: server)
        #expect(server.localAddress != nil)
        try await server.shutdown()
        try await listening.value
        #expect(server.localAddress == nil)
        try await server.shutdown()
    }

    @Test func concurrentShutdownCallsAreSafe() async throws {
        try await withServer(handler: { _ in .text("ok") }) { server, _ in
            async let first: Void = server.shutdown()
            async let second: Void = server.shutdown()
            _ = try await (first, second)
        }
    }

    @Test func cancellingListenClosesTheListenerAndAllowsRestart() async throws {
        let server = YoHTTPServer()
        server.handler { _ in .text("ok") }
        let first = Task { try await server.listen(ServerConfiguration(port: 0)) }
        _ = try await waitForAddress(of: server)
        first.cancel()
        _ = try? await first.value
        #expect(server.localAddress == nil)

        let second = Task { try await server.listen(ServerConfiguration(port: 0)) }
        _ = try await waitForAddress(of: server)
        try await server.shutdown()
        try await second.value
        #expect(server.localAddress == nil)
    }

    @Test func bindFailureClearsStateForRetry() async throws {
        let occupied = YoHTTPServer()
        occupied.handler { _ in .text("occupied") }
        let occupiedTask = Task { try await occupied.listen(ServerConfiguration(port: 0)) }
        let port = try #require(try await waitForAddress(of: occupied).port)

        let retrying = YoHTTPServer()
        retrying.handler { _ in .text("retry") }
        do {
            try await retrying.listen(ServerConfiguration(port: port))
            Issue.record("Expected bind failure")
        } catch {
            #expect(retrying.localAddress == nil)
        }

        try await occupied.shutdown()
        try await occupiedTask.value

        let retryTask = Task { try await retrying.listen(ServerConfiguration(port: port)) }
        _ = try await waitForAddress(of: retrying)
        try await retrying.shutdown()
        try await retryTask.value
    }

    @Test func shutdownRequestedDuringBindingClosesImmediatelyAfterBind() async throws {
        let reached = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let server = YoHTTPServer(afterBinding: {
            reached.continuation.yield()
            var iterator = release.stream.makeAsyncIterator()
            _ = await iterator.next()
        })
        server.handler { _ in .text("unused") }

        var reachedIterator = reached.stream.makeAsyncIterator()
        let listening = Task { try await server.listen(ServerConfiguration(port: 0)) }
        _ = await reachedIterator.next()
        try await server.shutdown()
        release.continuation.yield()
        release.continuation.finish()
        try await listening.value
        reached.continuation.finish()
        #expect(server.localAddress == nil)
    }
}

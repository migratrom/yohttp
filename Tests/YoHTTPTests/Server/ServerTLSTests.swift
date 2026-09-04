import Foundation
import Testing
@testable import YoHTTP

@Suite("Server TLS", .serialized)
struct ServerTLSTests {
    @Test func servesHTTPOverTLS() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, tls: TLSFixtures.valid),
            handler: { request in
                .text("secure \(request.method)")
            }
        ) { _, address in
            let port = try #require(address.port)
            let response = try parseSingleResponse(
                await exchangeRawHTTPS(port: port, tls: TLSFixtures.valid, request: rawRequest(port: port))
            )
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "secure GET")
        }
    }

    @Test func keepsTLSConnectionsAliveForPipelinedRequests() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, tls: TLSFixtures.valid),
            handler: { request in .text(request.path) }
        ) { _, address in
            let port = try #require(address.port)
            let first = rawRequest(port: port, target: "/first", close: false)
            let second = rawRequest(port: port, target: "/second", close: true)
            let responses = try parseResponses(
                await exchangeRawHTTPS(port: port, tls: TLSFixtures.valid, request: first + second)
            )

            #expect(responses.count == 2)
            #expect(String(decoding: responses[0].body, as: UTF8.self) == "/first")
            #expect(String(decoding: responses[1].body, as: UTF8.self) == "/second")
            #expect(responses[0].header("connection") == nil)
            #expect(responses[1].header("connection") == "close")
        }
    }

    @Test func rejectsPlaintextHTTPOnTLSPort() async throws {
        try await withServer(
            configuration: .init(hostname: "127.0.0.1", port: 0, tls: TLSFixtures.valid),
            handler: { _ in .text("nope") }
        ) { _, address in
            let port = try #require(address.port)
            do {
                let data = try await exchangeRawHTTP(port: port, request: rawRequest(port: port))
                if let response = try? parseSingleResponse(data) {
                    Issue.record("Plaintext HTTP succeeded against TLS: \(response.statusCode)")
                }
            } catch {
                // Handshake failure is the expected outcome.
            }
        }
    }

    @Test func rejectsInvalidTLSCredentialsBeforeBinding() async throws {
        let configurations = [
            ServerConfiguration(port: 0, tls: TLS(key: "not-a-key", cert: TLSFixtures.cert)),
            ServerConfiguration(port: 0, tls: TLS(key: TLSFixtures.key, cert: "not-a-cert")),
            ServerConfiguration(port: 0, tls: TLS(key: TLSFixtures.otherKey, cert: TLSFixtures.cert)),
        ]
        for configuration in configurations {
            let server = YoHTTPServer()
            server.handler { _ in .text("unused") }
            do {
                try await server.listen(configuration)
                Issue.record("Expected invalid TLS configuration")
            } catch let error as ServerError {
                guard case .invalidConfiguration = error else {
                    Issue.record("Unexpected server error: \(error)")
                    continue
                }
                #expect(server.localAddress == nil)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }
}

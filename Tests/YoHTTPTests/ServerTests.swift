import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import YoHTTP

@Suite("Server", .serialized)
struct ServerTests {
    @Test func servesRequestsOverHTTPAndShutsDown() async throws {
        let router = YoHTTPRouter()
        router.POST("/echo/:id") { request in
            Response.text("\(try request.parameters.require("id")):\(request.body.string() ?? "")")
        }

        let server = YoHTTPServer()
        server.handler(router)
        let listening = Task {
            try await server.listen(ServerConfiguration(hostname: "127.0.0.1", port: 0))
        }

        let address = try await waitForAddress(of: server)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(try #require(address.port))/echo/42")!)
        request.httpMethod = "POST"
        request.httpBody = Data("hello".utf8)
        let (data, response) = try await URLSession.shared.data(for: request)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "42:hello")
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server") == "yohttp")

        try await server.shutdown()
        try await listening.value
    }

    @Test func mapsHandlerErrorsToResponses() async throws {
        let server = YoHTTPServer()
        server.handler { _ in throw Abort(.unauthorized, headers: ["WWW-Authenticate": "Bearer"], body: "No") }
        let listening = Task {
            try await server.listen(ServerConfiguration(hostname: "127.0.0.1", port: 0))
        }

        let address = try await waitForAddress(of: server)
        let url = URL(string: "http://127.0.0.1:\(try #require(address.port))/")!
        let (data, response) = try await URLSession.shared.data(from: url)

        #expect((response as? HTTPURLResponse)?.statusCode == 401)
        #expect(String(decoding: data, as: UTF8.self) == "No")
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")

        try await server.shutdown()
        try await listening.value
    }

    private func waitForAddress(of server: YoHTTPServer) async throws -> SocketAddress {
        for _ in 0..<200 {
            if let address = server.localAddress { return address }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Server did not bind in time")
        throw CancellationError()
    }
}

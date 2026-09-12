import Foundation
import NIOCore
import Synchronization
import Testing

@testable import YoHTTP

@Route(.GET, "/sync")
private struct SynchronousEndpoint {
	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		response.head.initialize(HTTPResponseHead(version: request.head.version, status: .ok))
		response.write(ByteBuffer(string: "ok"))
		response.end()
	}
}

@Route(.GET, "/query")
private struct QueryEndpoint {
	@QueryParam("name") let name: String

	func handle(_ request: consuming Request, _ response: borrowing Response) throws {
		response.head.initialize(.init(version: request.head.version, status: .ok))
		response.write(ByteBuffer(string: name))
		response.end()
	}
}

@Suite("Event-loop-native server")
struct EventLoopServerTests {
	private func withServer<T: Sendable>(
		configuration: ServerConfiguration = .init(port: 0),
		handler: @escaping Handler,
		_ operation: @escaping @Sendable (Int) async throws -> T
	) async throws -> T {
		let server = YoHTTPServer()
		server.handler(handler)
		let listening = Task { try await server.listen(configuration) }
		for _ in 0..<100 where server.localAddress == nil {
			try await Task.sleep(for: .milliseconds(2))
		}
		let port = try #require(server.localAddress?.port)
		do {
			let value = try await operation(port)
			try await server.shutdown()
			try await listening.value
			return value
		} catch {
			try? await server.shutdown()
			_ = try? await listening.value
			throw error
		}
	}

	@Test func bodyStreamDeliversChunkAndEndSynchronously() {
		let stream = BodyStream()
		let bytes = Mutex(0)
		let ended = Mutex(false)

		stream.onChunk { chunk in bytes.withLock { $0 += chunk.readableBytes } }
			.onEnd { ended.withLock { $0 = true } }
		stream.receive(ByteBuffer(string: "hello"))
		stream.finish()

		#expect(bytes.withLock { $0 } == 5)
		#expect(ended.withLock { $0 })
	}

	@Test func responseWriterRecordsEventOrder() {
		let commands = Mutex<[Response.Command]>([])
		let response = Response { command in commands.withLock { $0.append(command) } }
		response.head.initialize(.init(version: .http1_1, status: .created))
		response.head.modify { $0.headers.add(name: "X-Test", value: "yes") }
		response.head.commit()
		response.write(ByteBuffer(string: "body"))
		response.end(["X-Trailer": "yes"])
		#expect(commands.withLock { $0.count } == 5)
		#expect(commands.withLock { commands in
			guard case .end(let trailers)? = commands.last else { return false }
			return trailers?.first(name: "X-Trailer") == "yes"
		})
	}

	@Test func runtimeConfigurationRejectsZeroEventLoops() async {
		let server = YoHTTPServer(runtimeConfiguration: .init(eventLoopCount: 0))
		server.handler { _, response in response.end() }
		await #expect(
			throws: ServerError.invalidConfiguration("eventLoopCount must be positive")
		) {
			try await server.listen(ServerConfiguration(port: 0))
		}
	}

	@Test func routerRoutesSynchronousMacroEndpointAfterRegistrationLocks() throws {
		let router = YoHTTPRouter()
		router.register(SynchronousEndpoint.self)
		router.registrationLocked()
		let commands = Mutex<[Response.Command]>([])
		try router.handler(
			Request(head: HTTPRequestHead(version: .http1_1, method: .GET, uri: "/sync")),
			Response { command in commands.withLock { $0.append(command) } }
		)
		#expect(commands.withLock { $0.count } == 3)
	}

	@Test func responseWriterStreamsAndMapsThrownHTTPErrors() async throws {
		let text = try await withServer(handler: { request, response in
			if request.head.uri == "/missing" {
				throw Abort(.notFound, body: ByteBuffer(string: "missing"))
			}
			response.head.initialize(.init(version: request.head.version, status: .ok))
			response.write(ByteBuffer(string: "hello "))
			response.write(ByteBuffer(string: "world"))
			response.end()
		}) { port in
			let (data, response) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/")!)
			#expect((response as? HTTPURLResponse)?.statusCode == 200)
			return String(decoding: data, as: UTF8.self)
		}
		#expect(text == "hello world")

		let status = try await withServer(handler: { _, _ in
			throw Abort(.notFound, body: ByteBuffer(string: "missing"))
		}) { port in
			let (data, response) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/missing")!)
			#expect(String(decoding: data, as: UTF8.self) == "missing")
			return (response as? HTTPURLResponse)?.statusCode
		}
		#expect(status == 404)
	}

	@Test func responseTimeoutEndsUncommittedResponse() async throws {
		let status = try await withServer(
			configuration: .init(port: 0, responseTimeout: .milliseconds(20)),
			handler: { _, _ in }
		) { port in
			let (_, response) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/")!)
			return (response as? HTTPURLResponse)?.statusCode
		}
		#expect(status == 504)
	}

	@Test func responseCanBeCompletedByApplicationOwnedWork() async throws {
		let value = try await withServer(handler: { _, response in
			let writer = response.writer()
			Task.detached {
				writer.head.initialize(.init(version: .http1_1, status: .ok))
				writer.write(ByteBuffer(string: "offloaded"))
				writer.end()
			}
		}) { port in
			let (data, response) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/")!)
			#expect((response as? HTTPURLResponse)?.statusCode == 200)
			return String(decoding: data, as: UTF8.self)
		}
		#expect(value == "offloaded")
	}

	@Test func stagedHeadModifiersAndExplicitCommitReachTheClient() async throws {
		let responseHeader = try await withServer(handler: { request, response in
			response.head.modify { $0.headers.add(name: "X-Trace", value: "server") }
			response.head.initialize(.init(version: request.head.version, status: .ok))
			response.head.commit()
			response.write(ByteBuffer(string: "ok"))
			response.end()
		}) { port in
			let (_, response) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/")!)
			return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Trace")
		}
		#expect(responseHeader == "server")
	}

	@Test func macroQueryParametersDecodeFromTheNIOHeadURI() async throws {
		let router = YoHTTPRouter()
		router.register(QueryEndpoint.self)
		router.registrationLocked()
		let value = try await withServer(handler: router.handler) { port in
			let (data, _) = try await URLSession.shared.data(
				from: URL(string: "http://127.0.0.1:\(port)/query?name=hello+world")!)
			return String(decoding: data, as: UTF8.self)
		}
		#expect(value == "hello world")
	}

	@Test func nioEncoderSuppressesHeadResponseBodies() async throws {
		let data = try await withServer(handler: { request, response in
			response.head.initialize(.init(version: request.head.version, status: .ok))
			response.write(ByteBuffer(string: "hidden"))
			response.end()
		}) { port in
			var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
			request.httpMethod = "HEAD"
			return try await URLSession.shared.data(for: request).0
		}
		#expect(data.isEmpty)
	}

	@Test func pauseAndResumeUseTheBodyControl() {
		let controls = Mutex<[Bool]>([])
		let stream = BodyStream(control: { paused in controls.withLock { $0.append(paused) }
		})
		stream.pause()
		stream.resume()
		#expect(controls.withLock { $0 } == [true, false])
	}

	@Test func serverStreamsRequestBodyAndEndsResponse() async throws {
		let server = YoHTTPServer()
		server.handler { request, response in
			let writer = response.writer()
			let count = Mutex(0)
			writer.head.initialize(.init(version: request.head.version, status: .ok))
			request.body.stream().onChunk { chunk in
				count.withLock { $0 += chunk.readableBytes }
			}.onEnd {
				writer.write(ByteBuffer(string: "\(count.withLock { $0 })"))
				writer.end()
			}
		}
		let listening = Task { try await server.listen(ServerConfiguration(port: 0)) }
		for _ in 0..<100 where server.localAddress == nil {
			try await Task.sleep(for: .milliseconds(2))
		}
		let port = try #require(server.localAddress?.port)
		var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload")!)
		request.httpMethod = "POST"
		request.httpBody = Data("hello".utf8)
		let (data, response) = try await URLSession.shared.data(for: request)
		#expect((response as? HTTPURLResponse)?.statusCode == 200)
		#expect(String(decoding: data, as: UTF8.self) == "5")
		try await server.shutdown()
		try await listening.value
	}
}

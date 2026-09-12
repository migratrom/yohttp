import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import Synchronization

public enum ServerError: Error, Sendable, Equatable, CustomStringConvertible {
	case alreadyListening
	case noHandler
	case invalidConfiguration(String)

	public var description: String {
		switch self {
		case .alreadyListening: "This server is already listening"
		case .noHandler: "Register a handler before listening"
		case .invalidConfiguration(let message): "Invalid server configuration: \(message)"
		}
	}
}

private final class ConnectionSignal: Sendable {
	enum Event: Sendable {
		case response(UUID, Response.Command)
		case pause(UUID, Bool)
		case requestTimeout(UUID)
		case responseTimeout(UUID)
	}

	private let events = Mutex<[Event]>([])
	private let channel: Channel

	init(channel: Channel) { self.channel = channel }

	func submit(_ event: Event) {
		events.withLock { $0.append(event) }
		channel.eventLoop.execute { [channel, self] in
			channel.pipeline.fireUserInboundEventTriggered(self)
		}
	}

	func drain() -> [Event] {
		events.withLock { events in
			defer { events.removeAll() }
			return events
		}
	}
}

private final class HTTPConnectionHandler: ChannelInboundHandler {
	typealias InboundIn = HTTPServerRequestPart
	typealias OutboundOut = HTTPServerResponsePart

	private struct ActiveRequest {
		let id: UUID
		let head: HTTPRequestHead
		let body: BodyStream
		var receivedBytes = 0
		var bodyEnded = false
		let expectsBody: Bool
		var responseStarted = false
		var responseEnded = false
		var forceClose = false
		var responseHead: HTTPResponseHead?
		var headModifiers: [@Sendable (inout HTTPResponseHead) -> Void] = []
		var requestTimer: Scheduled<Void>?
		var responseTimer: Scheduled<Void>?
	}

	private let handler: Handler
	private let configuration: ServerConfiguration
	private var signal: ConnectionSignal?
	private var current: ActiveRequest?

	init(handler: @escaping Handler, configuration: ServerConfiguration) {
		self.handler = handler
		self.configuration = configuration
	}

	func handlerAdded(context: ChannelHandlerContext) {
		signal = ConnectionSignal(channel: context.channel)
	}

	func channelRead(context: ChannelHandlerContext, data: NIOAny) {
		switch unwrapInboundIn(data) {
		case .head(let head): receiveHead(head, context: context)
		case .body(let buffer): receiveBody(buffer, context: context)
		case .end: receiveEnd(context: context)
		}
	}

	func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
		guard let signal, let received = event as? ConnectionSignal, received === signal
		else {
			context.fireUserInboundEventTriggered(event)
			return
		}
		for event in signal.drain() { apply(event, context: context) }
	}

	func channelInactive(context: ChannelHandlerContext) {
		if let current {
			current.requestTimer?.cancel()
			current.responseTimer?.cancel()
			current.body.fail(.cancelled)
		}
		self.current = nil
		context.fireChannelInactive()
	}

	func errorCaught(context: ChannelHandlerContext, error: Error) {
		context.close(promise: nil)
	}

	private func receiveHead(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
		guard current == nil, let signal else {
			context.close(promise: nil)
			return
		}
		let id = UUID()
		let body = BodyStream(control: { [signal] paused in
			signal.submit(.pause(id, paused))
		})
		let response = Response { [signal] command in signal.submit(.response(id, command))
		}
		var request = ActiveRequest(
			id: id, head: head, body: body,
			expectsBody: YoHTTPServer.requestHasBody(head)
		)
		if let timeout = configuration.requestTimeout {
			request.requestTimer = context.eventLoop.scheduleTask(
				in: Self.timeAmount(timeout)
			) {
				[signal] in
				signal.submit(.requestTimeout(id))
			}
		}
		current = request

		do {
			try handler(
				makeRequest(
					head: head, body: Body(stream: body),
					remoteAddress: context.channel.remoteAddress),
				response)
		} catch {
			writeError(error, requestHead: head, to: response)
		}
	}

	private func receiveBody(_ buffer: ByteBuffer, context: ChannelHandlerContext) {
		guard var request = current else {
			context.close(promise: nil)
			return
		}
		guard
			request.receivedBytes <= configuration.maxRequestBodySize
				- buffer.readableBytes
		else {
			request.body.fail(.tooLarge(limit: configuration.maxRequestBodySize))
			current = request
			timeoutRequest(
				status: .payloadTooLarge, message: "Content Too Large",
				context: context)
			return
		}
		request.receivedBytes += buffer.readableBytes
		current = request
		request.body.receive(buffer)
	}

	private func receiveEnd(context: ChannelHandlerContext) {
		guard var request = current else {
			context.close(promise: nil)
			return
		}
		request.bodyEnded = true
		request.requestTimer?.cancel()
		request.requestTimer = nil
		current = request
		request.body.finish()

		if request.responseEnded {
			completeRequest(context: context)
		} else {
			_ = context.channel.setOption(ChannelOptions.autoRead, value: false)
			if let timeout = configuration.responseTimeout, let signal {
				let requestID = request.id
				request.responseTimer = context.eventLoop.scheduleTask(
					in: Self.timeAmount(timeout)
				) {
					[signal] in
					signal.submit(.responseTimeout(requestID))
				}
				current = request
			}
		}
	}

	private func apply(_ event: ConnectionSignal.Event, context: ChannelHandlerContext) {
		guard var request = current else { return }
		switch event {
		case .response(let id, let command) where id == request.id:
			apply(command, to: &request, context: context)
			current = request
			if request.responseEnded, request.bodyEnded {
				completeRequest(context: context)
			}
		case .pause(let id, let paused) where id == request.id:
			_ = context.channel.setOption(ChannelOptions.autoRead, value: !paused)
			if !paused { context.read() }
		case .requestTimeout(let id) where id == request.id:
			request.body.fail(.timedOut)
			current = request
			timeoutRequest(
				status: .requestTimeout, message: "Request Timeout",
				context: context)
		case .responseTimeout(let id) where id == request.id:
			current = request
			if request.responseStarted {
				context.close(promise: nil)
			} else {
				timeoutRequest(
					status: .gatewayTimeout, message: "Gateway Timeout",
					context: context)
			}
		default:
			break
		}
	}

	private func apply(
		_ command: Response.Command, to request: inout ActiveRequest,
		context: ChannelHandlerContext
	) {
		guard !request.responseEnded else { return }
		switch command {
		case .initialize(let head):
			guard !request.responseStarted, request.responseHead == nil else {
				failResponse(&request, context: context)
				return
			}
			request.responseHead = head
		case .modify(let transform):
			guard !request.responseStarted else { return }
			request.headModifiers.append(transform)
		case .commit:
			guard commitResponse(&request, flush: true, context: context) else {
				failResponse(&request, context: context)
				return
			}
		case .write(let buffer):
			guard commitResponse(&request, flush: false, context: context) else {
				failResponse(&request, context: context)
				return
			}
			if buffer.readableBytes > 0 {
				context.write(
					wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
			}
		case .end(let trailers):
			guard commitResponse(&request, flush: false, context: context) else {
				failResponse(&request, context: context)
				return
			}
			request.responseEnded = true
			request.responseTimer?.cancel()
			request.responseTimer = nil
			if request.expectsBody && !request.bodyEnded { request.forceClose = true }
			context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
		}
	}

	@discardableResult
	private func commitResponse(
		_ request: inout ActiveRequest, flush: Bool, context: ChannelHandlerContext
	) -> Bool {
		if request.responseStarted { return true }
		guard var head = request.responseHead else { return false }
		for transform in request.headModifiers { transform(&head) }
		request.headModifiers.removeAll()
		if let serverName = configuration.serverName,
			head.headers.first(name: "server") == nil
		{
			head.headers.add(name: "Server", value: serverName)
		}
		request.responseHead = head
		let part = wrapOutboundOut(.head(head))
		if flush {
			context.writeAndFlush(part, promise: nil)
		} else {
			context.write(part, promise: nil)
		}
		request.responseStarted = true
		return true
	}

	private func failResponse(
		_ request: inout ActiveRequest, context: ChannelHandlerContext
	) {
		request.forceClose = true
		if !request.responseStarted {
			let head = HTTPResponseHead(
				version: request.head.version, status: .internalServerError)
			context.write(wrapOutboundOut(.head(head)), promise: nil)
			context.write(
				wrapOutboundOut(
					.body(.byteBuffer(ByteBuffer(string: "Internal Server Error")))),
				promise: nil)
			request.responseStarted = true
		}
		request.responseEnded = true
		context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
	}

	private func completeRequest(context: ChannelHandlerContext) {
		guard let request = current else { return }
		request.requestTimer?.cancel()
		request.responseTimer?.cancel()
		current = nil
		if request.forceClose || !request.head.isKeepAlive {
			context.close(promise: nil)
		} else {
			_ = context.channel.setOption(ChannelOptions.autoRead, value: true)
			context.read()
		}
	}

	private func timeoutRequest(
		status: HTTPResponseStatus, message: String, context: ChannelHandlerContext
	)
	{
		guard var request = current else { return }
		request.requestTimer?.cancel()
		request.responseTimer?.cancel()
		request.forceClose = true
		if !request.responseStarted {
			request.responseHead = HTTPResponseHead(
				version: request.head.version, status: status)
			_ = commitResponse(&request, flush: false, context: context)
			context.write(
				wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: message)))),
				promise: nil)
			context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
			request.responseEnded = true
		}
		current = request
		context.close(promise: nil)
	}

	private func writeError(
		_ error: Error, requestHead: HTTPRequestHead, to response: borrowing Response
	) {
		if let error = error as? any HTTPError {
			response.head.initialize(
				HTTPResponseHead(
					version: requestHead.version, status: error.status, headers: error.headers))
			response.write(error.body)
			response.end()
		} else {
			response.head.initialize(
				HTTPResponseHead(version: requestHead.version, status: .internalServerError))
			response.write(ByteBuffer(string: "Internal Server Error"))
			response.end()
		}
	}

	private func makeRequest(
		head: HTTPRequestHead, body: Body, remoteAddress: NIOCore.SocketAddress?
	)
		-> Request
	{
		Request(
			head: head, body: body, remoteAddress: remoteAddress)
	}

	private static func timeAmount(_ duration: Duration) -> TimeAmount {
		let parts = duration.components
		let nanos = parts.seconds.multipliedReportingOverflow(by: 1_000_000_000)
		let fractional = parts.attoseconds / 1_000_000_000
		return .nanoseconds(nanos.overflow ? Int64.max : nanos.partialValue + fractional)
	}
}

/// An event-loop-native HTTP/1.1 server backed by SwiftNIO.
public final class YoHTTPServer: Sendable {
	private struct State: Sendable {
		var channel: Channel?
		var connections: [ObjectIdentifier: Channel] = [:]
		var address: NIOCore.SocketAddress?
		var isBinding = false
		var shutdownRequested = false
	}

	private final class StateStorage: Sendable {
		let value = Mutex(State())
	}

	private let state = StateStorage()
	private let registeredHandler = Mutex<Handler?>(nil)
	private let runtimeConfiguration: ServerRuntimeConfiguration
	private let eventLoopGroup: MultiThreadedEventLoopGroup
	private let afterBinding: (@Sendable () async -> Void)?

	public convenience init() { self.init(runtimeConfiguration: .init()) }

	public convenience init(runtimeConfiguration: ServerRuntimeConfiguration) {
		self.init(runtimeConfiguration: runtimeConfiguration, afterBinding: nil)
	}

	convenience init(afterBinding: (@Sendable () async -> Void)?) {
		self.init(runtimeConfiguration: .init(), afterBinding: afterBinding)
	}

	private init(
		runtimeConfiguration: ServerRuntimeConfiguration,
		afterBinding: (@Sendable () async -> Void)?
	) {
		self.runtimeConfiguration = runtimeConfiguration
		self.afterBinding = afterBinding
		eventLoopGroup = MultiThreadedEventLoopGroup(
			numberOfThreads: max(1, runtimeConfiguration.eventLoopCount))
	}

	deinit { try? eventLoopGroup.syncShutdownGracefully() }

	public var localAddress: SocketAddress? { state.value.withLock { $0.address } }
	public func handler(_ handler: @escaping Handler) {
		registeredHandler.withLock { $0 = handler }
	}
	public func handler(_ router: YoHTTPRouter) { handler(router.handler) }
	public func listen(_ host: String = "127.0.0.1", _ port: Int) async throws {
		try await listen(ServerConfiguration(hostname: host, port: port))
	}

	public func listen(_ configuration: ServerConfiguration) async throws {
		try Self.validate(configuration, runtime: runtimeConfiguration)
		guard let handler = registeredHandler.withLock({ $0 }) else {
			throw ServerError.noHandler
		}
		let sslContext = try configuration.tls.map(Self.makeSSLContext)
		let claimed = state.value.withLock { state -> Bool in
			guard state.channel == nil, !state.isBinding else { return false }
			state.isBinding = true
			state.shutdownRequested = false
			return true
		}
		guard claimed else { throw ServerError.alreadyListening }
		do {
			let server = try await ServerBootstrap(group: eventLoopGroup)
				.serverChannelOption(
					ChannelOptions.backlog, value: Int32(configuration.backlog)
				)
				.serverChannelOption(
					ChannelOptions.socketOption(.so_reuseaddr),
					value: configuration.reuseAddress ? 1 : 0
				)
				.childChannelOption(
					ChannelOptions.socketOption(.tcp_nodelay), value: 1
				)
				.childChannelInitializer { [weak self] channel in
					let state = self?.state
					do {
						if let sslContext {
							try channel.pipeline.syncOperations
								.addHandler(
									NIOSSLServerHandler(
										context: sslContext)
								)
						}
						try channel.pipeline.syncOperations
							.configureHTTPServerPipeline()
						try channel.pipeline.syncOperations.addHandler(
							HTTPConnectionHandler(
								handler: handler,
								configuration: configuration))
					} catch {
						return channel.eventLoop.makeFailedFuture(error)
					}
					let id = ObjectIdentifier(channel)
					state?.value.withLock { $0.connections[id] = channel }
					channel.closeFuture.whenComplete { _ in
						_ = state?.value.withLock {
							$0.connections.removeValue(forKey: id)
						}
					}
					return channel.eventLoop.makeSucceededFuture(())
				}
				.bind(host: configuration.hostname, port: configuration.port)
				.get()
			if let afterBinding { await afterBinding() }
			let stop = state.value.withLock { state -> Bool in
				state.channel = server
				state.address = server.localAddress
				state.isBinding = false
				return state.shutdownRequested
			}
			if stop { server.close(mode: .all, promise: nil) }
			try await withTaskCancellationHandler(
				operation: { try await server.closeFuture.get() },
				onCancel: { server.close(mode: .all, promise: nil) }
			)
		} catch {
			clearState()
			throw error
		}
		clearState()
	}

	public func shutdown() async throws {
		let channels = state.value.withLock { state in
			state.shutdownRequested = true
			return [state.channel].compactMap { $0 } + Array(state.connections.values)
		}
		for channel in channels where channel.isActive { try? await channel.close().get() }
	}

	private func clearState() {
		state.value.withLock { state in
			state.channel = nil
			state.connections.removeAll()
			state.address = nil
			state.isBinding = false
			state.shutdownRequested = false
		}
	}

	private static func validate(
		_ configuration: ServerConfiguration, runtime: ServerRuntimeConfiguration
	) throws {
		guard runtime.eventLoopCount > 0 else {
			throw ServerError.invalidConfiguration("eventLoopCount must be positive")
		}
		guard !configuration.hostname.isEmpty else {
			throw ServerError.invalidConfiguration("hostname must not be empty")
		}
		guard (0...65_535).contains(configuration.port) else {
			throw ServerError.invalidConfiguration("port must be between 0 and 65535")
		}
		guard configuration.backlog > 0 else {
			throw ServerError.invalidConfiguration("backlog must be positive")
		}
		guard configuration.maxRequestBodySize >= 0 else {
			throw ServerError.invalidConfiguration(
				"maxRequestBodySize must not be negative")
		}
		if let timeout = configuration.requestTimeout, timeout < .zero {
			throw ServerError.invalidConfiguration(
				"requestTimeout must not be negative")
		}
		if let timeout = configuration.responseTimeout, timeout < .zero {
			throw ServerError.invalidConfiguration(
				"responseTimeout must not be negative")
		}
		if let tls = configuration.tls {
			guard !tls.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else {
				throw ServerError.invalidConfiguration(
					"TLS private key must not be empty")
			}
			guard !tls.cert.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else {
				throw ServerError.invalidConfiguration(
					"TLS certificate chain must not be empty")
			}
		}
	}

	private static func makeSSLContext(_ tls: TLS) throws -> NIOSSLContext {
		let certificates: [NIOSSLCertificate]
		do { certificates = try NIOSSLCertificate.fromPEMBytes(Array(tls.cert.utf8)) } catch
		{
			throw ServerError.invalidConfiguration(
				"TLS certificate chain is not valid PEM")
		}
		guard !certificates.isEmpty else {
			throw ServerError.invalidConfiguration(
				"TLS certificate chain is not valid PEM")
		}
		let key: NIOSSLPrivateKey
		do { key = try NIOSSLPrivateKey(bytes: Array(tls.key.utf8), format: .pem) } catch {
			throw ServerError.invalidConfiguration("TLS private key is not valid PEM")
		}
		do {
			var configuration = TLSConfiguration.makeServerConfiguration(
				certificateChain: certificates.map { .certificate($0) },
				privateKey: .privateKey(key))
			configuration.applicationProtocols = ["http/1.1"]
			return try NIOSSLContext(configuration: configuration)
		} catch {
			throw ServerError.invalidConfiguration(
				"TLS credentials could not be loaded")
		}
	}

	static func requestHasBody(_ head: HTTPRequestHead) -> Bool {
		for header in head.headers {
			if header.name.caseInsensitiveCompare("transfer-encoding") == .orderedSame {
				return true
			}
			if header.name.caseInsensitiveCompare("content-length") == .orderedSame,
				(Int(header.value.trimmingCharacters(in: .whitespacesAndNewlines))
					?? 0) > 0
			{
				return true
			}
		}
		return false
	}

}

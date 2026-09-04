import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
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

private typealias SendableResponsePart = HTTPPart<HTTPResponseHead, ByteBuffer>

private final class SendableResponseEncoder: ChannelOutboundHandler, RemovableChannelHandler {
    typealias OutboundIn = SendableResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        switch unwrapOutboundIn(data) {
        case .head(let head):
            context.write(wrapOutboundOut(.head(head)), promise: promise)
        case .body(let body):
            context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: promise)
        case .end(let trailers):
            context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

private struct HTTPConnection: Sendable {
    let channel: NIOAsyncChannel<HTTPServerRequestPart, SendableResponsePart>
    let remoteAddress: SocketAddress?
}

/// A bounded, single-reader bridge between the NIO connection task and a handler.
/// Suspending `send` stops consumption from `NIOAsyncChannel`, whose own watermarks
/// then apply back pressure to the socket.
actor RequestBodyChannel: BodyStorage {
    private let capacity: Int
    private var buffered: [ByteBuffer] = []
    private var reader: CheckedContinuation<ByteBuffer?, Swift.Error>?
    private var writers: [CheckedContinuation<Void, Swift.Error>] = []
    private var finished = false
    private var cancelled = false
    private var reachedEnd = false

    init(capacity: Int = 8) {
        self.capacity = capacity
    }

    func send(_ buffer: ByteBuffer) async throws {
        guard !cancelled, !finished else { throw CancellationError() }
        if let reader {
            self.reader = nil
            reader.resume(returning: buffer)
            return
        }
        while buffered.count >= capacity {
            try await withCheckedThrowingContinuation { continuation in
                writers.append(continuation)
            }
            guard !cancelled, !finished else { throw CancellationError() }
        }
        buffered.append(buffer)
    }

    func nextChunk() async throws -> ByteBuffer? {
        if !buffered.isEmpty {
            let buffer = buffered.removeFirst()
            if !writers.isEmpty {
                writers.removeFirst().resume()
            }
            return buffer
        }
        if cancelled { throw CancellationError() }
        if finished {
            reachedEnd = true
            return nil
        }
        let value = try await withCheckedThrowingContinuation { continuation in
            reader = continuation
        }
        if value == nil { reachedEnd = true }
        return value
    }

    func finish() {
        guard !finished, !cancelled else { return }
        finished = true
        if buffered.isEmpty, let reader {
            self.reader = nil
            reader.resume(returning: nil)
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        if let reader {
            self.reader = nil
            reader.resume(throwing: CancellationError())
        }
        for writer in writers {
            writer.resume(throwing: CancellationError())
        }
        writers.removeAll()
        buffered.removeAll()
    }

    func hasReachedEnd() -> Bool { reachedEnd }
}

private actor ResponseResult {
    private var response: Response?
    private var waiter: CheckedContinuation<Response, Never>?

    func complete(_ response: Response) {
        guard self.response == nil else { return }
        self.response = response
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: response)
        }
    }

    func value() async -> Response {
        if let response { return response }
        return await withCheckedContinuation { waiter = $0 }
    }

    func peek() -> Response? { response }
}

/// A Swift Concurrency-native HTTP/1.1 server backed by SwiftNIO.
public final class YoHTTPServer: Sendable {
    private struct State: Sendable {
        var channel: Channel?
        var connections: [ObjectIdentifier: Channel] = [:]
        var address: SocketAddress?
        var isBinding = false
        var shutdownRequested = false
    }

    private let state = Mutex(State())
    private let registeredHandler = Mutex<Handler?>(nil)
    private let eventLoopGroup: MultiThreadedEventLoopGroup
    private let afterBinding: (@Sendable () async -> Void)?

    public convenience init() {
        self.init(afterBinding: nil)
    }

    init(afterBinding: (@Sendable () async -> Void)?) {
        self.afterBinding = afterBinding
        eventLoopGroup = .singleton
    }

    /// The actual local address after binding. This is especially useful when configured with port `0`.
    public var localAddress: SocketAddress? {
        state.withLock { $0.address }
    }

    public func handler(_ handler: @escaping Handler) {
        registeredHandler.withLock { $0 = handler }
    }

    public func handler(_ router: YoHTTPRouter) {
        handler(router.handler)
    }

    public func listen(_ host: String = "127.0.0.1", _ port: Int) async throws {
        try await listen(ServerConfiguration(hostname: host, port: port))
    }

    /// Binds and serves until `shutdown()` is called, the task is cancelled, or the listener fails.
    public func listen(_ configuration: ServerConfiguration) async throws {
        try Self.validate(configuration)
        guard registeredHandler.withLock({ $0 != nil }) else { throw ServerError.noHandler }
        let claimed = state.withLock { state -> Bool in
            guard state.channel == nil, !state.isBinding else { return false }
            state.isBinding = true
            state.shutdownRequested = false
            return true
        }
        guard claimed else { throw ServerError.alreadyListening }

        do {
            let serverChannel = try await makeServerChannel(configuration: configuration)
            if let afterBinding { await afterBinding() }
            let shouldStop = state.withLock { state in
                state.channel = serverChannel.channel
                state.address = Self.address(from: serverChannel.channel.localAddress!)
                state.isBinding = false
                return state.shutdownRequested
            }
            if shouldStop { serverChannel.channel.close(promise: nil) }

            try await withTaskCancellationHandler {
                try await serve(serverChannel, configuration: configuration)
            } onCancel: {
                let channel = self.state.withLock { $0.channel }
                channel?.close(promise: nil)
            }
        } catch {
            clearState()
            throw error
        }
        clearState()
    }

    public func shutdown() async throws {
        let channels = state.withLock { state in
            state.shutdownRequested = true
            return [state.channel].compactMap { $0 } + Array(state.connections.values)
        }
        for channel in channels where channel.isActive {
            do {
                try await channel.close().get()
            } catch ChannelError.alreadyClosed {
                // Closing is idempotent from the public API's perspective.
            }
        }
    }

    private func makeServerChannel(
        configuration: ServerConfiguration
    ) async throws -> NIOAsyncChannel<HTTPConnection, Never> {
        try await ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.backlog))
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: configuration.reuseAddress ? 1 : 0
            )
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .bind(
                host: configuration.hostname,
                port: configuration.port,
                serverBackPressureStrategy: nil
            ) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(SendableResponseEncoder())
                    let asyncChannel = try NIOAsyncChannel<HTTPServerRequestPart, SendableResponsePart>(
                        wrappingChannelSynchronously: channel
                    )
                    return HTTPConnection(
                        channel: asyncChannel,
                        remoteAddress: Self.address(from: channel.remoteAddress!)
                    )
                }
            }
    }

    private func serve(
        _ serverChannel: NIOAsyncChannel<HTTPConnection, Never>,
        configuration: ServerConfiguration
    ) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel.executeThenClose { inbound in
                for try await connection in inbound {
                    let channel = connection.channel.channel
                    let identifier = ObjectIdentifier(channel)
                    state.withLock { $0.connections[identifier] = channel }
                    group.addTask { [self] in
                        defer { _ = state.withLock { $0.connections.removeValue(forKey: identifier) } }
                        do {
                            try await handle(connection, configuration: configuration)
                        } catch {
                            // A failed client connection must not terminate the listener.
                        }
                    }
                }
            }
        }
    }

    private func handle(_ connection: HTTPConnection, configuration: ServerConfiguration) async throws {
        try await connection.channel.executeThenClose { inbound, outbound in
            var current: (head: HTTPRequestHead, body: RequestBodyChannel, result: ResponseResult, task: Task<Void, Never>, responseWriter: Task<Bool, Swift.Error>?, receivedBytes: Int, expectsBody: Bool)?

            for try await part in inbound {
                switch part {
                case .head(let head):
                    guard current == nil else { throw Abort(.badRequest, body: "Request head received before prior request ended") }
                    let body = RequestBodyChannel()
                    let result = ResponseResult()
                    let request = makeRequest(head: head, body: Body(storage: body), remoteAddress: connection.remoteAddress)
                    let task = Task { [self] in
                        let response = await response(for: request, timeout: configuration.requestTimeout)
                        await result.complete(response)
                    }
                    current = (head, body, result, task, nil, 0, Self.requestHasBody(head))
                case .body(let buffer):
                    guard var request = current else { throw Abort(.badRequest, body: "Body received before request head") }
                    guard request.receivedBytes <= configuration.maxRequestBodySize - buffer.readableBytes else {
                        request.task.cancel()
                        await request.body.cancel()
                        _ = try await write(
                            Response.text("Content Too Large", status: .contentTooLarge),
                            for: request.head,
                            to: outbound,
                            configuration: configuration,
                            forceClose: true
                        )
                        return
                    }
                    if request.responseWriter == nil, let response = await request.result.peek() {
                        guard response.body.sharesStorage(with: Body(storage: request.body)) else {
                            await request.body.cancel()
                            _ = try await write(response, for: request.head, to: outbound, configuration: configuration, forceClose: true)
                            return
                        }
                        let responseToWrite = response
                        let requestHead = request.head
                        let outboundWriter = outbound
                        let serverConfiguration = configuration
                        request.responseWriter = Task { @Sendable [self] in
                            try await write(
                                responseToWrite,
                                for: requestHead,
                                to: outboundWriter,
                                configuration: serverConfiguration
                            )
                        }
                    }
                    request.receivedBytes += buffer.readableBytes
                    current = request
                    try await request.body.send(buffer)
                case .end:
                    guard let request = current else { throw Abort(.badRequest, body: "Request ended before request head") }
                    await request.body.finish()
                    if let writer = request.responseWriter {
                        let keepAlive = try await writer.value
                        current = nil
                        if !keepAlive { return }
                        continue
                    }
                    let response = await request.result.value()
                    let streamsRequestBody = response.body.sharesStorage(with: Body(storage: request.body))
                    let reachedEnd = await request.body.hasReachedEnd()
                    let forceClose = request.expectsBody && !reachedEnd && !streamsRequestBody
                    let keepAlive = try await write(
                        response,
                        for: request.head,
                        to: outbound,
                        configuration: configuration,
                        forceClose: forceClose
                    )
                    current = nil
                    if !keepAlive { return }
                }
            }
        }
    }

    private func response(for request: Request, timeout: Duration?) async -> Response {
        let handler = registeredHandler.withLock { $0! }
        do {
            if let timeout {
                return try await Self.withTimeout(timeout) { try await handler(request) }
            }
            return try await handler(request)
        } catch let error as any HTTPError {
            return Response(status: error.status, headers: error.headers, body: error.body)
        } catch is TimeoutError {
            return .text("Request Timeout", status: .requestTimeout)
        } catch {
            return .text("Internal Server Error", status: .internalServerError)
        }
    }

    private func makeRequest(
        head: HTTPRequestHead,
        body: Body,
        remoteAddress: SocketAddress?
    ) -> Request {
        var headers = Headers()
        for field in head.headers { headers.add(field.name, field.value) }
        return Request(
            method: Method(rawValue: head.method.rawValue),
            uri: head.uri,
            headers: headers,
            body: body,
            remoteAddress: remoteAddress
        )
    }

    private func write(
        _ response: Response,
        for requestHead: HTTPRequestHead,
        to outbound: NIOAsyncChannelOutboundWriter<SendableResponsePart>,
        configuration: ServerConfiguration,
        forceClose: Bool = false
    ) async throws -> Bool {
        var response = response
        if (100..<200).contains(response.status.code) {
            response = .text("Internal Server Error", status: .internalServerError)
        }
        let requestMethod = Method(rawValue: requestHead.method.rawValue)
        let statusOmitsBody = (100..<200).contains(response.status.code)
            || response.status.code == 204
            || response.status.code == 304
        let omitBody = statusOmitsBody || requestMethod == .HEAD
        var headers = response.headers
        headers.remove("Transfer-Encoding")
        headers.remove("Content-Length")
        if statusOmitsBody {
            headers["Content-Length"] = "0"
        } else if let length = response.body.knownLength {
            headers["Content-Length"] = String(length)
        } else if requestMethod != .HEAD {
            headers["Transfer-Encoding"] = "chunked"
        }
        if let serverName = configuration.serverName, !headers.contains("Server") {
            headers["Server"] = serverName
        }

        let keepAlive = !forceClose && requestHead.isKeepAlive
        if !keepAlive { headers["Connection"] = "close" }

        var nioHeaders = HTTPHeaders()
        for (name, value) in headers { nioHeaders.add(name: name, value: value) }
        let version = requestHead.version
        let status = HTTPResponseStatus(statusCode: response.status.code, reasonPhrase: response.status.reasonPhrase)

        try await outbound.write(.head(HTTPResponseHead(version: version, status: status, headers: nioHeaders)))
        if !omitBody {
            for try await chunk in response.body where chunk.readableBytes > 0 {
                try await outbound.write(.body(chunk))
            }
        }
        try await outbound.write(.end(nil))
        if !keepAlive { outbound.finish() }
        return keepAlive
    }

    private func clearState() {
        state.withLock { state in
            state.channel = nil
            state.connections.removeAll()
            state.address = nil
            state.isBinding = false
            state.shutdownRequested = false
        }
    }

    private static func validate(_ configuration: ServerConfiguration) throws {
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
            throw ServerError.invalidConfiguration("maxRequestBodySize must not be negative")
        }
    }

    static func requestHasBody(_ head: HTTPRequestHead) -> Bool {
        for header in head.headers {
            if header.name.caseInsensitiveCompare("transfer-encoding") == .orderedSame {
                return true
            }
            if header.name.caseInsensitiveCompare("content-length") == .orderedSame,
               (Int(header.value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0 {
                return true
            }
        }
        return false
    }

    private static func address(from address: NIOCore.SocketAddress) -> SocketAddress {
        SocketAddress(host: address.ipAddress!, port: address.port)
    }

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

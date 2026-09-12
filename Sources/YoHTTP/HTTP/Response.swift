import NIOCore
import NIOHTTP1

/// A staged HTTP response head.
///
/// Initialize and optionally modify the head before committing it. ``commit()``
/// flushes the head immediately; ``Response/write(_:)`` and ``Response/end(_:)``
/// commit it automatically when needed.
public final class ResponseHead: Sendable {
	private let submit: @Sendable (Response.Command) -> Void

	fileprivate init(submit: @escaping @Sendable (Response.Command) -> Void) {
		self.submit = submit
	}

	public func initialize(_ head: HTTPResponseHead) { submit(.initialize(head)) }
	public func modify(
		_ transform: @escaping @Sendable (inout HTTPResponseHead) -> Void
	) { submit(.modify(transform)) }
	public func commit() { submit(.commit) }
}

/// A copyable writer retained by an asynchronous callback.
public final class ResponseWriter: Sendable {
	private let submit: @Sendable (Response.Command) -> Void
	public let head: ResponseHead

	fileprivate init(submit: @escaping @Sendable (Response.Command) -> Void) {
		self.submit = submit
		head = ResponseHead(submit: submit)
	}

	public func write(_ buffer: ByteBuffer) { submit(.write(buffer)) }
	public func end(_ trailers: HTTPHeaders? = nil) { submit(.end(trailers)) }
}

/// A move-only, event-driven HTTP response capability.
///
/// Use it synchronously while handling a request. To retain a writer for an
/// asynchronous callback or application-owned executor, call ``writer()``.
public struct Response: ~Copyable, Sendable {
	enum Command: Sendable {
		case initialize(HTTPResponseHead)
		case modify(@Sendable (inout HTTPResponseHead) -> Void)
		case commit
		case write(ByteBuffer)
		case end(HTTPHeaders?)
	}

	private let storage: ResponseWriter

	init(submit: @escaping @Sendable (Command) -> Void) {
		storage = ResponseWriter(submit: submit)
	}

	/// Returns a copyable writer suitable for retaining in asynchronous work.
	public func writer() -> ResponseWriter { storage }
	public var head: ResponseHead { storage.head }
	public func write(_ buffer: ByteBuffer) { storage.write(buffer) }
	public func end(_ trailers: HTTPHeaders? = nil) { storage.end(trailers) }
}

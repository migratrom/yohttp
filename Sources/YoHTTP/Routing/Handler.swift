import NIOCore
import NIOHTTP1

public typealias Handler = @Sendable (consuming Request, borrowing Response) throws -> Void
public typealias Middleware = @Sendable (consuming Request, borrowing Response, Next) throws -> Void

public struct Next: Sendable {
	private let handler: Handler
	public init(_ handler: @escaping Handler) { self.handler = handler }
	public func callAsFunction(
		_ request: consuming Request, _ response: borrowing Response
	) throws {
		try handler(request, response)
	}
}

public protocol HTTPError: Error, Sendable {
	var status: HTTPResponseStatus { get }
	var headers: HTTPHeaders { get }
	var body: ByteBuffer { get }
}

public struct Abort: HTTPError {
	public let status: HTTPResponseStatus
	public let headers: HTTPHeaders
	public let body: ByteBuffer

	public init(
		_ status: HTTPResponseStatus,
		headers: HTTPHeaders = .init(),
		body: ByteBuffer = .init()
	) {
		self.status = status
		self.headers = headers
		self.body = body
	}
}

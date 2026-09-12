import NIOCore
import NIOHTTP1

public struct Request: ~Copyable, Sendable {
	public let head: HTTPRequestHead
	public let body: Body
	public let parameters: [String: String]
	public let remoteAddress: SocketAddress?

	public init(
		head: HTTPRequestHead,
		body: Body = .empty,
		parameters: [String: String] = [:],
		remoteAddress: SocketAddress? = nil
	) {
		self.head = head
		self.body = body
		self.parameters = parameters
		self.remoteAddress = remoteAddress
	}

	consuming func with(parameters: [String: String]) -> Request {
		Request(
			head: head,
			body: body,
			parameters: parameters,
			remoteAddress: remoteAddress
		)
	}
}

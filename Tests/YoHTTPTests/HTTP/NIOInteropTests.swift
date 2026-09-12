import Testing

@testable import YoHTTP

@Suite("NIO-native HTTP surface")
struct NIOInteropTests {
	@Test func requestRetainsTheNIOHeadAndRouteParameters() {
		var headers = HTTPHeaders()
		headers.add(name: "X-Trace", value: "one")
		let head = HTTPRequestHead(
			version: .http1_1, method: .POST, uri: "/todos/1?draft=true", headers: headers)
		let request = Request(head: head, parameters: ["id": "1"])

		#expect(request.head == head)
		#expect(request.parameters == ["id": "1"])
		#expect(request.head.headers.first(name: "x-trace") == "one")
	}

	@Test func yoHTTPReexportsNIOCoreAndNIOHTTP1() {
		let status: HTTPResponseStatus = .unprocessableEntity
		let buffer = ByteBuffer(string: "body")
		let head = HTTPResponseHead(version: .http1_1, status: status)

		#expect(head.status == .unprocessableEntity)
		#expect(buffer.readableBytes == 4)
	}
}

public typealias Handler = @Sendable (Request) async throws -> Response
public typealias Middleware = @Sendable (Request, Next) async throws -> Response

public struct Next: Sendable {
    private let handler: Handler
    public init(_ handler: @escaping Handler) { self.handler = handler }
    public func callAsFunction(_ request: Request) async throws -> Response {
        try await handler(request)
    }
}

public protocol HTTPError: Error, Sendable {
    var status: Status { get }
    var headers: Headers { get }
    var body: Body { get }
}

public struct Abort: HTTPError {
    public let status: Status
    public let headers: Headers
    public let body: Body

    public init(_ status: Status, headers: Headers = .init(), body: String = "") {
        self.status = status
        self.headers = headers
        self.body = Body(body)
    }

    public init(_ status: Status, headers: Headers = .init(), body: Body) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

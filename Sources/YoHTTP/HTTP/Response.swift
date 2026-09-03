import Foundation

public struct Response: Sendable, Equatable {
    public var status: Status
    public var headers: Headers
    public var body: Body

    public init(status: Status = .ok, headers: Headers = .init(), body: Body = .empty) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public init(status: Status = .ok, headers: Headers = .init(), body: String) {
        self.init(status: status, headers: headers, body: Body(body))
    }

    public static func text(
        _ value: String,
        status: Status = .ok,
        headers: Headers = .init()
    ) -> Response {
        var headers = headers
        headers["Content-Type"] = MediaType.text.rawValue
        return Response(status: status, headers: headers, body: value)
    }

    public static func html(
        _ value: String,
        status: Status = .ok,
        headers: Headers = .init()
    ) -> Response {
        var headers = headers
        headers["Content-Type"] = MediaType.html.rawValue
        return Response(status: status, headers: headers, body: value)
    }

    public static func json<T: Encodable>(
        _ value: T,
        status: Status = .ok,
        headers: Headers = .init(),
        encoder: JSONEncoder = .init()
    ) throws -> Response {
        var headers = headers
        headers["Content-Type"] = MediaType.json.rawValue
        return Response(status: status, headers: headers, body: Body(try encoder.encode(value)))
    }

    public static func redirect(
        _ location: String,
        status: Status = .found,
        headers: Headers = .init()
    ) -> Response {
        var headers = headers
        headers["Location"] = location
        return Response(status: status, headers: headers)
    }

    public mutating func cookie(_ cookie: Cookie) {
        headers.add("Set-Cookie", cookie.serialized())
    }

    public mutating func deleteCookie(_ name: String, path: String = "/") {
        cookie(Cookie(name: name, value: "", path: path, expires: Date(timeIntervalSince1970: 0), maxAge: .zero))
    }
}

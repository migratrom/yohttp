import Foundation

public struct Method: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible
{
    public let rawValue: String
    public var description: String { rawValue }

    public init(rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let GET: Self = "GET"
    public static let POST: Self = "POST"
    public static let PUT: Self = "PUT"
    public static let PATCH: Self = "PATCH"
    public static let DELETE: Self = "DELETE"
    public static let HEAD: Self = "HEAD"
    public static let OPTIONS: Self = "OPTIONS"
    public static let CONNECT: Self = "CONNECT"
    public static let TRACE: Self = "TRACE"
}

public struct Status: Hashable, Sendable, CustomStringConvertible {
    public let code: Int
    public let reasonPhrase: String
    public var description: String { "\(code) \(reasonPhrase)" }

    public init(_ code: Int, reasonPhrase: String) {
        self.code = code
        self.reasonPhrase = reasonPhrase
    }

    public init(_ code: Int) {
        self.init(code, reasonPhrase: Self.standardReason(for: code) ?? "")
    }

    public static let `continue` = Status(100, reasonPhrase: "Continue")
    public static let switchingProtocols = Status(101, reasonPhrase: "Switching Protocols")
    public static let ok = Status(200, reasonPhrase: "OK")
    public static let created = Status(201, reasonPhrase: "Created")
    public static let accepted = Status(202, reasonPhrase: "Accepted")
    public static let noContent = Status(204, reasonPhrase: "No Content")
    public static let movedPermanently = Status(301, reasonPhrase: "Moved Permanently")
    public static let found = Status(302, reasonPhrase: "Found")
    public static let seeOther = Status(303, reasonPhrase: "See Other")
    public static let notModified = Status(304, reasonPhrase: "Not Modified")
    public static let temporaryRedirect = Status(307, reasonPhrase: "Temporary Redirect")
    public static let permanentRedirect = Status(308, reasonPhrase: "Permanent Redirect")
    public static let badRequest = Status(400, reasonPhrase: "Bad Request")
    public static let unauthorized = Status(401, reasonPhrase: "Unauthorized")
    public static let forbidden = Status(403, reasonPhrase: "Forbidden")
    public static let notFound = Status(404, reasonPhrase: "Not Found")
    public static let methodNotAllowed = Status(405, reasonPhrase: "Method Not Allowed")
    public static let requestTimeout = Status(408, reasonPhrase: "Request Timeout")
    public static let conflict = Status(409, reasonPhrase: "Conflict")
    public static let lengthRequired = Status(411, reasonPhrase: "Length Required")
    public static let contentTooLarge = Status(413, reasonPhrase: "Content Too Large")
    public static let unsupportedMediaType = Status(415, reasonPhrase: "Unsupported Media Type")
    public static let unprocessableContent = Status(422, reasonPhrase: "Unprocessable Content")
    public static let tooManyRequests = Status(429, reasonPhrase: "Too Many Requests")
    public static let requestHeaderFieldsTooLarge = Status(431, reasonPhrase: "Request Header Fields Too Large")
    public static let internalServerError = Status(500, reasonPhrase: "Internal Server Error")
    public static let notImplemented = Status(501, reasonPhrase: "Not Implemented")
    public static let badGateway = Status(502, reasonPhrase: "Bad Gateway")
    public static let serviceUnavailable = Status(503, reasonPhrase: "Service Unavailable")

    private static func standardReason(for code: Int) -> String? {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 204: "No Content"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: nil
        }
    }
}

public struct MediaType: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(rawValue: value) }

    public static let json: Self = "application/json"
    public static let text: Self = "text/plain; charset=utf-8"
    public static let html: Self = "text/html; charset=utf-8"
    public static let formURLEncoded: Self = "application/x-www-form-urlencoded"
    public static let multipartFormData: Self = "multipart/form-data"
    public static let octetStream: Self = "application/octet-stream"
}

public struct SocketAddress: Sendable, Hashable, CustomStringConvertible {
    public let host: String
    public let port: Int?
    public var description: String { port.map { "\(host):\($0)" } ?? host }

    public init(host: String, port: Int? = nil) {
        self.host = host
        self.port = port
    }
}

import Foundation

public struct QueryParameters: Sendable, Sequence, Equatable {
    private var storage: [String: [String]]

    public init(_ storage: [String: [String]] = [:]) { self.storage = storage }
    public subscript(_ name: String) -> String? { storage[name]?.first }
    public func values(for name: String) -> [String] { storage[name] ?? [] }
    public func contains(_ name: String) -> Bool { storage[name] != nil }
    public func makeIterator() -> Dictionary<String, [String]>.Iterator { storage.makeIterator() }

    static func parse(uri: String) -> (path: String, query: QueryParameters) {
        let pieces = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? "/"
        guard pieces.count == 2 else { return (rawPath, .init()) }

        var values: [String: [String]] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { continue }
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = decodeQueryComponent(String(parts[0]))
            let value = parts.count == 2 ? decodeQueryComponent(String(parts[1])) : ""
            values[name, default: []].append(value)
        }
        return (rawPath, .init(values))
    }

    private static func decodeQueryComponent(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }
}

public struct PathParameters: Sendable, Equatable {
    private var storage: [String: String]

    public init(_ storage: [String: String] = [:]) { self.storage = storage }
    public subscript(_ name: String) -> String? { storage[name] }

    public func require(_ name: String) throws -> String {
        guard let value = storage[name] else {
            throw Abort(.badRequest, body: "Missing path parameter: \(name)")
        }
        return value
    }
}

public struct Request: Sendable {
    public let method: Method
    public let uri: String
    public let path: String
    public let headers: Headers
    public let body: Body
    public let query: QueryParameters
    public let parameters: PathParameters
    public let remoteAddress: SocketAddress?

    public init(
        method: Method,
        uri: String,
        path: String? = nil,
        headers: Headers = .init(),
        body: Body = .empty,
        query: QueryParameters? = nil,
        parameters: PathParameters = .init(),
        remoteAddress: SocketAddress? = nil
    ) {
        let parsed = QueryParameters.parse(uri: uri)
        self.method = method
        self.uri = uri
        self.path = path ?? parsed.path
        self.headers = headers
        self.body = body
        self.query = query ?? parsed.query
        self.parameters = parameters
        self.remoteAddress = remoteAddress
    }

    public var contentType: MediaType? {
        headers["content-type"].map(MediaType.init(rawValue:))
    }

    public func header(_ name: String) -> String? { headers[name] }

    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = .init()
    ) throws -> T {
        try body.decode(type, decoder: decoder)
    }

    public func cookie(_ name: String) -> String? {
        for header in headers.values(for: "cookie") {
            for item in header.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == name else { continue }
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func with(parameters: PathParameters) -> Request {
        Request(
            method: method,
            uri: uri,
            path: path,
            headers: headers,
            body: body,
            query: query,
            parameters: parameters,
            remoteAddress: remoteAddress
        )
    }
}

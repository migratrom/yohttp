import Foundation
import Synchronization

public struct RouteHandlers: Sendable {
    public var GET: Handler?
    public var POST: Handler?
    public var PUT: Handler?
    public var PATCH: Handler?
    public var DELETE: Handler?
    public var OPTIONS: Handler?
    public var HEAD: Handler?

    public init(
        GET: Handler? = nil,
        POST: Handler? = nil,
        PUT: Handler? = nil,
        PATCH: Handler? = nil,
        DELETE: Handler? = nil,
        OPTIONS: Handler? = nil,
        HEAD: Handler? = nil
    ) {
        self.GET = GET
        self.POST = POST
        self.PUT = PUT
        self.PATCH = PATCH
        self.DELETE = DELETE
        self.OPTIONS = OPTIONS
        self.HEAD = HEAD
    }

    fileprivate subscript(method: Method) -> Handler? {
        get {
            switch method {
            case .GET: GET
            case .POST: POST
            case .PUT: PUT
            case .PATCH: PATCH
            case .DELETE: DELETE
            case .OPTIONS: OPTIONS
            case .HEAD: HEAD
            default: nil
            }
        }
        set {
            switch method {
            case .GET: GET = newValue
            case .POST: POST = newValue
            case .PUT: PUT = newValue
            case .PATCH: PATCH = newValue
            case .DELETE: DELETE = newValue
            case .OPTIONS: OPTIONS = newValue
            case .HEAD: HEAD = newValue
            default: break
            }
        }
    }

    fileprivate var methods: [Method] {
        [Method.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS].filter { self[$0] != nil }
    }
}

/// A concurrency-safe HTTP request router.
public final class YoHTTPRouter: Sendable {
    private enum Segment: Sendable, Equatable {
        case literal(String)
        case parameter(String)
        case wildcard(String)
    }

    private struct Route: Sendable {
        var segments: [Segment]
        var handlers: RouteHandlers
        var order: Int

        var specificity: Int {
            segments.reduce(0) { result, segment in
                switch segment {
                case .literal: result + 100
                case .parameter: result + 10
                case .wildcard: result
                }
            }
        }
    }

    private struct MiddlewareEntry: Sendable {
        var prefix: String
        var middleware: Middleware
    }

    private struct State: Sendable {
        var routes: [Route] = []
        var middleware: [MiddlewareEntry] = []
        var nextOrder = 0
    }

    private final class Storage: Sendable {
        let state = Mutex(State())
    }

    private let storage: Storage
    private let prefix: String

    public init() {
        storage = Storage()
        prefix = ""
    }

    private init(storage: Storage, prefix: String) {
        self.storage = storage
        self.prefix = prefix
    }

    public func path(_ path: String, handlers: RouteHandlers) {
        let segments = Self.parsePattern(Self.join(prefix, path))
        storage.state.withLock { state in
            if let index = state.routes.firstIndex(where: { $0.segments == segments }) {
                var existing = state.routes[index].handlers
                for method in handlers.methods { existing[method] = handlers[method] }
                state.routes[index].handlers = existing
            } else {
                state.routes.append(Route(segments: segments, handlers: handlers, order: state.nextOrder))
                state.nextOrder += 1
            }
        }
    }

    public func path(_ path: String, _ configure: (inout RouteHandlers) -> Void) {
        var handlers = RouteHandlers()
        configure(&handlers)
        self.path(path, handlers: handlers)
    }

    public func route(_ method: Method, _ path: String, handler: @escaping Handler) {
        precondition(
            [.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS].contains(method),
            "YoHTTPRouter does not support dispatching \(method.rawValue)"
        )
        var handlers = RouteHandlers()
        handlers[method] = handler
        self.path(path, handlers: handlers)
    }

    public func GET(_ path: String, handler: @escaping Handler) { route(.GET, path, handler: handler) }
    public func POST(_ path: String, handler: @escaping Handler) { route(.POST, path, handler: handler) }
    public func PUT(_ path: String, handler: @escaping Handler) { route(.PUT, path, handler: handler) }
    public func PATCH(_ path: String, handler: @escaping Handler) { route(.PATCH, path, handler: handler) }
    public func DELETE(_ path: String, handler: @escaping Handler) { route(.DELETE, path, handler: handler) }
    public func OPTIONS(_ path: String, handler: @escaping Handler) { route(.OPTIONS, path, handler: handler) }
    public func HEAD(_ path: String, handler: @escaping Handler) { route(.HEAD, path, handler: handler) }

    public func middleware(_ middleware: @escaping Middleware) {
        storage.state.withLock { state in
            state.middleware.append(MiddlewareEntry(prefix: prefix, middleware: middleware))
        }
    }

    public func group(_ prefix: String, _ configure: (YoHTTPRouter) -> Void) {
        configure(YoHTTPRouter(storage: storage, prefix: Self.join(self.prefix, prefix)))
    }

    /// Routes a request without starting a server. Useful for composition and tests.
    public func respond(to request: Request) async throws -> Response {
        let snapshot = storage.state.withLock { ($0.routes, $0.middleware) }
        let resolution = Self.resolve(request: request, routes: snapshot.0)
        let applicableMiddleware = snapshot.1.filter { Self.path(request.path, hasPrefix: $0.prefix) }
        let routedRequest: Request
        if case .handler(_, let parameters) = resolution {
            routedRequest = request.with(parameters: PathParameters(parameters))
        } else {
            routedRequest = request
        }

        var pipeline: Handler = { routedRequest in
            switch resolution {
            case .handler(let handler, _):
                return try await handler(routedRequest)
            case .automaticOptions(let allow):
                return Response(status: .noContent, headers: ["Allow": allow])
            case .methodNotAllowed(let allow):
                throw Abort(.methodNotAllowed, headers: ["Allow": allow], body: "Method Not Allowed")
            case .notFound:
                throw Abort(.notFound, body: "Not Found")
            }
        }

        for entry in applicableMiddleware.reversed() {
            let next = Next(pipeline)
            pipeline = { request in try await entry.middleware(request, next) }
        }
        return try await pipeline(routedRequest)
    }

    public var handler: Handler {
        { [self] request in try await respond(to: request) }
    }

    private enum Resolution: Sendable {
        case handler(Handler, [String: String])
        case automaticOptions(String)
        case methodNotAllowed(String)
        case notFound
    }

    private struct Match: Sendable {
        var route: Route
        var parameters: [String: String]
    }

    private static func resolve(request: Request, routes: [Route]) -> Resolution {
        let pathSegments = splitPath(request.path)
        let matches = routes.compactMap { route -> Match? in
            match(route.segments, path: pathSegments).map { Match(route: route, parameters: $0) }
        }.sorted {
            if $0.route.specificity != $1.route.specificity {
                return $0.route.specificity > $1.route.specificity
            }
            return $0.route.order < $1.route.order
        }

        guard !matches.isEmpty else { return .notFound }
        let allowed = Set(matches.flatMap(\.route.handlers.methods))
            .union([.OPTIONS])
            .union(matches.contains { $0.route.handlers.GET != nil } ? [.HEAD] : [])
        let allowHeader = allowed.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ", ")

        if request.method == .OPTIONS,
           !matches.contains(where: { $0.route.handlers.OPTIONS != nil }) {
            return .automaticOptions(allowHeader)
        }

        for match in matches {
            if let handler = match.route.handlers[request.method] {
                return .handler(handler, match.parameters)
            }
            if request.method == .HEAD, let handler = match.route.handlers.GET {
                return .handler(handler, match.parameters)
            }
        }
        return .methodNotAllowed(allowHeader)
    }

    private static func match(_ pattern: [Segment], path: [String]) -> [String: String]? {
        var parameters: [String: String] = [:]
        var index = 0
        for segment in pattern {
            switch segment {
            case .literal(let expected):
                guard index < path.count, path[index] == expected else { return nil }
                index += 1
            case .parameter(let name):
                guard index < path.count else { return nil }
                parameters[name] = path[index].removingPercentEncoding ?? path[index]
                index += 1
            case .wildcard(let name):
                let remainder = path[index...].joined(separator: "/")
                parameters[name] = remainder.removingPercentEncoding ?? remainder
                index = path.count
            }
        }
        return index == path.count ? parameters : nil
    }

    private static func parsePattern(_ path: String) -> [Segment] {
        var names = Set<String>()
        let parts = splitPath(path)
        return parts.enumerated().map { index, part in
            if part.hasPrefix(":") {
                let name = String(part.dropFirst())
                precondition(!name.isEmpty && names.insert(name).inserted, "Invalid or duplicate path parameter in \(path)")
                return .parameter(name)
            }
            if part.hasPrefix("*") {
                let name = String(part.dropFirst())
                precondition(!name.isEmpty && names.insert(name).inserted, "Invalid wildcard in \(path)")
                precondition(index == parts.count - 1, "A wildcard must be the final path segment in \(path)")
                return .wildcard(name)
            }
            return .literal(part)
        }
    }

    private static func splitPath(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
        let left = lhs == "/" ? "" : lhs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = rhs.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if left.isEmpty && right.isEmpty { return "/" }
        if left.isEmpty { return "/\(right)" }
        if right.isEmpty { return "/\(left)" }
        return "/\(left)/\(right)"
    }

    private static func path(_ path: String, hasPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty, prefix != "/" else { return true }
        return path == prefix || path.hasPrefix(prefix + "/")
    }
}

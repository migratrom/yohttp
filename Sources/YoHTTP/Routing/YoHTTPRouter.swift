import Foundation
import Synchronization

/// A concurrency-safe HTTP request router for macro-declared endpoints.
public final class YoHTTPRouter: Sendable {
    private struct Route: Sendable {
        var definition: RouteDefinition
        var handler: Handler
        var order: Int

        var specificity: Int {
            definition.segments.reduce(0) { result, segment in
                switch segment {
                case .literal: result + 100
                case .parameter: result + 10
                case .wildcard: result
                }
            }
        }
    }

    private enum ShapeSegment: Equatable {
        case literal(String)
        case parameter
        case wildcard
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

    /// Registers every HTTP method declared by a macro-generated endpoint.
    public func register<Endpoint: RouteEndpoint>(_ endpoint: Endpoint.Type) {
        for definition in endpoint.routeDefinitions {
            let prefixed = RouteDefinition(
                method: definition.method,
                segments: Self.prefixedSegments(prefix, definition.segments)
            )
            Self.validate(prefixed)
            let handler: Handler = { request in try await endpoint.respond(to: request) }

            storage.state.withLock { state in
                let shape = Self.shape(of: prefixed.segments)
                precondition(
                    !state.routes.contains {
                        $0.definition.method == prefixed.method && Self.shape(of: $0.definition.segments) == shape
                    },
                    "A route for \(prefixed.method.rawValue) \(Self.displayPath(prefixed.segments)) is already registered"
                )
                state.routes.append(Route(definition: prefixed, handler: handler, order: state.nextOrder))
                state.nextOrder += 1
            }
        }
    }

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
            match(route.definition.segments, path: pathSegments).map { Match(route: route, parameters: $0) }
        }.sorted {
            if $0.route.specificity != $1.route.specificity {
                return $0.route.specificity > $1.route.specificity
            }
            return $0.route.order < $1.route.order
        }

        guard !matches.isEmpty else { return .notFound }
        let allowed = Set(matches.map(\.route.definition.method))
            .union([.OPTIONS])
            .union(matches.contains { $0.route.definition.method == .GET } ? [.HEAD] : [])
        let allowHeader = allowed.sorted { $0.rawValue < $1.rawValue }.map(\.rawValue).joined(separator: ", ")

        if request.method == .OPTIONS,
           !matches.contains(where: { $0.route.definition.method == .OPTIONS }) {
            return .automaticOptions(allowHeader)
        }

        if let match = matches.first(where: { $0.route.definition.method == request.method }) {
            return .handler(match.route.handler, match.parameters)
        }
        if request.method == .HEAD,
           let match = matches.first(where: { $0.route.definition.method == .GET }) {
            return .handler(match.route.handler, match.parameters)
        }
        return .methodNotAllowed(allowHeader)
    }

    private static func match(_ pattern: [RouteSegment], path: [String]) -> [String: String]? {
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

    private static func validate(_ definition: RouteDefinition) {
        let supported: Set<Method> = [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .HEAD]
        precondition(supported.contains(definition.method), "YoHTTPRouter does not support dispatching \(definition.method.rawValue)")

        var names = Set<String>()
        for (index, segment) in definition.segments.enumerated() {
            switch segment {
            case .literal:
                continue
            case .parameter(let name):
                precondition(!name.isEmpty && names.insert(name).inserted, "Invalid or duplicate path parameter")
            case .wildcard(let name):
                precondition(!name.isEmpty && names.insert(name).inserted, "Invalid wildcard")
                precondition(index == definition.segments.count - 1, "A wildcard must be the final path segment")
            }
        }
    }

    private static func prefixedSegments(_ prefix: String, _ segments: [RouteSegment]) -> [RouteSegment] {
        splitPath(prefix).map(RouteSegment.literal) + segments
    }

    private static func shape(of segments: [RouteSegment]) -> [ShapeSegment] {
        segments.map {
            switch $0 {
            case .literal(let value): .literal(value)
            case .parameter: .parameter
            case .wildcard: .wildcard
            }
        }
    }

    private static func displayPath(_ segments: [RouteSegment]) -> String {
        "/" + segments.map {
            switch $0 {
            case .literal(let value): value
            case .parameter(let name): "{\(name)}"
            case .wildcard(let name): "{*\(name)}"
            }
        }.joined(separator: "/")
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

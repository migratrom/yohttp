import Foundation
import Synchronization
import Testing
@testable import YoHTTP

@Route([.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS], "/all")
private struct AllMethodsEndpoint {
    func handle(_ request: Request) async throws -> Response { .text(request.method.rawValue) }
}

@Route(.GET, "/users/{id}")
private struct UserEndpoint {
    @PathParam("id") let id: String
    func handle(_ request: Request) async throws -> Response { .text(id) }
}

@Route(.GET, "/assets/{*path}")
private struct AssetEndpoint {
    @PathParam("path") let path: String
    func handle(_ request: Request) async throws -> Response { .text(path) }
}

@Route(.GET, "/numbers/{value}")
private struct NumberEndpoint {
    @PathParam("value") let value: Int
    func handle(_ request: Request) async throws -> Response { .text("\(value)") }
}

@Route(.GET, "/query")
private struct QueryEndpoint {
    @QueryParam("completed") let completed: Bool
    @QueryParam("search") let search: String?

    func handle(_ request: Request) async throws -> Response {
        .text("\(completed):\(search ?? "none")")
    }
}

private struct ProjectID: PathValue {
    let rawValue: String

    init?(pathValue: String) {
        guard pathValue.hasPrefix("project-") else { return nil }
        rawValue = pathValue
    }
}

@Route(.GET, "/projects/{id}")
private struct ProjectEndpoint {
    @PathParam("id") let projectID: ProjectID
    func handle(_ request: Request) async throws -> Response { .text(projectID.rawValue) }
}

@Route(.GET, "/files/{*rest}")
private struct WildcardEndpoint {
    @PathParam("rest") let rest: String
    func handle(_ request: Request) async throws -> Response { .text("wildcard") }
}

@Route(.GET, "/files/{name}")
private struct ParameterEndpoint {
    @PathParam("name") let name: String
    func handle(_ request: Request) async throws -> Response { .text("parameter") }
}

@Route(.GET, "/files/current")
private struct LiteralEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("literal") }
}

@Route(.GET, "/items")
private struct ItemsEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("items") }
}

@Route(.POST, "/items")
private struct CreateItemEndpoint {
    func handle(_ request: Request) async throws -> Response { Response(status: .created) }
}

@Route(.GET, "/explicit")
private struct ExplicitGetEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("get") }
}

@Route(.HEAD, "/explicit")
private struct ExplicitHeadEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("head") }
}

@Route(.OPTIONS, "/explicit")
private struct ExplicitOptionsEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("options") }
}

@Route(.GET, "/fallback")
private struct FallbackEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("fallback") }
}

@Route(.GET, "/users/{id}")
private struct ApiUserEndpoint {
    @PathParam("id") let id: String
    func handle(_ request: Request) async throws -> Response { .text("ok") }
}

@Route(.GET, "/apian")
private struct BoundaryEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("boundary") }
}

@Route(.GET, "/")
private struct RootEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("root") }
}

@Route(.GET, "/")
private struct NestedEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("nested") }
}

@Route(.GET, "/a/b")
private struct NormalizedEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("matched") }
}

@Route(.GET, "/one/{value}")
private struct OneEndpoint {
    @PathParam("value") let value: String
    func handle(_ request: Request) async throws -> Response { .text("parameter") }
}

@Route(.GET, "/duplicate/{id}")
private struct FirstDuplicateEndpoint {
    @PathParam("id") let id: String
    func handle(_ request: Request) async throws -> Response { .text(id) }
}

@Route(.GET, "/duplicate/{slug}")
private struct SecondDuplicateEndpoint {
    @PathParam("slug") let slug: String
    func handle(_ request: Request) async throws -> Response { .text(slug) }
}

private enum UnsupportedMethodEndpoint: RouteEndpoint {
    static let routeDefinitions = [RouteDefinition(method: .TRACE, segments: [.literal("unsupported")])]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

private enum EmptyParameterEndpoint: RouteEndpoint {
    static let routeDefinitions = [RouteDefinition(method: .GET, segments: [.parameter("")])]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

private enum DuplicateParameterEndpoint: RouteEndpoint {
    static let routeDefinitions = [RouteDefinition(method: .GET, segments: [.parameter("id"), .parameter("id")])]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

private enum EmptyWildcardEndpoint: RouteEndpoint {
    static let routeDefinitions = [RouteDefinition(method: .GET, segments: [.wildcard("")])]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

private enum NonterminalWildcardEndpoint: RouteEndpoint {
    static let routeDefinitions = [RouteDefinition(method: .GET, segments: [.wildcard("path"), .literal("later")])]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

private enum DuplicateWildcardEndpoint: RouteEndpoint {
    static let routeDefinitions = [
        RouteDefinition(method: .GET, segments: [.wildcard("first")]),
        RouteDefinition(method: .GET, segments: [.wildcard("second")]),
    ]
    static func respond(to request: Request) async throws -> Response { .text("unused") }
}

@Suite("Router")
struct RouterTests {
    @Test func registersOneEndpointForManyMethods() async throws {
        let router = YoHTTPRouter()
        router.register(AllMethodsEndpoint.self)

        for method: YoHTTP.Method in [.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS] {
            let response = try await router.respond(to: Request(method: method, uri: "/all"))
            #expect(try await response.body.string() == method.rawValue)
        }
    }

    @Test func decodesParametersWildcardsAndReportsBadTypedValues() async throws {
        let router = YoHTTPRouter()
        router.register(UserEndpoint.self)
        router.register(AssetEndpoint.self)
        router.register(NumberEndpoint.self)
        router.register(ProjectEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/users/a%20b"))).body.string() == "a b")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/assets/css/app.css"))).body.string() == "css/app.css")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/assets"))).body.string() == "")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/projects/project-42"))).body.string() == "project-42")

        do {
            _ = try await router.respond(to: Request(method: .GET, uri: "/numbers/not-a-number"))
            Issue.record("Expected a bad request")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
            #expect(try await error.body.string() == "Invalid path parameter: value")
        }
    }

    @Test func decodesRequiredAndOptionalQueryParameters() async throws {
        let router = YoHTTPRouter()
        router.register(QueryEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/query?completed=TRUE&search=two+words"))).body.string() == "true:two words")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/query?completed=false"))).body.string() == "false:none")

        do {
            _ = try await router.respond(to: Request(method: .GET, uri: "/query"))
            Issue.record("Expected a bad request")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
            #expect(try await error.body.string() == "Missing query parameter: completed")
        }

        do {
            _ = try await router.respond(to: Request(method: .GET, uri: "/query?completed=yes"))
            Issue.record("Expected a bad request")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
            #expect(try await error.body.string() == "Invalid query parameter: completed")
        }
    }

    @Test func prefersLiteralThenParametersThenWildcards() async throws {
        let router = YoHTTPRouter()
        router.register(WildcardEndpoint.self)
        router.register(ParameterEndpoint.self)
        router.register(LiteralEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/files/current"))).body.string() == "literal")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/files/other"))).body.string() == "parameter")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/files/a/b"))).body.string() == "wildcard")
    }

    @Test func returnsMethodNotAllowedForKnownPaths() async throws {
        let router = YoHTTPRouter()
        router.register(ItemsEndpoint.self)
        router.register(CreateItemEndpoint.self)

        do {
            _ = try await router.respond(to: Request(method: .TRACE, uri: "/items"))
            Issue.record("Expected method not allowed")
        } catch let error as Abort {
            #expect(error.status == .methodNotAllowed)
            #expect(error.headers["allow"] == "GET, HEAD, OPTIONS, POST")
        }

        let options = try await router.respond(to: Request(method: .OPTIONS, uri: "/items"))
        #expect(options.status == .noContent)
        #expect(options.headers["allow"] == "GET, HEAD, OPTIONS, POST")
    }

    @Test func explicitHeadAndOptionsWinWhileGetFallsBackForHead() async throws {
        let router = YoHTTPRouter()
        router.register(ExplicitGetEndpoint.self)
        router.register(ExplicitHeadEndpoint.self)
        router.register(ExplicitOptionsEndpoint.self)
        router.register(FallbackEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .HEAD, uri: "/explicit"))).body.string() == "head")
        #expect(try await (try await router.respond(to: Request(method: .OPTIONS, uri: "/explicit"))).body.string() == "options")
        #expect(try await (try await router.respond(to: Request(method: .HEAD, uri: "/fallback"))).body.string() == "fallback")
    }

    @Test func groupsScopeMiddlewareAndKeepRawParametersAvailable() async throws {
        let events = Mutex<[String]>([])
        let router = YoHTTPRouter()
        router.middleware { request, next in
            events.withLock { $0.append("outer-in:\(request.parameters["id"] ?? "none")") }
            let response = try await next(request)
            events.withLock { $0.append("outer-out") }
            return response
        }
        router.group("/api") { api in
            api.middleware { request, next in
                events.withLock { $0.append("api-in:\(request.parameters["id"] ?? "none")") }
                let response = try await next(request)
                events.withLock { $0.append("api-out") }
                return response
            }
            api.register(ApiUserEndpoint.self)
        }
        router.register(BoundaryEndpoint.self)

        _ = try await router.respond(to: Request(method: .GET, uri: "/api/users/42"))
        #expect(events.withLock { $0 } == ["outer-in:42", "api-in:42", "api-out", "outer-out"])

        events.withLock { $0.removeAll() }
        _ = try await router.respond(to: Request(method: .GET, uri: "/apian"))
        #expect(events.withLock { $0 } == ["outer-in:none", "outer-out"])
    }

    @Test func groupsComposeAndPathNormalizationRemainsDeterministic() async throws {
        let router = YoHTTPRouter()
        router.group("/") { $0.register(RootEndpoint.self) }
        router.group("api/") { api in
            api.group("/v1/") { v1 in
                v1.group("") { $0.register(NestedEndpoint.self) }
            }
        }
        router.register(NormalizedEndpoint.self)
        router.register(OneEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/"))).body.string() == "root")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/api/v1"))).body.string() == "nested")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/a//b/"))).body.string() == "matched")
        for path in ["/a", "/a/b/c", "/one"] {
            do {
                _ = try await router.respond(to: Request(method: .GET, uri: path))
                Issue.record("Expected \(path) not to match")
            } catch let error as Abort {
                #expect(error.status == .notFound)
            }
        }
    }

    @available(macOS 26, *)
    @Test func rejectsDuplicateMethodAndStructuralPath() async {
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            let router = YoHTTPRouter()
            router.register(FirstDuplicateEndpoint.self)
            router.register(SecondDuplicateEndpoint.self)
        }
    }

    @Test func handlerPropertyDelegatesToRouter() async throws {
        let router = YoHTTPRouter()
        router.register(RootEndpoint.self)
        #expect(try await (try await router.handler(Request(method: .GET, uri: "/"))).body.string() == "root")
    }

    @Test func decodesEveryBuiltInPathValueType() {
        #expect(decodePathValue(Bool.self, from: "TRUE") == true)
        #expect(decodePathValue(Bool.self, from: "false") == false)
        #expect(decodePathValue(Bool.self, from: "yes") == nil)

        #expect(decodePathValue(Int.self, from: "-1") == -1)
        #expect(decodePathValue(Int8.self, from: "-8") == -8)
        #expect(decodePathValue(Int16.self, from: "-16") == -16)
        #expect(decodePathValue(Int32.self, from: "-32") == -32)
        #expect(decodePathValue(Int64.self, from: "-64") == -64)
        #expect(decodePathValue(UInt.self, from: "1") == 1)
        #expect(decodePathValue(UInt8.self, from: "8") == 8)
        #expect(decodePathValue(UInt16.self, from: "16") == 16)
        #expect(decodePathValue(UInt32.self, from: "32") == 32)
        #expect(decodePathValue(UInt64.self, from: "64") == 64)

        let identifier = UUID()
        #expect(decodePathValue(UUID.self, from: identifier.uuidString) == identifier)
        #expect(decodePathValue(UUID.self, from: "not-a-uuid") == nil)

        #expect(decodeQueryValue(Bool.self, from: "TRUE") == true)
        #expect(decodeQueryValue(Bool.self, from: "false") == false)
        #expect(decodeQueryValue(Bool.self, from: "yes") == nil)
        #expect(decodeQueryValue(Int.self, from: "42") == 42)
        #expect(decodeQueryValue(UUID.self, from: identifier.uuidString) == identifier)
    }

    @Test func preservesMalformedPercentEscapesInParametersAndWildcards() async throws {
        let router = YoHTTPRouter()
        router.register(UserEndpoint.self)
        router.register(AssetEndpoint.self)

        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/users/%FF"))).body.string() == "%FF")
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/assets/%FF"))).body.string() == "%FF")
    }

    @Test func omitsHeadFromAllowWhenNoGetRouteMatches() async throws {
        let router = YoHTTPRouter()
        router.register(CreateItemEndpoint.self)

        await #expect(throws: Abort.self) {
            _ = try await router.respond(to: Request(method: .TRACE, uri: "/items"))
        }
    }

    @Test func normalizesAGroupNestedBelowTheRootGroup() async throws {
        let router = YoHTTPRouter()
        router.group("/") { root in
            root.group("api") { $0.register(NormalizedEndpoint.self) }
        }
        #expect(try await (try await router.respond(to: Request(method: .GET, uri: "/api/a/b"))).body.string() == "matched")
    }

    @available(macOS 26, *)
    @Test func rejectsUnsupportedAndInvalidRouteDefinitions() async {
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(UnsupportedMethodEndpoint.self)
        }
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(EmptyParameterEndpoint.self)
        }
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(DuplicateParameterEndpoint.self)
        }
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(EmptyWildcardEndpoint.self)
        }
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(NonterminalWildcardEndpoint.self)
        }
        await #expect(processExitsWith: .failure) {
            installCoverageSignalHandlers()
            YoHTTPRouter().register(DuplicateWildcardEndpoint.self)
        }
    }
}

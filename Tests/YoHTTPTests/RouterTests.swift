import Synchronization
import Testing
@testable import YoHTTP

@Suite("Router")
struct RouterTests {
    @Test func routesByMethodAndExtractsParameters() async throws {
        let router = YoHTTPRouter()
        router.GET("/users/:id") { request in
            Response.text(try request.parameters.require("id"))
        }
        router.POST("/users/:id") { _ in Response(status: .created) }

        let get = try await router.respond(to: Request(method: .GET, uri: "/users/a%20b"))
        let post = try await router.respond(to: Request(method: .POST, uri: "/users/42"))

        #expect(get.body.string() == "a b")
        #expect(post.status == .created)
    }

    @Test func staticRoutesTakePrecedenceOverParameters() async throws {
        let router = YoHTTPRouter()
        router.GET("/users/:id") { _ in .text("parameter") }
        router.GET("/users/me") { _ in .text("static") }

        let response = try await router.respond(to: Request(method: .GET, uri: "/users/me"))
        #expect(response.body.string() == "static")
    }

    @Test func wildcardCapturesRemainingPath() async throws {
        let router = YoHTTPRouter()
        router.GET("/assets/*path") { request in .text(try request.parameters.require("path")) }

        let response = try await router.respond(to: Request(method: .GET, uri: "/assets/css/app.css"))
        #expect(response.body.string() == "css/app.css")
    }

    @Test func reportsNotFoundMethodNotAllowedAndAutomaticOptions() async throws {
        let router = YoHTTPRouter()
        router.GET("/items") { _ in .text("items") }
        router.POST("/items") { _ in Response(status: .created) }

        await #expect(throws: Abort.self) {
            try await router.respond(to: Request(method: .GET, uri: "/missing"))
        }

        do {
            _ = try await router.respond(to: Request(method: .DELETE, uri: "/items"))
            Issue.record("Expected method-not-allowed")
        } catch let error as Abort {
            #expect(error.status == .methodNotAllowed)
            #expect(error.headers["allow"] == "GET, HEAD, OPTIONS, POST")
        }

        let options = try await router.respond(to: Request(method: .OPTIONS, uri: "/items"))
        #expect(options.status == .noContent)
        #expect(options.headers["allow"] == "GET, HEAD, OPTIONS, POST")
    }

    @Test func headFallsBackToGet() async throws {
        let router = YoHTTPRouter()
        router.GET("/health") { _ in .text("healthy") }

        let response = try await router.respond(to: Request(method: .HEAD, uri: "/health"))
        #expect(response.status == .ok)
        #expect(response.body.string() == "healthy")
    }

    @Test func middlewareIsOrderedAndGroupsAreScoped() async throws {
        let events = Mutex<[String]>([])
        let router = YoHTTPRouter()
        router.middleware { request, next in
            events.withLock { $0.append("outer-in") }
            let response = try await next(request)
            events.withLock { $0.append("outer-out") }
            return response
        }
        router.group("/api") { api in
            api.middleware { request, next in
                events.withLock { $0.append("api-in") }
                let response = try await next(request)
                events.withLock { $0.append("api-out") }
                return response
            }
            api.GET("/ping") { _ in
                events.withLock { $0.append("handler") }
                return .text("pong")
            }
        }
        router.GET("/outside") { _ in .text("outside") }

        _ = try await router.respond(to: Request(method: .GET, uri: "/api/ping"))
        #expect(events.withLock { $0 } == ["outer-in", "api-in", "handler", "api-out", "outer-out"])

        events.withLock { $0.removeAll() }
        _ = try await router.respond(to: Request(method: .GET, uri: "/outside"))
        #expect(events.withLock { $0 } == ["outer-in", "outer-out"])
    }
}

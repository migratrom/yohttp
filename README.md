# yohttp

`yohttp` is a small, concurrency-safe Swift HTTP/1.1 server library. It gives application code a Swift-native async API while SwiftNIO owns sockets, protocol parsing, pipelining, and backpressure.

## Requirements

- Swift 6.3 or newer
- macOS 15 or newer, or a Swift 6.3-supported Linux distribution

## Installation

Add the package to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/yohttp.git", from: "1.0.0"),
]
```

Then add the product to your target:

```swift
.target(
    name: "App",
    dependencies: [.product(name: "YoHTTP", package: "yohttp")]
)
```

## Quick start

```swift
import YoHTTP

@Route([.GET, .POST], "/users")
struct UsersEndpoint {
    func handle(_ request: Request) async throws -> Response {
        switch request.method {
        case .GET: .text("users")
        case .POST: Response(status: .created)
        default: throw Abort(.methodNotAllowed)
        }
    }
}

let router = YoHTTPRouter()
router.register(UsersEndpoint.self)

let server = YoHTTPServer()
server.handler(router)
try await server.listen("127.0.0.1", 9090)
```

Run the included example with `swift run yohttp-example`, then open `http://127.0.0.1:9090/users`.

## Routing

Declare each endpoint with a compile-time route template, then register its type:

```swift
@Route(.GET, "/users/{id}")
struct ShowUser {
    @PathParam("id") let id: UUID

    func handle(_ request: Request) async throws -> Response {
        .text("user \(id)")
    }
}

@Route(.POST, "/messages")
struct CreateMessage {
    func handle(_ request: Request) async throws -> Response {
        struct Input: Decodable { let text: String }
        let input = try await request.decode(Input.self)
        return try .json(["text": input.text], status: .created)
    }
}

@Route(.GET, "/assets/{*path}")
struct Asset {
    @PathParam("path") let path: String

    func handle(_ request: Request) async throws -> Response {
        .text(path)
    }
}

@Route(.GET, "/todos")
struct ListTodos {
    @QueryParam("completed") let completed: Bool
    @QueryParam("search") let search: String?

    func handle(_ request: Request) async throws -> Response {
        .text("completed: \(completed), search: \(search ?? "none")")
    }
}

router.register(ShowUser.self)
router.register(CreateMessage.self)
router.register(Asset.self)
router.register(ListTodos.self)
```

`@Route` accepts either one method or an array of methods. Its path must be a string literal; `{name}` binds a single segment and `{*name}` binds the remaining path. The macro validates route syntax and `@PathParam` bindings at build time. `@QueryParam` binds a query-string value: non-optional properties are required and optional properties are `nil` when absent. Built-in `PathValue` and `QueryValue` types include `String`, `Bool`, integer types, and `UUID`; domain IDs can conform to either protocol. A missing required value or a value that cannot decode returns `400 Bad Request`.

Literal segments win over parameters, and parameters win over a final wildcard. `HEAD` falls back to `GET`; `OPTIONS` is synthesized when it has no explicit handler; and a known path without the request method returns `405 Method Not Allowed` with an `Allow` header.

Groups compose prefixes and scope middleware:

```swift
@Route(.GET, "/health")
struct HealthEndpoint {
    func handle(_ request: Request) async throws -> Response { .text("ok") }
}

router.group("/api") { api in
    api.middleware { request, next in
        guard request.header("Authorization") != nil else {
            throw Abort(.unauthorized)
        }
        return try await next(request)
    }

    api.register(HealthEndpoint.self)
}
```

Middleware registered on the root router applies globally. Middleware runs in registration order on the way in and reverse order on the way out. Resolved path parameters are visible to applicable middleware.

## Requests and responses

`Request` exposes the method, original URI, path, case-insensitive headers, a one-shot byte body, repeated query parameters, path parameters, cookies, and peer address. A body is an `AsyncSequence` of NIO `ByteBuffer`s, so uploads can be processed without buffering them in memory. `decode` and the convenience collection helpers are asynchronous because they consume the stream.

```swift
import NIOCore

for try await chunk in request.body {
    print(chunk.readableBytes)
}
```

`Response` has helpers for text, HTML, JSON, redirects, and cookies. Throw `Abort`—or any custom `HTTPError`—to produce a controlled response. Other errors become a generic `500 Internal Server Error` without leaking implementation details.

```swift
var response = Response.text("signed in")
response.cookie(Cookie(
    name: "session",
    value: token,
    path: "/",
    secure: true,
    httpOnly: true,
    sameSite: .lax
))
return response
```

## Lifecycle and configuration

`listen` binds and suspends while serving. Call `shutdown()` from another task to close the listener and active connections. Port `0` asks the operating system for a free port; inspect `server.localAddress` after the bind completes.

```swift
try await server.listen(ServerConfiguration(
    hostname: "0.0.0.0",
    port: 8080,
    maxRequestBodySize: 2 * 1024 * 1024,
    requestTimeout: .seconds(15),
    serverName: "my-service"
))
```

The default request-body limit is 10 MiB. Timeouts use cooperative Swift task cancellation.

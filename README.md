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

let router = YoHTTPRouter()

router.path("/users", handlers: .init(
    GET: { request in
        Response.text("users")
    },
    POST: { request in
        Response(status: .created)
    }
))

let server = YoHTTPServer()
server.handler(router)
try await server.listen("127.0.0.1", 9090)
```

Run the included example with `swift run yohttp-example`, then open `http://127.0.0.1:9090/users`.

## Routing

Routes may be registered together or one method at a time:

```swift
router.GET("/users/:id") { request in
    let id = try request.parameters.require("id")
    return .text("user \(id)")
}

router.POST("/messages") { request in
    struct Input: Decodable { let text: String }
    let input = try request.decode(Input.self)
    return try .json(["text": input.text], status: .created)
}

router.GET("/assets/*path") { request in
    .text(try request.parameters.require("path"))
}
```

Literal segments win over `:parameters`, and parameters win over a final `*wildcard`. `HEAD` falls back to `GET`; `OPTIONS` is synthesized when it has no explicit handler; and known paths return `405 Method Not Allowed` with an `Allow` header.

Groups compose prefixes and scope middleware:

```swift
router.group("/api") { api in
    api.middleware { request, next in
        guard request.header("Authorization") != nil else {
            throw Abort(.unauthorized)
        }
        return try await next(request)
    }

    api.GET("/health") { _ in .text("ok") }
}
```

Middleware registered on the root router applies globally. Middleware runs in registration order on the way in and reverse order on the way out. Resolved path parameters are visible to applicable middleware.

## Requests and responses

`Request` exposes the method, original URI, path, case-insensitive headers, owned body, repeated query parameters, path parameters, cookies, and peer address. Bodies can be decoded with a custom `JSONDecoder`.

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

The default request-body limit is 10 MiB. Timeouts use cooperative Swift task cancellation. TLS termination, streaming bodies, WebSockets, and HTTP/2 are deliberately outside the 1.0 protocol surface; deploy behind a capable proxy when those are needed.

## Testing handlers

The router does not require a listening socket:

```swift
let response = try await router.respond(to: Request(method: .GET, uri: "/users/42"))
```

Run all unit and live-socket integration tests with `swift test`.

Architecture choices and their consequences are recorded in [ADRs](ADRs/).

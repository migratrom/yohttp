# yohttp

`yohttp` is a small, concurrency-safe HTTP/1.1 server library backed by
SwiftNIO. It dispatches application callbacks directly on NIO event loops;
handlers are synchronous and must offload expensive work themselves.

## Requirements

- Swift 6.3 or newer
- macOS 15 or newer, or a Swift 6.3-supported Linux distribution

## Quick start

```swift
import YoHTTP

@Route(.GET, "/health")
struct Health {
    func handle(_ request: consuming Request, _ response: borrowing Response) throws {
        response.head.initialize(.init(version: request.head.version, status: .ok))
        response.write(ByteBuffer(string: "ok"))
        response.end()
    }
}

let router = YoHTTPRouter()
router.register(Health.self)
router.registrationLocked()

let server = YoHTTPServer()
server.handler(router)
try await server.listen("127.0.0.1", 9090)
```

## Request and response streams

YoHTTP re-exports `NIOCore` and `NIOHTTP1`. Requests expose NIO's
`HTTPRequestHead` directly through `request.head`; `Request` otherwise carries
the streamed `Body`, peer `SocketAddress`, and router path parameters.

Handlers receive a request and a one-shot response writer:

```swift
server.handler { request, response in
    let writer = response.writer()
    var byteCount = 0
    writer.head.initialize(.init(version: request.head.version, status: .ok))
    request.body.stream()
        .onChunk { byteCount += $0.readableBytes }
        .onEnd {
            writer.write(ByteBuffer(string: "received \(byteCount) bytes"))
            writer.end()
        }
        .onError { _ in
            writer.write(ByteBuffer(string: "invalid upload"))
            writer.end()
        }
}
```

`onChunk`, `onEnd`, and `onError` run on the selected NIO event loop. Do not
block them. To apply backpressure while application-owned work catches up, call
`stream.pause()` and later `stream.resume()`. A body without a registered chunk
callback is drained without application buffering.

`Request` and `Response` are move-only (`~Copyable`) capabilities. Handlers
consume the request and borrow the response, so macro endpoints must spell their
parameters as `consuming Request` and `borrowing Response`.

`Response` is a thread-safe, one-shot writer. Initialize it with an NIO
`HTTPResponseHead`, optionally mutate that head, then write `ByteBuffer` chunks
and finish with optional NIO trailer headers. `write` and `end` commit an
initialized head automatically; call `response.head.commit()` to flush headers
before body bytes. To retain a writer in a stream callback or application-owned
work on another executor, obtain its copyable `ResponseWriter` with
`response.writer()`.

```swift
server.handler { request, response in
    response.head.initialize(.init(version: request.head.version, status: .ok))
    response.head.modify {
        $0.headers.add(name: "X-Request-ID", value: UUID().uuidString)
    }
    response.write(ByteBuffer(string: "first chunk\n"))
    response.write(ByteBuffer(string: "second chunk\n"))
    response.end()
}
```

## Routing and middleware

Route endpoints and middleware use the same synchronous writer contract:

```swift
router.middleware { request, response, next in
    response.head.modify { $0.headers.add(name: "X-Service", value: "example") }
    try next(request, response)
}
```

`@Route` accepts one method or an array of methods. Literal segments outrank
parameters, which outrank a final wildcard. `HEAD` falls back to `GET`,
`OPTIONS` is synthesized when missing, and unsupported methods for known paths
return `405` with `Allow`.

Configure all routes and middleware before calling `router.registrationLocked()`.
That makes the routing table immutable; adding routes or middleware afterwards is
a programming error. Lock registration before obtaining the router handler or
serving a request.

## Lifecycle and configuration

Each server owns one NIO event loop by default. Increase the count only when
your application has a demonstrated need:

```swift
let server = YoHTTPServer(runtimeConfiguration: .init(eventLoopCount: 4))
```

`listen` binds and suspends while serving. Call `shutdown()` from another task
to close the listener and active connections. `ServerConfiguration` keeps its
network settings and provides two optional deadlines:

```swift
try await server.listen(ServerConfiguration(
    hostname: "0.0.0.0",
    port: 8080,
    maxRequestBodySize: 2 * 1024 * 1024,
    requestTimeout: .seconds(15),
    responseTimeout: .seconds(30),
    serverName: "my-service"
))
```

`requestTimeout` covers receipt from request head through body end and returns
`408`. `responseTimeout` starts after the body ends; an uncommitted response
receives `504`, while an already-started response connection is closed.

Pass PEM credentials with `TLS(key:cert:)` to serve HTTP/1.1 over TLS.

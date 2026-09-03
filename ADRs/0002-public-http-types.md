# 0002: Owned public HTTP value types

- Status: Accepted
- Date: 2026-09-03

## Context

Requests cross from NIO event loops into arbitrary Swift tasks. Borrowed buffers and transport-owned header objects make lifetime and executor correctness difficult for callers. Directly exporting NIO also prevents replacing or supplementing the transport later.

## Decision

Define package-owned, `Sendable` value types for methods, statuses, headers, bodies, requests, responses, addresses, parameters, media types, and cookies.

Request and response bodies are owned `Foundation.Data` values. Headers are case-insensitive while retaining insertion order, original spelling, and repeated fields such as `Set-Cookie`. Handler and middleware closures are `@Sendable` and async throwing. Shared mutable router and server state is protected with the Swift 6 `Synchronization.Mutex`; no public type needs `@unchecked Sendable`.

Controlled failures conform to `HTTPError`. Unexpected errors are converted to a generic 500 response at the server boundary.

## Consequences

- Values can safely leave an event loop and are straightforward to construct in tests.
- NIO is replaceable without an application source migration.
- Copy-on-write `Data` and arrays keep normal requests inexpensive, but the 1.0 API buffers complete bodies rather than streaming them.
- Header names and values are not eagerly rejected during construction. NIO validates outbound fields at the wire boundary, keeping pure response construction ergonomic while preventing response splitting.
- Application error details are not leaked by default; observability hooks will need a separate, explicit design.

## Alternatives considered

- Re-exporting NIO HTTP types would avoid conversion, but it would leak executor-sensitive implementation details and weaken API ownership.
- A reference-type request could enable lazy parsing, but would introduce isolation questions into every handler.
- Streaming-only bodies would maximize throughput for large payloads, but substantially complicate simple handlers and middleware. Streaming can be added later as a separate body representation without pretending buffered bodies are streams.

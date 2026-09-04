# 0002: Owned public HTTP value types

- Status: Accepted
- Date: 2026-09-03

## Context

Requests cross from NIO event loops into arbitrary Swift tasks. Borrowed buffers and transport-owned header objects make lifetime and executor correctness difficult for callers. Directly exporting NIO also prevents replacing or supplementing the transport later.

## Decision

Define package-owned, `Sendable` value types for methods, statuses, headers, bodies, requests, responses, addresses, parameters, media types, and cookies. `Body` is a package-owned wrapper over a unicast `AsyncSequence` of NIO `ByteBuffer`s.

Headers are case-insensitive while retaining insertion order, original spelling, and repeated fields such as `Set-Cookie`. Handler and middleware closures are `@Sendable` and async throwing. Shared mutable router and server state is protected with the Swift 6 `Synchronization.Mutex`; no public type needs `@unchecked Sendable`.

Controlled failures conform to `HTTPError`. Unexpected errors are converted to a generic 500 response at the server boundary.

## Consequences

- Values can safely leave an event loop and are straightforward to construct in tests.
- NIO `ByteBuffer` is an intentional public dependency for body chunks; transport replacement would now be a source migration.
- Bodies are single-consumer streams. Reading them into `Data`, text, or JSON is explicit and asynchronous.
- Header names and values are not eagerly rejected during construction. NIO validates outbound fields at the wire boundary, keeping pure response construction ergonomic while preventing response splitting.
- Application error details are not leaked by default; observability hooks will need a separate, explicit design.

## Alternatives considered

- Re-exporting NIO HTTP head types would avoid conversion, but it would leak protocol parsing concerns. Exposing `ByteBuffer` only for body chunks retains an owned HTTP surface while preserving byte-level performance.
- A reference-type request could enable lazy parsing, but would introduce isolation questions into every handler.
- Buffered-only bodies are easy to use but make large uploads and generated downloads unnecessarily eager.

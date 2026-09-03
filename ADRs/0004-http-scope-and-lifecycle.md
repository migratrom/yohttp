# 0004: HTTP/1.1 scope and lifecycle

- Status: Accepted
- Date: 2026-09-03

## Context

An immediately usable server needs a precise operational contract. Calling a buffered HTTP/1.1 library "complete" while silently implying TLS, HTTP/2, or unbounded uploads would create unsafe expectations.

The motivating call to `listen` is asynchronous and naturally represents the lifetime of the listener. Tests and managed services also need readiness information, ephemeral ports, cancellation, and an explicit stop operation.

## Decision

Version 1.0 serves HTTP/1.1 with persistent connections and NIO pipelining assistance. Requests are buffered up to `maxRequestBodySize`, which defaults to 10 MiB. NIO's parser owns request syntax and header limits. Responses always receive an authoritative `Content-Length`; user-supplied transfer encoding is removed. Bodies prohibited by status, and bodies for `HEAD`, are not written.

`listen` binds, publishes `localAddress`, and suspends until shutdown, cancellation, or listener failure. Port zero is supported. `shutdown` is idempotent and closes both the listener and active connections so the listening task has a bounded completion path. Calling shutdown during the bind records the stop request and closes the channel as soon as binding succeeds.

Request timeouts race the handler against `Task.sleep` in a structured task group and cancel the losing task. Therefore timeout enforcement is cooperative: handlers that suppress cancellation can delay completion.

TLS, HTTP/2, WebSockets, streaming request or response bodies, multipart parsing, compression, access logging, and trusted-proxy interpretation are outside the 1.0 contract. TLS and newer protocol negotiation should normally be handled by a reverse proxy until separately designed APIs justify native support.

## Consequences

- The lifecycle composes with `async let`, task groups, service managers, and tests.
- Shutdown is prompt and deterministic, but it is not graceful draining; in-flight requests can be cancelled by connection closure.
- Body-size enforcement bounds application memory per request, though aggregate memory still scales with concurrent buffered requests.
- The narrow protocol surface is honest and deployable, while leaving room for additive streaming and graceful-drain APIs.

## Alternatives considered

- Returning immediately from `listen` would hide listener failures and require a second lifetime primitive.
- Graceful draining by default can hang indefinitely on long-lived or malicious connections; it needs explicit deadlines and readiness semantics before becoming a promise.
- Native TLS in the core target would add certificate configuration and another dependency surface before the server has a transport-extension design.

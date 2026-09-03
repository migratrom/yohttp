# 0001: SwiftNIO transport with a Swift Concurrency boundary

- Status: Accepted
- Date: 2026-09-03

## Context

The library needs production-shaped nonblocking networking on macOS and Linux while presenting async/await handlers. A custom socket loop would duplicate protocol parsing, backpressure, pipelining, and portability work. Exposing NIO futures or buffers would make every application handler depend on transport mechanics.

Swift 6.3 makes `Sendable` enforcement and structured concurrency the appropriate baseline. SwiftNIO 2.101.3 supports Swift 6.3 and provides async bootstrap and `NIOAsyncChannel` APIs specifically for the boundary between event loops and task-based application logic.

## Decision

Use SwiftNIO's `NIOPosix`, `NIOHTTP1`, and `NIOCore` products. Configure HTTP codecs in the child channel pipeline, then synchronously wrap each configured channel in `NIOAsyncChannel` before registration can deliver reads.

NIO types remain internal. Each connection is consumed in a child of a throwing discarding task group, preserving backpressure without accumulating completed child tasks. A small outbound channel handler converts the sendable `HTTPPart<HTTPResponseHead, ByteBuffer>` used by concurrent code into NIO's `HTTPServerResponsePart`, whose `IOData` body is not sendable.

The server uses SwiftNIO's process-wide event-loop singleton. The package does not create thread pools that callers must remember to stop.

## Consequences

- Protocol parsing, response validation, pipelining assistance, socket portability, and nonblocking I/O inherit NIO's mature implementation.
- Handler code uses only `yohttp` values and Swift concurrency.
- SwiftNIO is the package's one runtime dependency and its compatible 2.x updates are accepted under semantic versioning.
- A process-wide loop is operationally simple, but per-server event-loop sizing and ownership are not configuration knobs in 1.0.
- Bridging code is a deliberate audit point whenever NIO changes sendability or async-channel APIs.

## Alternatives considered

- Network.framework would avoid a package dependency but make the server Apple-only.
- Direct POSIX sockets would reduce dependencies at the cost of a new parser, scheduler integration, and a materially larger security surface.
- EventLoopFuture-based public handlers would align with historical NIO code but work against the Swift 6.3 API goal and couple application code to the transport.

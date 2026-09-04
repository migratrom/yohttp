# yohttp contributor guide

## Project purpose

`yohttp` is a small Swift 6, concurrency-safe HTTP/1.1 server library. It presents an async/await application API while SwiftNIO owns socket I/O, HTTP parsing, pipelining, and backpressure. The package is pre-alpha, but its documented behavior and accepted architecture decisions are deliberate contracts.

## Working conventions

- Use Swift >6.3 idioms and preserve strict concurrency safety. Public values and escaping closures should be `Sendable` when appropriate; do not introduce `@unchecked Sendable` to bypass isolation checks.
- Preserve existing conventions unless explicitly asked.


## Architecture and documentation

- Accepted ADRs record historical decisions. Do not rewrite one to conceal changed assumptions. For a changed constraint, add a superseding ADR and link it to the record it replaces.
- Update `README.md` whenever a user-facing API, documented behavior, platform requirement, or example changes. Keep public API behavior consistent with the README and ADRs.
- Avoid unrelated refactors, formatting churn, and dependency changes. Discuss a new dependency or a material public-API change before adding it.

## Testing and validation

- Use Swift Testing (`import Testing`, `@Suite`, `@Test`, and `#expect`) for new tests. Place coverage beside the affected area under `Tests/YoHTTPTests/`.
- Run `swift test` for runtime, macro, routing, HTTP, server, or package-manifest changes. Use `swift build` when a full test run is disproportionate but compilation still needs checking.
- Keep test coverage above 86%.
- For lifecycle or wire-protocol changes, include focused tests for cancellation, shutdown, response framing, body consumption, or persistent-connection behavior as relevant.

## Completion checklist

- Keep the patch narrowly scoped and preserve existing caller behavior unless the task explicitly changes it.
- Verify the relevant build or test command and report what ran and any limitation.
- Review `git diff` before finishing; do not commit, tag, or publish unless asked.

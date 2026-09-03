# 0003: Deterministic routing and middleware

- Status: Accepted
- Date: 2026-09-03

## Context

The motivating API registers several method handlers at one path. Real services also need parameters, catch-all paths, groups, middleware, and correct behavior for `HEAD`, `OPTIONS`, missing methods, and concurrent registration or dispatch.

Ambiguous precedence based only on registration order makes refactors dangerous. Holding a lock while awaiting application code risks deadlocks and serializes unrelated requests.

## Decision

Compile route patterns into literal, named-parameter, and final-wildcard segments. Rank matches by specificity: literals outrank parameters, which outrank wildcards; registration order breaks exact ties. Re-registering the same pattern merges or replaces its method handlers.

Support `:name` for one decoded segment and `*name` for the decoded remaining path. A wildcard is valid only in the final position. Invalid patterns and unsupported methods are programmer configuration errors and fail with a precondition at registration time.

Take a locked snapshot of routes and middleware, then release the lock before invoking user code. Root middleware applies globally; group middleware is prefix-scoped. Path parameters are resolved before middleware begins. Middleware wraps in registration order.

An explicit `HEAD` route wins; otherwise `GET` handles `HEAD` and the transport suppresses its body while retaining the representation's content length. An explicit `OPTIONS` route wins; otherwise the router synthesizes a 204. Known paths with unsupported methods return 405. Both responses include a deterministic `Allow` header.

## Consequences

- Adding a literal route cannot accidentally be shadowed by an older parameter route.
- `YoHTTPRouter` mutation and request dispatch are data-race safe, and handlers do not execute under library locks.
- A dispatch observes one coherent snapshot; configuration added concurrently affects a subsequent request.
- Route lookup is a sorted linear scan. This favors a small, auditable implementation for the expected route counts. A trie can replace the internal representation after profiling without changing the public API or semantics.
- Collapsing empty slash-separated components means `/a//b` routes like `/a/b`; applications requiring byte-exact path routing need a future opt-in policy.

## Alternatives considered

- First-registration-wins matching is simpler but makes route behavior depend on source ordering.
- A trie improves asymptotic lookup but adds mutation and precedence complexity before measurements justify it.
- Running only matched-route middleware would make 404 logging and global response policy inconsistent.

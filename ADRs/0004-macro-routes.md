# 0005: Macro-declared typed routes

- Status: Accepted
- Date: 2026-09-03
- Supersedes: [0003: Deterministic routing and middleware](0003-routing.md), for route authoring

## Context

String route patterns and string-key path parameter lookup defer route-template mistakes and parameter type errors until registration or request dispatch. The package is pre-alpha, so replacing that API is less costly than supporting two route-authoring models.

## Decision

Routes are endpoint structs annotated with `@Route`. The macro accepts one method or an array of methods, parses a string-literal template at build time, and generates `RouteEndpoint` metadata plus a dispatcher. `{name}` parameters and final `{*name}` wildcards bind explicitly to `@PathParam("name")` stored properties.

`PathValue` supplies canonical decoders for strings, booleans, integer types, and UUIDs; applications extend path typing by conforming domain types. A failed decode returns 400. Endpoints are explicitly registered with `router.register(Endpoint.self)`, including within groups.

The router stores generated segment metadata rather than parsing route strings. A known structural path with no matching method returns 405 and a deterministic `Allow` header. Exact `HEAD` endpoints win over `GET` fallback. Duplicate method and structural-path registrations fail fast.

## Consequences

- Route syntax and parameter bindings are compiler diagnostics, and handlers receive typed endpoint fields.
- The prior `RouteHandlers`, `path`, `route`, and verb-string APIs are removed.
- Middleware continues to receive decoded raw `PathParameters` before the macro-generated endpoint is invoked.
- SwiftSyntax becomes a build dependency for clients using the package.

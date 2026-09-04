/// Declares an endpoint and one or more HTTP methods served by it.
///
/// The path must be a string literal. Use `{name}` for a parameter and
/// `{*name}` for a final catch-all parameter. Each parameter must correspond to
/// one stored property annotated with ``PathParam(_:)``.
@attached(extension, conformances: RouteEndpoint, names: named(routeDefinitions), named(respond))
public macro Route(_ method: Method, _ path: String) = #externalMacro(
    module: "YoHTTPMacros",
    type: "RouteMacro"
)

/// Declares an endpoint for several HTTP methods.
@attached(extension, conformances: RouteEndpoint, names: named(routeDefinitions), named(respond))
public macro Route(_ methods: [Method], _ path: String) = #externalMacro(
    module: "YoHTTPMacros",
    type: "RouteMacro"
)

/// Maps a stored endpoint property to a named route parameter.
///
/// This marker is checked by ``Route`` and does not alter the property.
@attached(peer)
public macro PathParam(_ name: String) = #externalMacro(
    module: "YoHTTPMacros",
    type: "PathParamMacro"
)

/// Maps a stored endpoint property to a named query parameter.
///
/// This marker is checked by ``Route`` and does not alter the property. A
/// non-optional property is required; declare it as an optional type when the
/// query parameter may be absent.
@attached(peer)
public macro QueryParam(_ name: String) = #externalMacro(
    module: "YoHTTPMacros",
    type: "QueryParamMacro"
)

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct YoHTTPMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RouteMacro.self,
        PathParamMacro.self,
        QueryParamMacro.self,
    ]
}

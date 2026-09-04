import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

private struct RouteMacroError: Error, CustomStringConvertible {
    let description: String
}

private struct ParsedParameter {
    enum Source: Equatable {
        case path
        case query
    }

    let name: String
    let property: String
    let type: String
    let source: Source
}

public enum PathParamMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public enum QueryParamMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public enum RouteMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let endpoint = declaration.as(StructDeclSyntax.self) else {
            throw RouteMacroError(description: "@Route can only be attached to a struct")
        }

        let (methods, template) = try parseRouteArguments(node)
        let segments = try parseTemplate(template)
        let parameters = try parseParameters(in: endpoint, expected: segments.parameterNames)
        try validateHandle(in: endpoint)

        let segmentSource = segments.source
        let definitions = methods.map {
            "RouteDefinition(method: \($0), segments: [\(segmentSource)])"
        }.joined(separator: ",\n            ")
        let decoding = parameters.path.map { parameter in
            """
            guard let \(parameter.property): \(parameter.type) = decodePathValue(
                \(parameter.type).self,
                from: try request.parameters.require("\(parameter.name)")
            ) else {
                throw Abort(.badRequest, body: "Invalid path parameter: \(parameter.name)")
            }
            """
        }.joined(separator: "\n            ")
        let queryDecoding = parameters.query.map(queryDecoding).joined(separator: "\n            ")
        let initializerArguments = parameters.all.map { "\($0.property): \($0.property)" }.joined(separator: ", ")
        let initializer = "Self(\(initializerArguments))"

        let extensionSource = """
        extension \(type.trimmedDescription): RouteEndpoint {
            static var routeDefinitions: [RouteDefinition] {
                [
                    \(definitions)
                ]
            }

            static func respond(to request: Request) async throws -> Response {
                \(decoding)
                \(queryDecoding)
                return try await \(initializer).handle(request)
            }
        }
        """
        guard let routeExtension = Parser.parse(source: extensionSource).statements.first?.item.as(ExtensionDeclSyntax.self) else {
            throw RouteMacroError(description: "Unable to generate route endpoint")
        }
        return [routeExtension]
    }

    private static func parseRouteArguments(_ node: AttributeSyntax) throws -> ([String], String) {
        guard case let .argumentList(arguments) = node.arguments,
              arguments.count == 2,
              let pathArgument = arguments.last,
              let path = stringLiteral(pathArgument.expression)
        else {
            throw RouteMacroError(description: "@Route requires one or more methods followed by a string-literal path")
        }

        let supported = Set(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"])
        let methodExpressions: [ExprSyntax]
        if let array = arguments.first?.expression.as(ArrayExprSyntax.self) {
            methodExpressions = array.elements.map(\.expression)
        } else if let method = arguments.first?.expression {
            methodExpressions = [method]
        } else {
            throw RouteMacroError(description: "@Route requires at least one HTTP method")
        }
        guard !methodExpressions.isEmpty else {
            throw RouteMacroError(description: "@Route requires at least one HTTP method")
        }
        let methods = try methodExpressions.map { expression -> String in
            let text = expression.trimmedDescription
            guard let name = text.split(separator: ".").last.map(String.init), supported.contains(name) else {
                throw RouteMacroError(description: "@Route only supports GET, POST, PUT, PATCH, DELETE, HEAD, and OPTIONS")
            }
            return text
        }
        guard Set(methods).count == methods.count else {
            throw RouteMacroError(description: "@Route cannot declare the same HTTP method more than once")
        }
        return (methods, path)
    }

    private static func parseTemplate(_ template: String) throws -> (source: String, parameterNames: [String]) {
        var parameterNames: [String] = []
        var source: [String] = []
        let parts = template.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        for (index, part) in parts.enumerated() {
            if part.hasPrefix("{*") && part.hasSuffix("}") {
                let name = String(part.dropFirst(2).dropLast())
                try validateParameterName(name, in: template)
                guard index == parts.count - 1 else {
                    throw RouteMacroError(description: "A wildcard must be the final path segment in \(template)")
                }
                parameterNames.append(name)
                source.append(".wildcard(\(swiftStringLiteral(name)))")
            } else if part.hasPrefix("{") && part.hasSuffix("}") {
                let name = String(part.dropFirst().dropLast())
                try validateParameterName(name, in: template)
                parameterNames.append(name)
                source.append(".parameter(\(swiftStringLiteral(name)))")
            } else {
                guard !part.contains("{") && !part.contains("}") else {
                    throw RouteMacroError(description: "Invalid path parameter syntax in \(template)")
                }
                source.append(".literal(\(swiftStringLiteral(part)))")
            }
        }

        guard Set(parameterNames).count == parameterNames.count else {
            throw RouteMacroError(description: "Route parameters must have unique names")
        }
        return (source.joined(separator: ", "), parameterNames)
    }

    private static func parseParameters(
        in endpoint: StructDeclSyntax,
        expected names: [String]
    ) throws -> (path: [ParsedParameter], query: [ParsedParameter], all: [ParsedParameter]) {
        var pathBindings: [String: ParsedParameter] = [:]
        var queryBindings: [String: ParsedParameter] = [:]
        var allBindings: [ParsedParameter] = []

        for member in endpoint.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else { continue }
            let isStatic = variable.modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
            for binding in variable.bindings {
                guard let property = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    continue
                }
                let pathAttribute = variable.attributes.first(where: isPathParam)?.as(AttributeSyntax.self)
                let queryAttribute = variable.attributes.first(where: isQueryParam)?.as(AttributeSyntax.self)
                guard pathAttribute != nil || queryAttribute != nil else {
                    if !isStatic {
                        throw RouteMacroError(description: "Stored property '\(property)' must be annotated with @PathParam or @QueryParam")
                    }
                    continue
                }
                guard pathAttribute == nil || queryAttribute == nil else {
                    throw RouteMacroError(description: "Stored property '\(property)' cannot use both @PathParam and @QueryParam")
                }
                guard !isStatic else {
                    throw RouteMacroError(description: "@PathParam and @QueryParam cannot be applied to a static property")
                }
                guard let type = binding.typeAnnotation?.type.trimmedDescription else {
                    throw RouteMacroError(description: "Parameter property '\(property)' must declare a type")
                }
                let attribute = pathAttribute ?? queryAttribute!
                guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
                      let argument = arguments.first,
                      let name = stringLiteral(argument.expression),
                      !name.isEmpty
                else {
                    throw RouteMacroError(description: "@\(pathAttribute == nil ? "QueryParam" : "PathParam") requires a non-empty string-literal name")
                }
                let parameter = ParsedParameter(
                    name: name,
                    property: property,
                    type: type,
                    source: pathAttribute == nil ? .query : .path
                )
                if pathAttribute != nil {
                    guard pathBindings[name] == nil else {
                        throw RouteMacroError(description: "Route parameter '\(name)' has more than one @PathParam binding")
                    }
                    pathBindings[name] = parameter
                } else {
                    guard queryBindings[name] == nil else {
                        throw RouteMacroError(description: "Query parameter '\(name)' has more than one @QueryParam binding")
                    }
                    queryBindings[name] = parameter
                }
                allBindings.append(parameter)
            }
        }

        let expected = Set(names)
        let bound = Set(pathBindings.keys)
        guard expected == bound else {
            let missing = expected.subtracting(bound).sorted()
            let unused = bound.subtracting(expected).sorted()
            var problems: [String] = []
            if !missing.isEmpty { problems.append("missing @PathParam binding(s): \(missing.joined(separator: ", "))") }
            if !unused.isEmpty { problems.append("unused @PathParam binding(s): \(unused.joined(separator: ", "))") }
            throw RouteMacroError(description: problems.joined(separator: "; "))
        }
        return (
            path: names.compactMap { pathBindings[$0] },
            query: allBindings.filter { $0.source == .query },
            all: allBindings
        )
    }

    private static func queryDecoding(_ parameter: ParsedParameter) -> String {
        let name = swiftStringLiteral(parameter.name)
        let missingMessage = swiftStringLiteral("Missing query parameter: \(parameter.name)")
        let invalidMessage = swiftStringLiteral("Invalid query parameter: \(parameter.name)")
        if let wrappedType = queryWrappedType(parameter.type) {
            return """
            let \(parameter.property): \(parameter.type)
            if let rawValue = request.query[\(name)] {
                guard let value: \(wrappedType) = decodeQueryValue(\(wrappedType).self, from: rawValue) else {
                    throw Abort(.badRequest, body: \(invalidMessage))
                }
                \(parameter.property) = value
            } else {
                \(parameter.property) = nil
            }
            """
        }
        return """
        guard let rawValue = request.query[\(name)] else {
            throw Abort(.badRequest, body: \(missingMessage))
        }
        guard let \(parameter.property): \(parameter.type) = decodeQueryValue(
            \(parameter.type).self,
            from: rawValue
        ) else {
            throw Abort(.badRequest, body: \(invalidMessage))
        }
        """
    }

    private static func validateHandle(in endpoint: StructDeclSyntax) throws {
        guard let handle = endpoint.memberBlock.members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) }).first(where: {
            $0.name.text == "handle"
        }) else {
            throw RouteMacroError(description: "@Route endpoint must define func handle(_ request: Request) async throws -> Response")
        }
        let parameters = handle.signature.parameterClause.parameters
        guard parameters.count == 1,
              parameters.first?.type.trimmedDescription == "Request",
              handle.signature.returnClause?.type.trimmedDescription == "Response",
              handle.signature.effectSpecifiers?.asyncSpecifier != nil,
              handle.signature.effectSpecifiers?.throwsClause != nil
        else {
            throw RouteMacroError(description: "@Route endpoint must define func handle(_ request: Request) async throws -> Response")
        }
    }

    private static func isPathParam(_ element: AttributeListSyntax.Element) -> Bool {
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last == "PathParam"
    }

    private static func isQueryParam(_ element: AttributeListSyntax.Element) -> Bool {
        guard let attribute = element.as(AttributeSyntax.self) else { return false }
        return attribute.attributeName.trimmedDescription.split(separator: ".").last == "QueryParam"
    }

    private static func queryWrappedType(_ type: String) -> String? {
        if type.hasSuffix("?") {
            return String(type.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard type.hasPrefix("Optional<"), type.hasSuffix(">") else { return nil }
        return String(type.dropFirst("Optional<".count).dropLast())
    }

    private static func stringLiteral(_ expression: ExprSyntax) -> String? {
        guard let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              case let .stringSegment(segment)? = literal.segments.first
        else {
            return nil
        }
        return segment.content.text
    }

    private static func validateParameterName(_ name: String, in template: String) throws {
        guard let first = name.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first),
              name.unicodeScalars.dropFirst().allSatisfy({ $0 == "_" || CharacterSet.alphanumerics.contains($0) })
        else {
            throw RouteMacroError(description: "Invalid path parameter name '\(name)' in \(template)")
        }
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

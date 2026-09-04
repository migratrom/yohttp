import Foundation
import Testing
@testable import YoHTTP

@Suite("Request and parameters")
struct RequestTests {
    @Test func parsesRepeatedAndEncodedQueryParameters() {
        let request = Request(
            method: .GET,
            uri: "/search?q=swift+nio&tag=a&tag=b%20c&flag&empty=&na+me=value&&bad=%ZZ"
        )

        #expect(request.path == "/search")
        #expect(request.query["q"] == "swift nio")
        #expect(request.query.values(for: "tag") == ["a", "b c"])
        #expect(request.query["flag"] == "")
        #expect(request.query["empty"] == "")
        #expect(request.query["na me"] == "value")
        #expect(request.query["bad"] == "%ZZ")
        #expect(request.query.contains("flag"))
        #expect(!request.query.contains("missing"))
        #expect(request.query.values(for: "missing").isEmpty)
        #expect(Dictionary(uniqueKeysWithValues: request.query.map { ($0.key, $0.value) })["tag"] == ["a", "b c"])
    }

    @Test func supportsNoQueryAndExplicitOverrides() {
        let plain = Request(method: .GET, uri: "/plain")
        #expect(plain.path == "/plain")
        #expect(Array(plain.query).isEmpty)

        let query = QueryParameters(["explicit": ["yes"]])
        let overridden = Request(method: .POST, uri: "/ignored?x=1", path: "/chosen", query: query)
        #expect(overridden.path == "/chosen")
        #expect(overridden.query == query)
    }

    @Test func exposesHeadersContentTypeBodyAndAddress() async throws {
        struct Input: Decodable, Equatable { let someValue: String }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let address = SocketAddress(host: "localhost", port: 1234)
        let request = Request(
            method: .POST,
            uri: "/",
            headers: ["Content-Type": "application/custom+json", "X-Test": "yes"],
            body: Body(#"{"some_value":"decoded"}"#),
            remoteAddress: address
        )

        #expect(request.contentType == MediaType(rawValue: "application/custom+json"))
        #expect(request.header("x-test") == "yes")
        #expect(request.header("missing") == nil)
        #expect(try await request.decode(Input.self, decoder: decoder) == Input(someValue: "decoded"))
        #expect(request.remoteAddress == address)
        #expect(Request(method: .GET, uri: "/").contentType == nil)
    }

    @Test func parsesCookiesAcrossHeadersAndPreservesEqualsInValues() {
        var headers = Headers()
        headers.add("Cookie", "broken; first=one; token=a=b=c")
        headers.add("cookie", "empty=; spaced = value ")
        let request = Request(method: .GET, uri: "/", headers: headers)

        #expect(request.cookie("first") == "one")
        #expect(request.cookie("token") == "a=b=c")
        #expect(request.cookie("empty") == "")
        #expect(request.cookie("spaced") == "value")
        #expect(request.cookie("missing") == nil)
    }

    @Test func pathParametersReturnValuesAndThrowUsefulAbort() async throws {
        let parameters = PathParameters(["id": "42"])
        #expect(parameters["id"] == "42")
        #expect(try parameters.require("id") == "42")

        do {
            _ = try parameters.require("missing")
            Issue.record("Expected missing parameter to throw")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
            #expect(try await error.body.string() == "Missing path parameter: missing")
        }
    }
}

import Foundation
import Testing
@testable import YoHTTP

@Suite("HTTP value types")
struct HTTPTypesTests {
    @Test func headersAreCaseInsensitiveOrderedAndRepeatable() {
        var headers = Headers()
        headers.add("X-Trace", "one")
        headers.add("x-trace", "two")
        headers["CONTENT-TYPE"] = "text/plain"

        #expect(headers["x-TRACE"] == "one")
        #expect(headers.values(for: "X-Trace") == ["one", "two"])
        #expect(Array(headers).map(\.1) == ["one", "two", "text/plain"])

        headers["X-TRACE"] = "replacement"
        #expect(headers.values(for: "x-trace") == ["replacement"])
    }

    @Test func requestParsesQueryAndCookies() {
        let request = Request(
            method: .GET,
            uri: "/search?q=swift+nio&tag=a&tag=b%20c",
            headers: ["Cookie": "session=abc; theme=dark"]
        )

        #expect(request.path == "/search")
        #expect(request.query["q"] == "swift nio")
        #expect(request.query.values(for: "tag") == ["a", "b c"])
        #expect(request.cookie("theme") == "dark")
    }

    @Test func responseHelpersSetRepresentations() throws {
        struct Message: Codable, Equatable { let value: String }

        let text = Response.text("hello", status: .created)
        #expect(text.status == .created)
        #expect(text.headers["content-type"] == MediaType.text.rawValue)
        #expect(text.body.string() == "hello")

        let json = try Response.json(Message(value: "hello"))
        #expect(json.headers["content-type"] == MediaType.json.rawValue)
        #expect(try json.body.decode(Message.self) == Message(value: "hello"))
    }

    @Test func responseSupportsMultipleCookiesAndDeletion() {
        var response = Response()
        response.cookie(Cookie(name: "session", value: "abc", path: "/", secure: true, httpOnly: true, sameSite: .lax))
        response.deleteCookie("legacy")

        let cookies = response.headers.values(for: "set-cookie")
        #expect(cookies.count == 2)
        #expect(cookies[0].contains("session=abc; Path=/; Secure; HttpOnly; SameSite=Lax"))
        #expect(cookies[1].contains("legacy=; Path=/"))
        #expect(cookies[1].contains("Max-Age=0"))
    }
}

import Foundation
import Testing
@testable import YoHTTP

@Suite("Response, cookies, and errors")
struct ResponseAndCookieTests {
    private struct Message: Codable, Equatable { let value: String }

    @Test func responseHelpersSetRepresentationsAndPreserveOtherHeaders() async throws {
        let text = Response.text("hello", status: .created, headers: ["X-Test": "yes", "Content-Type": "old"])
        #expect(text.status == .created)
        #expect(text.headers["content-type"] == MediaType.text.rawValue)
        #expect(text.headers["x-test"] == "yes")
        #expect(try await text.body.string() == "hello")

        let html = Response.html("<b>hello</b>", status: .accepted, headers: ["X-Test": "html"])
        #expect(html.status == .accepted)
        #expect(html.headers["content-type"] == MediaType.html.rawValue)
        #expect(html.headers["x-test"] == "html")

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try Response.json(Message(value: "hello"), status: .created, headers: ["X-Test": "json"], encoder: encoder)
        #expect(json.status == .created)
        #expect(json.headers["content-type"] == MediaType.json.rawValue)
        #expect(json.headers["x-test"] == "json")
        #expect(try await json.body.decode(Message.self) == Message(value: "hello"))

        let redirect = Response.redirect("/next", status: .seeOther, headers: ["X-Test": "redirect"])
        #expect(redirect.status == .seeOther)
        #expect(redirect.headers["location"] == "/next")
        #expect(redirect.headers["x-test"] == "redirect")
        #expect(redirect.body.knownLength == 0)
    }

    @Test func serializesEveryCookieAttributeAndSameSiteValue() {
        let date = Date(timeIntervalSince1970: 0)
        var response = Response()
        response.cookie(Cookie(
            name: "session", value: "abc", domain: "example.com", path: "/app",
            expires: date, maxAge: .seconds(3600), secure: true, httpOnly: true, sameSite: .strict
        ))
        response.cookie(Cookie(name: "lax", value: "1", sameSite: .lax))
        response.cookie(Cookie(name: "none", value: "1", sameSite: SameSite.none))

        #expect(response.headers.values(for: "set-cookie") == [
            "session=abc; Domain=example.com; Path=/app; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=3600; Secure; HttpOnly; SameSite=Strict",
            "lax=1; SameSite=Lax",
            "none=1; SameSite=None",
        ])
    }

    @Test func deletionUsesEpochAndRequestedPath() {
        var response = Response()
        response.deleteCookie("legacy", path: "/legacy")
        #expect(response.headers["set-cookie"] == "legacy=; Path=/legacy; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0")
    }

    @Test func abortSupportsStringAndOwnedBodyInitializers() async throws {
        let stringAbort = Abort(.unauthorized, headers: ["X-Test": "one"], body: "No")
        #expect(stringAbort.status == .unauthorized)
        #expect(stringAbort.headers["x-test"] == "one")
        #expect(try await stringAbort.body.string() == "No")

        let bodyAbort = Abort(.conflict, headers: ["X-Test": "two"], body: Body("Conflict"))
        #expect(bodyAbort.status == .conflict)
        #expect(bodyAbort.headers["x-test"] == "two")
        #expect(try await bodyAbort.body.string() == "Conflict")
    }
}

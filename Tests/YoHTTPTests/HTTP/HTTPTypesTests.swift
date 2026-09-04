import Testing
@testable import YoHTTP

@Suite("HTTP primitive types")
struct HTTPTypesTests {
    @Test func methodsNormalizeAndExposeStandardValues() {
        let methods: [Method] = [.GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS, .CONNECT, .TRACE]
        #expect(methods.map(\.rawValue) == ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"])
        #expect(Method(rawValue: "custom").rawValue == "CUSTOM")
        #expect(Method(stringLiteral: "lower").description == "LOWER")
    }

    @Test func statusInfersEveryStandardReasonAndHandlesUnknownCodes() {
        let expected: [(Int, String)] = [
            (100, "Continue"), (101, "Switching Protocols"),
            (200, "OK"), (201, "Created"), (202, "Accepted"), (204, "No Content"),
            (301, "Moved Permanently"), (302, "Found"), (303, "See Other"),
            (304, "Not Modified"), (307, "Temporary Redirect"), (308, "Permanent Redirect"),
            (400, "Bad Request"), (401, "Unauthorized"), (403, "Forbidden"),
            (404, "Not Found"), (405, "Method Not Allowed"), (408, "Request Timeout"),
            (409, "Conflict"), (411, "Length Required"), (413, "Content Too Large"),
            (415, "Unsupported Media Type"), (422, "Unprocessable Content"),
            (429, "Too Many Requests"), (431, "Request Header Fields Too Large"),
            (500, "Internal Server Error"), (501, "Not Implemented"),
            (502, "Bad Gateway"), (503, "Service Unavailable"),
        ]

        for (code, reason) in expected {
            let status = Status(code)
            #expect(status.reasonPhrase == reason)
            #expect(status.description == "\(code) \(reason)")
        }
        #expect(Status(599).reasonPhrase.isEmpty)
        #expect(Status(299, reasonPhrase: "Custom").description == "299 Custom")
    }

    @Test func namedStatusesHaveExpectedCodes() {
        let statuses: [Status] = [
            .continue, .switchingProtocols, .ok, .created, .accepted, .noContent,
            .movedPermanently, .found, .seeOther, .notModified, .temporaryRedirect,
            .permanentRedirect, .badRequest, .unauthorized, .forbidden, .notFound,
            .methodNotAllowed, .requestTimeout, .conflict, .lengthRequired,
            .contentTooLarge, .unsupportedMediaType, .unprocessableContent,
            .tooManyRequests, .requestHeaderFieldsTooLarge, .internalServerError,
            .notImplemented, .badGateway, .serviceUnavailable,
        ]
        #expect(statuses.map(\.code) == [100, 101, 200, 201, 202, 204, 301, 302, 303, 304, 307, 308, 400, 401, 403, 404, 405, 408, 409, 411, 413, 415, 422, 429, 431, 500, 501, 502, 503])
    }

    @Test func mediaTypesAndSocketAddressesExposeValues() {
        let mediaTypes: [MediaType] = [.json, .text, .html, .formURLEncoded, .multipartFormData, .octetStream]
        #expect(mediaTypes.map(\.rawValue) == [
            "application/json", "text/plain; charset=utf-8", "text/html; charset=utf-8",
            "application/x-www-form-urlencoded", "multipart/form-data", "application/octet-stream",
        ])
        #expect(MediaType(rawValue: "image/png").rawValue == "image/png")
        #expect(MediaType(stringLiteral: "image/jpeg").rawValue == "image/jpeg")

        #expect(SocketAddress(host: "127.0.0.1", port: 8080).description == "127.0.0.1:8080")
        #expect(SocketAddress(host: "unix-socket").description == "unix-socket")
    }
}

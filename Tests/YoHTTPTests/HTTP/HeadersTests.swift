import Testing
@testable import YoHTTP

@Suite("Headers")
struct HeadersTests {
    @Test func storageIsCaseInsensitiveOrderedAndRepeatable() {
        var headers = Headers([("X-Trace", "one"), ("x-trace", "two")])
        headers["CONTENT-TYPE"] = "text/plain"

        #expect(headers["x-TRACE"] == "one")
        #expect(headers.values(for: "X-Trace") == ["one", "two"])
        #expect(headers.values(for: "missing").isEmpty)
        #expect(Array(headers).map(\.0) == ["X-Trace", "x-trace", "CONTENT-TYPE"])
        #expect(Array(headers).map(\.1) == ["one", "two", "text/plain"])
        #expect(headers.contains("content-TYPE"))
        #expect(!headers.contains("missing"))
    }

    @Test func setReplacesAllValuesAtTheirFirstPosition() {
        var headers: Headers = ["Before": "a", "X-Trace": "one", "Between": "b"]
        headers.add("x-trace", "two")
        headers.set("X-TRACE", "replacement")

        #expect(headers.values(for: "x-trace") == ["replacement"])
        #expect(Array(headers).map(\.0) == ["Before", "X-TRACE", "Between"])

        headers.set("After", "c")
        #expect(Array(headers).map(\.1) == ["a", "replacement", "b", "c"])
    }

    @Test func removalWorksThroughBothAPIs() {
        var headers: Headers = ["A": "1", "B": "2"]
        headers["a"] = nil
        #expect(headers["A"] == nil)

        headers.remove("b")
        headers.remove("missing")
        #expect(Array(headers).isEmpty)
        #expect(headers == Headers())
    }
}

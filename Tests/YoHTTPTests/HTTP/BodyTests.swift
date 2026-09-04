import Foundation
import NIOCore
import Testing
@testable import YoHTTP

@Suite("Body")
struct BodyTests {
    private struct Message: Codable, Equatable {
        let value: String
    }

    @Test func streamsDataAndStrings() async throws {
        let empty = Body.empty
        #expect(empty.knownLength == 0)
        #expect(try await empty.data() == Data())

        let string = Body("héllo")
        #expect(string.knownLength == Data("héllo".utf8).count)
        #expect(try await string.string() == "héllo")

        let ascii = Body(Data([0x68, 0x69]))
        #expect(try await ascii.string(encoding: .ascii) == "hi")
        #expect(try await Body(Data([0xff])).string() == nil)
    }

    @Test func decodesJSONWithDefaultAndCustomDecoders() async throws {
        let body = Body(#"{"value":"hello"}"#)
        #expect(try await body.decode(Message.self) == Message(value: "hello"))

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Custom: Decodable, Equatable { let someValue: String }
        #expect(try await Body(#"{"some_value":"ok"}"#).decode(Custom.self, decoder: decoder) == Custom(someValue: "ok"))
        await #expect(throws: DecodingError.self) { try await Body("not json").decode(Message.self) }
    }

    @Test func rejectsSecondConsumer() async throws {
        let body = Body("once")
        _ = try await body.data()
        var iterator = body.makeAsyncIterator()
        await #expect(throws: Body.Error.alreadyConsumed) { try await iterator.next() }
    }

    @Test func rejectsBodiesThatExceedTheCollectionLimit() async {
        await #expect(throws: Body.Error.tooLarge(limit: 2)) {
            _ = try await Body("three").data(upTo: 2)
        }
    }

    @Test func forwardsFailuresFromAnAsynchronousSequence() async {
        struct StreamFailure: Error {}
        let stream = AsyncThrowingStream<ByteBuffer, Error> { continuation in
            continuation.finish(throwing: StreamFailure())
        }
        await #expect(throws: StreamFailure.self) {
            _ = try await Body(stream).data()
        }
    }

    @Test func appliesBackpressureUntilTheConsumerDrainsTheBuffer() async throws {
        let stream = AsyncStream<ByteBuffer> { continuation in
            for index in 0..<9 {
                continuation.yield(ByteBuffer(string: "\(index)"))
            }
            continuation.finish()
        }
        let body = Body(stream)

        // Let Body's producer fill its eight-chunk buffer before consuming it.
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await body.string() == "012345678")
    }

    @Test func sequenceChannelHandlesCompletionAndBackpressureTransitions() async throws {
        struct StreamFailure: Error {}

        let completed = SequenceChannel()
        await completed.finish()
        await #expect(throws: CancellationError.self) {
            try await completed.send(ByteBuffer())
        }
        await completed.finish()

        let failed = SequenceChannel()
        await failed.finish(StreamFailure())
        await #expect(throws: StreamFailure.self) {
            _ = try await failed.nextChunk()
        }

        let waitingReader = SequenceChannel()
        let reader = Task { try await waitingReader.nextChunk() }
        try await Task.sleep(for: .milliseconds(20))
        await waitingReader.finish()
        #expect(try await reader.value == nil)

        let waitingWriter = SequenceChannel()
        for _ in 0..<8 {
            try await waitingWriter.send(ByteBuffer(string: "x"))
        }
        let writer = Task { try await waitingWriter.send(ByteBuffer(string: "x")) }
        try await Task.sleep(for: .milliseconds(20))
        await waitingWriter.finish()
        await #expect(throws: CancellationError.self) {
            try await writer.value
        }

        let resumedWriter = SequenceChannel()
        for _ in 0..<8 {
            try await resumedWriter.send(ByteBuffer(string: "x"))
        }
        let resumedTask = Task { try await resumedWriter.send(ByteBuffer(string: "x")) }
        try await Task.sleep(for: .milliseconds(20))
        _ = try await resumedWriter.nextChunk()
        await resumedWriter.finish()
        await #expect(throws: CancellationError.self) {
            try await resumedTask.value
        }
    }
}

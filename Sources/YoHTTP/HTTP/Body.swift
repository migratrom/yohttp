import Foundation
import NIOCore
import Synchronization

/// A single-consumer, asynchronously produced HTTP message body.
///
/// `Body` is intentionally a unicast sequence. A request body is supplied by a
/// connection and a response body is sent on one connection, so silently allowing
/// a second consumer would either duplicate buffered data or race the first one.
public struct Body: AsyncSequence, Sendable {
    public typealias Element = ByteBuffer

    public enum Error: Swift.Error, Sendable, Equatable {
        /// A body can only be iterated once.
        case alreadyConsumed
        /// Collecting the body would exceed the caller supplied limit.
        case tooLarge(limit: Int)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let nextChunk: @Sendable () async throws -> ByteBuffer?

        fileprivate init(nextChunk: @escaping @Sendable () async throws -> ByteBuffer?) {
            self.nextChunk = nextChunk
        }

        public mutating func next() async throws -> ByteBuffer? {
            try await nextChunk()
        }
    }

    private let storage: any BodyStorage
    private let length: Int?
    private let consumption = Consumption()

    /// An empty body with a known length.
    public static var empty: Body { Body(ByteBuffer()) }

    /// The body length when it is known before streaming begins.
    public var knownLength: Int? { length }

    public init(_ buffer: ByteBuffer) {
        self.init(sequence: OneChunkSequence(chunk: buffer), knownLength: buffer.readableBytes)
    }

    public init(_ data: Data) {
        self.init(ByteBuffer(bytes: data))
    }

    public init(_ string: String) {
        self.init(ByteBuffer(string: string))
    }

    /// Creates a body from an arbitrary asynchronous byte sequence.
    ///
    /// Supply `knownLength` only when the sequence is guaranteed to yield exactly
    /// that many readable bytes. An unspecified length is sent chunked over HTTP/1.1.
    public init<S: AsyncSequence & Sendable>(_ sequence: S, knownLength: Int? = nil)
    where S.Element == ByteBuffer {
        self.init(sequence: sequence, knownLength: knownLength)
    }

    private init<S: AsyncSequence & Sendable>(sequence: S, knownLength: Int?) where S.Element == ByteBuffer {
        self.storage = SequenceStorage(sequence)
        self.length = knownLength
    }

    init(storage: any BodyStorage, knownLength: Int? = nil) {
        self.storage = storage
        self.length = knownLength
    }

    func sharesStorage(with other: Body) -> Bool {
        storage === other.storage
    }

    public func makeAsyncIterator() -> AsyncIterator {
        let claimed = consumption.claim()
        guard claimed else {
            return AsyncIterator { throw Error.alreadyConsumed }
        }
        return AsyncIterator { try await storage.nextChunk() }
    }

    /// Buffers the remaining bytes up to `limit`.
    public func collect(upTo limit: Int = .max) async throws -> ByteBuffer {
        var result = ByteBuffer()
        for try await var chunk in self {
            guard result.readableBytes <= limit - chunk.readableBytes else {
                throw Error.tooLarge(limit: limit)
            }
            result.writeBuffer(&chunk)
        }
        return result
    }

    public func data(upTo limit: Int = .max) async throws -> Data {
        let buffer = try await collect(upTo: limit)
        return Data(buffer.readableBytesView)
    }

    public func string(
        encoding: String.Encoding = .utf8,
        upTo limit: Int = .max
    ) async throws -> String? {
        String(data: try await data(upTo: limit), encoding: encoding)
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = .init(),
        upTo limit: Int = .max
    ) async throws -> T {
        try decoder.decode(type, from: await data(upTo: limit))
    }
}

private final class Consumption: Sendable {
    private let state = Mutex(false)

    func claim() -> Bool {
        state.withLock { consumed in
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }
}

protocol BodyStorage: AnyObject, Sendable {
    func nextChunk() async throws -> ByteBuffer?
}

private final class SequenceStorage<S: AsyncSequence & Sendable>: BodyStorage where S.Element == ByteBuffer {
    private let channel = SequenceChannel()

    init(_ sequence: S) {
        Task { [channel] in
            do {
                for try await chunk in sequence {
                    try await channel.send(chunk)
                }
                await channel.finish()
            } catch {
                await channel.finish(error)
            }
        }
    }

    func nextChunk() async throws -> ByteBuffer? {
        try await channel.nextChunk()
    }
}

actor SequenceChannel {
    private var chunks: [ByteBuffer] = []
    private var reader: CheckedContinuation<ByteBuffer?, Swift.Error>?
    private var writers: [CheckedContinuation<Void, Swift.Error>] = []
    private var completion: Swift.Error??

    func send(_ chunk: ByteBuffer) async throws {
        guard completion == nil else { throw CancellationError() }
        if let reader {
            self.reader = nil
            reader.resume(returning: chunk)
            return
        }
        while chunks.count >= 8 {
            try await withCheckedThrowingContinuation { writers.append($0) }
            guard completion == nil else { throw CancellationError() }
        }
        chunks.append(chunk)
    }

    func nextChunk() async throws -> ByteBuffer? {
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            if !writers.isEmpty { writers.removeFirst().resume() }
            return chunk
        }
        if let completion {
            if let error = completion { throw error }
            return nil
        }
        return try await withCheckedThrowingContinuation { reader = $0 }
    }

    func finish(_ error: Swift.Error? = nil) {
        guard completion == nil else { return }
        completion = error
        if chunks.isEmpty, let reader {
            self.reader = nil
            if let error { reader.resume(throwing: error) } else { reader.resume(returning: nil) }
        }
        for writer in writers { writer.resume(throwing: CancellationError()) }
        writers.removeAll()
    }
}

private struct OneChunkSequence: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    struct AsyncIterator: AsyncIteratorProtocol {
        var chunk: ByteBuffer?

        mutating func next() async -> ByteBuffer? {
            defer { chunk = nil }
            return chunk
        }
    }

    let chunk: ByteBuffer

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunk: chunk)
    }
}

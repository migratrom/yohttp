import Foundation

/// An owned, in-memory HTTP message body.
public struct Body: Sendable, Equatable {
    private var storage: Data

    public static let empty = Body(Data())

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public init(_ data: Data) {
        storage = data
    }

    public init(_ string: String) {
        storage = Data(string.utf8)
    }

    public func data() -> Data { storage }

    public func string(encoding: String.Encoding = .utf8) -> String? {
        String(data: storage, encoding: encoding)
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        decoder: JSONDecoder = .init()
    ) throws -> T {
        try decoder.decode(type, from: storage)
    }
}

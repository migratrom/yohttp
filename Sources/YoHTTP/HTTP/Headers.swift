/// Case-insensitive HTTP header storage that preserves insertion order and repeated fields.
public struct Headers: Sendable, Sequence, ExpressibleByDictionaryLiteral, Equatable {
    private struct Field: Sendable, Equatable {
        var name: String
        var normalizedName: String
        var value: String
    }

    private var fields: [Field] = []

    public init() {}

    public init<S: Sequence>(_ fields: S) where S.Element == (String, String) {
        for (name, value) in fields { add(name, value) }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    public subscript(_ name: String) -> String? {
        get { fields.first { $0.normalizedName == Self.normalize(name) }?.value }
        set {
            switch newValue {
            case .some(let value): set(name, value)
            case .none: remove(name)
            }
        }
    }

    public func values(for name: String) -> [String] {
        let normalized = Self.normalize(name)
        return fields.compactMap { $0.normalizedName == normalized ? $0.value : nil }
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append(Field(name: name, normalizedName: Self.normalize(name), value: value))
    }

    public mutating func set(_ name: String, _ value: String) {
        let normalized = Self.normalize(name)
        let firstIndex = fields.firstIndex { $0.normalizedName == normalized }
        fields.removeAll { $0.normalizedName == normalized }
        let field = Field(name: name, normalizedName: normalized, value: value)
        if let firstIndex { fields.insert(field, at: Swift.min(firstIndex, fields.endIndex)) }
        else { fields.append(field) }
    }

    public mutating func remove(_ name: String) {
        let normalized = Self.normalize(name)
        fields.removeAll { $0.normalizedName == normalized }
    }

    public func contains(_ name: String) -> Bool {
        let normalized = Self.normalize(name)
        return fields.contains { $0.normalizedName == normalized }
    }

    public struct Iterator: IteratorProtocol {
        private var iterator: Array<(String, String)>.Iterator
        fileprivate init(_ fields: [(String, String)]) {
            iterator = fields.makeIterator()
        }
        public mutating func next() -> (String, String)? { iterator.next() }
    }

    public func makeIterator() -> Iterator { Iterator(fields.map { ($0.name, $0.value) }) }

    private static func normalize(_ name: String) -> String { name.lowercased() }
}

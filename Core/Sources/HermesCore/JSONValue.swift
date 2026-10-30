import Foundation

/// A JSON value as data.
///
/// The dashboard sends frames whose shape the client cannot know in advance: an event payload
/// depends on the tool that ran, an approval carries fields the server adds over time. Modelling
/// those as `Codable` structs would turn every server change into a decoding failure, so a frame is
/// kept as this and read where it is needed, the way the Kotlin client reads `JsonObject`.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A string the server may have written as a string or as a number: ids, epochs and similar
    /// fields arrive both ways across the dashboard's versions.
    public var scalarString: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            guard value.isFinite else { return nil }
            return value == value.rounded() ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite, value == value.rounded() else { return nil }
        return Int(exactly: value)
    }

    public var int64Value: Int64? {
        guard case .number(let value) = self, value.isFinite, value == value.rounded() else { return nil }
        return Int64(exactly: value)
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// A number written as a string as well: `expires_at` comes as one or the other.
    public var numericValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    /// The strings of an array, skipping anything else: `auth_flows`, `auth_providers`.
    public var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap(\.stringValue)
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

// MARK: - Writing

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Coding

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    /// The bytes of one frame, compact, as the socket sends them.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads one frame. `fragmentsAllowed` keeps a bare string or number readable, which a broken
    /// server may send.
    public static func decode(_ data: Data) throws -> JSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(JSONValue.self, from: data)
    }

    public static func decode(_ text: String) throws -> JSONValue {
        try decode(Data(text.utf8))
    }
}

import Foundation

/// 任意 JSON 值（Sendable，便于跨并发域传递原始字段）。
public enum JSONValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
}

/// ipatool 输出的一行 zerolog JSON（每行一个对象，带 level/time，可能带 error/success/message 等）。
public struct IpatoolLogEvent: Sendable, Equatable {
    public let level: String?
    public let time: String?
    public let message: String?
    public let error: String?
    public let success: Bool?
    /// 全部字段（含上面几个）。
    public let fields: [String: JSONValue]
    /// 该行原始 JSON 字节，用于按需解码成具体结构。
    public let rawData: Data

    public var isError: Bool { level == "error" || error != nil || success == false }

    public subscript(key: String) -> JSONValue? { fields[key] }

    /// 把整行解码为某个 Decodable 结构（未知字段忽略）。
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: rawData)
    }
}

/// 子进程输出的一行：JSON 事件或普通文本（进度条、提示等）。
public enum IpatoolLine: Sendable, Equatable {
    case json(IpatoolLogEvent)
    case text(String)
}

public enum IpatoolLineParser {
    /// 解析一行。只有以 `{` 开头、能解析成 JSON 对象的才算 JSON 行，其余原样作为文本。
    public static func parse(_ line: String) -> IpatoolLine {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return .text(line)
        }
        return .json(IpatoolLogEvent(
            level: object["level"]?.stringValue,
            time: object["time"]?.stringValue,
            message: object["message"]?.stringValue,
            error: object["error"]?.stringValue,
            success: object["success"]?.boolValue,
            fields: object,
            rawData: data
        ))
    }
}

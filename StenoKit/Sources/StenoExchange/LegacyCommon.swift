import CoreFoundation
import Foundation

public enum LegacyExchangeError: Error, Equatable, Sendable {
    case invalidFormat(String)
    case missingTranscriptLines
    case transcriptLineCountMismatch(expected: Int, actual: Int)
}

public indirect enum LegacyJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LegacyJSONValue])
    case object([String: LegacyJSONValue])
}

extension LegacyJSONValue {
    init(jsonObject: Any) throws {
        switch jsonObject {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as [Any]:
            self = .array(try value.map(Self.init(jsonObject:)))
        case let value as [String: Any]:
            self = .object(try value.mapValues(Self.init(jsonObject:)))
        default:
            throw LegacyExchangeError.invalidFormat("Unsupported JSON value")
        }
    }
}

public struct LegacyTimestampParser: Sendable {
    private let timeZoneIdentifier: String

    public init(timeZone: TimeZone = .current) {
        timeZoneIdentifier = timeZone.identifier
    }

    public func date(fromUnixSeconds seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    public func date(fromUnixMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    public func recordingStartedAt(stem: String) -> Date? {
        guard stem.hasPrefix("sysaudio-") else { return nil }
        let remainder = stem.dropFirst("sysaudio-".count)
        guard let separator = remainder.firstIndex(of: "-") else { return nil }
        guard let milliseconds = Int64(remainder[..<separator]) else { return nil }
        return date(fromUnixMilliseconds: milliseconds)
    }

    public func date(fromISO8601 value: String) -> Date? {
        if hasExplicitTimeZone(value) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }
        return parseLocal(value, formats: [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        ])
    }

    public func date(fromLegacyHeader value: String) -> Date? {
        parseLocal(value, formats: ["yyyy-MM-dd HH:mm:ss"])
    }

    private func hasExplicitTimeZone(_ value: String) -> Bool {
        if value.hasSuffix("Z") || value.hasSuffix("z") {
            return true
        }
        guard value.count >= 6 else { return false }
        let suffix = value.suffix(6)
        return (suffix.first == "+" || suffix.first == "-") && suffix.dropFirst(3).first == ":"
    }

    private func parseLocal(_ value: String, formats: [String]) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}

func legacyJSONObject(from url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw LegacyExchangeError.invalidFormat("Expected JSON object in \(url.lastPathComponent)")
    }
    return object
}

func legacyString(_ object: [String: Any], _ key: String) -> String? {
    object[key] as? String
}

func legacyDouble(_ object: [String: Any], _ key: String) -> Double? {
    (object[key] as? NSNumber)?.doubleValue
}

func legacyInt(_ object: [String: Any], _ key: String) -> Int? {
    (object[key] as? NSNumber)?.intValue
}

func legacyBool(_ object: [String: Any], _ key: String) -> Bool? {
    object[key] as? Bool
}

func legacyStringArray(_ value: Any?) -> [String] {
    value as? [String] ?? []
}

func legacyTrimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
}

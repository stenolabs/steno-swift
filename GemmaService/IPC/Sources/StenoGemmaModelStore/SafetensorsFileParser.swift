import Foundation

/// Code-owned structural limits for parsing a safetensors file before any ML runtime sees it.
package enum SafetensorsFileLimits {
    package static let maximumHeaderByteCount = 4 * 1024 * 1024
    package static let maximumTensorCount = 16_384
    package static let maximumTensorNameByteCount = 1_024
    package static let maximumTensorRank = 16
    package static let maximumTensorDimension = UInt64(Int32.max)
    package static let maximumMetadataEntryCount = 256
    package static let maximumMetadataKeyByteCount = 1_024
    package static let maximumMetadataValueByteCount = 64 * 1024
    package static let maximumTotalMetadataByteCount = 256 * 1024

    fileprivate static let maximumJSONDepth = 32
    fileprivate static let maximumJSONStringByteCount = maximumHeaderByteCount
    fileprivate static let maximumJSONNumberByteCount = 20
    fileprivate static let maximumJSONContainerElementCount = maximumTensorCount + 1

    /// One root object, the maximum tensor records and their complete value trees, plus the
    /// metadata object and every permitted metadata string value.
    static let maximumJSONValueCount = 1
        + maximumTensorCount * (maximumTensorRank + 6)
        + 1 + maximumMetadataEntryCount
}

/// The exact safetensors dtypes accepted by the MLX revision pinned by Steno.
///
/// This list mirrors `dtype_from_safetensor_str` in mlx-swift revision
/// `0bb916c67f4b9e5c682cbe02a42c701c93ab5021`.
package enum SafetensorsDType: String, CaseIterable, Sendable, Equatable {
    case float16 = "F16"
    case bfloat16 = "BF16"
    case float32 = "F32"
    case bool = "BOOL"
    case int8 = "I8"
    case int16 = "I16"
    case int32 = "I32"
    case int64 = "I64"
    case uint8 = "U8"
    case uint16 = "U16"
    case uint32 = "U32"
    case uint64 = "U64"
    case float8E4M3 = "F8_E4M3"
    case complex64 = "C64"

    package var byteWidth: UInt64 {
        switch self {
        case .bool, .int8, .uint8, .float8E4M3:
            1
        case .float16, .bfloat16, .int16, .uint16:
            2
        case .float32, .int32, .uint32:
            4
        case .int64, .uint64, .complex64:
            8
        }
    }
}

package struct SafetensorsTensor: Sendable, Equatable {
    package let name: String
    package let dtype: SafetensorsDType
    package let shape: [UInt64]

    /// The tensor bytes relative to the first payload byte after the declared JSON header.
    package let payloadByteRange: Range<Int>
}

package struct SafetensorsFile: Sendable, Equatable {
    package let metadata: [String: String]
    package let tensors: [SafetensorsTensor]
    package let payloadByteCount: Int
}

package enum SafetensorsFileError: Error, Equatable, Sendable {
    case fileTooShort
    case emptyHeader
    case headerTooLarge(limit: Int, actual: UInt64)
    case headerLengthNotRepresentable
    case headerBeyondEndOfFile
    case invalidHeaderUTF8
    case invalidHeaderJSON
    case invalidHeaderPadding
    case topLevelIsNotObject
    case duplicateJSONKey(String)
    case jsonNestingTooDeep
    case jsonContainerTooLarge(limit: Int)
    case jsonStringTooLarge(limit: Int)
    case jsonValueBudgetExceeded(limit: Int)
    case emptyTensorName
    case tensorNameTooLarge(limit: Int, actual: Int)
    case emptyTensorSet
    case tooManyTensors(limit: Int, actual: Int)
    case tensorRecordIsNotObject(String)
    case unknownTensorRecordKey(tensor: String, key: String)
    case missingTensorRecordKey(tensor: String, key: String)
    case invalidDType(tensor: String, value: String?)
    case invalidShape(tensor: String)
    case tensorRankTooLarge(tensor: String, limit: Int, actual: Int)
    case tensorDimensionTooLarge(tensor: String, limit: UInt64, actual: UInt64)
    case invalidInteger(tensor: String, field: String)
    case tensorByteCountOverflow(String)
    case invalidDataOffsets(String)
    case reversedDataOffsets(String)
    case dataOffsetsOutOfBounds(String)
    case tensorByteCountMismatch(String)
    case overlappingTensorRanges(previous: String, current: String)
    case gapBeforeTensor(String)
    case unreferencedPayloadBytes
    case metadataIsNotObject
    case metadataValueIsNotString(String)
    case tooManyMetadataEntries(limit: Int, actual: Int)
    case metadataKeyTooLarge(limit: Int, actual: Int)
    case metadataValueTooLarge(key: String, limit: Int, actual: Int)
    case metadataTooLarge(limit: Int, actualAtLeast: Int)
}

/// Strictly parses an immutable safetensors file without invoking MLX or another JSON parser.
package enum SafetensorsFileParser {
    package static func parse(_ data: Data) throws -> SafetensorsFile {
        guard data.count >= 8 else {
            throw SafetensorsFileError.fileTooShort
        }

        var headerLength: UInt64 = 0
        for index in 0 ..< 8 {
            headerLength |= UInt64(data[data.startIndex + index]) << UInt64(index * 8)
        }
        guard headerLength > 0 else {
            throw SafetensorsFileError.emptyHeader
        }
        guard headerLength <= UInt64(Int.max) else {
            throw SafetensorsFileError.headerLengthNotRepresentable
        }
        guard headerLength <= UInt64(SafetensorsFileLimits.maximumHeaderByteCount) else {
            throw SafetensorsFileError.headerTooLarge(
                limit: SafetensorsFileLimits.maximumHeaderByteCount,
                actual: headerLength
            )
        }
        let (headerEnd, headerEndOverflow) = 8.addingReportingOverflow(Int(headerLength))
        guard !headerEndOverflow, headerEnd <= data.count else {
            throw SafetensorsFileError.headerBeyondEndOfFile
        }
        let headerStartIndex = data.index(data.startIndex, offsetBy: 8)
        let headerEndIndex = data.index(headerStartIndex, offsetBy: Int(headerLength))
        let headerBytes = [UInt8](data[headerStartIndex ..< headerEndIndex])
        guard String(bytes: headerBytes, encoding: .utf8) != nil else {
            throw SafetensorsFileError.invalidHeaderUTF8
        }
        guard headerBytes.first == UInt8(ascii: "{") else {
            throw SafetensorsFileError.topLevelIsNotObject
        }

        var jsonParser = StrictSafetensorsJSONParser(bytes: headerBytes)
        let root = try jsonParser.parseRoot()
        guard case .object(let entries) = root else {
            throw SafetensorsFileError.topLevelIsNotObject
        }

        let payloadByteCount = data.count - headerEnd
        var metadata: [String: String] = [:]
        var tensors: [SafetensorsTensor] = []
        tensors.reserveCapacity(min(entries.count, SafetensorsFileLimits.maximumTensorCount))

        for (name, value) in entries {
            if name == "__metadata__" {
                metadata = try parseMetadata(value)
                continue
            }
            guard !name.isEmpty else {
                throw SafetensorsFileError.emptyTensorName
            }
            let nameByteCount = name.utf8.count
            guard nameByteCount <= SafetensorsFileLimits.maximumTensorNameByteCount else {
                throw SafetensorsFileError.tensorNameTooLarge(
                    limit: SafetensorsFileLimits.maximumTensorNameByteCount,
                    actual: nameByteCount
                )
            }
            guard tensors.count < SafetensorsFileLimits.maximumTensorCount else {
                throw SafetensorsFileError.tooManyTensors(
                    limit: SafetensorsFileLimits.maximumTensorCount,
                    actual: SafetensorsFileLimits.maximumTensorCount + 1
                )
            }
            tensors.append(try parseTensor(
                name: name,
                value: value,
                payloadStart: headerEnd,
                payloadByteCount: payloadByteCount,
                fileByteCount: data.count
            ))
        }

        guard !tensors.isEmpty else {
            throw SafetensorsFileError.emptyTensorSet
        }
        try validateCanonicalPayloadCoverage(tensors, payloadByteCount: payloadByteCount)
        return SafetensorsFile(
            metadata: metadata,
            tensors: tensors.sorted(by: tensorNameOrder),
            payloadByteCount: payloadByteCount
        )
    }

    private static func parseMetadata(_ value: StrictJSONValue) throws -> [String: String] {
        guard case .object(let entries) = value else {
            throw SafetensorsFileError.metadataIsNotObject
        }
        guard entries.count <= SafetensorsFileLimits.maximumMetadataEntryCount else {
            throw SafetensorsFileError.tooManyMetadataEntries(
                limit: SafetensorsFileLimits.maximumMetadataEntryCount,
                actual: entries.count
            )
        }

        var result: [String: String] = [:]
        var totalByteCount = 0
        for (key, value) in entries {
            let keyByteCount = key.utf8.count
            guard keyByteCount <= SafetensorsFileLimits.maximumMetadataKeyByteCount else {
                throw SafetensorsFileError.metadataKeyTooLarge(
                    limit: SafetensorsFileLimits.maximumMetadataKeyByteCount,
                    actual: keyByteCount
                )
            }
            guard case .string(let string) = value else {
                throw SafetensorsFileError.metadataValueIsNotString(key)
            }
            let valueByteCount = string.utf8.count
            guard valueByteCount <= SafetensorsFileLimits.maximumMetadataValueByteCount else {
                throw SafetensorsFileError.metadataValueTooLarge(
                    key: key,
                    limit: SafetensorsFileLimits.maximumMetadataValueByteCount,
                    actual: valueByteCount
                )
            }
            let (withKey, keyOverflow) = totalByteCount.addingReportingOverflow(keyByteCount)
            let (next, valueOverflow) = withKey.addingReportingOverflow(valueByteCount)
            guard !keyOverflow, !valueOverflow,
                  next <= SafetensorsFileLimits.maximumTotalMetadataByteCount
            else {
                throw SafetensorsFileError.metadataTooLarge(
                    limit: SafetensorsFileLimits.maximumTotalMetadataByteCount,
                    actualAtLeast: keyOverflow || valueOverflow ? Int.max : next
                )
            }
            totalByteCount = next
            result[key] = string
        }
        return result
    }

    private static func parseTensor(
        name: String,
        value: StrictJSONValue,
        payloadStart: Int,
        payloadByteCount: Int,
        fileByteCount: Int
    ) throws -> SafetensorsTensor {
        guard case .object(let entries) = value else {
            throw SafetensorsFileError.tensorRecordIsNotObject(name)
        }

        var fields: [String: StrictJSONValue] = [:]
        for (key, value) in entries {
            guard key == "dtype" || key == "shape" || key == "data_offsets" else {
                throw SafetensorsFileError.unknownTensorRecordKey(tensor: name, key: key)
            }
            fields[key] = value
        }
        for required in ["dtype", "shape", "data_offsets"] where fields[required] == nil {
            throw SafetensorsFileError.missingTensorRecordKey(tensor: name, key: required)
        }

        guard case .string(let dtypeName)? = fields["dtype"],
              let dtype = SafetensorsDType(rawValue: dtypeName)
        else {
            let value: String? = if case .string(let string)? = fields["dtype"] { string } else { nil }
            throw SafetensorsFileError.invalidDType(tensor: name, value: value)
        }

        guard case .array(let shapeValues)? = fields["shape"] else {
            throw SafetensorsFileError.invalidShape(tensor: name)
        }
        guard shapeValues.count <= SafetensorsFileLimits.maximumTensorRank else {
            throw SafetensorsFileError.tensorRankTooLarge(
                tensor: name,
                limit: SafetensorsFileLimits.maximumTensorRank,
                actual: shapeValues.count
            )
        }
        let shape = try shapeValues.map {
            try plainUnsignedInteger($0, tensor: name, field: "shape")
        }
        for dimension in shape where dimension > SafetensorsFileLimits.maximumTensorDimension {
            throw SafetensorsFileError.tensorDimensionTooLarge(
                tensor: name,
                limit: SafetensorsFileLimits.maximumTensorDimension,
                actual: dimension
            )
        }

        var elementCount: UInt64 = 1
        for dimension in shape {
            let (next, overflow) = elementCount.multipliedReportingOverflow(by: dimension)
            guard !overflow else {
                throw SafetensorsFileError.tensorByteCountOverflow(name)
            }
            elementCount = next
        }
        let (expectedByteCount, byteCountOverflow) = elementCount.multipliedReportingOverflow(
            by: dtype.byteWidth
        )
        guard !byteCountOverflow else {
            throw SafetensorsFileError.tensorByteCountOverflow(name)
        }

        guard case .array(let offsetValues)? = fields["data_offsets"], offsetValues.count == 2 else {
            throw SafetensorsFileError.invalidDataOffsets(name)
        }
        let start = try plainUnsignedInteger(offsetValues[0], tensor: name, field: "data_offsets")
        let end = try plainUnsignedInteger(offsetValues[1], tensor: name, field: "data_offsets")
        guard end >= start else {
            throw SafetensorsFileError.reversedDataOffsets(name)
        }
        guard end - start == expectedByteCount else {
            throw SafetensorsFileError.tensorByteCountMismatch(name)
        }
        guard end <= UInt64(payloadByteCount), start <= UInt64(Int.max), end <= UInt64(Int.max) else {
            throw SafetensorsFileError.dataOffsetsOutOfBounds(name)
        }

        let startInt = Int(start)
        let endInt = Int(end)
        let (absoluteStart, startOverflow) = payloadStart.addingReportingOverflow(startInt)
        let (absoluteEnd, endOverflow) = payloadStart.addingReportingOverflow(endInt)
        guard !startOverflow, !endOverflow,
              absoluteStart <= absoluteEnd,
              absoluteEnd <= fileByteCount
        else {
            throw SafetensorsFileError.dataOffsetsOutOfBounds(name)
        }
        return SafetensorsTensor(
            name: name,
            dtype: dtype,
            shape: shape,
            payloadByteRange: startInt ..< endInt
        )
    }

    private static func plainUnsignedInteger(
        _ value: StrictJSONValue,
        tensor: String,
        field: String
    ) throws -> UInt64 {
        guard case .number(let token) = value,
              !token.isEmpty,
              token.utf8.allSatisfy({ (48 ... 57).contains($0) }),
              let result = UInt64(token)
        else {
            throw SafetensorsFileError.invalidInteger(tensor: tensor, field: field)
        }
        return result
    }

    private static func validateCanonicalPayloadCoverage(
        _ tensors: [SafetensorsTensor],
        payloadByteCount: Int
    ) throws {
        let ordered = tensors.sorted {
            if $0.payloadByteRange.lowerBound != $1.payloadByteRange.lowerBound {
                return $0.payloadByteRange.lowerBound < $1.payloadByteRange.lowerBound
            }
            if $0.payloadByteRange.upperBound != $1.payloadByteRange.upperBound {
                return $0.payloadByteRange.upperBound < $1.payloadByteRange.upperBound
            }
            return tensorNameOrder($0, $1)
        }

        var expectedStart = 0
        var previousName: String?
        for tensor in ordered {
            if tensor.payloadByteRange.lowerBound < expectedStart {
                throw SafetensorsFileError.overlappingTensorRanges(
                    previous: previousName ?? tensor.name,
                    current: tensor.name
                )
            }
            if tensor.payloadByteRange.lowerBound > expectedStart {
                throw SafetensorsFileError.gapBeforeTensor(tensor.name)
            }
            expectedStart = tensor.payloadByteRange.upperBound
            previousName = tensor.name
        }
        guard expectedStart == payloadByteCount else {
            throw SafetensorsFileError.unreferencedPayloadBytes
        }
    }

    private static func tensorNameOrder(_ lhs: SafetensorsTensor, _ rhs: SafetensorsTensor) -> Bool {
        lhs.name.utf8.lexicographicallyPrecedes(rhs.name.utf8)
    }
}

private indirect enum StrictJSONValue {
    case object([(String, StrictJSONValue)])
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

private struct StrictSafetensorsJSONParser {
    let bytes: [UInt8]
    var index = 0
    var remainingValueCount = SafetensorsFileLimits.maximumJSONValueCount

    mutating func parseRoot() throws -> StrictJSONValue {
        let value = try parseValue(depth: 0)
        guard bytes[index...].allSatisfy({ $0 == UInt8(ascii: " ") }) else {
            throw SafetensorsFileError.invalidHeaderPadding
        }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> StrictJSONValue {
        guard remainingValueCount > 0 else {
            throw SafetensorsFileError.jsonValueBudgetExceeded(
                limit: SafetensorsFileLimits.maximumJSONValueCount
            )
        }
        remainingValueCount -= 1
        guard depth <= SafetensorsFileLimits.maximumJSONDepth else {
            throw SafetensorsFileError.jsonNestingTooDeep
        }
        skipJSONWhitespace()
        guard let byte = currentByte else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
        switch byte {
        case UInt8(ascii: "{"):
            return try parseObject(depth: depth)
        case UInt8(ascii: "["):
            return try parseArray(depth: depth)
        case UInt8(ascii: "\""):
            return .string(try parseString())
        case UInt8(ascii: "t"):
            try consumeLiteral("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try consumeLiteral("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try consumeLiteral("null")
            return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0") ... UInt8(ascii: "9"):
            return .number(try parseNumber())
        default:
            throw SafetensorsFileError.invalidHeaderJSON
        }
    }

    private mutating func parseObject(depth: Int) throws -> StrictJSONValue {
        try consume(UInt8(ascii: "{"))
        skipJSONWhitespace()
        if consumeIfPresent(UInt8(ascii: "}")) {
            return .object([])
        }

        var entries: [(String, StrictJSONValue)] = []
        var keys = Set<String>()
        while true {
            skipJSONWhitespace()
            guard currentByte == UInt8(ascii: "\"") else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw SafetensorsFileError.duplicateJSONKey(key)
            }
            skipJSONWhitespace()
            try consume(UInt8(ascii: ":"))
            let value = try parseValue(depth: depth + 1)
            entries.append((key, value))
            guard entries.count <= SafetensorsFileLimits.maximumJSONContainerElementCount else {
                throw SafetensorsFileError.jsonContainerTooLarge(
                    limit: SafetensorsFileLimits.maximumJSONContainerElementCount
                )
            }
            skipJSONWhitespace()
            if consumeIfPresent(UInt8(ascii: "}")) {
                return .object(entries)
            }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseArray(depth: Int) throws -> StrictJSONValue {
        try consume(UInt8(ascii: "["))
        skipJSONWhitespace()
        if consumeIfPresent(UInt8(ascii: "]")) {
            return .array([])
        }

        var values: [StrictJSONValue] = []
        while true {
            values.append(try parseValue(depth: depth + 1))
            guard values.count <= SafetensorsFileLimits.maximumJSONContainerElementCount else {
                throw SafetensorsFileError.jsonContainerTooLarge(
                    limit: SafetensorsFileLimits.maximumJSONContainerElementCount
                )
            }
            skipJSONWhitespace()
            if consumeIfPresent(UInt8(ascii: "]")) {
                return .array(values)
            }
            try consume(UInt8(ascii: ","))
        }
    }

    private mutating func parseString() throws -> String {
        try consume(UInt8(ascii: "\""))
        var decoded: [UInt8] = []
        while let byte = currentByte {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let string = String(bytes: decoded, encoding: .utf8) else {
                    throw SafetensorsFileError.invalidHeaderUTF8
                }
                return string
            case UInt8(ascii: "\\"):
                try appendEscape(to: &decoded)
            case 0x00 ... 0x1f:
                throw SafetensorsFileError.invalidHeaderJSON
            default:
                decoded.append(byte)
            }
            guard decoded.count <= SafetensorsFileLimits.maximumJSONStringByteCount else {
                throw SafetensorsFileError.jsonStringTooLarge(
                    limit: SafetensorsFileLimits.maximumJSONStringByteCount
                )
            }
        }
        throw SafetensorsFileError.invalidHeaderJSON
    }

    private mutating func appendEscape(to decoded: inout [UInt8]) throws {
        guard let escaped = currentByte else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
        index += 1
        switch escaped {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"):
            decoded.append(escaped)
        case UInt8(ascii: "b"):
            decoded.append(0x08)
        case UInt8(ascii: "f"):
            decoded.append(0x0c)
        case UInt8(ascii: "n"):
            decoded.append(0x0a)
        case UInt8(ascii: "r"):
            decoded.append(0x0d)
        case UInt8(ascii: "t"):
            decoded.append(0x09)
        case UInt8(ascii: "u"):
            let first = try parseHexCodeUnit()
            let scalarValue: UInt32
            if (0xd800 ... 0xdbff).contains(first) {
                guard consumeIfPresent(UInt8(ascii: "\\")), consumeIfPresent(UInt8(ascii: "u")) else {
                    throw SafetensorsFileError.invalidHeaderJSON
                }
                let second = try parseHexCodeUnit()
                guard (0xdc00 ... 0xdfff).contains(second) else {
                    throw SafetensorsFileError.invalidHeaderJSON
                }
                scalarValue = 0x10000
                    + (UInt32(first - 0xd800) << 10)
                    + UInt32(second - 0xdc00)
            } else {
                guard !(0xdc00 ... 0xdfff).contains(first) else {
                    throw SafetensorsFileError.invalidHeaderJSON
                }
                scalarValue = UInt32(first)
            }
            guard let scalar = UnicodeScalar(scalarValue) else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            decoded.append(contentsOf: String(scalar).utf8)
        default:
            throw SafetensorsFileError.invalidHeaderJSON
        }
    }

    private mutating func parseHexCodeUnit() throws -> UInt16 {
        var value: UInt16 = 0
        for _ in 0 ..< 4 {
            guard let byte = currentByte, let digit = hexDigit(byte) else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            index += 1
            value = value * 16 + UInt16(digit)
        }
        return value
    }

    private func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48 ... 57: byte - 48
        case 65 ... 70: byte - 55
        case 97 ... 102: byte - 87
        default: nil
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = index
        _ = consumeIfPresent(UInt8(ascii: "-"))
        guard let first = currentByte else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
        if first == UInt8(ascii: "0") {
            index += 1
            if let next = currentByte, (48 ... 57).contains(next) {
                throw SafetensorsFileError.invalidHeaderJSON
            }
        } else {
            guard (49 ... 57).contains(first) else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            consumeDigits()
        }
        if consumeIfPresent(UInt8(ascii: ".")) {
            guard let next = currentByte, (48 ... 57).contains(next) else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            consumeDigits()
        }
        if consumeIfPresent(UInt8(ascii: "e")) || consumeIfPresent(UInt8(ascii: "E")) {
            _ = consumeIfPresent(UInt8(ascii: "+")) || consumeIfPresent(UInt8(ascii: "-"))
            guard let next = currentByte, (48 ... 57).contains(next) else {
                throw SafetensorsFileError.invalidHeaderJSON
            }
            consumeDigits()
        }
        guard index - start <= SafetensorsFileLimits.maximumJSONNumberByteCount else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
        return String(decoding: bytes[start ..< index], as: UTF8.self)
    }

    private mutating func consumeDigits() {
        while let byte = currentByte, (48 ... 57).contains(byte) {
            index += 1
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let literalBytes = Array(String(describing: literal).utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index ..< index + literalBytes.count]) == literalBytes
        else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
        index += literalBytes.count
    }

    private mutating func consume(_ expected: UInt8) throws {
        guard consumeIfPresent(expected) else {
            throw SafetensorsFileError.invalidHeaderJSON
        }
    }

    private mutating func consumeIfPresent(_ expected: UInt8) -> Bool {
        guard currentByte == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipJSONWhitespace() {
        while let byte = currentByte, byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d {
            index += 1
        }
    }

    private var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
}

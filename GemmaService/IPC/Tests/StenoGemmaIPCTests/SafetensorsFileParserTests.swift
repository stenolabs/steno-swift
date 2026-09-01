import Foundation
import Testing
@testable import StenoGemmaModelStore

@Suite("Safetensors file parser")
struct SafetensorsFileParserTests {
    @Test("a tiny canonical shard returns exact tensor metadata and payload-relative range")
    func parsesTinyShard() throws {
        let data = makeFile(
            header: #"{"weight":{"dtype":"U8","shape":[3],"data_offsets":[0,3]}}"#,
            payload: Data([1, 2, 3])
        )

        let parsed = try SafetensorsFileParser.parse(data)

        #expect(parsed.metadata.isEmpty)
        #expect(parsed.payloadByteCount == 3)
        #expect(parsed.tensors == [
            SafetensorsTensor(
                name: "weight",
                dtype: .uint8,
                shape: [3],
                payloadByteRange: 0 ..< 3
            ),
        ])
    }

    @Test("metadata is an exact bounded string map")
    func parsesMetadata() throws {
        let data = makeFile(
            header: #"{"__metadata__":{"format":"mlx","escaped":"line\nvalue"},"z":{"dtype":"BOOL","shape":[],"data_offsets":[0,1]}}"#,
            payload: Data([1])
        )

        let parsed = try SafetensorsFileParser.parse(data)

        #expect(parsed.metadata == ["format": "mlx", "escaped": "line\nvalue"])
        #expect(parsed.tensors.first?.shape == [])
    }

    @Test("the dtype allowlist exactly matches the pinned MLX safetensors loader")
    func acceptsPinnedMLXDTypes() throws {
        let expected = Set([
            "F16", "BF16", "F32", "BOOL", "I8", "I16", "I32", "I64",
            "U8", "U16", "U32", "U64", "F8_E4M3", "C64",
        ])
        #expect(Set(SafetensorsDType.allCases.map(\.rawValue)) == expected)

        for dtype in SafetensorsDType.allCases {
            let width = Int(dtype.byteWidth)
            let data = makeFile(
                header: "{\"tensor\":{\"dtype\":\"\(dtype.rawValue)\",\"shape\":[],\"data_offsets\":[0,\(width)]}}",
                payload: Data(repeating: 0, count: width)
            )
            #expect(try SafetensorsFileParser.parse(data).tensors.first?.dtype == dtype)
        }
    }

    @Test("header length handling fails closed")
    func rejectsInvalidHeaderLengths() {
        #expect(throws: SafetensorsFileError.fileTooShort) {
            _ = try SafetensorsFileParser.parse(Data(repeating: 0, count: 7))
        }
        #expect(throws: SafetensorsFileError.emptyHeader) {
            _ = try SafetensorsFileParser.parse(encodedLength(0))
        }
        #expect(throws: SafetensorsFileError.headerLengthNotRepresentable) {
            _ = try SafetensorsFileParser.parse(encodedLength(UInt64.max))
        }

        let oversized = UInt64(SafetensorsFileLimits.maximumHeaderByteCount + 1)
        #expect(throws: SafetensorsFileError.headerTooLarge(
            limit: SafetensorsFileLimits.maximumHeaderByteCount,
            actual: oversized
        )) {
            _ = try SafetensorsFileParser.parse(encodedLength(oversized))
        }
        #expect(throws: SafetensorsFileError.headerBeyondEndOfFile) {
            _ = try SafetensorsFileParser.parse(encodedLength(8) + Data("{}".utf8))
        }
    }

    @Test("header UTF-8, root type, and padding are strict")
    func rejectsInvalidEncodingRootAndPadding() throws {
        let unpaddedHeader = Data(
            #"{"a":{"dtype":"U8","shape":[1],"data_offsets":[0,1]}}"#.utf8
        )
        let unpaddedFile = encodedLength(UInt64(unpaddedHeader.count)) + unpaddedHeader + Data([1])
        #expect(try SafetensorsFileParser.parse(unpaddedFile).payloadByteCount == 1)

        var invalidUTF8 = Data([UInt8(ascii: "{"), UInt8(ascii: "\""), 0xff])
        invalidUTF8.append(Data(repeating: UInt8(ascii: " "), count: 5))
        #expect(throws: SafetensorsFileError.invalidHeaderUTF8) {
            _ = try SafetensorsFileParser.parse(encodedLength(8) + invalidUTF8)
        }

        #expect(throws: SafetensorsFileError.topLevelIsNotObject) {
            _ = try SafetensorsFileParser.parse(makeFile(header: "[]"))
        }
        #expect(throws: SafetensorsFileError.topLevelIsNotObject) {
            _ = try SafetensorsFileParser.parse(makeFile(header: " {}"))
        }

        var paddedWithTab = Data(#"{"a":{"dtype":"U8","shape":[0],"data_offsets":[0,0]}}"#.utf8)
        let padding = paddingByteCount(for: paddedWithTab.count)
        paddedWithTab.append(Data(repeating: UInt8(ascii: " "), count: max(0, padding - 1)))
        paddedWithTab.append(UInt8(ascii: "\t"))
        #expect(throws: SafetensorsFileError.invalidHeaderPadding) {
            _ = try SafetensorsFileParser.parse(encodedLength(UInt64(paddedWithTab.count)) + paddedWithTab)
        }
    }

    @Test("duplicate decoded keys are rejected at every object level")
    func rejectsDuplicateKeys() {
        let duplicateTensor = makeFile(
            header: #"{"a":{"dtype":"U8","shape":[0],"data_offsets":[0,0]},"\u0061":{"dtype":"U8","shape":[0],"data_offsets":[0,0]}}"#
        )
        #expect(throws: SafetensorsFileError.duplicateJSONKey("a")) {
            _ = try SafetensorsFileParser.parse(duplicateTensor)
        }

        let duplicateField = makeFile(
            header: #"{"a":{"dtype":"U8","dtype":"I8","shape":[0],"data_offsets":[0,0]}}"#
        )
        #expect(throws: SafetensorsFileError.duplicateJSONKey("dtype")) {
            _ = try SafetensorsFileParser.parse(duplicateField)
        }

        let duplicateMetadata = makeFile(
            header: #"{"__metadata__":{"key":"one","\u006bey":"two"},"a":{"dtype":"U8","shape":[0],"data_offsets":[0,0]}}"#
        )
        #expect(throws: SafetensorsFileError.duplicateJSONKey("key")) {
            _ = try SafetensorsFileParser.parse(duplicateMetadata)
        }
    }

    @Test("tensor records permit only the exact schema and pinned dtypes")
    func rejectsInvalidTensorRecords() {
        #expect(throws: SafetensorsFileError.tensorRecordIsNotObject("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(header: #"{"a":true}"#))
        }
        #expect(throws: SafetensorsFileError.unknownTensorRecordKey(tensor: "a", key: "extra")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[0],"data_offsets":[0,0],"extra":0}}"#
            ))
        }
        #expect(throws: SafetensorsFileError.missingTensorRecordKey(tensor: "a", key: "shape")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","data_offsets":[0,0]}}"#
            ))
        }
        #expect(throws: SafetensorsFileError.invalidDType(tensor: "a", value: "F64")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"F64","shape":[0],"data_offsets":[0,0]}}"#
            ))
        }
    }

    @Test("shape and offset numbers must be nonnegative plain-decimal integers")
    func rejectsNonPlainIntegers() {
        for token in ["-1", "1.0", "1e0", "1E+0"] {
            #expect(throws: SafetensorsFileError.invalidInteger(tensor: "a", field: "shape")) {
                _ = try SafetensorsFileParser.parse(makeFile(
                    header: "{\"a\":{\"dtype\":\"U8\",\"shape\":[\(token)],\"data_offsets\":[0,0]}}"
                ))
            }
            #expect(throws: SafetensorsFileError.invalidInteger(tensor: "a", field: "data_offsets")) {
                _ = try SafetensorsFileParser.parse(makeFile(
                    header: "{\"a\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,\(token)]}}"
                ))
            }
        }

        let beyondUInt64 = "18446744073709551616"
        #expect(throws: SafetensorsFileError.invalidInteger(tensor: "a", field: "shape")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"a\":{\"dtype\":\"U8\",\"shape\":[\(beyondUInt64)],\"data_offsets\":[0,0]}}"
            ))
        }
    }

    @Test("rank, element product, and dtype byte multiplication are overflow-safe")
    func rejectsRankAndByteCountOverflow() {
        let excessiveRank = Array(repeating: "1", count: SafetensorsFileLimits.maximumTensorRank + 1)
            .joined(separator: ",")
        #expect(throws: SafetensorsFileError.tensorRankTooLarge(
            tensor: "a",
            limit: SafetensorsFileLimits.maximumTensorRank,
            actual: SafetensorsFileLimits.maximumTensorRank + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"a\":{\"dtype\":\"U8\",\"shape\":[\(excessiveRank)],\"data_offsets\":[0,0]}}"
            ))
        }

        #expect(throws: SafetensorsFileError.tensorByteCountOverflow("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[2147483647,2147483647,2147483647],"data_offsets":[0,0]}}"#
            ))
        }
        #expect(throws: SafetensorsFileError.tensorByteCountOverflow("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"C64","shape":[2147483647,2147483647],"data_offsets":[0,0]}}"#
            ))
        }
    }

    @Test("every shape dimension fits MLX ShapeElem before product evaluation")
    func enforcesMLXShapeDimensionLimit() throws {
        let firstOversized = #"{"a":{"dtype":"U8","shape":[0,2147483648],"data_offsets":[0,0]}}"#
        let firstOversizedError = SafetensorsFileError.tensorDimensionTooLarge(
            tensor: "a",
            limit: UInt64(Int32.max),
            actual: UInt64(Int32.max) + 1
        )
        #expect(throws: firstOversizedError) {
            _ = try SafetensorsFileParser.parse(makeFile(header: firstOversized))
        }

        let leadingOversized = #"{"a":{"dtype":"U8","shape":[2147483648,0],"data_offsets":[0,0]}}"#
        #expect(throws: firstOversizedError) {
            _ = try SafetensorsFileParser.parse(makeFile(header: leadingOversized))
        }

        let boundary = #"{"a":{"dtype":"U8","shape":[2147483647,0],"data_offsets":[0,0]}}"#
        let parsed = try SafetensorsFileParser.parse(makeFile(header: boundary))
        #expect(parsed.tensors.first?.shape == [UInt64(Int32.max), 0])
    }

    @Test("a global value budget bounds generic JSON AST amplification")
    func enforcesGlobalJSONValueBudget() {
        let nestedContainers = Array(repeating: "[]", count: 400).joined(separator: ",")
        let entries = (0 ..< 1_000).map { index in
            "\"t\(index)\":[\(nestedContainers)]"
        }.joined(separator: ",")
        let header = "{\(entries)}"

        #expect(header.utf8.count < SafetensorsFileLimits.maximumHeaderByteCount)
        #expect(throws: SafetensorsFileError.jsonValueBudgetExceeded(
            limit: SafetensorsFileLimits.maximumJSONValueCount
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(header: header))
        }
    }

    @Test("offset ordering, bounds, and tensor byte counts are exact")
    func rejectsInvalidOffsets() {
        #expect(throws: SafetensorsFileError.reversedDataOffsets("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[1],"data_offsets":[2,1]}}"#,
                payload: Data(repeating: 0, count: 2)
            ))
        }
        #expect(throws: SafetensorsFileError.dataOffsetsOutOfBounds("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[4],"data_offsets":[0,4]}}"#,
                payload: Data(repeating: 0, count: 3)
            ))
        }
        #expect(throws: SafetensorsFileError.tensorByteCountMismatch("a")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U16","shape":[2],"data_offsets":[0,3]}}"#,
                payload: Data(repeating: 0, count: 3)
            ))
        }
    }

    @Test("canonical shard payload ranges are nonoverlapping and gapless with no trailer")
    func rejectsOverlapGapsAndTrailers() {
        #expect(throws: SafetensorsFileError.overlappingTensorRanges(previous: "a", current: "b")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[2],"data_offsets":[0,2]},"b":{"dtype":"U8","shape":[2],"data_offsets":[1,3]}}"#,
                payload: Data(repeating: 0, count: 3)
            ))
        }
        #expect(throws: SafetensorsFileError.gapBeforeTensor("b")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[1],"data_offsets":[0,1]},"b":{"dtype":"U8","shape":[1],"data_offsets":[2,3]}}"#,
                payload: Data(repeating: 0, count: 3)
            ))
        }
        #expect(throws: SafetensorsFileError.unreferencedPayloadBytes) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"a":{"dtype":"U8","shape":[2],"data_offsets":[0,2]}}"#,
                payload: Data(repeating: 0, count: 3)
            ))
        }
    }

    @Test("tensor and metadata limits fail closed")
    func enforcesSemanticLimits() {
        let longName = String(repeating: "n", count: SafetensorsFileLimits.maximumTensorNameByteCount + 1)
        #expect(throws: SafetensorsFileError.tensorNameTooLarge(
            limit: SafetensorsFileLimits.maximumTensorNameByteCount,
            actual: SafetensorsFileLimits.maximumTensorNameByteCount + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"\(longName)\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}}"
            ))
        }

        let tensors = (0 ... SafetensorsFileLimits.maximumTensorCount).map { index in
            "\"t\(index)\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}"
        }.joined(separator: ",")
        #expect(throws: SafetensorsFileError.tooManyTensors(
            limit: SafetensorsFileLimits.maximumTensorCount,
            actual: SafetensorsFileLimits.maximumTensorCount + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(header: "{\(tensors)}"))
        }

        let metadataEntries = (0 ... SafetensorsFileLimits.maximumMetadataEntryCount).map {
            "\"key\($0)\":\"value\""
        }.joined(separator: ",")
        #expect(throws: SafetensorsFileError.tooManyMetadataEntries(
            limit: SafetensorsFileLimits.maximumMetadataEntryCount,
            actual: SafetensorsFileLimits.maximumMetadataEntryCount + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"__metadata__\":{\(metadataEntries)},\"a\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}}"
            ))
        }

        let longKey = String(repeating: "k", count: SafetensorsFileLimits.maximumMetadataKeyByteCount + 1)
        #expect(throws: SafetensorsFileError.metadataKeyTooLarge(
            limit: SafetensorsFileLimits.maximumMetadataKeyByteCount,
            actual: SafetensorsFileLimits.maximumMetadataKeyByteCount + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"__metadata__\":{\"\(longKey)\":\"v\"},\"a\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}}"
            ))
        }

        let longValue = String(
            repeating: "v",
            count: SafetensorsFileLimits.maximumMetadataValueByteCount + 1
        )
        #expect(throws: SafetensorsFileError.metadataValueTooLarge(
            key: "key",
            limit: SafetensorsFileLimits.maximumMetadataValueByteCount,
            actual: SafetensorsFileLimits.maximumMetadataValueByteCount + 1
        )) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"__metadata__\":{\"key\":\"\(longValue)\"},\"a\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}}"
            ))
        }

        let largeMetadata = (0 ..< SafetensorsFileLimits.maximumMetadataEntryCount).map {
            "\"key\($0)\":\"\(String(repeating: "v", count: 1_100))\""
        }.joined(separator: ",")
        do {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: "{\"__metadata__\":{\(largeMetadata)},\"a\":{\"dtype\":\"U8\",\"shape\":[0],\"data_offsets\":[0,0]}}"
            ))
            Issue.record("Expected the total metadata byte limit to reject the header")
        } catch let error as SafetensorsFileError {
            guard case .metadataTooLarge(let limit, let actualAtLeast) = error else {
                Issue.record("Unexpected metadata error: \(error)")
                return
            }
            #expect(limit == SafetensorsFileLimits.maximumTotalMetadataByteCount)
            #expect(actualAtLeast > limit)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(throws: SafetensorsFileError.metadataValueIsNotString("key")) {
            _ = try SafetensorsFileParser.parse(makeFile(
                header: #"{"__metadata__":{"key":1},"a":{"dtype":"U8","shape":[0],"data_offsets":[0,0]}}"#
            ))
        }
    }
}

private func makeFile(header: String, payload: Data = Data()) -> Data {
    var headerData = Data(header.utf8)
    headerData.append(
        Data(repeating: UInt8(ascii: " "), count: paddingByteCount(for: headerData.count))
    )
    return encodedLength(UInt64(headerData.count)) + headerData + payload
}

private func paddingByteCount(for byteCount: Int) -> Int {
    (8 - byteCount % 8) % 8
}

private func encodedLength(_ value: UInt64) -> Data {
    var littleEndian = value.littleEndian
    return withUnsafeBytes(of: &littleEndian) { Data($0) }
}

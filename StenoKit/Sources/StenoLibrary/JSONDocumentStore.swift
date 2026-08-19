import Foundation

enum JSONDocumentStore {
    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(value), to: url)
    }

    static func read<Value: Decodable>(
        _ type: Value.Type,
        from url: URL,
        currentSchemaVersion: Int,
        schemaVersion: (Value) -> Int
    ) throws -> Value {
        let data = try Data(contentsOf: url)
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw try corruptDocument(at: url)
        }

        guard envelope.schemaVersion == currentSchemaVersion else {
            throw LibraryError.unsupportedSchemaVersion(
                document: url,
                found: envelope.schemaVersion,
                supported: currentSchemaVersion
            )
        }

        let value: Value
        do {
            value = try JSONDecoder().decode(type, from: data)
        } catch {
            throw try corruptDocument(at: url)
        }
        guard schemaVersion(value) == envelope.schemaVersion else {
            throw try corruptDocument(at: url)
        }
        return value
    }

    static func migrateAndRead<Legacy: Decodable, Current: Codable>(
        current: Current.Type,
        legacy: Legacy.Type,
        from url: URL,
        legacySchemaVersion: Int,
        currentSchemaVersion: Int,
        currentSchema: (Current) -> Int,
        migrate: (Legacy) throws -> Current
    ) throws -> Current {
        let data = try Data(contentsOf: url)
        let envelope: SchemaEnvelope
        do {
            envelope = try JSONDecoder().decode(SchemaEnvelope.self, from: data)
        } catch {
            throw try corruptDocument(at: url)
        }

        switch envelope.schemaVersion {
        case currentSchemaVersion:
            let value: Current
            do {
                value = try JSONDecoder().decode(current, from: data)
            } catch {
                throw try corruptDocument(at: url)
            }
            guard currentSchema(value) == currentSchemaVersion else {
                throw try corruptDocument(at: url)
            }
            return value

        case legacySchemaVersion:
            let value: Current
            do {
                let legacyValue = try JSONDecoder().decode(legacy, from: data)
                value = try migrate(legacyValue)
            } catch {
                throw try corruptDocument(at: url)
            }
            guard currentSchema(value) == currentSchemaVersion else {
                throw try corruptDocument(at: url)
            }
            try write(value, to: url)
            return value

        default:
            throw LibraryError.unsupportedSchemaVersion(
                document: url,
                found: envelope.schemaVersion,
                supported: currentSchemaVersion
            )
        }
    }

    private static func corruptDocument(at url: URL) throws -> LibraryError {
        LibraryError.corruptDocument(
            original: url,
            quarantined: try quarantine(url)
        )
    }

    private static func quarantine(_ url: URL) throws -> URL {
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        var candidate = url.appendingPathExtension("corrupt-\(timestamp)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.appendingPathExtension("corrupt-\(timestamp)-\(suffix)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: url, to: candidate)
        return candidate
    }
}

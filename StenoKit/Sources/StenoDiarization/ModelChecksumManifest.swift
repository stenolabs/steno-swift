import CryptoKit
import Foundation
import StenoDomain

/// Prueft heruntergeladene Modelldateien gegen eingecheckte Pruefsummen.
///
/// FluidAudio prueft nichts: der Download laeuft gegen den beweglichen
/// Branch (`resolve/main`), und die eingebaute Verifikation prueft nur, ob
/// die Datei existiert. Ohne diese Stelle koennte ein spaeterer Lauf andere
/// Bytes holen als die, denen zugestimmt wurde.
///
/// Grenze: Das sichert Reproduzierbarkeit, nicht Echtheit. Es friert die
/// Bytes ein, die bei der Erzeugung des Manifests vorlagen.
public struct ModelChecksumManifest: Sendable, Equatable, Codable {
    /// Relativer Pfad zur Kleinbuchstaben-SHA-256 in Hex.
    public let entries: [String: String]

    public init(entries: [String: String]) {
        self.entries = entries
    }

    public func verify(directory: URL) throws {
        for (relativePath, expected) in entries.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw DiarizationError.modelInstallationFailed(
                    "Model file is missing after download: \(relativePath)"
                )
            }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == expected else {
                // Eigener Typ, nicht `modelInstallationFailed`: die
                // Oberflaeche muss diesen Fall von einem Netzfehler
                // unterscheiden koennen, siehe `ModelIntegrityError`.
                throw ModelIntegrityError.bytesDoNotMatch(
                    file: relativePath,
                    expected: expected,
                    actual: actual
                )
            }
        }
    }

    /// Alle Eintraege, deren Datei zwar vorhanden ist, aber andere Bytes
    /// traegt. Fehlende Dateien stehen nicht darin: die sind kein Fall fuer
    /// die Reparatur, sie laedt der naechste Downloadlauf ohnehin.
    ///
    /// `verify` wirft beim ersten Treffer und taugt deshalb nicht, um zu
    /// entscheiden, was geloescht werden muss - bei mehreren verfaelschten
    /// Dateien braeuchte der Nutzer sonst einen Klick je Datei.
    public func mismatchingFiles(directory: URL) -> [String] {
        entries.sorted { $0.key < $1.key }.compactMap { relativePath, expected in
            let url = directory.appendingPathComponent(relativePath)
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return actual == expected ? nil : relativePath
        }
    }

    public static func bundled(name: String = "model-checksums") throws -> ModelChecksumManifest {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw DiarizationError.modelInstallationFailed("Checksum manifest is missing from the bundle")
        }
        return try JSONDecoder().decode(ModelChecksumManifest.self, from: Data(contentsOf: url))
    }
}

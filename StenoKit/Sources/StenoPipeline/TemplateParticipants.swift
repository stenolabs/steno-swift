import Foundation
import StenoDomain
import StenoIdentity

/// Baut die verbindliche Teilnehmerliste für datenbasierte Vorlagensektionen
/// aus der (unaufgelösten) Revision und dem Review-Stand.
///
/// Regeln aus dem Realtest-Feedback:
/// - Sortiert nach Beitragsmenge (Wortzahl), absteigend.
/// - Bestätigte Personen erscheinen mit Namen; mehrere Cluster derselben
///   Person werden zusammengezählt.
/// - Unbestätigte Cluster erscheinen als generisches Label ("Speaker N",
///   nummeriert nach erstem Auftreten wie im Transkript).
/// - Als generisch oder mehrdeutig markierte Cluster (Hot-Mic, mehrere
///   Personen) und reine Kanal-Labels ("Andere", Spurnamen) sind keine
///   benennbaren Teilnehmer und bleiben draußen.
package enum TemplateParticipants {
    /// `additional` sind vom Benutzer ergänzte Anwesende ohne Redebeitrag.
    /// Sie stehen hinter den sprechenden Teilnehmern, weil die Reihenfolge
    /// den Redeanteil abbildet und sie keinen haben.
    package static func list(
        revision: TranscriptRevision,
        review: MeetingReviewData,
        additional: [String] = []
    ) -> [String] {
        var names = speakingNames(revision: revision, review: review)
        for name in additional where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private static func speakingNames(
        revision: TranscriptRevision,
        review: MeetingReviewData
    ) -> [String] {
        struct Entry {
            let name: String
            var wordCount: Int
            let firstAppearance: Int
        }
        var entries: [String: Entry] = [:]
        var placeholderNumbers: [String: Int] = [:]

        for (index, turn) in revision.turns.enumerated() {
            guard let reference = turn.speaker else { continue }
            guard let name = participantName(
                for: reference,
                review: review,
                placeholderNumbers: &placeholderNumbers
            ) else { continue }

            let words = turn.segments.reduce(into: 0) { count, segment in
                count += segment.text
                    .split(whereSeparator: { $0.isWhitespace })
                    .count
            }
            if var entry = entries[name] {
                entry.wordCount += words
                entries[name] = entry
            } else {
                entries[name] = Entry(
                    name: name,
                    wordCount: words,
                    firstAppearance: index
                )
            }
        }

        return entries.values
            .sorted {
                if $0.wordCount != $1.wordCount {
                    return $0.wordCount > $1.wordCount
                }
                return $0.firstAppearance < $1.firstAppearance
            }
            .map(\.name)
    }

    /// Name mit Firma, wo eine hinterlegt ist. In einem Protokoll ist die
    /// Zugehoerigkeit ueblich, und sie hilft dem Modell, den Firmennamen
    /// korrekt zu schreiben, auch wenn das Transkript ihn verstuemmelt hat.
    /// Die E-Mail-Adresse bleibt draussen - sie ist reines Ordnungsmerkmal.
    package static func label(for person: Person) -> String {
        guard let organization = person.organization else { return person.displayName }
        return "\(person.displayName) (\(organization))"
    }

    private static func participantName(
        for reference: SpeakerReference,
        review: MeetingReviewData,
        placeholderNumbers: inout [String: Int]
    ) -> String? {
        if let person = review.confirmedPerson(for: reference) {
            return Self.label(for: person)
        }
        switch reference {
        case .person:
            // Person ohne auffindbaren Namen: als Teilnehmer nicht benennbar.
            return nil
        case .channel:
            return nil
        case .importedTextLabel(let imported):
            guard imported.wasConfirmedAtSource,
                  !imported.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                let key = "imported/\(imported.id.uuidString)"
                if let number = placeholderNumbers[key] {
                    return "Speaker \(number)"
                }
                let number = placeholderNumbers.count + 1
                placeholderNumbers[key] = number
                return "Speaker \(number)"
            }
            return imported.text
        case .cluster(let runID, let clusterID):
            guard runID == review.runID else { return nil }
            let resolvedCluster = review.resolvedCluster(for: reference)
            let key = resolvedCluster.map {
                "\(SpeakerClusterKey.normalizedChannel($0.channel))\u{0}\(SpeakerClusterKey(clusterID: $0.clusterID).clusterID)"
            } ?? {
                let clusterKey = SpeakerClusterKey(clusterID: clusterID)
                return "\(clusterKey.channel ?? "")\u{0}\(clusterKey.clusterID)"
            }()
            let state = resolvedCluster?.reviewState
            guard resolvedCluster?.containsMultipleSpeakers != true,
                  state != .multiple
            else {
                return nil
            }
            switch state {
            case .generic, .multiple:
                return nil
            case .confirmed, .unreviewed, .stale, nil:
                // .stale (frühere Bestätigung, nicht mehr sicher) bewusst
                // als Platzhalter: keine unbestätigte Identität als Fakt.
                // Nummerierung nach erstem Auftreten, konsistent mit den
                // generischen Labels im Transkriptteil der Prompts.
                if let number = placeholderNumbers[key] {
                    return "Speaker \(number)"
                }
                let number = placeholderNumbers.count + 1
                placeholderNumbers[key] = number
                return "Speaker \(number)"
            }
        }
    }
}

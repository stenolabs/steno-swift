# Gemeinsame Sprecherpraesentation

Stand: 2026-08-11.
Verfasser: Codex, nach dem Auftrag, alle offenen Punkte in einem Zug umzusetzen.

## Ziel

macOS und iOS leiten Sprechername und Farbrolle aus derselben getesteten Kernlogik ab.
Ein Kanal darf nie unter dem Namen eines gleich benannten Clusters aus einem anderen Kanal erscheinen.
Unbestaetigte Sprecher bleiben generisch, Vermutungen bleiben als Vermutung markiert und mehrdeutige Cluster bekommen keinen Personennamen.

## Beobachtete Ursache

`SpeakerDisplay` liegt fast identisch in beiden App-Targets.
Die macOS-Fassung verwirft im Fallback ohne Review-Daten den Kanal und macht aus `mic/SPEAKER_0` und `system/SPEAKER_0` jeweils `Speaker 1`.
Die iOS-Fassung rekonstruiert den Kanal bereits aus dem bekannten Praefix.

Mehrere Review-Lookups reduzieren den fachlichen Clusterschluessel derzeit auf `clusterID`.
Der Identitaetskern behandelt dagegen Kanal und Cluster-ID gemeinsam als Schluessel.
Bei gleicher nackter Cluster-ID auf Mikrofon- und Systemspur darf die Darstellung deshalb nicht den ersten beliebigen Treffer verwenden.

## Architektur

`StenoPipeline` erhaelt einen SwiftUI-freien Resolver.
Er liefert einen `SpeakerPresentation`-Wert mit sichtbarem Namen und einer semantischen Markerrolle.
Die Markerrolle ist entweder eine bestaetigte `PersonID`, der Rang eines unbestaetigten Clusters oder nicht vorhanden.

Die beiden Apps bilden nur noch diese Markerrolle mit ihrem vorhandenen Theme auf `Color` ab.
Damit bleiben Farben App-Darstellung, waehrend Identitaets- und Wahrheitsschutzregeln genau einmal im gemeinsamen Kern liegen.

Der Resolver verwendet fuer Clustertreffer immer Kanal und Cluster-ID, sobald der Kanal aus Review-Daten oder einem bekannten namespaceten Cluster-Identifier hervorgeht.
Ist eine nackte Cluster-ID ueber mehrere Kanaele mehrdeutig, bleibt die Ausgabe generisch und bekommt weder Namen noch Vermutung noch Personenfarbe.
Das ist ein absichtliches Fail-closed-Verhalten: Steno zeigt weniger Komfort, statt eine falsche Person als Tatsache darzustellen.

## Schnittstelle

`SpeakerPresentation` enthaelt:

- `label: String?`
- `marker: SpeakerMarker?`
- `channel: String?`

`SpeakerMarker` enthaelt die Faelle:

- `person(PersonID)`
- `unconfirmedRank(Int)`

`SpeakerPresentationResolver.presentation(for:review:)` loest eine `SpeakerReference?` auf.
Eine zweite gleichnamige Variante fuer `IdentityCluster` wird in der Review-Oberflaeche verwendet, weil dort der Kanal sicher bekannt ist.
Gemeinsame Hilfen loesen Merge-Resolutions und Vorschlaege anhand des kanalspezifischen Schluessels auf.

## Kompatibilitaet

Es gibt keine Bibliotheksmigration und keinen Schema-Bump.
Bekannte Legacy-IDs mit `mic/` oder `system/` werden besser dargestellt als bisher.
Die persistierte Form von `SpeakerReference.cluster` wird in diesem Paket nicht veraendert.
Eine spaetere explizite Kanalerweiterung dieses Codable-Typs bleibt ein eigenes Migrationspaket.

## Tests

Kern-Tests decken mindestens ab:

- `mic/SPEAKER_0` und `system/SPEAKER_0` ohne Review-Daten ergeben verschiedene Labels.
- bestaetigte, veraltete, mehrdeutige, generische und vorgeschlagene Sprecher behalten ihre Wahrheitsschutzregeln.
- ein Review eines anderen Runs wird nicht verwendet.
- gleiche nackte Cluster-IDs in mehreren Kanaelen werden nicht willkuerlich aufgeloest.
- der Rang unbestaetigter Cluster ist stabil und ignoriert Selbst- sowie Mehrpersonencluster.
- Kanalnamen laufen ueber `ChannelLabel` und veraendern keine gespeicherten Werte.

Beide Apps werden danach gebaut.
Die vorhandenen Transkript- und Review-Ansichten muessen den gemeinsamen Resolver tatsaechlich verwenden, damit die Tests keine ungenutzte Parallellogik pruefen.

## Abnahmekriterien

- Die beiden lokalen `SpeakerDisplay`-Kopien sind entfernt.
- macOS zeigt gleich nummerierte Mikrofon- und Systemcluster unterscheidbar.
- Kein Lookup bestaetigt einen kanalmehrdeutigen Cluster anhand der nackten ID.
- iOS und macOS zeigen dieselben Namen und dieselbe semantische Markerrolle.
- Der Kern importiert fuer diese Logik kein SwiftUI.

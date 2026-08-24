# Manueller AirDrop-Austausch einzelner Meetings

**Datum:** 16. August 2026

**Status:** Nach fehlgeschlagenem Dateipaket-Gate korrigierter V1-Entwurf zur Nutzerprüfung.

## Ausgangslage

Steno speichert Meetings auf macOS und iPadOS heute in getrennten lokalen Bibliotheken.
Eine Cloud-Synchronisierung ist ohne Ende-zu-Ende-Verschlüsselung aus Datenschutzgründen nicht zulässig.
Trotzdem soll ein einzelnes Meeting bewusst zwischen den eigenen Geräten übertragen werden können.

Der wichtigste erste Ablauf ist eine auf dem iPad sauber beendete Aufnahme, die mit Audio an den Mac übertragen und dort nach ausdrücklicher lokaler Bestätigung weiterverarbeitet wird.
Daneben soll dasselbe Format bereits verarbeitete Textinhalte ohne Audio oder Text und Audio gemeinsam übertragen können.

Der vorhandene Markdown-Export ist für Menschen lesbar, besitzt aber weder ein strukturiertes Importformat noch stabile Ursprungs- und Konfliktregeln.
Der vorhandene `LegacyImporter` und `PreparedMeetingImport` liefern brauchbare Bausteine für einen atomaren Import, sind jedoch an das Altformat und an genau eine vorhandene Transkriptrevision gebunden.
Ein vollständiges Kopieren eines Meetingverzeichnisses ist nicht zulässig, weil darin lokale Jobs, Runs, Identitätsbezüge und biometrische Review-Daten liegen können.

Der reale Gate-0-Test am 16. August 2026 hat außerdem die ursprüngliche Containerannahme widerlegt.
Ein als `com.apple.package` registriertes Verzeichnis `Probe.stenomeeting` kam nach dem AirDrop-Hin- und Rückweg nicht als Dokumenteinheit zurück.
Im Mac-Ordner `Downloads` lag ausschließlich das bytegleiche innere `manifest.json`.
V1 verwendet deshalb kein System-Dateipaket, sondern eine einzelne reguläre Archivdatei.

## Verbindliche Produktgrenzen

- V1 verwendet keine iCloud, keinen Cloudspeicher, keinen Server und keine Hintergrundsynchronisierung.
- Die iPadOS-Steno-Bibliothek wird bis zur Umsetzung einer geeigneten Verschlüsselung ausdrücklich von iCloud-Gerätebackups ausgeschlossen.
- Jedes Meeting wird einzeln und bewusst freigegeben.
- Steno sendet nie automatisch und startet keinen Transfer im Hintergrund.
- Der Nutzer öffnet die Systemfreigabe und wählt dort AirDrop selbst aus.
- Ein allgemeines System-Share-Sheet kann technisch nicht garantieren, dass ausschließlich AirDrop gewählt wird.
- Steno selbst bietet in V1 keinen anderen Transport an und erklärt vor der Freigabe, dass AirDrop auszuwählen ist.
- Das Paket ist nicht verschlüsselt und nicht digital signiert.
- AirDrop schützt den Transport durch das Betriebssystem, nicht jedoch die Klartextdatei am Sender oder Empfänger.
- Die lokale Steno-Bibliothek bleibt ebenfalls unverschlüsselt.

Die fehlende iCloud-Sicherung erzeugt bewusst ein Gegenrisiko.
Bei Verlust oder Defekt des iPads kann eine nur dort vorhandene Aufnahme verloren gehen.
Die Oberfläche muss diesen lokalen Charakter ehrlich benennen, bis eine verschlüsselte Sicherung verfügbar ist.

## Ziele

- Eine versionierte reguläre `.stenomeeting`-Archivdatei überträgt genau ein Meeting.
- Das Paket unterstützt Text ohne Audio, eine sauber beendete Aufnahme mit Audio ohne Transkript sowie Text und Audio gemeinsam.
- Audio ist bei jedem Export standardmäßig ausgeschaltet.
- Notizen, Zeitmarker, ein portables Transkript und bestätigte Sprechernamen können als Text übertragen werden.
- Der Empfänger prüft das gesamte Paket als nicht vertrauenswürdige Eingabe, bevor eine Bibliothek verändert wird.
- Der Empfang zeigt eine Vorschau und benötigt eine ausdrückliche Importbestätigung.
- Ein Audioimport auf dem Mac wird zunächst als bereites Meeting angelegt und erst nach einer zweiten, lokalen Verarbeitungsentscheidung in die Pipeline eingereiht.
- Import und erste Verarbeitungsanforderung bleiben über Abstürze hinweg eindeutig und wiederaufnehmbar.
- Ein importiertes Meeting ist sichtbar als importiert markiert und seine Notizen sind sofort editierbar.
- Ein erneuter identischer Import ist ein sichtbarer No-op.
- Ein abweichender Import desselben Ursprungs ist ein Konflikt ohne Mutation.

## Nicht-Ziele

- V1 implementiert keine Cloud-Synchronisierung und keine Cloudverschlüsselung.
- V1 synchronisiert weder im Hintergrund noch mehrere Meetings als Sammlung.
- V1 führt keine bidirektionalen Text-Merges, Konfliktkopien oder Aktualisierungsreihen ein.
- V1 überträgt keine Personenbibliothek, Teilnehmerliste oder Ordnerstruktur.
- V1 überträgt keine Reports, Jobs, Runs oder Review-Zustände.
- V1 authentisiert nicht kryptografisch, von welchem Gerät oder Benutzer ein Paket stammt.
- V1 komprimiert, normalisiert oder transkodiert keine Audiooriginale.
- V1 löscht keine empfangene Datei außerhalb des eigenen App-Containers.
- V1 erweitert die Diarisierungsfachlogik nicht.

## Gemeinsame Architektur

Die Fachlogik liegt in gemeinsamen StenoKit-Targets.
macOS und iPadOS behalten nur Dokumentöffnung, Systemfreigabe, Darstellung, Gerätezugriff und plattformspezifische Modellzustimmung.

```mermaid
flowchart LR
    UI1["iPadOS oder macOS\nVorschau und Freigabe"] --> Exchange["StenoExchange\nSchema, Allowlist, Hashes und Validierung"]
    Exchange --> Package[".stenomeeting\nreguläre AppleArchive-Datei"]
    Package --> ImportUI["Empfangende App\nVorschau und Zustimmung"]
    ImportUI --> Library["StenoLibrary\nStaging, Deduplizierung und atomarer Commit"]
    Library --> Ready["Importiertes Meeting\nbereit"]
    Ready --> Confirm["Lokale Sprach- und\nVerarbeitungsbestätigung"]
    Confirm --> Pipeline["StenoPipeline\ngepinnter, eindeutiger Job"]
```

### Verantwortlichkeiten

`StenoExchange` erhält das Transfermanifest, die portablen DTOs, den kanonischen Inhaltsdigest, die Export-Allowlist und den vollständigen AppleArchive-Parser für nicht vertrauenswürdige Transferdateien.

`StenoLibrary` erhält den Importbeleg, den lokalen Transferzustand, die optionale Transkriptrevision, die sichere Neuregistrierung von Medien und den atomaren Staging-Commit.

`StenoPipeline` erhält eine pro Job gepinnte Transkriptionssprache, die eindeutige erste Verarbeitungsanforderung und den Abgleich liegengebliebener Anforderungen.

Die macOS- und iPadOS-Apps registrieren den Dokumenttyp, zeigen Vorschau und Warnungen, öffnen die Systemfreigabe beziehungsweise den Dokumentimport und rufen ausschließlich gemeinsame Anwendungsfälle auf.
Keine App rekonstruiert Paket-, Deduplizierungs-, Medien- oder Jobregeln in ihrer Oberfläche.

## Dokumenttyp und Transportcontainer

`.stenomeeting` ist ein eigener, versionierter Dokumenttyp mit der registrierten `UTType` `org.steno.meeting-transfer`.
Die `UTType` konformiert zu `public.archive`, nicht zu `com.apple.package`.
Die sichtbare `.stenomeeting`-Einheit ist auf dem Dateisystem immer genau eine reguläre Datei und niemals ein Verzeichnis oder File-Wrapper-Paket.

Der Dateiinhalt ist ein unkomprimierter AppleArchive-Strom aus dem öffentlichen Apple-Framework `AppleArchive`.
Die Entscheidung für `AppleArchive` nutzt eine vorhandene native Implementierung auf beiden Zielplattformen und führt weder eine ZIP-Abhängigkeit noch einen selbst geschriebenen ZIP-Entpacker ein.
V1 verwendet bewusst keine Kompression, weil Audio bereits komprimiert sein kann, der erwartete Größengewinn gering ist und ein zusätzlicher Dekompressionsstrom die Angriffs- und Fehlerfläche vergrößern würde.

Der Import verwendet niemals `ArchiveStream.extractStream` und entpackt das Archiv nicht blind in ein Zielverzeichnis.
`StenoExchange` öffnet die äußere Datei genau einmal mit `O_RDONLY`, `O_NOFOLLOW` und `O_CLOEXEC`, prüft denselben Deskriptor mit `fstat` und kopiert und hasht ihn in einem Durchlauf in eine eigene exklusive Snapshotdatei.
Nur dieser unveränderliche Snapshot wird anschließend gelesen, in der Vorschau gehalten und beim bestätigten Import erneut geprüft.
`StenoExchange` liest dessen AppleArchive-Strom Eintrag für Eintrag, prüft jeden Header vor dem Lesen seiner Daten und schreibt ausschließlich bekannte reguläre Einträge unter selbst erzeugten kanonischen Namen in ein eigenes temporäres Stagingverzeichnis.
Einträge vom Typ Verzeichnis, Symlink, Hardlink, Gerät, FIFO, Socket oder Metadaten sowie unbekannte Headerfelder werden abgelehnt.
Archivpfade werden nie direkt an eine Dateisystem-Extraktionsfunktion übergeben.

Das korrigierte Architektur-Gate erzeugt zunächst mit dem macOS-Systemwerkzeug `aa` eine unkomprimierte Diagnose-Archivdatei und prüft auf echtem iPad und Mac, dass AirDrop genau diese eine reguläre Datei in beide Richtungen erhält.
Nach Registrierung des neuen Archiv-UTType und Installation beider Builds wird derselbe Hin- und Rückweg innerhalb von Gate 0 erneut geprüft, damit alte UTI-Auflösung oder Cachezustände den Nachweis nicht verfälschen.
Erst nach diesem Nachweis werden Produktreader und -writer implementiert.
Die endgültige Abnahme wiederholt denselben Transport mit einem von `StenoExchange` erzeugten Archiv.

Das logische Paket enthält ausschließlich manifestierte reguläre Nutzdateien.
AppleArchive-Reihenfolge und Archivmetadaten besitzen keine fachliche Bedeutung.

```text
Meeting.stenomeeting              reguläre AppleArchive-Datei
  manifest.json
  meeting.json
  notes.md                        optional
  transcript.json                 optional
  audio/track-1.caf               optional
  audio/track-1.json              optional
```

Mehrere Audiospuren verwenden fortlaufende paketlokale Namen.
Ihre ursprünglichen Dateinamen und lokalen `MediaAssetID`-Werte werden nicht übernommen.

## Manifest und Versionierung

Das Manifest enthält mindestens:

- `formatMajor` und `formatMinor`.
- Die ursprüngliche `sourceMeetingID`.
- Eine optionale `sourceRevisionID` für den exportierten Transkript-Snapshot.
- Den Erstellzeitpunkt des Pakets und die erzeugende App-Version.
- Die aktivierten Fähigkeiten `notes`, `transcript` und `audio`.
- Die Quellsprache und deren Herkunft `explicit`, `estimated` oder `absent`, sofern bekannt.
- Für jede Nutzdatei den relativen Pfad, die Bytegröße, den Medientyp und den SHA-256-Wert.
- Den kanonischen `contentDigest` des übertragenen fachlichen Inhalts.

`manifest.json` führt sich niemals selbst in `entries` auf und enthält weder einen eigenen Datei-Hash noch seinen eigenen Hash im `contentDigest`.
`entries` beschreibt ausschließlich alle anderen Archiveinträge.
Das Limit von 32 Dateien zählt sämtliche Archiveinträge einschließlich des genau einen Manifests.
Die 24-GiB-Gesamtgrenze zählt die tatsächlichen `DAT`-Bytes sämtlicher Archiveinträge einschließlich Manifest.

Eine unbekannte Hauptversion wird abgelehnt.
Eine neuere Nebenversion darf nur gelesen werden, wenn alle verwendeten Fähigkeiten bekannt sind und keine unbekannte Nutzdatei vorhanden ist.
Unbekannte Dateien werden auch bei einer bekannten Nebenversion abgelehnt.

Der `contentDigest` wird aus den sortierten stabilen Nutzpfaden, Bytegrößen und SHA-256-Werten gebildet.
Exportzeitpunkt, App-Version, Gerätename, Dateireihenfolge und Dateisystemmetadaten gehen nicht in diesen Digest ein.
Dadurch erzeugt derselbe fachliche Inhalt unabhängig vom Exportzeitpunkt denselben Vergleichswert.
Die optionale Quell-Revisionskennung dient nur der Diagnose und geht ebenfalls nicht in Deduplizierung oder Konfliktentscheidung ein.

SHA-256 dient nur der Integritätsprüfung und Inhaltsgleichheit.
Der Digest beweist weder Urheberschaft noch Vertrauenswürdigkeit.

## Zulässige Nutzdatenzustände

Ein Paket besitzt keinen frei gesetzbaren Profilnamen, sondern bekannte Fähigkeiten mit folgenden Invarianten:

### Text

- Mindestens Notizen oder ein Transkript sind enthalten.
- Audio ist nicht enthalten.
- Das Meeting kann bereits verarbeitet sein.

### Aufnahme

- Mindestens eine vollständig finalisierte Audiospur ist enthalten.
- Ein Transkript ist nicht erforderlich.
- Notizen und Marker dürfen bereits vorhanden sein.
- Die Quellaufnahme muss sauber beendet und als unveränderliches Medienasset registriert sein.
- Der lokale Laufzeitstatus darf während der Nachverarbeitung `processing` oder danach `ready` sein; im portablen Meetingdokument wird eine enthaltene Aufnahme kanonisch als `ready` beschrieben.

### Text und Aufnahme

- Mindestens eine vollständig finalisierte Audiospur ist enthalten.
- Notizen und ein portables Transkript dürfen gemeinsam enthalten sein.
- Die Quellaufnahme muss sauber beendet und als unveränderliches Medienasset registriert sein.
- Der lokale Laufzeitstatus darf während der Nachverarbeitung `processing` oder danach `ready` sein; im portablen Meetingdokument wird eine enthaltene Aufnahme kanonisch als `ready` beschrieben.

Ein Paket ohne Notizen, Transkript und Audio ist ungültig.
Meetings im Zustand `recording`, unterbrochene Capture-Verzeichnisse, Recovery-Fragmente und noch nicht registrierte Mediendateien sind nicht exportierbar.
Jobs und Runs werden unabhängig vom Zustand nie exportiert.

## Strikte Datenschutz-Allowlist

Der Export wird aus freigegebenen Transfer-DTOs aufgebaut und niemals durch Kopieren des Meetingverzeichnisses.
Zulässig sind ausschließlich:

- Technische Transfer- und Basis-Metadaten wie Ursprungskennung, Titel und Meetingdatum.
- Die sichtbare Notiz bytegetreu als UTF-8-Markdown.
- Ein portabler Transkript-Snapshot mit Text, Wort- und Segmentzeiten.
- Generische Sprecherbezeichnungen und bestätigte sichtbare Sprechernamen als reine Textlabels.
- Bewusst ausgewählte finalisierte Audiooriginale mit paketlokalen Metadaten.

Explizit ausgeschlossen sind:

- `identity/persons.json` und jede andere Personenbibliothek.
- E-Mail-Adressen, Firmenfelder und globale Personendaten.
- Stimm-Embeddings und sonstige biometrische Merkmale.
- `review.json`, Bestätigungsbelege, Hard-Negatives und Suggestions.
- Diarisierungsartefakte und Diarisierungs-, Identitäts- oder sonstige Processing-Runs.
- Jobs und Recovery-Zustände.
- Reports und gerenderte Protokolle.
- Teilnehmerkennungen und zusätzliche Teilnehmer.
- `folderID`, globale Ordner und Sortierzustände.
- Capture-Reste, temporäre Dateien und Modelle.

Automatisierte Sentinel-Tests legen jede ausgeschlossene Datenklasse mit eindeutig erkennbarem Inhalt an und weisen nach, dass sie weder im Standardpaket noch im Audiopaket vorkommt.

## Notizen und Marker

Die sichtbare Notiz wird als UTF-8-Markdown übertragen.
Zeitmarker wie `[00:12:34]` bleiben dadurch bytegetreu erhalten und benötigen kein paralleles Markermodell.

Nach dem Import wird die Datei über den bestehenden `MeetingNotesStore` als lokale `notes/user-notes.md` angelegt.
Sie ist sofort editierbar.
Die lokale Bearbeitung verändert weder den gespeicherten Importbeleg noch den Digest des ursprünglich empfangenen Pakets.

Der sichtbare Herkunftshinweis liegt in Meeting-Metadaten und nicht im Notiztext.
Steno fügt deshalb keinen unveränderlichen Vorspann in die editierbare Notiz ein.

## Portables Transkript und Sprecherlabels

Das Paket übernimmt keine rohe `TranscriptRevision`.
Eine rohe Revision kann auf nicht übertragene Elternrevisionen, Runs, Cluster oder Personen verweisen.

`StenoExchange` definiert stattdessen einen eigenständigen Snapshot mit:

- Der Quellsprache und ihrer Herkunft.
- Geordneten Turns beziehungsweise Segmenten.
- Worttexten und Wortzeiten.
- Paketlokalen Sprecherkennungen.
- Einer sichtbaren Sprecherbezeichnung je Sprecherkennung.
- Der Labelart `generic` oder `confirmedDisplayName`.

Ein bestätigter Name wird nur als angezeigter String übertragen.
Personenkennung, Stimmprobe, Bestätigungsbeleg und Embedding bleiben ausgeschlossen.
Ein unbestätigter Namensvorschlag wird nicht übertragen, sondern bleibt eine generische Sprecherbezeichnung.

Beim Import entsteht eine neue lokale Snapshot-Revision ohne Quell-Run- oder Personenbezüge.
Importierte Namen erhalten die Herkunft `importedTextLabel` und gelten nicht als lokal bestätigte Identität.
Sie dürfen nicht automatisch mit der lokalen Personenbibliothek verknüpft werden.
Paketlokale Sprecherkennungen werden neu abgebildet und dürfen nicht mit vorhandenen Kanal-, Cluster- oder Personenkennungen kollidieren.

Wird ein Paket mit Audio und Transkript später auf dem Mac neu transkribiert, bleibt der importierte Snapshot als ältere unveränderliche Revision erhalten.
Der lokale finale ASR-Lauf erzeugt eine neue aktuelle Revision.
Importierte Textlabels werden dabei nicht als biometrische oder lokal bestätigte Evidenz in die neue Verarbeitung übernommen.

## Audioauswahl und Warnung

Audio ist in jedem neuen Freigabevorgang ausgeschaltet.
Die Auswahl wird weder global noch pro Meeting für den nächsten Transfer gespeichert.

Vor dem Einschalten zeigt die Exportvorschau:

- Die Zahl der übertragbaren Spuren.
- Die konkrete Größe jeder Spur.
- Die konkrete Gesamtgröße des zusätzlichen Audios.
- Den Hinweis, dass die unverschlüsselte Rohaufnahme das Gerät verlässt.
- Den Hinweis, dass Mikrofonspuren Nebenstimmen und Gespräche im Raum enthalten können.
- Den Hinweis, dass das Paket beim Empfänger als Klartextdatei bestehen bleiben kann.

Nur unveränderliche, registrierte Originalspuren eines sauber beendeten Meetings sind auswählbar.
Capture-Dateien und teilweise geschriebene Dateien bleiben ausgeschlossen.
Die Originale werden beim Export nicht transkodiert oder verändert.

## Sichere Medienübernahme

Der Import vertraut weder Quell-Dateinamen noch Quell-Assetkennungen, Quell-Provenienz, Dateiendungen, Samplerate oder Dauer.
Für jede Audiodatei werden Manifestgröße und SHA-256 geprüft, anschließend wird der Inhalt als unterstütztes Audio geöffnet.
Eine Spur mit beschädigtem Container, nicht unterstütztem Codec oder null lesbaren Samples wird abgelehnt.
Samplerate, Kanalzahl und Dauer werden aus dem validierten Inhalt neu abgeleitet.

`StenoLibrary` erzeugt neue lokale `MediaAssetID`-Werte und sichere lokale Dateinamen.
Die semantische Art einer iPad-Aufnahme bleibt `micTrack`, damit die Mac-Pipeline den vorgesehenen Mikrofonpfad verwendet.
Die lokale Medienprovenienz wird aus Ursprungs-Meeting, paketlokaler logischer Spur und Byte-Hash abgeleitet und nicht aus einer ungeprüften Zeichenkette des Pakets übernommen.
Gleiche Audiodateien in unterschiedlichen Ursprungsmeetings kollidieren dadurch nicht versehentlich.

Vor Snapshot und Staging prüft die gemeinsame Importstrecke den freien Speicher für äußere Snapshotdatei, validierte Nutzdaten und Sicherheitsreserve.
Weil die validierten Nutzdaten auf demselben Volume in das Meeting-Staging übernommen werden, plant sie keine dritte vollständige Audiokopie ein.
Ein Fehler verändert weder eine vorhandene Aufnahme noch ein vorhandenes Meeting.

## Importbeleg und sichtbare Herkunft

`MeetingMetadata` erhält einen eigenen optionalen Transferbeleg und verwendet dafür nicht `legacyProvenanceKey`.
Damit löst ein AirDrop-Import keine Legacy-Upgrade-Oberfläche aus.

Der persistierte Beleg enthält mindestens:

```swift
public struct MeetingTransferReceipt: Codable, Equatable, Sendable {
    public let sourceMeetingID: MeetingID
    public let sourceRevisionID: RevisionID?
    public let sourcePackageContentDigest: String
    public let importedAt: Date
    public let sourceAppVersion: String?
    public let includedCapabilities: Set<MeetingTransferCapability>
    public let sourceLocaleIdentifier: String?
    public let sourceLocaleOrigin: MeetingTransferLocaleOrigin
}
```

Das importierte Meeting erhält den Status `ready`, leere Teilnehmerfelder und keine Ordnerzuordnung.
Es behält die gültige ursprüngliche `sourceMeetingID` als lokale Meetingkennung.
Da V1 bei jeder abweichenden vorhandenen Fassung fail-closed abbricht, ist dafür keine automatische Kennungsumschreibung notwendig.
Die Detailansicht zeigt mindestens `Über AirDrop importiert`, den Importzeitpunkt, enthaltenes Audio und den aktuellen Verarbeitungszustand.
Importierte Sprechertextlabels werden als solche erklärt, wenn sie angezeigt oder bearbeitet werden.

## Deduplizierung und Konflikte

Der fachliche Ursprung ist in V1 die unveränderte `sourceMeetingID`.
Vor jedem Commit prüft die Bibliothek alle vorhandenen Meetings und Importbelege.

- Gleicher Ursprung und gleicher kanonischer Paketinhalt ergibt einen sichtbaren No-op ohne Mutation.
- Gleicher Ursprung und abweichender kanonischer Paketinhalt ergibt einen Konflikt ohne Mutation.
- Ein vorhandenes lokales Meeting mit derselben Kennung, aber ohne passenden Importbeleg, wird konservativ als Konflikt behandelt, sofern sein aktuell berechneter Transferdigest nicht exakt übereinstimmt.
- Ein übereinstimmendes natives Ursprungsmeeting mit identischem Transferdigest ergibt ebenfalls einen No-op.
- Medienprovenienz ist ein zusätzlicher Kollisionsschutz, aber nie der primäre Deduplizierungsschlüssel.

Beim No-op zeigt die App, dass dieses Meeting bereits vorhanden ist, und kann das vorhandene Meeting öffnen.
Beim Konflikt überschreibt, merged oder dupliziert V1 nichts.
Die App erklärt, dass eine andere Fassung desselben Ursprungs vorhanden ist.

Bei einem bereits importierten Meeting wird gegen den unveränderlichen Digest im Importbeleg verglichen.
Spätere lokale Notizänderungen machen einen erneuten Import desselben Pakets deshalb nicht irrtümlich zum Konflikt.
Ein späteres Paket desselben Ursprungs mit anderem Text oder einer anderen Audioauswahl bleibt dagegen bewusst ein Konflikt.

## Validierung als nicht vertrauenswürdige Eingabe

Der Import liest die Datei ausschließlich über einen sicherheitsbeschränkten Dokumentzugriff und validiert sie vollständig vor der Nutzerbestätigung und vor jeder Bibliotheksmutation.
Bei großen Audiodateien zeigt die App während Hash- und Inhaltsprüfung einen abbrechbaren Fortschritt, ohne bereits ein Meeting anzulegen.

Vor dem Öffnen des Archivstroms öffnet der Reader die externe Datei einmal mit `O_RDONLY|O_NOFOLLOW|O_CLOEXEC`, verlangt per `fstat` genau eine reguläre Datei und prüft eine harte äußere Dateigröße.
Die maximale `.stenomeeting`-Dateigröße ist die maximale Datengröße von 24 GiB zuzüglich 2 MiB festem Spielraum für höchstens 32 Raw-AppleArchive-Header.
Der Reader verwendet den unkomprimierten AppleArchive-Decode-Strom und hält zu keinem Zeitpunkt eine komplette Audio- oder Transferdatei im Speicher.
Während des einmaligen Lesens des geöffneten externen Deskriptors erzeugt der Reader mit `O_CREAT|O_EXCL|O_NOFOLLOW` und Modus `0600` eine private Snapshotdatei und berechnet über exakt dieselben kopierten Bytes den SHA-256-`transportDigest`.
Die Snapshotdatei liegt in einem nur für den Nutzer zugänglichen, vom Meetingbestand getrennten Steno-Validierungsverzeichnis mit Modus `0700` auf demselben Volume wie das spätere Bibliotheks-Staging.
Vorschau und Import lesen nur diesen Snapshot und öffnen die externe URL nicht erneut.
Unmittelbar vor dem Commit validiert der Import den unveränderten Snapshot erneut und verlangt denselben `transportDigest`.
Der fachliche `contentDigest` bleibt davon getrennt und dient weiterhin Deduplizierung und Konfliktentscheidung.

Die gemeinsame Validierung erzwingt:

- Genau ein Manifest und ausschließlich erlaubte relative Nutzpfade.
- Keine absoluten Pfade und keine Komponenten `.` oder `..`.
- Keine Symlinks, Hardlinks, Geräte, Sockets oder anderen Spezialdateien.
- Keine Archiv-Verzeichnis- oder Metadateneinträge und keine unbekannten AppleArchive-Headerfelder.
- Genau je ein Feld `TYP`, `PAT`, `SIZ` und `DAT` pro Eintrag mit den AppleArchive-Feldtypen `.uint`, `.string`, `.uint` und `.blob`.
- Zusätzlich muss `header.entryType == .regularFile` gelten; `PAT` muss eine gültige Zeichenkette, `SIZ` eine darstellbare Ganzzahl und `DAT` ein Blob mit Offset null und exakt derselben Größe wie `SIZ` sein.
- Doppelte Felder, Integerüberläufe, abgeschnittene Daten und Bytes hinter dem letzten vollständigen Archiveintrag werden abgelehnt.
- Keine kollidierenden Pfade nach Unicode-Normalisierung oder Groß-Kleinschreibung.
- Harte Grenzen für Dateizahl, Verzeichnistiefe, Einzeldateigröße und Gesamtgröße.
- Zusätzliche Grenzen für Notizlänge, Turns, Segmente und Wörter.
- Übereinstimmung von tatsächlicher Bytegröße, SHA-256 und Manifest.
- Eine bekannte Hauptversion und ausschließlich bekannte Fähigkeiten.
- Konsistente Referenzen innerhalb des Meeting- und Transkript-Snapshots.
- Inhaltliche Audioprüfung zusätzlich zur Dateiendung und zum MIME-Wert.
- Ablehnung jeder nicht manifestierten oder mehrfach referenzierten Datei.

Die V1-Obergrenzen sind 32 Archiveinträge einschließlich Manifest, zwei Unterverzeichnisebenen, 16 GiB pro Audiodatei und 24 GiB für sämtliche `DAT`-Bytes zusammen.
Notizen sind auf 16 MiB, der Transkript-Snapshot auf 64 MiB, Sprecher auf 10.000, Turns auf 200.000 und Wörter auf 2.000.000 begrenzt.
`manifest.json` und `meeting.json` sind jeweils auf 1 MiB und jede `track-N.json` auf 64 KiB begrenzt.
Titel und einzelne Sprecherlabels sind nach UTF-8-Kodierung jeweils auf 1.024 Byte begrenzt.
Diese Werte liegen als zentrale gemeinsame Konstanten mit Grenzwerttests vor und dürfen nicht getrennt in beiden Apps definiert werden.
Eine spätere Änderung ist eine Schema- und Sicherheitsentscheidung mit eigener Review, nicht nur eine UI-Anpassung.

Die Exportseite unterliegt denselben Limits.
Steno darf kein Paket erzeugen, das der eigene aktuelle Import ablehnen würde.
Der Writer erzeugt ausschließlich Header mit Typ, kanonischem Pfad, Bytegröße und Datenstrom und übernimmt keine Eigentümer, Rechte, Zeitstempel, erweiterten Attribute oder Links aus lokalen Quelldateien.
Eine gemeinsame StenoExchange-Hilfsfunktion erzeugt und öffnet jeden privaten Validation- oder Export-Root mit `mkdir` Modus `0700`, `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` und anschließender `fstat`-Prüfung von Typ, Eigentümer und effektiven Rechten.
Ein vorhandener Symlink, eine fremde Eigentümerkennung oder Gruppen- beziehungsweise Weltrechte führen fail-closed zum Abbruch.
Der Writer schreibt zuerst eine eindeutig benannte reguläre Stagingdatei innerhalb eines so geprüften Roots mit `O_CREAT|O_EXCL|O_NOFOLLOW` und Modus `0600`, synchronisiert und validiert sie mit demselben Reader und benennt sie erst danach ohne Ersetzen eines vorhandenen Ziels atomar auf `.stenomeeting` um.
Nach der Umbenennung synchronisiert er das Elternverzeichnis.

Vor dem Erzeugen des Snapshots prüft Steno am privaten Validation-Root freien Speicher für die gesamte äußere Datei und einen festen Sicherheitsabstand.
Nach dem Lesen des Manifests und vor dem Staging der Nutzdaten prüft Steno zusätzlichen freien Speicher für alle deklarierten `DAT`-Bytes und den bestehenden Sicherheitsabstand.
Der feste V1-Sicherheitsabstand beträgt in beiden Prüfungen 2.000.000.000 Byte.
Snapshot und validierte Nutzdaten bleiben während der Vorschau in derselben privaten Sitzung erhalten.
Beim Import übernimmt `StenoLibrary` die bereits validierten Dateien durch Moves auf demselben Volume in sein nicht sichtbares Meeting-Staging, damit keine dritte vollständige Audiokopie nötig wird.
Abbruch, Fehler, No-op, Konflikt und geschlossene Vorschau entfernen ausschließlich die eigene private Validierungssitzung.

## Atomarer Import

Nach erfolgreicher Validierung erzeugt `StenoLibrary` das komplette lokale Meeting in einem Stagingverzeichnis innerhalb des endgültigen Meetings-Dateisystems.
Dadurch kann der Abschluss als atomare Umbenennung erfolgen.

Im Staging werden:

- Die geprüfte Ursprungs-Meetingkennung übernommen und lokale Medienkennungen erzeugt.
- Basis-Metadaten und Importbeleg geschrieben.
- Notizen geschrieben.
- Optionale Audiodateien kopiert und erneut geprüft.
- Eine optionale lokale Snapshot-Revision geschrieben und als aktuell markiert.
- Der lokale Transfer- und Verarbeitungszustand geschrieben.
- Alle notwendigen Dateien synchronisiert.

`PreparedMeetingImport` wird so erweitert, dass eine Transkriptrevision optional ist.
Ein reines Aufnahmepaket besitzt nach dem Commit keine aktuelle Transkriptrevision.
Bestehende Altimporte behalten ihr heutiges Verhalten mit genau einer Revision.

Erst die atomare Umbenennung macht das Meeting sichtbar.
Ein Absturz vor der Umbenennung hinterlässt kein sichtbares Teilmeeting.
Ein späterer Recovery-Lauf darf ausschließlich eindeutig als Steno-Staging erkannte Reste entfernen oder erneut prüfen und niemals fremde Dateien raten.

## Empfangs- und Importablauf

Die empfangende App zeigt nach erfolgreicher Vorvalidierung:

- Titel und Meetingdatum.
- Ursprungskennung in einer für Menschen gekürzten technischen Detailansicht.
- Enthaltene Notiz, Marker und Transkriptzusammenfassung.
- Enthaltene sichtbare Sprechernamen mit Hinweis auf personenbezogenen Text.
- Audioanzahl, Einzelgrößen, Gesamtgröße und Rohaufnahme-Warnung.
- Quellsprache und deren Herkunft.
- Lokalen Modellstatus, sofern eine Verarbeitung angeboten wird.
- Das Ergebnis der Deduplizierungsprüfung.

Ohne ausdrücklichen Klick auf `Importieren` wird nichts in die Bibliothek geschrieben.
Bei Audio bietet der Mac `Nur importieren` und `Importieren und verarbeiten` an.
Beide Entscheidungen sind lokale Bestätigungen und werden nicht aus dem Paket übernommen.

`Nur importieren` legt das Meeting atomar als bereit an und erzeugt keinen Job.
`Importieren und verarbeiten` verlangt vor dem Commit zusätzlich die Sprachentscheidung und persistiert eine eindeutige Verarbeitungsanforderung.
Die tatsächliche Jobübergabe beginnt erst nach dem erfolgreichen Meeting-Commit.

## Sprache und Modellzustand

Das Paket kann eine Sprache samt Herkunft enthalten.
Eine auf dem iPad ausdrücklich gewählte Sprache wird auf dem Mac vorausgewählt, aber die Verarbeitung benötigt weiterhin die lokale Bestätigung.
Eine geschätzte, abgeleitete oder fehlende Sprache muss auf dem Mac ausdrücklich bestätigt beziehungsweise gewählt werden.
Die System-Locale wird niemals als stiller Ersatz verwendet.

Der finale ASR-Job speichert den bestätigten `localeIdentifier` dauerhaft.
Die Pipeline verwendet diesen Wert für den gesamten Job und dessen Wiederaufnahme.
Eine spätere Änderung der globalen Mac-Einstellung verändert einen bereits angelegten Job nicht.
Der zugehörige Processing-Run zeichnet die effektiv verwendete Sprache ebenfalls auf.
Alte Jobs ohne Sprachfeld dürfen aus Kompatibilitätsgründen weiterhin die bisher konfigurierte Laufzeitsprache verwenden.

Ein fehlendes oder nicht unterstütztes Modell verhindert weder Import noch Sicherung des Audios.
Es startet auch keinen automatischen Download.
Das Meeting bleibt sichtbar und bereit, der Transferzustand zeigt `Modell für <Sprache> fehlt`, und die Oberfläche bietet Modellinstallation und einen anschließenden bewussten Retry an.
Ist das Modell bereits in der Importvorschau nicht verfügbar, legt `Importieren und verarbeiten` keinen aussichtslosen Job an.
Die App importiert nach ausdrücklicher Bestätigung stattdessen sicher mit `awaitingModel`, merkt sich die bestätigte Sprache und bietet danach Installation und manuelles Verarbeiten an.
Verschwindet ein zuvor verfügbares Modell erst nach dem Einreihen, endet der gepinnte Job sichtbar als fehlgeschlagen und wartet ebenfalls auf einen manuellen Retry.

Ein fehlendes Diarisierungsmodell darf ein bereits erzeugtes Transkript und das Audio ebenfalls nicht gefährden.
Ein fehlgeschlagener oder abgebrochener Job wird nicht automatisch erneut eingereiht.
Jeder Retry ist eine sichtbare Nutzeraktion und behält die gewählte Sprache bei, sofern der Nutzer sie nicht vorher ausdrücklich ändert.

## Persistierter Verarbeitungszustand

Der Transferzustand liegt getrennt vom groben Meetingstatus, weil ein `ready`-Meeting gleichzeitig auf eine Sprache, ein Modell oder einen Retry warten kann.
Er wird als eigene versionierte Datei im Meetingverzeichnis gespeichert und atomar ersetzt.
Der Importbeleg in `MeetingMetadata` bleibt unveränderliche Herkunft, während diese Zustandsdatei den lokalen Ablauf fortschreibt.

```swift
public enum ImportedMeetingProcessingState: Codable, Equatable, Sendable {
    case importedOnly
    case awaitingLanguageConfirmation
    case awaitingModel(localeIdentifier: String)
    case processingRequested(ImportedProcessingRequest)
    case jobEnqueued(jobID: JobID, localeIdentifier: String)
    case needsManualRetry(jobID: JobID, localeIdentifier: String, reason: String)
}
```

Fehlertexte aus externen Dateien werden nicht ungeprüft in `reason` übernommen.
Die App bildet lokale, klassifizierte Fehler auf verständliche Meldungen ab.

Eine `ImportedProcessingRequest` enthält eine lokale Request-Kennung, eine vorab erzeugte feste `JobID`, die Meetingkennung, die Jobart `finalASR`, die gepinnte Sprache und den Erstellzeitpunkt.
Sie wird bei `Importieren und verarbeiten` im selben Staging-Commit wie das Meeting persistiert.

## Genau-einmal und Crashsicherheit

Genau-einmal bezeichnet in V1 genau eine dauerhafte logische erste Verarbeitungsanforderung und genau eine zugehörige Jobkennung.
Ein Prozessabsturz kann eine interne Provider-Ausführung wiederholen, weshalb alle Pipeline-Artefakte weiterhin idempotent über stabile Job- und Run-Kennungen geschrieben werden müssen.
V1 verspricht nicht, dass ein externer Framework-Aufruf physisch nur einmal beginnt.

Nach dem atomaren Meeting-Commit gleicht ein gemeinsamer Reconciler die persistierte Anforderung mit dem globalen `JobStore` ab:

- Existiert die vorab festgelegte `JobID` nicht, wird genau dieser Job mit der gepinnten Sprache eingereiht.
- Existiert dieselbe `JobID` mit passender Meetingkennung, Jobart und Sprache, wird kein zweiter Job angelegt.
- Existiert dieselbe `JobID` mit abweichenden Daten, stoppt der Reconciler mit einem sichtbaren Integritätsfehler.
- Nach erfolgreichem Einreihen oder bestätigtem Vorhandensein wird der Meetingzustand auf `jobEnqueued` geschrieben.
- Ein fehlgeschlagener, abgebrochener oder abgeschlossener Job wird vom Reconciler nicht als neue Anforderung interpretiert.

Damit gelten folgende Absturzfälle:

- Vor dem atomaren Rename existiert kein sichtbares Meeting und kein Job.
- Nach dem Rename, aber vor dem Enqueue findet der Startabgleich die persistierte Anforderung und legt den festen Job an.
- Nach dem Enqueue, aber vor dem Zustandsupdate findet der Abgleich denselben Job und legt keinen zweiten an.
- Nach einem Jobfehler bleibt Meeting samt Audio erhalten und wartet auf einen manuellen Retry.

Gleichzeitige Importversuche und Startabgleiche werden durch die Actors von Bibliothek und JobStore serialisiert.
Der Deduplizierungscheck wird unmittelbar im Commitpfad unter derselben Bibliotheksserialisierung wiederholt, damit zwei parallele Vorschauen nicht zwei Meetings erzeugen.

## Weiterverarbeitung auf dem Mac

Ein Audio enthaltendes Paket führt niemals allein durch seinen Inhalt zur Verarbeitung.
Erst `Importieren und verarbeiten` oder eine spätere Aktion im importierten Meeting erzeugt eine lokale Anforderung.

Der finale ASR-Lauf verwendet die importierten, neu registrierten Originalspuren und die gepinnte Sprache.
Er erzeugt seine üblichen lokalen Runs und unveränderlichen Revisionen.
Eine anschließende bestehende Diarisierungs- und Vorschlagskette darf lokal laufen, überträgt ihre Ergebnisse aber nicht rückwirkend in das Quellpaket.
Reports werden weder importiert noch automatisch erzeugt.

Die Detailansicht zeigt die Zustände `bereit`, `Sprache bestätigen`, `Modell fehlt`, `in Verarbeitung`, `Verarbeitung fehlgeschlagen` und `erneut versuchen` ausdrücklich.
Keiner dieser Zustände versteckt oder löscht das importierte Audio.

## Klartextdateien und Aufräumgrenzen

Eine Exportdatei wird in einem Steno-eigenen temporären Verzeichnis erzeugt, vom Backup ausgeschlossen und nach Abschluss oder Abbruch der Systemfreigabe entfernt, sobald das Betriebssystem sie nicht mehr verwendet.
Nur diese eindeutig von Steno erzeugte temporäre Datei samt ihrem eigenen Elternverzeichnis darf automatisch entfernt werden.

Eine per AirDrop empfangene `.stenomeeting`-Datei kann insbesondere auf dem Mac in `Downloads` verbleiben.
Nach einem erfolgreichen Import weist Steno sichtbar darauf hin, dass dort eine unverschlüsselte Kopie mit Notizen, Transkript und gegebenenfalls Rohaufnahme liegen kann.
Steno löscht, verschiebt oder verändert diese externe Datei niemals still.
Der Nutzer entscheidet selbst über ihre Aufbewahrung oder Löschung.

Der Hinweis erklärt außerdem, dass Dateien in `Downloads` durch lokale Suchindizierung oder eine vom Nutzer eingerichtete Datensicherung erfasst werden können.
Steno behauptet nicht, diese externen Systeme kontrollieren zu können.

## iCloud-Backup-Ausschluss auf iPadOS

Der bestehende Bibliothekspfad unter `Documents/StenoLibrary` bleibt für die Dateien-App erreichbar, wird aber bis zu einer späteren Verschlüsselung von Gerätebackups ausgeschlossen.
Beim Bootstrap setzt die iPadOS-App `URLResourceValues.isExcludedFromBackup = true` auf dem bestehenden Bibliothekswurzelverzeichnis und prüft den gelesenen Wert anschließend.
Dasselbe geschieht unmittelbar nach dem erstmaligen Erzeugen des Verzeichnisses.
Das benachbarte private Transfer-Validierungsverzeichnis mit Snapshots und gestagten Klartextdaten erhält denselben geprüften Backup-Ausschluss.

Die Vererbung auf neu angelegte Inhalte wird auf echten Geräten geprüft.
Falls einzelne neu erzeugte Dateien den Ausschluss nicht zuverlässig erben, setzt ein gemeinsamer Bibliotheks-Hook das Attribut zusätzlich bei deren atomarem Commit.
Ein Fehler beim Setzen oder Prüfen wird sichtbar diagnostiziert und nicht als erfolgreicher Datenschutzstatus ausgegeben.

Es wird kein iCloud-Container, keine ubiquitäre Dokumentablage und kein CloudKit verwendet.
Die spätere Produktdokumentation muss die bisherige Aussage, Aufnahmen blieben bewusst im Backup, auf diese neue verbindliche Entscheidung aktualisieren.

## Exportablauf

1. Der Nutzer öffnet ein exportfähiges, sauber beendetes Meeting und wählt `Meeting teilen`.
2. Steno ermittelt die erlaubten Textinhalte und finalisierten Audiospuren über gemeinsame Logik.
3. Die Vorschau zeigt Titel, Datum, Textinhalte und den ausgeschalteten Audio-Schalter.
4. Beim Einschalten von Audio zeigt die Vorschau Spuren, konkrete Größen und die Klartext- und Nebenstimmenwarnung.
5. Nach der Bestätigung erzeugt `StenoExchange` eine validierte reguläre AppleArchive-Datei in einem eigenen temporären Verzeichnis.
6. Die App öffnet die Systemfreigabe und fordert dazu auf, AirDrop auszuwählen.
7. Steno startet keine automatische Sendung und kennt keinen Hintergrundempfänger.
8. Die temporäre eigene Kopie wird nach dem Systemabschluss sicher aufgeräumt.

## Importablauf auf dem Mac

1. Der Nutzer öffnet eine empfangene `.stenomeeting`-Datei.
2. Steno erhält sicherheitsbeschränkten Zugriff und validiert äußere Datei, AppleArchive-Header, Struktur, Grenzen, Hashes und Inhalte ohne Bibliotheksmutation.
3. Steno berechnet No-op oder Konflikt gegen den aktuellen Bibliotheksstand.
4. Die App zeigt die vollständige Importvorschau und die Klartextgrenzen.
5. Bei einem Konflikt ist keine Importaktion verfügbar.
6. Bei einem No-op bestätigt die App sichtbar das bereits vorhandene Meeting, schreibt nichts und bietet an, das vorhandene Meeting zu öffnen und dort gegebenenfalls die Verarbeitung zu starten.
7. Bei neuen Textinhalten bestätigt der Nutzer `Importieren`.
8. Bei Audio wählt der Nutzer `Nur importieren` oder `Importieren und verarbeiten`.
9. Für Verarbeitung wird die Sprache vorausgewählt oder ausdrücklich bestätigt und der Modellzustand angezeigt.
10. `StenoLibrary` commitet Meeting, Importbeleg und gegebenenfalls Verarbeitungsanforderung atomar.
11. Der Reconciler legt bei bestätigter Verarbeitung genau den vorab benannten Job an.
12. Die App öffnet das sichtbar als importiert markierte Meeting.
13. Die App weist darauf hin, dass die empfangene Klartextdatei außerhalb von Steno bestehen bleiben kann.

Der iPad-Import verwendet denselben Paketparser, dieselbe Deduplizierung und denselben Bibliothekscommit.
Eine Mac-spezifische Weiterverarbeitungsschaltfläche bleibt eine dünne Oberfläche über dem gemeinsamen Verarbeitungsauftrag.

## Fehlerverhalten

- Ein ungültiges Paket wird vor der Vorschau als nicht importierbar gemeldet und verändert nichts.
- Eine Änderung oder ein Austausch der externen Datei nach fertiger Vorschau beeinflusst den Import nicht, weil ausschließlich der private Snapshot der angezeigten Vorschau verwendet wird.
- Eine Änderung des privaten Snapshots oder seiner validierten Stagingdateien wird durch erneute Größen-, Hash- und `transportDigest`-Prüfung erkannt.
- Zu wenig Speicher verhindert den Commit, ohne das Paket oder vorhandene Meetings zu verändern.
- Ein Stagingfehler hinterlässt kein sichtbares Meeting.
- Ein Konflikt verändert weder die vorhandene noch die eingehende Fassung.
- Ein fehlendes Modell lässt Meeting und Audio bereit und erzeugt keinen Download ohne Zustimmung.
- Ein Jobfehler lässt Originale und importierten Snapshot unverändert und bietet einen manuellen Retry.
- Ein Fehler beim Aufräumen der eigenen temporären Exportkopie wird lokal diagnostiziert, rechtfertigt aber niemals das Löschen einer empfangenen externen Datei.

## Kompatibilität mit vorhandenen Ansätzen

Der bestehende Markdown-Export bleibt für lesbare Exporte bestehen.
Er wird nicht als Importformat verwendet, weil ihm Manifest, Ursprungskennung, strukturierte Zeitdaten und Deduplizierung fehlen.

`LegacyImporter` bleibt für das Altformat zuständig.
Die neue Archivlogik verwendet dessen Staging-Idee, übernimmt aber weder Altformatannahmen noch `legacyProvenanceKey`.

`PreparedMeetingImport` wird als gemeinsamer atomarer Unterbau erweitert.
Es akzeptiert künftig optional eine Transkriptrevision und zusätzliche sichere Transfermetadaten, ohne die strengeren Altimportprüfungen abzuschwächen.

Ein bestehender Roh-Audioimport wird nicht als Abkürzung verwendet, weil ihm die hier festgelegten Paket-, Ursprungs-, Sprach- und Konfliktgrenzen fehlen.

Die Datenschutzerklärung in `docs/PLAN-PRIVACY.md`, nach der Audio die Maschine nie verlässt, muss bei der späteren Produktumsetzung präzisiert werden.
Die enge neue Ausnahme lautet sinngemäß: Audio verlässt das Gerät nur nach einer ausdrücklichen lokalen Einzeltransferentscheidung, niemals automatisch, für Cloud-Sync oder für ein Modell.

## Automatisierte Abnahme

### `StenoExchange`

- Alle drei zulässigen Nutzdatenzustände durchlaufen einen Mac-iPad-Roundtrip.
- Jeder Export ist genau eine reguläre `.stenomeeting`-Datei in unkomprimiertem AppleArchive-Format.
- Das Standardpaket enthält nie Audio.
- Audio erscheint nur bei ausdrücklichem Flag und enthält exakt die ausgewählten Spuren und Größen.
- Notizen und `[HH:MM:SS]`-Marker bleiben bytegetreu erhalten.
- Transkripttext, Wortzeiten, generische Sprecher und bestätigte sichtbare Textlabels bleiben erhalten.
- Importierte Namen enthalten keine Personen-, Cluster-, Run- oder Embeddingbezüge.
- Sentinels für Personen-E-Mail, Firma, Embedding, Review, Runs, Reports, Jobs, Teilnehmer, Ordner, Capture und Modelle fehlen in jedem Paket.
- Laufende, unterbrochene und nur teilweise finalisierte Aufnahmen sind nicht exportierbar.
- Unbekannte Hauptversionen, Fähigkeiten, Dateien und inkonsistente Referenzen werden abgelehnt.
- Äußere Verzeichnisse und Symlinks sowie Archiv-Traversal, Verzeichnis-, Symlink-, Hardlink-, Spezial- und Metadateneinträge, unbekannte Headerfelder, Unicode- und Case-Kollisionen werden abgelehnt.
- Doppelte bekannte Headerfelder, falsche Feldtypen, ein nichtnull `DAT`-Offset, abweichende `DAT`- und `SIZ`-Werte, Integerüberläufe, abgeschnittene Daten und Trailing Garbage werden abgelehnt.
- Der Reader verwendet keinen automatischen Extractor und schreibt vor vollständiger Header- und Pfadprüfung keinen Archiveintrag.
- Komprimierte AppleArchive-Ströme und andere Archivformate werden in V1 abgelehnt.
- Datei-, Tiefen-, Größen-, Notiz-, Turn-, Segment- und Wortgrenzen werden an und unmittelbar über jedem Grenzwert geprüft.
- Die äußere Dateigrenze von 24 GiB plus 2 MiB wird an und unmittelbar über dem Grenzwert geprüft.
- Die eigenen Grenzen für Manifest, Meetingdokument und Audio-Metadaten werden an und unmittelbar über jedem Grenzwert geprüft.
- Falsche Größen, Hashes und Inhaltsdigests werden abgelehnt.
- Ein Austausch der externen Datei während des einmaligen Snapshots kann nie dazu führen, dass Digest und Parser unterschiedliche Dateien verwenden.
- Eine externe Änderung nach der Vorschau verändert den gehaltenen Snapshot nicht; eine Snapshotmanipulation vor Commit wird erkannt.
- Zu wenig Speicher, Disk-full und Cancellation entfernen die eigene private Validierungssitzung vollständig und verändern kein Meeting.
- Beschädigtes Audio, null Samples und widersprüchliche Audiometadaten werden abgelehnt.

### `StenoLibrary`

- Text-only, Aufnahme-only und kombinierte Pakete werden atomar importiert.
- Ein Import ohne Transkript erzeugt keinen aktuellen Revisionszeiger.
- Ein Import mit Transkript erzeugt genau eine lokale Snapshot-Revision ohne fehlende Fremdbezüge.
- Lokale Medienkennungen, Namen, Eigenschaften und Provenienz werden aus validiertem Inhalt neu erzeugt.
- Ein Fehler an jedem Staging-Schritt hinterlässt kein sichtbares Teilmeeting.
- Ein identisches Paket ergibt einen No-op ohne Mutation.
- Ein abweichendes Paket desselben Ursprungs ergibt einen Konflikt ohne Mutation.
- Derselbe Paketimport bleibt nach lokaler Bearbeitung der importierten Notiz ein No-op.
- Parallele identische Importe erzeugen höchstens ein Meeting.
- Medienprovenienzkollisionen werden zusätzlich erkannt.
- Zu wenig Speicher wird vor der endgültigen Kopie erkannt.

### `StenoPipeline`

- Eine ausdrücklich gewählte iPad-Sprache wird vorausgewählt und nach Mac-Bestätigung im Job gepinnt.
- Eine geschätzte oder fehlende Sprache erzeugt ohne Mac-Bestätigung keinen Job.
- Eine abweichende globale Mac-Sprache verändert den gepinnten Job nicht.
- Der Processing-Run zeichnet die effektiv gepinnte Sprache auf.
- Ein fehlendes ASR-Modell lässt Meeting und Audio erhalten und erzeugt keinen automatischen Download oder Retry.
- Ein fehlendes Diarisierungsmodell lässt Transkript und Audio erhalten und erzeugt keinen automatischen Retry.
- Ein manueller Retry erzeugt genau eine neue bewusste Anforderung.
- Abstürze vor Commit, nach Commit, nach Enqueue und vor Zustandsupdate erfüllen die festgelegten Wiederanlaufregeln.
- Zwei gleichzeitige Reconciler erzeugen nur die vorab persistierte `JobID`.
- Ein vorhandener Job mit derselben ID und abweichenden Parametern wird als Integritätsfehler gemeldet.

### iPadOS-Backupgrenze

- Eine neu erzeugte Bibliothek trägt nach dem Bootstrap den Backup-Ausschluss.
- Eine bereits vorhandene Bibliothek erhält den Backup-Ausschluss ohne Datenmigration oder Datenverlust.
- Neue Meeting-, Notiz- und Audiodateien bleiben nach App-Neustart vom Gerätebackup ausgeschlossen.
- Ein Fehler beim Setzen oder Prüfen wird nicht als erfolgreicher Zustand dargestellt.

### Gesamtabnahme

- `swift test --package-path StenoKit` läuft vollständig durch.
- Die macOS-App wird aus einem neu erzeugten Xcode-Projekt gebaut.
- Die iOS-App wird aus einem neu erzeugten Xcode-Projekt gebaut.
- Relevante iOS-Kit-Tests laufen gegen einen Simulator.
- Auf echten Geräten wird ein Textpaket in beide Richtungen per AirDrop geprüft.
- Auf echten Geräten wird eine sauber beendete iPad-Aufnahme mit bewusst eingeschaltetem Audio an den Mac übertragen.
- Die manuelle Abnahme prüft Größenanzeige, Warnung, Importvorschau, Sprachbestätigung, fehlendes Modell, Verarbeitung und sichtbaren Importstatus.
- Die manuelle Abnahme bestätigt, dass die empfangene Datei in `Downloads` bestehen bleibt und Steno nur darauf hinweist.
- Die manuelle Abnahme bestätigt, dass die reguläre `.stenomeeting`-Archivdatei den AirDrop-Transport bytegleich und als einzelne Datei übersteht.

## Spätere Umsetzungsreihenfolge

1. Reales Architektur-Gate mit einer unkomprimierten AppleArchive-Probe als reguläre Einzeldatei.
2. Gemeinsames Schema, Allowlist, Limits, Digest und adversariale Archive-Parser-Tests in `StenoExchange`.
3. Backup-Ausschluss der bestehenden und neuen iPadOS-Bibliothek mit Gerätetest.
4. Gemeinsamer Export und manuelle Archivdatei-Abnahme über AirDrop.
5. Atomarer Import, Importbeleg, optionale Revision und Deduplizierung in `StenoLibrary`.
6. Gepinnte Job-Sprache, persistierte Verarbeitungsanforderung und Reconciler in `StenoPipeline`.
7. Dünne Export-, Empfangs-, Vorschau-, Status- und Retry-Oberflächen auf beiden Plattformen.
8. Vollständige automatisierte und manuelle Abnahme des iPad-zu-Mac-Verarbeitungswegs.

Vor der Wiederaufnahme der Produktumsetzung muss der Nutzer diese korrigierte Spezifikation und den dazugehörigen Plan prüfen.
Task 1 bleibt bis zu dieser Freigabe und bis zum bestandenen neuen Einzeldatei-Gate gesperrt.

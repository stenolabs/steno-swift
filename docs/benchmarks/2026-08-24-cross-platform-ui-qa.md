# Cross-platform UI QA vom 24.08.2026

## Umfang

Geprueft wurde der konsolidierte Stand von `codex/ui-modernization` fuer macOS, iPhone und iPad.

Alle Laufzeittests mit Demo-Daten verwendeten isolierte Bibliotheks- und Modellverzeichnisse.
Die echte Meeting-Bibliothek des Nutzers wurde nicht geoeffnet oder veraendert.

## Gemessen und direkt beobachtet

- Die iPhone-Pruefung lief auf einem iPhone-17-Simulator mit iOS 26.5.
- Die iPad-Pruefung lief auf einem iPad-Pro-13-Zoll-M5-Simulator mit iPadOS 26.5 in Hoch- und Querformat.
- Die macOS-Pruefung lief mit einer isolierten temporaeren Bibliothek.
- Heller und dunkler Darstellungsmodus wurden fuer die zentralen Bibliotheks-, Meeting-, Aufnahme-, Demo- und Einstellungsansichten visuell geprueft.
- Die Demo-Bibliothek installiert drei klar mit `DEMO:` und `Demo` gekennzeichnete, lokale synthetische Meetings in einem eigenen Ordner.
- Die Demo-Detailansicht nennt die synthetische Herkunft und zeigt keine unbestaetigten Sprecher als reale Personen an.
- Die iPad-Rueckfrage fuer `Erneut transkribieren` aus dem Menue oben rechts erscheint zentriert im Hauptinhalt und nicht in der Seitenleiste.
- Die Rueckfrage nennt die neue Revision, den Erhalt des bisherigen Transkripts und seiner Korrekturen, neue Cluster-Kennungen sowie die erneut notwendige Sprecherbestaetigung.
- Die Aktion wurde bei der UI-Pruefung abgebrochen und deshalb nicht eingereiht.
- Die installierte Offline-Modellzeile blieb auf iPhone- und iPad-Groesse unter 80 Punkten hoch und erschien im Laufzeittest als normale einzeilige Karte.
- Die uebergrosse Zeile liess sich auf `LabeledContent` innerhalb dieser dynamischen List-Zeile eingrenzen.
  Der Inhalt und die nachfolgenden Statuszeilen erzeugten die Hoehe nicht.
  Der Ersatz durch eine explizite `HStack` beseitigte sie, und ein UIKit-Hierarchietest sichert die Zellhoehe auf beiden Geraetegroessen ab.
- Fuer die gespeicherte deutsche Sprache enthielten beide Transkriptions-Picker jeweils zwei Eintraege: Apple Speech Analyzer und FluidAudio Parakeet TDT.
  Ein Picker ist damit in dieser Konfiguration sachlich richtig.
  Nicht installierte oder experimentell gesperrte Eintraege bleiben sichtbar und nennen ihren Zustand.
- Der deutsch lokalisierte Lauf zeigte keine fehlenden deutschen Eintraege in den beiden App-Katalogen.
- Die deutsch lokalisierte Datenschutzwarnung fuer externe Textmodelle nennt die uebertragenen Datenklassen, Ziel und fehlende Transportverschluesselung.
- Das bisherige Steno-Icon der macOS- und iOS-Quellen war bytegleich.
- Seine gemessenen Standard-Farbendpunkte sind `#0DACBD` und `#00717E`.
- Die weisse Marke belegt im 1024-Pixel-Original die Grenzen x=302 bis 786 und y=186 bis 809.
- Die vektorisierte S-Marke erreicht 99,313 Prozent Masken-IoU zum Rasteroriginal.
- Der Punkt ist als exakter Vektorkreis erhalten.
- Icon Composer, `actool`, beide App-Builds und die sichtbare Simulator-Darstellung wurden mit dem gemeinsamen Icon-Dokument geprueft.
- macOS-App, macOS-Testbundle, iOS-Simulator-App, iOS-Testbundle, StenoiOSKit-Testbundle und signierte Geraete-App sind jeweils nicht-fette ARM64-Mach-O-Dateien.
- Der signierte Build `org.steno.Steno` Version 1.0 Build 1 wurde auf dem iPhone 15 Pro und dem iPad Pro 11 Zoll installiert und anschliessend in beiden App-Listen gefunden.

## Vollstaendige Tests

- `swift test --package-path StenoKit`: 1082 Tests in 125 Suiten bestanden.
- macOS-App-Suite: 319 Tests in 31 Suiten bestanden.
- iOS-App-Suite: 476 Tests in 43 Suiten bestanden.
- StenoiOSKit-Suite: 35 Tests in 5 Suiten bestanden.
- Die Shell-Pruefungen fuer Apple-Silicon-only und die iOS-Buildargumente bestanden ebenfalls.

Der erste vollstaendige iOS-Lauf deckte alte Tests auf, die sichtbare Texte fest auf Englisch erwarteten, obwohl der Testprozess deutsch lief.
Die Produkttexte waren korrekt deutsch.
Die Erwartungen wurden sprachstabil gemacht und die vollstaendige Suite danach erfolgreich wiederholt.

Claude Fable pruefte den konsolidierten Diff als unabhaengige zweite Meinung.
Der wesentliche uebernommene Hinweis war, feste Sprecherrollen nicht anhand ihres angezeigten Texts zu erkennen.
`SpeakerPresentation` traegt diese Rollen nun typisiert, bestaetigte Nutzernamen wie `Me` bleiben unveraendert und nur der Quellenzusatz undurchsichtiger Cluster-Kennungen wird lokalisiert.
Die gemeldete moegliche Umwandlung von `NaN` oder Unendlich in einen ganzzahligen Pegel wurde nach Quellverfolgung und einem Swift-Lauf verworfen: `AudioLevel` normalisiert diese Werte bereits beim oeffentlichen Initialisieren auf den gueltigen Pegelbereich.

## Abgeleitet oder bewusst gestaltet

- Der horizontale Anteil des Icon-Verlaufs von etwa 30 Prozent ist aus den gemessenen Eckfarben abgeleitet, nicht als Metadatum aus dem alten PNG auslesbar.
- Dunkelmodus-Material und Icon-Composer-Rendition sind bewusste Designentscheidungen.
- Die Zuordnung der uebergrossen Modellzeile zu `LabeledContent` beruht auf der isolierten Komponenten-Aenderung und dem reproduzierenden Zelltest.
  Eine interne SwiftUI-Ursache unterhalb dieser Komponente ist nicht oeffentlich beobachtbar.

## Nicht gemessen

- VoiceOver wurde strukturell ueber Accessibility-Labels und Layouttests geprueft, aber nicht als vollstaendige gesprochene Sitzung mit Kopfhoerer abgenommen.
- Die beiden physischen Installationen wurden technisch verifiziert.
  Eine visuelle und interaktive Abnahme auf den physischen Displays wurde nicht automatisiert behauptet.
- Die Ruecktranskription wurde in der isolierten iPad-Pruefung bewusst nicht gestartet, damit keine unnoetige Modellarbeit laeuft.

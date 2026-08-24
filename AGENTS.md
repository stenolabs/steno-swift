# Arbeiten in diesem Repository

Steno nimmt Besprechungen auf, transkribiert und diarisiert sie lokal und erzeugt daraus Protokolle.
Alles laeuft auf dem Geraet; nur ein ausdruecklich gewaehltes Sprachmodell fuer die Protokollerstellung darf nach aussen gehen.

Dieses Repository enthaelt **beide** Apps und den gemeinsamen Kern.
Der Name `steno-macos` ist historisch.

## Plattformziel

Steno wird ausschliesslich fuer Apple Silicon gebaut und getestet.
Die macOS-App, die iOS-/iPadOS-App und eigene Build- oder Fixture-Helfer sind arm64-only.
Intel, x86_64, Rosetta und Universal Binaries werden nicht unterstuetzt und erhalten keine Kompatibilitaetsarbeit.
`universal` in einem Asset Catalog bezeichnet dagegen die Apple-Geraeteklasse und keine Prozessorarchitektur.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `StenoKit/` | Der gemeinsame Kern, ein SwiftPM-Paket mit zehn Bibliotheks-Targets. Beide Apps haengen daran. |
| `App/` | Die macOS-App. |
| `iOS/App/`, `iOS/StenoiOSKit/` | Die iOS- und iPadOS-App. `StenoiOSKit` ist ein eigenes Paket und bewusst kein StenoKit-Target: es haengt am `AVAudioSession`-Lebenszyklus, den es auf dem Mac nicht gibt. |
| `docs/` | Plaene, Messprotokolle. `ARCHITECTURE.md` (an der Wurzel) und `docs/PLAN-IOS.md` zuerst lesen. |
| `scripts/` | `build-app.sh` (macOS), `build-ios.sh` (iOS/iPadOS), `generate-model-checksums.sh` (Pruefsummen-Manifest fuer Modelle). |

Welche Teile plattformgebunden sind, entscheidet die Target-Zugehoerigkeit:

- `StenoAudioCore` ist portabel und enthaelt alles, was eine Aufnahme vertrauenswuerdig macht: `TrackWriter`, `CaptureRecovery`, `DiskSpaceChecker`, `RecordingSession`.
  **Beide** Plattformen nehmen damit auf. Nichts davon nachbauen.
- `StenoMacAudio` ist macOS-only: die Mikrofonaufnahme des Mac (`MicRecorder`, `MicrophoneDiscovery`, `CoreAudioInputDevice`), der CoreAudio-Process-Tap fuer Systemaudio (`SystemAudioRecorder`), die Berechtigungspruefung und der Ruhezustandsschutz.
  Wird fuer iOS nie gebaut; das Gegenstueck dort ist `StenoiOSAudio` in `StenoiOSKit`.

## Bauen und testen

```
swift test --package-path StenoKit     # der Kern, derzeit 813 Tests
scripts/build-app.sh [--run]           # macOS-App
scripts/build-ios.sh                   # iOS, nur bauen
scripts/build-ios.sh --simulator [UDID] # in den gebooteten Simulator, ohne UDID den ersten
scripts/build-ios.sh --ipad-simulator  # in ein iPad, bootet oder erzeugt eines bei Bedarf
scripts/build-ios.sh --device [UUID]   # aufs Geraet, ohne UUID das erste iPhone/iPad
```

**Es gibt vier Testsuiten, nicht eine.** Die drei uebrigen laufen ueber xcodebuild und rufen `xcodegen` **nicht** von selbst auf - nach einem Branch-Wechsel also erst `xcodegen generate`, sonst kommt `cannot find type ...`:

```
xcodebuild -project Steno.xcodeproj -scheme Steno \
  -destination 'platform=macOS' test                     # macOS-App, derzeit 193 Tests

cd iOS && xcodebuild -project StenoiOS.xcodeproj -scheme Steno \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath build/DerivedData test                # iOS-App, derzeit 253 Tests

cd iOS/StenoiOSKit && xcodebuild -scheme StenoiOSKit \
  -destination 'platform=iOS Simulator,name=iPhone 17' test   # derzeit 35 Tests
```

Die Zahlen veralten; sie stehen da, damit ein stiller Rueckgang auffaellt.

Getestet wird mit Swift Testing. Zwei Fallen, die schon zugeschlagen haben:

- `#expect` verpackt seinen Ausdruck in eine Closure mit unveraenderlichem Empfaenger. Der Aufruf einer **mutierenden** Methode darin uebersetzt nicht ("cannot use mutating member on immutable value"). Die Mutation davor ziehen und nur das Ergebnis pruefen.
- Wer in einem Test einen Haltepunkt in produktiven async-Code einschleust und dort synchron wartet, blockiert einen Thread des Cooperative Pools. Genug davon gleichzeitig, und der ganze Lauf steht. Die vorhandenen Helfer in `TestSupport.swift` (`withBlockingTestExecutor`, `blockingTestTask`) legen solche Waits auf eine eigene DispatchQueue - benutze sie, statt neue zu bauen.

**Beide Xcode-Projekte sind Generate aus ihrer `project.yml` und stehen in `.gitignore`.**
Nach jedem Branch-Wechsel, Merge oder Rebase erst `xcodegen generate` laufen lassen, sonst fehlen neue Quelldateien im alten Projekt und der Build bricht mit `cannot find type ...` ab.
Das sieht wie ein Codefehler aus und ist keiner.
Die Skripte tun das von selbst.

Einstellungen gehoeren in die `project.yml`, nie in Xcodes Oberflaeche: der naechste `xcodegen`-Lauf wirft sie sonst weg.
Das gilt besonders fuer Signieren, Bundle-ID und Info.plist-Schluessel.
`App/Info.plist` und `iOS/App/Info.plist` sind selbst Erzeugnisse aus dem `info:`-Block und stehen in `.gitignore` - wer sie direkt bearbeitet, verliert die Aenderung kommentarlos.

## Regeln, die nicht verhandelbar sind

- **Die Aufnahme ist das einzige unersetzliche Artefakt.**
  Transkription, Diarisierung und Protokolle lassen sich wiederholen, eine verlorene Aufnahme nicht.
  Deshalb darf ein fehlendes Sprachmodell, eine nicht unterstuetzte Sprache oder ein Transkriptionsfehler die Aufnahme nie beenden.
  Beide Apps trennen das in getrennte Tasks; wer daran arbeitet, muss diese Trennung erhalten.
- **Originale sind unveraenderlich.**
  Sie werden geschrieben, nie ueberschrieben. Korrekturen entstehen als neue Revision (`ARCHITECTURE.md` Abschnitt 4).
- **Nichts raten, was der Nutzer als Tatsache liest.**
  Ein unbestaetigter Sprechercluster bleibt ein generischer Sprecher, eine Vermutung wird als Vermutung angezeigt, und ein Cluster mit mehreren Stimmen bekommt keinen Namen.
- **Der System-Locale ist nicht die gesprochene Sprache.**
  Ein englisch eingestelltes Geraet in Deutschland meldet `en_DE` und wuerde deutsche Rede als Englisch transkribieren, ohne Fehlermeldung und mit plausibel aussehendem Ergebnis.
  Beide Apps fuehren deshalb eine ausdrueckliche, gespeicherte Transkriptionssprache. `Locale.current` gehoert nicht in den Transkriptionspfad.
- **Modelle laden nicht von selbst.**
  Seit der Onboarding-Arbeit laeuft jede Installation ueber `ModelInstallationCoordinator` mit Zustimmung und Pruefsummen. Die Provider laden nicht mehr eigenstaendig.
- **Stimm-Evidenz wird ausgenommen, nie geloescht.**
  Prototypen und Hard Negatives tragen `excludedAt`, und jede Auswertung filtert ueber `isActive`. Wer Eintraege entfernt statt sie auszunehmen, hebelt Ausschluss und Widerruf aus, und der Verlust ist unsichtbar: spaeter bleibt nur eine Erkennung ohne erkennbaren Grund aus.
- **Lauf- und Revisions-Provenienz sind tragend.**
  Eine Hoerprobe stammt aus genau der Spur, die dieser Lauf diarisiert hat, nicht aus irgendeiner desselben Typs; und eine Korrektur setzt auf der aktuellen Revision auf, sonst weist der `RevisionStore` sie als Konflikt ab. Bei Mehrdeutigkeit lieber nichts liefern als das Falsche.

## Wenn du den Kern anfasst

Eine Aenderung in `StenoKit` trifft beide Apps.
Genau dafuer liegen sie in einem Repository: ein Bruch faellt beim Bauen auf und nicht Tage spaeter.
Damit das funktioniert, gehoert nach jeder Kernaenderung die volle Kette dazu:

```
xcodegen generate && scripts/build-app.sh && scripts/build-ios.sh && swift test --package-path StenoKit
```

Bauen allein genuegt nicht: wer Verhalten im Kern aendert, laesst auch die beiden App-Suiten laufen (oben).
Sie finden Brueche, die der Compiler nicht sieht.

Zwei Brueche am 08.08.2026 waren fuer git unsichtbar, weil beide Seiten andere Zeilen anfassten, und fielen nur so auf:
eine neue View benutzte einen Typ, der gerade das Modul gewechselt hatte, und die iOS-App rief Provider-Initializer auf, die ihre Parameter verloren hatten.

## Parallel arbeiten

Fuer mehrere gleichzeitige Aufgaben Arbeitsbaeume nutzen, `.worktrees/` ist dafuer vorgesehen und ignoriert:

```
git worktree add .worktrees/<name> -b <branch>
```

Was Arbeitsbaeume **nicht** loesen:

- Semantische Kollisionen im Kern. Sie trennen Dateien, nicht Bedeutung. Gegenmittel sind kurze Branches, frueh auf `main` rebasen und danach die Kette oben.
- Die Mac-Bibliothek unter `~/Library/Application Support/Steno/Library` gehoert allen Mac-Builds gemeinsam.
  Fuer alle Tests, die keine nutzereigenen Aufnahmen anfassen sollen, `STENO_LIBRARY_DIR` und `STENO_MODEL_DIR` auf ein Wegwerfverzeichnis setzen.
- Auf einem Geraet gibt es die Bundle-ID `org.steno.Steno` nur einmal. Zwei Arbeitsbaeume, die beide installieren, ueberschreiben sich gegenseitig.

`iOS/StenoiOSKit/Package.resolved` ist bewusst unversioniert: der einzige externe Pin lebt in `StenoKit/Package.resolved`, zwei Dateien fuer denselben Pin liefen auseinander.

## Praktisches zu iOS

- Signiert wird automatisch ueber `DEVELOPMENT_TEAM` in der ignorierten lokalen `.steno-signing.xcconfig`.
  Als Vorlage dient `.steno-signing.xcconfig.example`.
  Mit einem kostenlosen Apple-Konto startet die App nach sieben Tagen nicht mehr und muss neu installiert werden. Das ist kein Fehler.
- Das Geraet haengt nach dem ersten Pairing per Kabel danach ueber das lokale Netz (`transportType: localNetwork`). Entsperrt und im selben Netz genuegt.
- Der Simulator kann kein `SpeechTranscriber`: er meldet null unterstuetzte Sprachen.
  Live-Transkript, Sprachwahl und Modellinstallation lassen sich nur am Geraet pruefen.
- Den Simulator nicht per `cliclick` fernsteuern. Mehrere Anlaeufe am 07.08.2026 trafen die Bedienelemente nicht; ein Mensch tippt schneller.
  Fuer Screenshots `xcrun simctl io <udid> screenshot` verwenden, nie `screencapture`: das nimmt den ganzen Bildschirm auf, samt fremder Fenster.

## Handoffs

`HANDOFF.md`, `HANDOFF-*.md` und `UEBERGABE*.md` sind Sitzungsartefakte, stehen in `.gitignore` und werden nie committet.
Wer unfertige Arbeit hinterlaesst, schreibt einen: Branch, Stand, offene Punkte, bekannte Sackgassen.
Ein Handoff gehoert der Aufgabe, die ihn geschrieben hat; fremde nicht ueberschreiben.

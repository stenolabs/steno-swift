# Onboarding und Modellzustimmung

Stand: 2026-08-07.
Verfasser: Claude (Opus 5), Zweitmeinung von Fable 5 eingeholt und eingearbeitet.
Kennzeichnung: **[Fakt]** ist an der genannten Datei geprüft, **[Annahme]** ist plausibel aber ungemessen, **[Auflage]** ist eine Bedingung an spätere Arbeit.

## Anlass

Auf einem frischen Rechner scheitert jede Verarbeitung nach dem Import einer Audiodatei mit
"Diarization models are not installed (missing: SortformerNvidiaHigh_v2 ...). Re-run with allowModelDownload: true after explicit user consent to install them."

**[Fakt]** `allowModelDownload: false` ist fest verdrahtet in `StenoKit/Sources/StenoPipeline/PipelineStartup.swift:29` und `PipelineCoordinator.swift:50`.
Kein Pfad in der App setzt den Wert je auf `true`; nur `steno-diarize-bench` kann Modelle laden.
Auf dem getesteten Mac mini funktioniert Diarisierung deshalb nur, weil die Modelle dort bereits auf der Platte liegen.

**[Fakt]** Zugleich lädt der ASR-Pfad ungefragt: `SpeechAnalyzerProvider.prepareTranscriber` (Zeile 174) ruft bei jeder Live-Session und jedem Finallauf `ensureAssets` (Zeile 193), das ohne Rückfrage installiert (Rumpf ab Zeile 197).
Zwei Haltungen zur selben Sache im selben Programm.

**[Fakt]** Die Quellen unterscheiden sich: Sprachmodelle kommen über Apples `AssetInventory`, Diarisierungsmodelle von `huggingface.co` (`ModelRegistry.swift:57`).

## Entscheidungen

Als Produktentscheidungen getroffen, nicht mehr zur Debatte:

1. Die Modellzustimmung ist ein eigenständiges Bauteil, das überall greift, wo Modelle fehlen. Der Erstlauf-Wizard ist nur die Vordertür, die dasselbe Bauteil aufruft.
2. Eine Zustimmung für alle lokalen Modelle, die beide Quellen offen benennt. Widerrufbar.
3. Das Betreiberprofil (Name, optional Organisation) speist den Protokollkopf. (Der Vorlagenkontext entfiel, siehe Nachtrag weiter unten.)
4. Wizard-Schritte: Rechtshinweis, Name und Organisation, Sprache, Modelle, Berechtigungen.
5. Modelle werden gegen ein eingechecktes Prüfsummen-Manifest verifiziert.

## Nicht in diesem Paket

Bewusst ausgeschlossen, damit dieses Paket endet:

- **Die Ich-Person im Personenmodell** und `selfPersonID`. Ohne die Mikrofonbindung hat der Zeiger keinen Abnehmer.
- **Die Bindung "wer war bei diesem Meeting am Mikrofon"**, das geteilte Gerät, das Auftragstranskript. Eigenes Arbeitspaket, Zielort nach heutiger Analyse `meeting.json`, analog zur meeting-skopierten Teilnehmerliste (`ARCHITECTURE.md:121`).
- **Stimm-Evidenz aus Selbst-Clustern.** Sie wäre totes Gewicht: Selbst-Cluster erhalten garantiert keine Vorschläge, mit `.infinity` als Distanz und der Begründung "self is outside named-speaker identification" (`SpeakerSuggestionEngine.swift:161,171`). Bestätigungen erzeugen zudem gegenseitige Hard Negatives (`ARCHITECTURE.md:162`), deren Kontext hier die Nahbesprechung ist; sie könnten echte Treffer auf anderen Spuren unterdrücken und verletzten die Regel "nie gemittelt über Kontexte hinweg" (`ARCHITECTURE.md:126`).
- **Firmennamen im ASR-Kontext.** `Identity.swift:161-166` nennt diesen Weg ausdrücklich "weder gebaut noch gemessen". Das Betreiberprofil ging in den Vorlagenkontext, nicht in den Transkriptionskontext; inzwischen in keinen von beiden, siehe Nachtrag.

## Bausteine und Grenzen

### Der Download verlässt den Provider

`FluidSortformerProvider` lädt heute selbst nach und trägt dafür `allowModelDownload` als `let` im Konstruktor.
Beides entfällt ersatzlos.
Der Provider wirft künftig nur noch `modelsNotInstalled`; geladen wird ausschließlich im Installer.

Begründung, **[Fakt]** am Code geprüft:

- Der Provider hält keine Modelle im Speicher. `loadModels` läuft in jedem `diarize()`-Aufruf, `LoadedModels` ist ein lokaler Rückgabewert (`FluidSortformerProvider.swift:45,82,176-179`). Eine zur Laufzeit befragte Regel im Provider wäre also gar nicht nötig, um ohne Neustart zustimmen zu können.
- Der Provider sagt selbst, was richtig wäre: "Do not delete a possibly recoverable cache and do not retry via the network. Installation is an explicit caller-owned action." (`FluidSortformerProvider.swift:146-148`).
- Ein Download mitten in `diarize()` könnte nie Fortschritt melden, und ein Fehlschlag verbrennt sonst den laufenden Job.

### Vier Bauteile

| Bauteil | Ort | Aufgabe |
|---|---|---|
| `ModelInstalling` | StenoPipeline | Vertrag pro Modellart: Beschreibung, Zustand je Locale, Installation mit Fortschritt |
| `SpeechAssetInstaller` | StenoTranscription | Hüllt den vorhandenen `AssetInventory`-Pfad ein. Quelle: Apple |
| `DiarizationModelInstaller` | StenoDiarization | Hüllt den FluidAudio-Download ein, prüft Prüfsummen. Quelle: `huggingface.co` |
| `ModelInstallationCoordinator` | StenoPipeline | Fasst beide zusammen, beantwortet Arbeitsfähigkeit je Sprache, treibt Installation, serialisiert Downloads |

Kein neues Target: StenoPipeline hängt bereits von StenoTranscription und StenoDiarization ab.

`ensureAssets` wird künftig vom `SpeechAssetInstaller` gerufen, nicht mehr vom Provider im Vorbeigehen.
Ohne diese Umhängung wäre die gemeinsame Zustimmung eine Lüge: wer ablehnt und dann aufnimmt, lädt sonst trotzdem Apple-Assets.

### Zustimmung

Liegt in der App-Schicht, nicht in der Bibliothek.
Sie ist eine Entscheidung über diesen Rechner und sein Netz, keine Eigenschaft der Meetings, und darf nicht mitwandern, wenn die Bibliothek auf einen anderen Mac zieht.
StenoKit liest nie `UserDefaults`; die App reicht den Zustand in den Koordinator.

Gespeichert wird kein nackter Bool, sondern Zeitpunkt und benannte Quellen.
Im Behördenumfeld ist die Nachvollziehbarkeit der halbe Wert.

Widerruf heißt: es wird nichts mehr geladen.
Bereits installierte Modelle bleiben nutzbar, Apple-Assets sind ohnehin systemweit und von Steno nicht entfernbar.
Der Text muss das so sagen, sonst verspricht "widerrufbar" ein Löschen, das nicht stattfindet.

### Arbeitsfähigkeit ist keine einzelne Ja-Nein-Antwort

Sie wird je Sprache beantwortet, weil ASR-Assets locale-gebunden sind und reserviert werden (`SpeechAnalyzerProvider.swift:286-301`).
Ein einzelner Bool kippte beim Sprachwechsel.

### Prüfsummen

**[Fakt]** FluidAudio prüft nichts: In `DownloadUtils.swift` und `ModelRegistry.swift` kommt keine Prüfsummenbildung vor (Suche nach `sha256`, `checksum`, `CryptoKit`: keine Treffer).
Die "Verify"-Passage prüft nur die Existenz der Datei (`DownloadUtils.swift:620-627`).
Geladen wird gegen den beweglichen Branch: `resolve/main` (`ModelRegistry.swift:57`), gelistet über `tree/main` (`DownloadUtils.swift:400`).
Eine Revisionsangabe wird nicht durchgereicht.
`ARCHITECTURE.md:271` führt genau dieses Thema bereits als offenes Risiko.

Der `DiarizationModelInstaller` hasht deshalb nach dem Download jede Datei gegen ein im Repository eingechecktes Manifest (relativer Pfad zu SHA-256), erzeugt aus einer lokal geprüften Installation.
Bei Abweichung schlägt die Installation laut fehl und nennt die Datei, statt fremde Bytes zu verwenden.

**Ehrlichkeitsgrenze:** Das sichert Reproduzierbarkeit, nicht Echtheit.
Es friert die Bytes ein, die bei der Manifest-Erzeugung vorlagen.
Wäre das Modell zu diesem Zeitpunkt bereits manipuliert gewesen, schriebe das Manifest die Manipulation fest.

**[Auflage]** Ein bewegtes `main` wird damit vom stillen Austausch zu einem Fehlschlag, der ein bewusstes Manifest-Update verlangt.
`ModelRegistry.baseURL` ist programmatisch und über `REGISTRY_URL` umlenkbar (`ModelRegistry.swift:26-42`); das ist die spätere Spiegel-Option für abgeschottete Netze, heute unnötiger Betrieb.

### Downloads bleiben sichtbar

`ARCHITECTURE.md:228` legt fest, Modell-Downloads seien "einmalige, sichtbare Downloads ohne Inhaltsdaten".
Stilles Nachladen widerspräche dem.
Also: unaufdringlicher Fortschritt und ein Eintrag, welche Quelle wann was geliefert hat.

### Der Wizard: Zustand in StenoKit, Fenster in der App

**Amendiert am 2026-08-07 nach Fables Entscheidung, ursprünglich stand hier "StenoKit weiß nichts vom Wizard".**
Es gilt jetzt: StenoKit kennt den **Zustand** des Wizards, nicht sein **Fenster**.
Grund: Seitenfolge, Abbruch, Wiedereintritt und Überspringen sind echte Verzweigungen, die am Bildschirm niemand vollständig durchklickt, und die spätere iOS-App braucht genau dieselbe Zustandsmaschine.
Der ursprüngliche Satz diente dem iOS-Ziel; die Änderung dient ihm besser.

Ein eigenes `Window`-Szenario plus ein `OnboardingModel`, das nur speichert und anbindet.
Dieselbe Trennung gilt für das Betreiberprofil: die Bildung der Verfasserzeile ist ein geprüfter Werttyp in StenoKit, die Speicherung liegt in der App.
Die Bildschirmprüfungen bleiben davon unberührt und ungekürzt: eine grüne Suite heißt in diesem Projekt nicht "funktioniert" (`docs/UX-REVIEW.md`).
Ausgelöst über einen Zustand in den App-Einstellungen, der gesetzt wird, wenn der Wizard abgeschlossen **oder** bewusst abgebrochen wurde; erneut zu öffnen über das Menü.

## Ablauf

Fünf Seiten, in dieser Reihenfolge:

1. **Begrüßung und Rechtshinweis.** Drei Sätze zu § 201 StGB, dem Aufnehmen des nichtöffentlich gesprochenen Wortes ohne Einwilligung. Kein Häkchen, kein gespeicherter Zustand. Information, keine Entscheidung.
2. **Name und optional Organisation.** Beides überspringbar, später in den Einstellungen nachtragbar.
3. **Sprache der Transkription.**
4. **Modelle.** Was geladen wird, von wo, wie groß. Dann die Zustimmung, dann der Download mit sichtbarem Fortschritt.
5. **Mikrofon- und Systemaudio-Freigabe.**

Sprache steht vor den Modellen, weil ASR-Assets locale-gebunden sind und ohne gewählte Sprache das Falsche geladen würde.

**Auf Seite 4 muss offen stehen, was Ablehnen bedeutet:** ohne Modelle kann Steno nicht transkribieren.
Nicht "Sprechertrennung fehlt", sondern nichts.
Das ist die Folge der gemeinsamen Zustimmung und gehört in den Wizard, nicht in einen späteren rätselhaften Fehlschlag.

## Datenfluss

**Betreiberprofil** liegt in den App-Einstellungen, neben der Zustimmung.
Es beschreibt, wer dieses Steno bedient, nicht wem die Meetings gehören, und bleibt beim Auftragstranskript über fremde Bibliotheken hinweg dasselbe.

**Es gelangt beim Einreihen des Vorlagenlaufs in den Auftrag, nicht beim Rendern.**
`TemplateRenderRequest.enqueue` pinnt heute schon die Revision beim Einreihen, weil das Protokoll zu dem Textstand gehört, den der Nutzer vor sich hatte (`TemplateRenderRequest.swift:13-16`).
Für den Verfassernamen gilt dasselbe Argument.

**Datenschutzlage:** Name und Organisation fallen in die bestehende Klasse "Teilnehmerliste, Namen und Firmen", die laut `PLAN-PRIVACY.md:50-53` mitgeht, wenn und nur wenn für diesen Lauf ein externes Modell gewählt ist.

> **Nachtrag 2026-08-07, nach Produktentscheidung: der Verfassername geht gar nicht mehr an ein Sprachmodell.**
> Die Übertragung war erlaubt, aber ohne Empfänger: keine der fünf Sektionen von `Template.meetingMinutes` (`Template.swift:88-124`) fragt danach, wer das Protokoll schreibt, obwohl der Promptblock genau das anbot.
> Damit entfallen `RenderContext.author`, `Job.authorLine` und das Pinnen beim Einreihen; der Absatz oben beschreibt einen Stand, den es nicht mehr gibt.
> Der Name bleibt im Exportkopf, der lokal entsteht.
> Wer sich selbst als Anwesenden nennen will, trägt sich in die Teilnehmer des Meetings ein - dort führt der Name eine Aufgabe und geht bewusst mit.
Es entsteht keine neue Datenklasse.

**[Fakt]** Ein Datenklassen-Manifest existiert im Code noch nicht; die Suche nach `PromptDataClass` und `dataClasses` bleibt im ganzen Baum ohne Treffer.
`PLAN-PRIVACY.md` ist ein Plan, kein gebautes Register.

**[Auflage]** Wenn das Register gebaut wird, sind die Modellquellen als ausgehende Verbindungen aufzunehmen. Das Betreiberprofil ist dort **nicht** als übertragene Klasse zu führen, seit der Verfassername den Prompt verlassen hat (siehe Nachtrag).
Sonst schweigt das Register über eine Verbindung, die es gibt: ein Download sendet keine Inhalte, aber IP, Modellnamen und Zeitpunkte an `huggingface.co`.

**Das Label "Ich"** wird weiterhin nur in der Anzeige ersetzt, nie in gespeicherten Werten.
Transkript-Revisionen bleiben unberührt (Append-only, `ARCHITECTURE.md:136`).

**[Auflage]** Die Auflösung des Labels läuft über genau eine Funktion.
Das ist die Naht, an der das spätere Bindungs-Paket `meeting.json` befragen kann, ohne dass zehn Aufrufstellen umlernen.
Heutiger Stand: `SpeakerDisplay.channelName` (`AppModel+Review.swift:638`) wird von vier Stellen gerufen, davon zwei für Sprecherlabels (`AppModel+Review.swift:543`, `RecordingView.swift:78`) und zwei für Dateinamen von Audiospuren aus `MediaAsset.Kind` (`AppModel+Export.swift:80,97`).
Diese beiden Verwendungen sind zu trennen, weil nur die erste je eine Person meint.

## Fehlerfälle

**Aufnahme hängt nie an Modellen.**
Ein fehlgeschlagener Download darf niemals ein Meeting kosten: aufgenommen und geschrieben wird, transkribiert wird später.

**Zustimmung verweigert.**
Aufnahme und Import funktionieren, Verarbeitung nicht. Der Zustand ist im Meeting sichtbar benannt, mit einem Weg, die Entscheidung zu ändern. Kein stiller Fehlschlag.

**Download scheitert** (kein Netz, Quelle nicht erreichbar).
Der Job bleibt wiederholbar und wird nicht verbraucht. Die Meldung nennt Quelle und Grund.

**Prüfsummenfehler.**
Installation bricht ab, nennt die Datei, verwendet nichts von dem, was ankam.

**Abgebrochener Download.**
**[Annahme]** Ob FluidAudios Downloader danach sauber wieder aufsetzt oder an Teilresten scheitert, ist ungeprüft. Das ist ein benanntes Risiko und eine Testaufgabe.

**Gleichzeitigkeit.**
Wizard-Installation und ein anlaufender Verarbeitungsjob dürfen nicht gleichzeitig auf denselben Downloader treffen.
Der Koordinator serialisiert. Dieselbe Fehlerklasse ist im ASR-Pfad bereits behandelt: dort wartet `waitForExistingInstallation` auf eine parallel angelaufene Installation, statt sofort zu werfen (`SpeechAnalyzerProvider.swift:265,275-277,334`).

## Tests

Alle ohne Netz, mit eingesetzten Attrappen für beide Installer:

- Zustimmung verweigert: es wird nichts angefragt.
- Zustimmung erteilt: genau ein Installationsversuch, nicht mehrere.
- Fehlschlag beim Laden: der Job bleibt wiederholbar und wird nicht verbraucht.
- Manifest mit einem veränderten Byte: die Installation wirft und nennt die Datei.
- Arbeitsfähigkeit je Sprache: Deutsch installiert, Englisch nicht, die Antwort unterscheidet beide.
- Zwei gleichzeitige Installationswünsche führen zu genau einem Download.
- Wizard: jede Seite überspringbar, Zustand nach Abschluss und nach Abbruch gesetzt, aus dem Menü erneut zu öffnen.
- ~~Betreiberprofil landet beim Einreihen im Auftrag, nicht erst beim Rendern.~~ Hinfällig: der Verfassername erreicht den Vorlagenlauf nicht mehr, siehe Nachtrag.
- Wächtertest: die Auflösung des Labels "Ich" läuft über genau eine Funktion.

## Offene Risiken

- ~~**[Annahme]** Wiederaufsetzen nach abgebrochenem Download, siehe oben.~~ **Erledigt am 2026-08-07:** gemessen. Ein Download wurde nach 132 MB widerrufen, sechs Teildateien blieben liegen, der zweite Versuch lief durch und ergab alle 36 Dateien.
- ~~**[Auflage]** Das Prüfsummen-Manifest braucht einen dokumentierten Weg, wie es erzeugt und bei einem bewussten Modellwechsel erneuert wird.~~ **Erledigt am 2026-08-07:** `scripts/generate-model-checksums.sh`. Der Weg steht im Kopf des Skripts, samt der Bedingung, dass das Verzeichnis aus genau einem Lauf des Installers stammen muss.
- Die gemeinsame Zustimmung bündelt eine Apple-Systemfunktion mit einer Drittverbindung zu `huggingface.co`. Für einen Nutzer, dessen Netz Dritthosts blockt oder protokolliert, ist das ein Unterschied, den nur der Text der Seite 4 sichtbar macht.

## Geprüfte Belege

Alle Dateiangaben oben wurden am 2026-08-07 im Arbeitsbaum bei Commit `ccc570a` gelesen.
FluidAudio-Angaben stammen aus dem Checkout unter `.build/DerivedData/SourcePackages/checkouts/FluidAudio` in der gepinnten Version 0.15.2.

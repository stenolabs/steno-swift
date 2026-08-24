# Code-Review der gesamten Codebasis - 20.08.2026

Vollstaendiger Review von StenoKit, macOS-App und iOS-App auf Stand `03193e5` (main).
Vorgehen: 8 Subsystem-Reviewer (Opus 5), danach je ein adversarialer Pruefer, der jeden Befund am Code widerlegen sollte.
Nur Befunde, deren Fehlerpfad der Pruefer selbst nachvollzogen hat, gelten als bestaetigt.
Die beiden schwersten Befunde (iOS-Routenwechsel, LocaleResolver) wurden zusaetzlich vom Driver stichprobenartig am Code verifiziert.

Ergebnis: **39 bestaetigte Befunde** (1 critical, 11 high, 27 medium), 3 unsichere, 1 widerlegte.

## Inhaltsuebersicht der bestaetigten Befunde

| Nr | Schwere | Subsystem | Stelle | Befund |
|---|---|---|---|---|
| 1 | critical | ios | `iOS/StenoiOSKit/Sources/StenoiOSAudio/MicrophoneCapture.swift:53` | AVAudioEngineConfigurationChange wird nirgends beobachtet - Aufnahme laeuft nach Routenwechsel als reine Stille weiter |
| 2 | high | audio-core | `StenoKit/Sources/StenoAudioCore/CaptureRecovery.swift:47` | Ein einziges fehlschlagendes Meeting bricht die gesamte Capture-Recovery ab |
| 3 | high | intelligence | `StenoKit/Sources/StenoIntelligence/OpenAICompatibleProvider.swift:233` | Umleitungen werden ungeprueft gefolgt: Transkript und API-Schluessel koennen an einen anderen als den gewaehlten Endpunkt gehen |
| 4 | high | intelligence | `App/Sources/AppModel.swift:397` | macOS leitet die Transkriptionssprache aus `Locale.current` ab und kann eine abgeleitete Sprache nicht von einer gewaehlten unterscheiden |
| 5 | high | ios | `iOS/App/Sources/AppModel.swift:457` | Modellinstallation waehrend laufender Aufnahme verliert den Requeue der fehlgeschlagenen ASR-Jobs endgueltig |
| 6 | high | library | `StenoKit/Sources/StenoLibrary/IdentityStore.swift:341` | Personendokument: Lesen ausserhalb der Sperre, Schreiben des ganzen Dokuments -> Stimm-Evidenz geht still verloren |
| 7 | high | macos-app | `App/Sources/AppModel.swift:748` | Sprachwechsel während laufendem Aufnahmestart startet die Pipeline neu und löscht die gerade entstehende Aufnahme |
| 8 | high | macos-app | `App/Sources/AppModel.swift:1004` | Nach einem fehlgeschlagenen Stopp wandert das Live-Transkript der alten Aufnahme in die Revision der nächsten |
| 9 | high | pipeline | `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:201` | cancel() liest den Job-Status vor einem Suspension-Point und umgeht dadurch die cancellationTooLate-Sperre |
| 10 | high | speech | `StenoKit/Sources/StenoTranscription/LocaleResolver.swift:33` | Explizit gewaehlte Transkriptionssprache faellt still auf Locale.current zurueck (Regel 4) |
| 11 | high | speech | `StenoKit/Sources/StenoIdentity/IdentityReviewFlow.swift:269` | Review loescht Stimm-Evidenz statt sie auszunehmen und meldet ausgenommene Proben als Eigentuemer |
| 12 | high | speech | `StenoKit/Sources/StenoIdentity/IdentityReviewFlow.swift:335` | rebuildHardNegatives leitet Hard Negatives aus ausgenommener Evidenz ab |
| 13 | medium | audio-core | `StenoKit/Sources/StenoAudioCore/RecordingSession.swift:319` | Capture-Original wird gelöscht, bevor die Bibliothekskopie dauerhaft auf der Platte liegt |
| 14 | medium | audio-core | `StenoKit/Sources/StenoAudioCore/DiskSpaceChecker.swift:17` | Vollständig volle Platte wird als "Kapazität nicht ermittelbar" behandelt, der Plattenwächter schluckt das still |
| 15 | medium | audio-core | `StenoKit/Sources/StenoAudioCore/TrackContinuity.swift:186` | Unbegrenzter Stille-Schub in den 64-Slot-Ring, dessen Überlauf die ganze Aufnahme beendet |
| 16 | medium | exchange | `StenoKit/Sources/StenoExchange/LegacyImporter.swift:188` | Doppelte oder fehlende IDs in folders.json/config.json lassen den Legacy-Import hart abstuerzen |
| 17 | medium | exchange | `StenoKit/Sources/StenoExchange/LegacyImporter.swift:105` | Eine einzige beschaedigte Legacy-Beidatei bricht den gesamten Import ab, dauerhaft |
| 18 | medium | exchange | `StenoKit/Sources/StenoExchange/MeetingTransferArchiveReader.swift:393` | validateOwnedSnapshot verschluckt den Validierungsfehler und gibt keinen Cleanup-Handle heraus |
| 19 | medium | exchange | `StenoKit/Sources/StenoExchange/LegacyMeetingPreparation.swift:190` | Mehrdeutige Cluster-Schluessel aus Legacy-Sprecherdaten koennen den Import abstuerzen lassen |
| 20 | medium | intelligence | `StenoKit/Sources/StenoIntelligence/OpenAICompatibleProvider.swift:186` | Der response_format-Rueckfall feuert bei jedem 4xx und schickt das komplette Transkript ein zweites Mal |
| 21 | medium | ios | `iOS/StenoiOSKit/Sources/StenoiOSAudio/MicrophoneCapture.swift:57` | Format-Cache wird nie invalidiert: zweiter Metering-Lauf installiert den Tap mit dem Format des alten Geraets |
| 22 | medium | ios | `iOS/App/Sources/AudioReadinessView.swift:316` | Metering wird beim Verlassen des Bildschirms nie gestoppt - zweiter Tap auf dem Input-Node und dauerhaft aktive Audiosession |
| 23 | medium | ios | `iOS/App/Sources/RecordingModel.swift:553` | Unterbrechungen im Zustand .preparing werden verworfen - die App meldet danach eine Aufnahme, die nicht laeuft |
| 24 | medium | library | `StenoKit/Sources/StenoLibrary/Library.swift:344` | Meeting-Mutatoren lesen ausserhalb der Sperre und schreiben das ganze meeting.json zurueck |
| 25 | medium | library | `StenoKit/Sources/StenoLibrary/MeetingNotesEditingSession.swift:69` | Nach fehlgeschlagenem Laden ueberschreibt die erste Eingabe die vorhandene Notiz |
| 26 | medium | library | `StenoKit/Sources/StenoLibrary/FolderStore.swift:402` | FolderStore schreibt folders.json ganz ohne Bibliothekssperre |
| 27 | medium | library | `StenoKit/Sources/StenoLibrary/JobStore.swift:465` | claimNext und transition laufen ohne Bibliothekssperre - derselbe Job kann zweimal beansprucht werden |
| 28 | medium | library | `StenoKit/Sources/StenoLibrary/RevisionStore.swift:392` | RevisionAppendRecovery spielt eine liegengebliebene Absicht bedingungslos ueber einen neueren Zeiger |
| 29 | medium | macos-app | `App/Sources/AppModel.swift:1005` | Scheitert der Stopp, bleibt das Meeting dauerhaft auf Status `.recording` und ohne finalASR-Job |
| 30 | medium | macos-app | `App/Sources/AppModel+Review.swift:286` | Herausgeschnittener Audio-Ausschnitt bleibt im Temp-Verzeichnis liegen, wenn der Player nicht initialisiert werden kann |
| 31 | medium | macos-app | `App/Sources/AppModel+Review.swift:301` | Wiedergabefehler aus der Transkriptliste erreichen den Nutzer nie |
| 32 | medium | macos-app | `App/Sources/AppModel.swift:717` | Die Pipeline läuft mit einer anderen Transkriptionssprache als die Oberfläche anzeigt, und der Nutzer kann das nicht korrigieren |
| 33 | medium | pipeline | `StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:196` | cancel() wartet unbegrenzt, wenn handle() den Statuswechsel nicht persistieren kann |
| 34 | medium | pipeline | `StenoKit/Sources/StenoPipeline/MeetingReviewController.swift:103` | Eine Review-Aktion wird in drei unabhaengigen Transaktionen persistiert und kann halb geschrieben liegenbleiben |
| 35 | medium | pipeline | `StenoKit/Sources/StenoPipeline/PersonVoiceSamples.swift:275` | Hoerprobe waehlt die Spur ueber die Spurart statt ueber die Asset-Kennung des Laufs |
| 36 | medium | pipeline | `StenoKit/Sources/StenoPipeline/MeetingDiarizationRequest.swift:247` | Unbegrenzte Rekursion beim Zurueckverfolgen der Lauf-Kette (Stack Overflow bei beschaedigtem Artefakt) |
| 37 | medium | speech | `StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift:148` | Fehlgeschlagene oder abgebrochene Installation legt eine intakte, geprueft installierte Modellsammlung lahm |
| 38 | medium | speech | `StenoKit/Sources/StenoDiarization/SortformerEmbeddingExtraction.swift:81` | Maske des letzten, kuerzeren Audiofensters ist gegenueber dem Audio zeitlich verschoben |
| 39 | medium | speech | `StenoKit/Sources/StenoIdentity/SpeakerSuggestionEngine.swift:338` | Single-Linkage-Verschmelzung kann zwei Stimmen zu einem unmarkierten Cluster verketten, der danach benannt werden darf |

## Bestaetigte Befunde im Detail

### 1. [CRITICAL] AVAudioEngineConfigurationChange wird nirgends beobachtet - Aufnahme laeuft nach Routenwechsel als reine Stille weiter

`iOS/StenoiOSKit/Sources/StenoiOSAudio/MicrophoneCapture.swift:53` - Subsystem ios, Kategorie correctness/regel-1

Beobachtet werden ausschliesslich drei AVAudioSession-Notifications (AudioSessionController.startObservingIfNeeded, Zeilen 104-144: interruption, routeChange, mediaServicesWereReset). `AVAudioEngineConfigurationChange` wird im ganzen Repository nicht referenziert (geprueft per grep ueber iOS/, StenoKit/Sources, App/Sources - kein Treffer). Genau diese Notification schickt iOS, wenn sich Kanalzahl oder Abtastrate der Ein-/Ausgabe-Hardware aendert: die Engine stoppt und deinitialisiert sich dabei selbst.

Fehlerpfad: Aufnahme laeuft ueber das eingebaute Mikrofon. Nach 12 Minuten steckt der Nutzer ein Kabel-Headset oder ein USB-Interface an. Das ergibt `routeChange` mit `.newDeviceAvailable`, und `AudioRouteChangeReason.endsCurrentCapture` stuft genau diesen Grund ausdruecklich als *nicht* aufnahmebeendend ein (AudioSessionEvents.swift:88-96). RecordingModel.swift:545 verwirft das Ereignis daher mit `continue`. Die AVAudioEngine hat sich zu diesem Zeitpunkt aber bereits gestoppt; der Tap aus `installTap` liefert keinen Buffer mehr, und weder MicrophoneCapture noch RecordingModel starten sie neu. `MicrophoneCapture.isRunning` bleibt `true`, `RecordingSession.state` bleibt `.recording`, also greift auch `tick()`s Terminal-Pruefung (RecordingModel.swift:500) nicht.

Folge: `TrackContinuity.detectStall` (StenoAudioCore/TrackContinuity.swift:133-142, Stall-Timeout 2 s) erklaert die Spur fuer haengend und `fillSilence` schreibt ab da digitale Stille bis zum Ende der Besprechung. Roter Punkt und Laufzeit laufen weiter. Einzige Ruecksicht ist der SilenceMonitor, der nach 20 s "Nothing heard" meldet - eine Warnung, keine Rettung. Das unersetzliche Artefakt ist ab dem Kabelanschluss wertlos, ohne dass irgendetwas die Aufnahme beendet oder als gescheitert markiert.

```swift
AudioSessionEvents.swift:88-96
    public var endsCurrentCapture: Bool {
        switch self {
        case .oldDeviceUnavailable, .noSuitableRouteForCategory, .categoryChange: true
        case .newDeviceAvailable, .override, .wakeFromSleep,
             .routeConfigurationChange, .unknown: false
        }
    }

RecordingModel.swift:541-546
                case .routeChanged(let reason) where reason.endsCurrentCapture:
                    await self.handleInterruption("input device changed")
                ...
                case .routeChanged, .interruptionEnded:
                    continue

MicrophoneCapture.swift:53-74 - installiert den Tap einmal, kein Observer, kein Neustart der Engine.
```

**Korrekturskizze:** In MicrophoneCapture (oder AudioSessionController) `AVAudioEngine.configurationChangeNotification` beobachten und als eigenes Ereignis melden. Zwei vertretbare Reaktionen, aber eine davon muss kommen: entweder Engine neu vorbereiten (`prepare()` erneut, Format neu lesen, Tap neu installieren, `start()`) und den Bruch ueber `AudioSourceEvent.unavailable/.available` in TrackContinuity als echte Luecke protokollieren - oder das Ereignis wie `endsCurrentCapture` behandeln und die Aufnahme sauber beenden. Stillschweigend weiterschreiben darf sie nicht.

**Adversariale Pruefung:** Am Code nachvollzogen. `AVAudioEngineConfigurationChange` wird nur auf dem Mac beobachtet (StenoKit/Sources/StenoMacAudio/MicRecorder.swift:671); in iOS/ gibt es keinen Treffer. MicrophoneCapture.swift:53-81 installiert den Tap einmal und startet die Engine nie neu; `stop()` ist der einzige Weg aus `isRunning`. Der Verwerfungspfad stimmt: AudioSessionEvents.swift:88-96 stuft `.newDeviceAvailable` als nicht aufnahmebeendend ein, RecordingModel.swift:545 macht `continue`. Es greift auch keine Absicherung tiefer im Kern: `MicrophoneCapture+AudioSource.swift:11` uebernimmt nur `track`, also nutzt iOS die Default-Implementierung von `AudioSource.start(bufferHandler:eventHandler:)` (StenoAudioCore/AudioSource.swift:22-28) und meldet nie `.unavailable`. Damit bleibt nur `TrackContinuity.detectStall` (TrackContinuity.swift:137-143), das den Zustand auf `sourceStalled` setzt und ueber `tick`/`fillSilence` (121-127, 181-195) Stille schreibt. RecordingSession wird davon nicht terminal - `state = .failed` entsteht nur ueber Disk-, Writer- oder Ring-Overflow-Pfade (RecordingSession.swift:325ff, writerRingDidOverflow) -, also greift RecordingModel.swift:500 nicht. Einziger Hinweis bleibt der SilenceMonitor (RecordingView.swift:109, RecordingStrip.swift:31). Nicht am Code pruefbar ist nur die Betriebssystem-Annahme, dass ein Kabel-/USB-Anschluss die Engine tatsaechlich stoppt; dass das Team es auf dem Mac ausdruecklich behandelt, stuetzt sie. Schwere bleibt kritisch: stiller Totalverlust des einzigen unersetzlichen Artefakts (Regel 1).

### 2. [HIGH] Ein einziges fehlschlagendes Meeting bricht die gesamte Capture-Recovery ab

`StenoKit/Sources/StenoAudioCore/CaptureRecovery.swift:47` - Subsystem audio-core, Kategorie data-loss

In der Schleife über alle `interrupted`-Meetings wird nur `LibraryError.duplicateProvenance` abgefangen. Jeder andere Fehler aus `library.registerMediaAsset` (I/O-Fehler beim `copyItem`, volle Platte, `meetingNotFound` bei kaputter meeting.json, Schreibfehler der Asset-Metadaten) propagiert aus `run` heraus und beendet die Adoption für ALLE noch nicht bearbeiteten Meetings. Konkreter Fehlerpfad: nach zwei harten Abstürzen liegen Meeting A (alphabetisch/Reihenfolge zuerst) und Meeting B beide auf `interrupted` mit unregistrierten CAF-Dateien. As Meeting A ist die meeting.json beschädigt -> `registerMediaAsset` wirft `LibraryError.meetingNotFound` -> `run` wirft -> Meeting B wird nie erreicht. Der Aufrufer schluckt das mit `_ = try? await CaptureRecovery.run(...)` (App/Sources/AppModel.swift:689, iOS/App/Sources/AppModel.swift:318), es gibt keine Meldung. Beim nächsten Start wiederholt sich derselbe Fehler an A, also wird B dauerhaft nie adoptiert: die Aufnahme liegt unsichtbar als CAF im capture-Ordner, ohne Asset, ohne finalASR-Job, das Meeting bleibt leer. Das trifft genau das unersetzliche Artefakt. Zusätzlich behauptet der Kommentar in Zeile 38-39, ein unlesbares Prefix werde "gemeldet" - im Code passiert nichts dergleichen, `continue` schluckt es still.

```swift
do {
    _ = try await library.registerMediaAsset(
        for: meeting.id,
        sourceURL: file,
        kind: track == .microphone ? .micTrack : .systemTrack,
        sampleRate: sampleRate,
        duration: duration
    )
} catch LibraryError.duplicateProvenance {
    // Frühere Adoption wurde zwischen Registrierung und
    // Aufräumen unterbrochen: Asset existiert schon.
}
```

**Korrekturskizze:** Den Rumpf pro Meeting (und pro Datei) in ein eigenes `do/catch` kapseln, das jeden Fehler auffängt, das betroffene Meeting überspringt und in einer Liste `failedMeetings: [(MeetingID, Error)]` sammelt. Diese Liste zusätzlich zu `[AdoptedMeeting]` zurückgeben, damit der Aufrufer sie melden kann, statt `try?` blind über alles zu legen. Beim Datei-Loop gilt dasselbe: ein unlesbares oder nicht registrierbares Prefix darf die restlichen Spuren desselben Meetings nicht mitreißen.

**Adversariale Pruefung:** Am Code nachvollzogen: In CaptureRecovery.swift:47-58 faengt das do/catch ausschliesslich LibraryError.duplicateProvenance. Jeder andere Fehler aus library.registerMediaAsset propagiert aus der for-Schleife (Zeile 23-82) heraus und beendet run() fuer alle noch nicht bearbeiteten Meetings. Realistische Ausloeser in Library.swift:429-441: copyItem schlaegt fehl (volle Platte, I/O-Fehler, fehlendes media-Verzeichnis, bereits vorhandenes Ziel) oder JSONDocumentStore.write der Asset-Metadaten schlaegt fehl. Beide Aufrufer schlucken das still: App/Sources/AppModel.swift:689 und iOS/App/Sources/AppModel.swift:318 verwenden '_ = try? await CaptureRecovery.run(...)', ohne report(). Kein Test in StenoKit/Tests/StenoAudioCoreTests/CaptureRecoveryTests.swift deckt Fehlerisolierung pro Meeting ab. Zwei Korrekturen am Befund: (a) der konkret genannte Pfad 'kaputte meeting.json -> LibraryError.meetingNotFound' ist so nicht erreichbar, weil listMeetings (Library.swift:146-168) beim Lesen einer defekten meeting.json selbst wirft - dann bricht die Recovery sogar noch frueher und fuer wirklich alle Meetings ab, also derselbe Defekt in staerkerer Form; (b) die Aufnahme wird nicht zerstoert, removeItem (Zeile 59) laeuft erst nach erfolgreicher Registrierung - die CAF-Datei bleibt liegen, ist aber fuer den Nutzer unsichtbar und wird ohne Codefix nie adoptiert. Zusaetzlich zutreffend: der Kommentar Zeile 38-39 behauptet eine Meldung, die es im Code nicht gibt. Schwere 'high' bleibt wegen Regel 1 (unersetzliches Artefakt bleibt dauerhaft unzugaenglich, ohne jede Meldung).

### 3. [HIGH] Umleitungen werden ungeprueft gefolgt: Transkript und API-Schluessel koennen an einen anderen als den gewaehlten Endpunkt gehen

`StenoKit/Sources/StenoIntelligence/OpenAICompatibleProvider.swift:233` - Subsystem intelligence, Kategorie security-privacy

Beide Netzaufrufe des Providers (`probe` Zeile 114 und `completion` Zeile 233) laufen ueber `URLSession` ohne Delegate; der Standard ist `.shared` (Zeile 51). URLSession folgt HTTP-Umleitungen automatisch (bis zu 20) und uebernimmt dabei die Header der urspruenglichen Anfrage, inklusive `Authorization`. `TextModelEndpointPolicy` prueft ausschliesslich `endpoint.baseURL` (TextModelEndpointPolicy.swift:50-53) - Schema, eingebettete Anmeldedaten, Query, Fragment und die https/lokal-Regel gelten also nur fuer die erste Anfrage, nicht fuer das Umleitungsziel. Fehlerpfad: Der Nutzer konfiguriert den vorgeschlagenen lokalen Endpunkt `http://localhost:1234/v1` (TextModelSettingsView.swift:163) oder einen LAN-Endpunkt, den die Policy als `localPlaintext` erlaubt (TextModelEndpointPolicy.swift:41-44, u.a. 10/8, 192.168/16, 100.64/10). Antwortet dieser Host - kompromittiert, falsch konfiguriert oder per MITM auf der unverschluesselten Verbindung - auf den POST `/v1/chat/completions` mit `307 Location: https://fremder-host.example/v1/chat/completions`, sendet URLSession denselben Body erneut dorthin. Der Body enthaelt das vollstaendige Transkript mit Sprechernamen, die Teilnehmerliste und die Benutzernotizen (requestBody, Zeile 156-167), dazu den Bearer-Token (Zeile 221). Das verletzt Regel 6 (nur der ausdruecklich gewaehlte Endpunkt darf Netzverkehr sehen) und macht `ExternalModelNotice` unwahr, das dem Nutzer genau einen Zielhost nennt (ExternalModelNotice.swift:16: `endpoint.baseURL.host()`). Eine Gegenmassnahme existiert nirgends im Repo: `willPerformHTTPRedirection` kommt in keiner Quelldatei vor.

```swift
Zeile 51: `session: URLSession = .shared`
Zeile 216-222: `var urlRequest = URLRequest(url: url, timeoutInterval: 300)` ... `urlRequest.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")`
Zeile 233: `(data, response) = try await session.data(for: urlRequest)`
TextModelEndpointPolicy.swift:50-53: `public static func validate(_ endpoint: TextModelEndpoint) throws -> TextModelEndpoint { _ = try transportSecurity(for: endpoint.baseURL); return endpoint }`
```

**Korrekturskizze:** Den Provider mit einer eigenen `URLSession` plus `URLSessionTaskDelegate` bauen und in `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` `nil` zurueckgeben (Umleitung nicht folgen) bzw. das Ziel erneut durch `TextModelEndpointPolicy.transportSecurity(for:)` schicken und nur denselben Host/dasselbe Schema zulassen. Alternativ die Antwort mit 3xx als `OpenAICompatibleProviderError.invalidResponse` behandeln. Gleiches fuer `probe`.

**Adversariale Pruefung:** Am Code nachvollzogen: OpenAICompatibleProvider haelt `session: URLSession = .shared` (Zeile 51) und ruft `session.data(for:)` ohne Delegate auf (probe Zeile 114, completion Zeile 233). Beide App-Seiten bauen den Provider ohne eigene Session: App/Sources/TextModelSettings.swift:397, App/Sources/TextModelSettingsView.swift:125, iOS/App/Sources/TextModelSettings.swift:285, iOS/App/Sources/TextModelSettingsView.swift:108 - alle nur mit `endpoint:` und `resolvingSecret:`. `grep -rn willPerformHTTPRedirection` ueber App, iOS/App, iOS/StenoiOSKit und StenoKit liefert null Treffer, es gibt also nirgends eine Umleitungsrichtlinie. TextModelEndpointPolicy.validate (Zeile 50-53) prueft tatsaechlich nur `endpoint.baseURL`; Schema-, Credential-, Query- und http/lokal-Regel greifen damit ausschliesslich fuer die erste Anfrage. Die http-Freigabe fuer LAN-Adressen (Zeile 41-44, 86-93: 10/8, 172.16/12, 192.168/16, 169.254/16, 100.64/10, .local) und die vorbelegte URL `http://localhost:1234/v1` (TextModelSettingsView.swift:163) machen den unverschluesselten Fall zum Normalfall. ExternalModelNotice.swift:16 nennt dem Nutzer genau einen Zielhost. Einschraenkung, die ich nicht am Code belegen kann: dass URLSession ohne Delegate Umleitungen automatisch folgt und bei 307/308 Methode und Body beibehaelt, ist dokumentiertes Foundation-Verhalten, kein Code in diesem Repo; ob CFNetwork den manuell gesetzten `Authorization`-Header ueber eine Hostgrenze hinweg mitschickt, habe ich nicht empirisch geprueft - der Transkript-Body geht aber in jedem Fall mit. Der Pfad setzt ausserdem einen feindlichen oder kompromittierten Endpunkt bzw. einen MITM auf der erlaubten Klartextverbindung voraus. Trotzdem hoch: Regel 6 sagt, nur der ausdruecklich gewaehlte Endpunkt darf den Verkehr sehen, und dagegen gibt es hier keinerlei Absicherung.

### 4. [HIGH] macOS leitet die Transkriptionssprache aus `Locale.current` ab und kann eine abgeleitete Sprache nicht von einer gewaehlten unterscheiden

`App/Sources/AppModel.swift:397` - Subsystem intelligence, Kategorie rule-violation

`selectedLanguageID` faellt ohne gespeicherte Wahl auf `Locale.current.identifier` zurueck. Dieser Wert fliesst ueber `locale` (Zeile 398) direkt in den Transkriptionspfad: er wird der Pipeline als Erkennersprache uebergeben (Zeile 656 `locale: locale`) und bestimmt, welche Sprachassets installiert und reserviert werden (Zeile 507 ff., `installModels(for: locale)`). Fehlerpfad, exakt der in AGENTS.md beschriebene: Ein auf Englisch gestellter Mac in Deutschland meldet `Locale.current.identifier == "en_DE"`. Beim Start findet `loadAvailableLocales` (Zeile 717-736) `en_DE` nicht in `availableLocales` und laesst `LocaleResolver.select` aufloesen; dort scheitert der exakte Treffer, danach der Regionstreffer (kein `en_DE` in der Liste), und es greift `supported.first { $0.language.languageCode == "en" }` (LocaleResolver.swift:69-71) - Ergebnis `en_US`. Deutsche Rede wird als Englisch transkribiert, mit plausibel aussehendem Ergebnis und ohne Fehlermeldung. Die Onboarding-Seite zeigt zwar einen Picker, aber mit dieser Ableitung vorbelegt; ein Klick auf "Continue" uebernimmt sie. Anders als iOS fuehrt die Mac-App keinen getrennten Beleg dafuer, ob die Sprache je gewaehlt wurde: `wasChosenExplicitly`/`languageWasChosenExplicitly` existiert ausschliesslich unter `iOS/App/Sources` (TranscriptionLanguage.swift:58, RecordingModel.swift:136), auf dem Mac gibt es weder das Flag noch die daran haengende Warnung (RecordingView.swift:169) noch die Regel, `MeetingSourceLocale` nur bei ausdruecklicher Wahl zu setzen (RecordingModel.swift:225-234). Damit steht `Locale.current` im Transkriptionspfad und eine abgeleitete Sprache ist von einer gewaehlten nicht unterscheidbar - Regel 4.

```swift
App/Sources/AppModel.swift:395-398:
```
private(set) var selectedLanguageID: String = UserDefaults.standard
    .string(forKey: AppModel.languageDefaultsKey)
    ?? Locale.current.identifier
private var locale: Locale { Locale(identifier: selectedLanguageID) }
```
Gegenstueck auf iOS, TranscriptionLanguage.swift:39-41: `?? Locale.transcriptionAutomatic.identifier` plus `private(set) var wasChosenExplicitly = UserDefaults.standard.bool(forKey: ...explicitChoiceKey)`
```

**Korrekturskizze:** Denselben Mechanismus wie auf iOS uebernehmen: als Vorbelegung `Locale.transcriptionAutomatic` statt `Locale.current.identifier` verwenden, die aufgeloeste Sprache nur als nicht persistierten Fallback fuehren, einen eigenen Schluessel `steno.transcription.language.chosen` setzen, sobald `setLanguage` gerufen wird, und die Aufnahmeansicht warnen lassen, solange keine ausdrueckliche Wahl vorliegt.

**Adversariale Pruefung:** Vollstaendig am Code nachvollzogen. App/Sources/AppModel.swift:395-398: `selectedLanguageID` faellt ohne gespeicherten Wert auf `Locale.current.identifier` zurueck, `locale` leitet direkt daraus ab und geht als `locale:` in `startPipeline` (Zeile ~656) sowie in `installModels(for: locale)`. `loadAvailableLocales` (Zeile 717-736) ersetzt einen nicht unterstuetzten Identifier ueber `LocaleResolver.select`; dort greift nach exaktem und Regionstreffer die Sprachregel `supported.first { $0.language.languageCode == requestedLanguage }` (LocaleResolver.swift:71-73), aus `en_DE` wird also `en_US`. Der so abgeleitete Wert wird nur im Speicher gesetzt - `UserDefaults` beschreibt ausschliesslich `setLanguage` (Zeile 747-754), und die steigt bei `identifier != selectedLanguageID` sofort aus. Waehlt der Nutzer im Onboarding-Picker (OnboardingView.swift:110-132) also genau den vorbelegten Wert, wird nichts gespeichert und nichts als Wahl vermerkt. Der Gegenbeleg stimmt ebenfalls: `grep -rn wasChosenExplicitly|languageWasChosenExplicitly|MeetingSourceLocale` findet Treffer nur unter iOS/App (TranscriptionLanguage.swift:58/128, RecordingModel.swift:136/225-234) und deren Tests - auf dem Mac existiert weder das Kennzeichen noch die daran haengende Warnung noch die Regel, `MeetingSourceLocale` nur bei ausdruecklicher Wahl zu setzen. Damit steht `Locale.current` im Transkriptionspfad und eine abgeleitete Sprache ist von einer gewaehlten nicht unterscheidbar. Schwere von medium auf high angehoben: das ist woertlich der in AGENTS.md beschriebene Fall (`en_DE`, deutsche Rede englisch transkribiert, plausibles Ergebnis ohne Fehlermeldung) und damit ein Verstoss gegen Regel 4. Mildernd, aber nicht entkraeftend: die Onboarding-Seite zeigt die Sprache vor dem Modelldownload sichtbar an.

### 5. [HIGH] Modellinstallation waehrend laufender Aufnahme verliert den Requeue der fehlgeschlagenen ASR-Jobs endgueltig

`iOS/App/Sources/AppModel.swift:457` - Subsystem ios, Kategorie correctness/datenverlust

`allowAndInstallSpeechModel` laedt zuerst (langlaufend) und betritt erst danach `runtimeChanges.run`. Dort bricht `guard let detached = self.detachRuntimeIfIdle() else { return }` ab, sobald eine Aufnahme laeuft - und setzt dabei, anders als `restartPipelineAfterConfigurationChange` (Zeilen 360-365), *kein* `pendingRuntimeRestartAfterRecording = true`. Der Nachholpfad existiert also, wird hier aber nicht benutzt. `allowAndInstallDiarizationModels` hat denselben Defekt in Zeile 559.

Erreichbar ist das, weil `canStartRecording` (Zeile 510-516) `models.isInstalling` nicht prueft - nur `diarizationModels.isInstalling`. Konkret: Nutzer tippt in Audio readiness auf "Allow and install", der Download laeuft mehrere Minuten, waehrenddessen tippt er auf Record (der Knopf ist aktiv). Download endet, Aufnahme laeuft noch -> die Closure kehrt wirkungslos zurueck.

Folge: `MissingSpeechModelJobRetrier.requeue` laeuft nie. Die vorher mit "The speech model for X is not installed yet" gescheiterten `finalASR`-Jobs bleiben `.failed`. `startPipeline` holt sie beim naechsten Start nicht zurueck: `JobStore.recoverAtLaunch` (JobStore.swift:372-378) transitioniert ausschliesslich `.running`-Jobs. Und es gibt keinen zweiten Ausloeser mehr, denn AudioReadinessView.swift:156 blendet den "Allow and install"-Knopf aus, sobald `models.isReady == true` ist; Consent widerrufen deinstalliert nichts und aendert `isReady` nicht. Die betroffenen Besprechungen bleiben dauerhaft ohne Transkript - waehrend MeetingDetailView.swift:376 dem Nutzer "Steno retries automatically" zusichert.

```swift
AppModel.swift:447-461 (Sprachmodell)
        await runtimeChanges.run { [weak self] in
            ...
            guard let detached = self.detachRuntimeIfIdle() else { return }

zum Vergleich AppModel.swift:360-365
        guard let detached = detachRuntimeIfIdle() else {
            if recording.isActive {
                pendingRuntimeRestartAfterRecording = true
            }
            return
        }

AppModel.swift:510-516
    var canStartRecording: Bool {
        recording.canRecord
            && !diarizationModels.isInstalling   // models.isInstalling fehlt
            ...
```

**Korrekturskizze:** In beiden Install-Closures denselben Nachholpfad benutzen wie `restartPipelineAfterConfigurationChange`: bei aktiver Aufnahme eine Absicht vormerken (eigenes Flag, das Locale bzw. die Art des Requeues mittraegt) und sie in `recordingDidBecomeIdle()` ausfuehren. Zusaetzlich entweder `models.isInstalling` in `canStartRecording` aufnehmen oder - passender zu Regel 1 - `diarizationModels.isInstalling` dort streichen und stattdessen den Nachholpfad tragen lassen.

**Adversariale Pruefung:** Erreichbarkeit belegt: `canStartRecording` (AppModel.swift:510-516) prueft `diarizationModels.isInstalling`, aber nicht `models.isInstalling`; RecordingView.swift:331 haengt genau daran. `IOSModelInstallationState.allowAndInstall` (IOSModelInstallationState.swift:61-62) prueft `recordingIsActive` nur beim Eintritt, nicht nach dem Download. Waehrend des Downloads ist `runtimeChanges.isRunning` noch false, weil `runtimeChanges.run` erst nach `await models.allowAndInstall(...)` betreten wird (AppModel.swift:441-447). Danach bricht `guard let detached = self.detachRuntimeIfIdle() else { return }` (457) ohne `pendingRuntimeRestartAfterRecording` ab, und `MissingSpeechModelJobRetrier.requeue` (465) laeuft nie. Dass es kein zweites Sicherheitsnetz gibt, habe ich nachgeprueft: `JobStore.recoverAtLaunch` (StenoLibrary/JobStore.swift:372-378) holt ausschliesslich `.running`-Jobs zurueck, `requeueFailedJobs` hat genau zwei Aufrufer (die beiden Retrier), und in iOS/App/Sources gibt es keinen manuellen Retry fuer finalASR. Der Knopf verschwindet bei `isReady == true` (AudioReadinessView.swift:156), die Zusicherung 'Steno retries automatically' steht wortwoertlich in MeetingDetailView.swift:376. Zwei Einschraenkungen: (a) der vorgeschlagene Vergleichspfad heilt es nicht vollstaendig - `restartPipelineAfterConfigurationChange` startet nur die Pipeline neu und requeued nichts; (b) die Diarisierungs-Variante (559) ist ueber dieselbe Route kaum erreichbar, weil `canStartRecording` `diarizationModels.isInstalling` sehr wohl prueft - dort bleibt nur ein winziges Fenster zwischen dem `defer { isInstalling = false }` und dem Setzen von `runtimeChanges.isRunning`. Der Sprachmodell-Pfad allein traegt die hohe Schwere: dauerhaft transkriptloses Meeting bei gegenteiliger Zusicherung.

### 6. [HIGH] Personendokument: Lesen ausserhalb der Sperre, Schreiben des ganzen Dokuments -> Stimm-Evidenz geht still verloren

`StenoKit/Sources/StenoLibrary/IdentityStore.swift:341` - Subsystem library, Kategorie concurrency/data-loss

Jeder Mutator liest `persons.json` ungesperrt (`listPersons()` in createPerson:73, renamePerson:91, setPersonEmail:116, setPersonOrganization:138, mergePersons:214, deletePerson:268, restorePerson:297, updatePerson:320) und schreibt danach das VOLLSTAENDIGE Dokument innerhalb von `withExclusiveAccess`. Die Sperre umschliesst nur den Schreibvorgang, nicht das Read-Modify-Write. Die Actor-Isolation hilft nicht, weil `IdentityStore` an jedem Aufrufort neu erzeugt wird (MeetingReviewController.swift:42, PipelineCoordinator.swift:929, MeetingTransferExportService.swift:360, AppModel+People.swift:42/96/121/195, AppModel+Review.swift:47/59/75/167) - es gibt also ein Dutzend unabhaengiger Actor-Instanzen ohne gemeinsame Serialisierung. Konkreter Fehlerpfad: Instanz A (AppModel+Review.swift:59, setPersonEmail) liest P0. Parallel schreibt Instanz B aus dem Sprecher-Review `replacePersons(P0 + neuer SpeakerPrototype + neues HardNegative)` (MeetingReviewController.swift:103) und gibt die Sperre frei. Danach nimmt A die Sperre und schreibt P0 mit gesetzter E-Mail zurueck. Der Prototyp und das Hard Negative sind geloescht - nicht `excludedAt`-markiert, sondern weg. Das verletzt die Grundregel, dass Stimm-Evidenz ausgenommen und nie geloescht wird, und der Verlust ist unsichtbar: spaeter bleibt nur eine Erkennung ohne erkennbaren Grund aus. `replacePersons` (Zeile 148) verschaerft das, weil es ohne jede Erwartungspruefung einen moeglicherweise Minuten alten Snapshot ueber den aktuellen Stand legt.

```swift
private func write(_ persons: [Person]) throws {
    try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
        try JSONDocumentStore.write(PersonsDocument(persons: persons), to: layout.persons)
    }
}
// deletePerson:268  var persons = try listPersons()   <- ausserhalb der Sperre
// replacePersons:148 public func replacePersons(_ persons: [Person]) throws { try Self.validateUniqueNames(persons); try write(persons) }
```

**Korrekturskizze:** Lesen und Schreiben in eine Transaktion ziehen: `withExclusiveTransaction { _ in let persons = try readDocument(); ...; try JSONDocumentStore.write(...) }`, analog zu `Library.updateMeetingStatus(_:to:transaction:)`. Zusaetzlich `replacePersons` durch eine Variante mit erwartetem Vorzustand (Compare-and-Set auf einer Dokument-Revision) ersetzen, damit ein veralteter Review-Snapshot nicht gewinnt, sondern scheitert.

**Adversariale Pruefung:** Am Code nachvollzogen. `IdentityStore.write` (IdentityStore.swift:341-348) nimmt die Sperre nur um `JSONDocumentStore.write`; jeder Mutator liest davor ungesperrt (`listPersons()` in 73, 91, 116, 138, 214, 268, 297, 320). `replacePersons` (148) hat keinerlei Erwartungspruefung. Die Actor-Isolation traegt nicht: `IdentityStore(layout:)` wird an jedem Aufrufort neu erzeugt (MeetingReviewController.swift:42, AppModel+People.swift:42/96/121/195, AppModel+Review.swift:47/59/75/167, LegacyImporter.swift:280) - bestaetigt per grep, es gibt keine geteilte Instanz.

Der erreichbare Pfad braucht nicht einmal ein Thread-Rennen: MeetingDetailView.swift:44 haelt `review: MeetingReviewData` als @State, und die Aktualisierungsschleife bricht ab, sobald ein Transkript da und kein Job offen ist (MeetingDetailView.swift:791-797, `MeetingDetailObservationPolicy.shouldContinue`) - also genau im Review-Zustand. `review.persons` ist damit ein eingefrorener Schnappschuss. Aendert der Benutzer waehrenddessen in Einstellungen > Personen etwas (AppModel+People.swift:75/81 `setPrototypeExcluded`/`setHardNegativeExcluded`, 65 `renamePerson`, 129 `mergePersons`, AppModel+Review.swift:174 `createPerson`), schreibt die naechste Sprecheraktion ueber MeetingReviewController.swift:103 `replacePersons(result.state.persons)` den alten Stand zurueck. Eine dort neu angelegte Person verschwindet samt ihrer Prototypen und Hard Negatives - geloescht, nicht `excludedAt`-markiert; eine gerade gesetzte Ausnahme wird still zurueckgenommen. Der einzige Staleness-Schutz im Pfad prueft nur die RunID (IdentityReviewFlow.swift:99/139/163 `runID == state.currentRunID`), nichts am Personendokument. Auch ParticipantsSection.reload() (ParticipantsSection.swift:208) frischt nur den eigenen lokalen Zustand auf, nicht das `review`-Binding, deshalb geht auch die eben gesetzte E-Mail verloren.

Schwere von critical auf high korrigiert: Es verletzt die Regel, dass Stimm-Evidenz ausgenommen und nie geloescht wird (rule 3), und der Verlust ist unsichtbar - aber die Aufnahme selbst ist nicht betroffen, und der Verlust trifft nur wiederherstellbare Metadaten/Evidenz, nicht das unersetzliche Artefakt.

### 7. [HIGH] Sprachwechsel während laufendem Aufnahmestart startet die Pipeline neu und löscht die gerade entstehende Aufnahme

`App/Sources/AppModel.swift:748` - Subsystem macos-app, Kategorie -

`setLanguage` sperrt nur gegen `isRecording`, nicht gegen `isStartingRecording`. Zwischen dem Klick auf "Aufnehmen" und dem Setzen von `isRecording = true` (Zeile 922) liegen mehrere Suspendierungspunkte, die Sekunden dauern können: `AudioPermissions.requestMicrophone()` (865, TCC-Dialog), `refreshMicrophoneDiscovery()` (878), `createMeeting` (888), `session.start()` (907, System-Audio-Tap). Konkreter Fehlerpfad: Nutzer klickt Aufnehmen, `session.start()` läuft bereits und schreibt Capture-Dateien in `captureDirectory(meeting.id)`; das Meeting hat Status `.recording`. Nutzer öffnet parallel die Einstellungen (Cmd-,) — der `TranscriptionLanguagePicker` ist nur über `availableLocales.isEmpty` gesperrt (SettingsView.swift:66) — und wählt eine andere Sprache. `setLanguage` läuft durch, ruft `runtime.coordinator.stop()`, setzt `self.runtime = nil` und ruft `bootstrap()`. `bootstrap` ruft `startPipeline`, das `RecoverySweep.run(library:jobStore:)` ohne `activeMeetingIDs` ausführt (PipelineStartup.swift:61); der Sweep setzt jedes Meeting mit Status `.recording` auf `.interrupted`. Direkt danach ruft `bootstrap` `CaptureRecovery.run` (Zeile 689), das für jedes `.interrupted`-Meeting die Capture-Dateien als Originalspuren registriert und anschließend `try? FileManager.default.removeItem(at: file)` ausführt (CaptureRecovery.swift) — während `RecordingSession`/`TrackWriter` noch in genau diese Dateien schreibt. Alles ab diesem Zeitpunkt aufgenommene Audio geht in eine entlinkte Inode und ist beim Schließen verloren; registriert wird ein abgeschnittener Torso. Zusätzlich arbeitet `startRecording` mit dem lokal gebundenen, bereits gestoppten `runtime` weiter (Zeile 860). Das verletzt Regel 1 (die Aufnahme ist das einzige unersetzliche Artefakt).

```swift
AppModel.swift:748  `guard !isRecording, identifier != selectedLanguageID else { return }`
AppModel.swift:755-762  `if let runtime { ... await runtime.coordinator.stop(); self.runtime = nil; ...; await bootstrap() }`
AppModel.swift:689  `_ = try? await CaptureRecovery.run(library: runtime.library, jobStore: runtime.jobStore)`
PipelineStartup.swift:61  `try await RecoverySweep.run(library: library, jobStore: jobStore)`
RecoverySweep.swift  `for meeting in meetings where meeting.status == .recording && !activeMeetingIDs.contains(meeting.id) { ... updateMeetingStatus(meeting.id, to: .interrupted) }`
CaptureRecovery.swift  `try? FileManager.default.removeItem(at: file)`
```

**Korrekturskizze:** Wächter erweitern: `guard !isRecording, !isStartingRecording, identifier != selectedLanguageID else { return }` und den Picker in `TranscriptionLanguagePicker` entsprechend deaktivieren (bzw. den Wechsel bis zum Ende der Aufnahme parken). Zusätzlich `startPipeline`/`RecoverySweep` beim Neustart die aktiven Meeting-IDs (`recordingMeetingID` bzw. die von `RecordingStartState` gemerkte ID) übergeben, damit ein Neustart aus einem anderen Grund eine laufende Aufnahme nie adoptieren kann.

**Adversariale Pruefung:** Mechanismus am Code vollstaendig nachvollzogen. (a) AppModel.swift:748 sperrt nur `!isRecording`; `isStartingRecording` existiert (AppModel.swift:325) und wird an anderen Stellen bewusst mitgeprueft (selectAutomaticMicrophone 372, selectMicrophone 378, resolveRecordingPermissions 811, MicrophoneSelectionView 16/49/63, StenoApp.swift:46) - beim Sprachwechsel fehlt genau diese Pruefung, und TranscriptionLanguagePicker (SettingsView.swift:66) sperrt nur auf `availableLocales.isEmpty`. (b) `isRecording = true` faellt erst in AppModel.swift:922, davor liegen echte Suspendierungspunkte (865 requestMicrophone, 878 refreshMicrophoneDiscovery, 888 createMeeting, 907 session.start()), waehrend deren Await der MainActor frei ist; das Meeting steht ab 888 auf `.recording` und RecordingSession schreibt ab 907 in `captureDirectory(meeting.id)`. (c) setLanguage setzt `self.runtime = nil` und ruft `bootstrap()`; `bootstrap` laeuft dann durch, weil sein Guard `runtime == nil` erfuellt ist. (d) startPipeline ruft `RecoverySweep.run(library:jobStore:)` ohne `activeMeetingIDs` (PipelineStartup.swift:61); RecoverySweep.swift setzt jedes `.recording`-Meeting auf `.interrupted`. (e) bootstrap ruft danach CaptureRecovery.run (AppModel.swift:689); CaptureRecovery.swift adoptiert fuer jedes `.interrupted`-Meeting die Dateien im captureDirectory und ruft direkt nach `registerMediaAsset` `try? FileManager.default.removeItem(at: file)` - waehrend TrackWriter noch hineinschreibt. Library.registerMediaAsset kopiert (Library.swift:431), der Torso wird also festgeschrieben, und weil der provenanceKey `<meetingID>/<kind>` (Library.swift:405) danach belegt ist, kann die spaetere echte Registrierung in finalizeStop (RecordingSession.swift:310-317) nie mehr gelingen (duplicateProvenance bzw. fehlende Quelldatei). Damit ist das Audio ab dem Adoptionszeitpunkt verloren - Verstoss gegen Regel 1. Schwere von critical auf high korrigiert: das Zeitfenster ist eng (nur zwischen Klick und Zeile 922) und verlangt ein parallel geoeffnetes Einstellungsfenster; Folge und Mechanismus sind aber genau wie beschrieben.

### 8. [HIGH] Nach einem fehlgeschlagenen Stopp wandert das Live-Transkript der alten Aufnahme in die Revision der nächsten

`App/Sources/AppModel.swift:1004` - Subsystem macos-app, Kategorie -

`performStopRecording` leert `liveTasks` ausschließlich im Erfolgspfad (Zeile 990). Wirft `session.stop()` (974) oder `appendRevision` (997) oder `jobStore.enqueue` (1000), springt der Code in den `catch`, meldet nur und lässt `liveTasks` unangetastet — die Tasks werden weder ausgewertet noch abgebrochen. `startRecording` hängt beim nächsten Lauf lediglich an (`liveTasks.append`, Zeile 928), leert das Array aber nie. Konkreter Fehlerpfad: Aufnahme A wird gestoppt, `finalizeStop` scheitert an `writer.close()` oder `registerMediaAsset` (RecordingSession.swift:310-317) — die Ingress- und Writer-Tasks sind zu diesem Zeitpunkt bereits beendet (Zeilen 289-303), die beiden Live-Tasks von A haben also ihre `TranscriptOutput` fertig. `liveTasks` enthält danach 2 abgeschlossene Tasks. Nutzer startet Aufnahme B: `liveTasks` hat 4 Einträge. Beim Stopp von B sammelt die Schleife (985-989) alle 4 Ergebnisse ein und schreibt sie über `TranscriptMapper.revision(from: outputs, meetingID: meetingID, origin: .liveProvisional)` in die Revision von **B**. Das gesprochene Wort aus Meeting A steht damit als Tatsache im Transkript von Meeting B — auch über Gesprächs- und Teilnehmergrenzen hinweg.

```swift
AppModel.swift:926-929  `for track in AudioTrack.allCases { let stream = try await session.liveAudioEvents(for: track); liveTasks.append(makeLiveTask(track: track, stream: stream)) }`
AppModel.swift:985-990  `for task in liveTasks { if let output = await task.value { outputs.append(output) } }` / `liveTasks = []`
AppModel.swift:1004-1006  `} catch { report(Self.message("The recording could not be stopped cleanly.", error)) }`
```

**Korrekturskizze:** `liveTasks` in `performStopRecording` unabhängig vom Ausgang leeren (z. B. `let tasks = liveTasks; liveTasks = []` vor dem `do`, danach über `tasks` iterieren) und zusätzlich am Anfang von `startRecording` `liveTasks.forEach { $0.cancel() }; liveTasks = []` setzen, damit kein Rest eines früheren Laufs überleben kann.

**Adversariale Pruefung:** Am Code bestaetigt. `liveTasks` wird nur an zwei Stellen geleert: AppModel.swift:990 (im do-Block von performStopRecording, hinter session.stop() 974) und 1020 in `abortRecordingCleanup`, das ausschliesslich aus dem catch von startRecording (944) aufgerufen wird - nicht aus dem catch von performStopRecording (1004-1006), das nur `report(...)` macht. `startRecording` haengt in 928 nur an (`liveTasks.append`). Der Fehlerpfad ist erreichbar: finalizeStop beendet Ingress- und Writer-Tasks (RecordingSession.swift:285-302) und wirft erst danach in `writer.close()` / `registerMediaAsset` (310-317), die Live-Tasks von A sind also fertig und liefern beim naechsten Stopp ihren Wert. Nach dem gescheiterten Stopp ist `isRecording = false` (1008) und `session = nil`, eine neue Aufnahme B ist also startbar; deren Stopp sammelt in 985-989 alle vier Tasks ein und uebergibt sie an `TranscriptMapper.revision(from:meetingID: <B>, origin: .liveProvisional)` - `TranscriptOutput` traegt keine Meeting-Bindung, die Zuordnung entsteht allein aus dem Parameter. Rede aus Meeting A steht damit als Tatsache im Transkript von B (Regel 3). Variante: wirft session.stop() bereits im Guard (RecordingSession.swift:272-274), sind die alten Streams nicht beendet und der naechste Stopp blockiert unbegrenzt in `await task.value`.

### 9. [HIGH] cancel() liest den Job-Status vor einem Suspension-Point und umgeht dadurch die cancellationTooLate-Sperre

`StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:201` - Subsystem pipeline, Kategorie concurrency

`cancel(jobID:)` prueft zuerst `activeJobID == jobID`. Trifft das (noch) nicht zu, laedt es den Job mit `try await jobStore.load(jobID)`. `JobStore` ist ein eigener Aktor (StenoLibrary/JobStore.swift:29), also ist Zeile 201 ein Suspension-Point auf dem `PipelineCoordinator`-Aktor. Waehrend dieser Suspension darf `consumeQueue()` reentrant laufen: es ruft `claimNextJob()` (Zeile 244/281), der genau diesen Job per `transition(.queued -> .running)` beansprucht, setzt `activeJobID`/`activePhase` und startet `execute(job)`. Danach setzt `cancel` mit dem veralteten Snapshot `job.status == .queued` fort und fuehrt den kompletten Abbruchpfad auf einem bereits laufenden Job aus.

Konkreter Fehlerpfad: Meeting M hat genau einen wartenden finalASR-Job J. Der Nutzer drueckt "Abbrechen" in dem Moment, in dem der Poll-Timer (25 ms) feuert.
1. `cancel(J)` -> `activeJobID` ist nil -> `await jobStore.load(J)` liefert `.queued`, Continuation wird eingereiht.
2. `consumeQueue` claimt J (`.running`), setzt `activeJobID = J`, startet `execute`, suspendiert in `await task.value`.
3. `cancel` setzt fort: `runStore.removeTemporaryArtifacts(for: J)` loescht `.run-<runID>.tmp` samt der von `prepare` geschriebenen run.json des GERADE LAUFENDEN Laufs; danach `transition(J, to: .cancelled)` (aus `.running` erlaubt, JobStore.swift:483).
4. `execute` laeuft weiter (`activeTask.cancel()` wurde nie aufgerufen, weil der `activeJobID`-Zweig nicht genommen wurde) und ruft am Ende `runStore.commit` -> `encode(run, to: temporary/run.json)` in ein geloeschtes Verzeichnis -> Fehler.
5. `handle` -> `persistFailure` -> `jobStore.transition(J, to: .failed)` aus `.cancelled`; `allowsTransition(.cancelled, .failed)` ist false -> `invalidStatusTransition` -> `persistenceErrors` -> `runtimeFailure` gesetzt. Ab da wirft `waitUntilIdle()` dauerhaft.

Zweite, schlimmere Variante derselben Wurzel: liegt der Suspension-Point spaeter, kann `cancel` den Job auch dann noch auf `.cancelled` setzen, wenn `execute` bereits `activePhase = .committing` gesetzt und Run + Revision committet hat. Genau das soll `PipelineError.cancellationTooLate` verhindern (Zeile 191-193) - der Guard greift hier nicht, weil er nur im `activeJobID == jobID`-Zweig steht. Ergebnis: eine vollstaendig committete Transkriptions-Revision liegt in der Bibliothek, waehrend der Job dem Nutzer als abgebrochen/fehlgeschlagen angezeigt wird, und `finish()` scheitert an `transition(.cancelled -> .finished)`.

```swift
public func cancel(jobID: JobID) async throws {
    if activeJobID == jobID {
        guard activePhase != .committing else {
            throw PipelineError.cancellationTooLate(jobID)
        }
        ...
        return
    }
    let job = try await jobStore.load(jobID)          // <- Suspension: consumeQueue kann J hier claimen
    if job.status == .queued || job.status == .failed {   // <- veralteter Snapshot
        do {
            try withCurrentMeetingGeneration(for: job) { transaction in
                try runStore.removeTemporaryArtifacts(for: job, transaction: transaction)
            }
        } ...
        _ = try await jobStore.transition(jobID, to: .cancelled)
```

**Korrekturskizze:** Den Statuswechsel atomar in den JobStore-Aktor verlagern, z.B. ein `jobStore.cancelIfStillQueued(jobID)`, das Laden und `transition` in einem einzigen aktor-isolierten Aufruf macht und `nil`/`false` zurueckgibt, wenn der Job inzwischen `.running` ist. `cancel` muss danach den `activeJobID`/`activePhase`-Zweig erneut auswerten (Schleife), statt auf dem alten Snapshot weiterzuarbeiten. Alternativ vor dem Loeschen der temporaeren Artefakte erneut `activeJobID == jobID` pruefen und dann in den cancellationTooLate-/Task-cancel-Pfad wechseln.

**Adversariale Pruefung:** Rennen am Code nachvollzogen. `cancel` prueft `activeJobID == jobID` synchron (PipelineCoordinator.swift:190), danach ist Zeile 201 `await jobStore.load` ein echter Suspension-Point auf dem Aktor (JobStore ist eigener Aktor, JobStore.swift:29). `consumeQueue` haengt zu diesem Zeitpunkt in `Task.sleep`/`claimNext` (Zeile 245/281); zwischen Claim (`transition(.queued->.running)`, JobStore.swift:465-471) und dem naechsten Suspension-Point (`await task.value`, Zeile 258) liegen nur synchrone Aufrufe (`importedStateAction`, `importedGenerationIsCurrent`), also kann consumeQueue den Job vollstaendig beanspruchen, bevor cancels Continuation wieder laeuft. Danach arbeitet cancel mit dem veralteten Snapshot `.queued` weiter: `removeTemporaryArtifacts` loescht `.run-<runID>.tmp` samt der von `prepare` geschriebenen run.json (RunArtifactStore.swift:220-228, 40-61), und `transition(.running -> .cancelled)` ist erlaubt (JobStore.swift:484). Das laufende `execute` bekommt kein `activeTask.cancel()` und scheitert spaeter in `commit` beim `encode(run, to: temporary/run.json)` (RunArtifactStore.swift:88-93). In `persistFailure` schlaegt dann `transition(.cancelled -> .failed)` fehl (nicht in allowsTransition), landet in `persistenceErrors` und setzt `runtimeFailure` dauerhaft (Zeile 1199-1217), womit `waitUntilIdle` (Zeile 231) fuer immer wirft. Auch die zweite Variante stimmt: der `cancellationTooLate`-Guard (Zeile 191-193) steht nur im `activeJobID`-Zweig, der stale Pfad umgeht ihn. `cancelJob` wird aus der UI parallel zum laufenden Queue-Task aufgerufen (App/Sources/AppModel+Review.swift:539), das Fenster ist also produktiv erreichbar. Nebenbefund derselben Wurzel: bei umgekehrter Reihenfolge (claimNext zuerst) laedt cancel `.running` und tut still gar nichts. Schwere von critical auf high korrigiert: es braucht ein enges Timing-Fenster, die Aufnahme bleibt unangetastet, Originale werden nicht ueberschrieben; der Schaden ist ein inkonsistenter Jobzustand plus klebendes `runtimeFailure`.

### 10. [HIGH] Explizit gewaehlte Transkriptionssprache faellt still auf Locale.current zurueck (Regel 4)

`StenoKit/Sources/StenoTranscription/LocaleResolver.swift:33` - Subsystem speech, Kategorie rule-violation

`select` behandelt eine nicht gefundene *ausdrueckliche* Anfrage genauso wie `auto`: findet `equivalent(to: requested, ...)` keinen Treffer, laeuft die Funktion weiter in die `automaticCandidates`-Schleife, deren Standardwert `[.autoupdatingCurrent, .current]` ist. Damit steht `Locale.current` genau im Transkriptionspfad, den AGENTS.md ausschliesst.

Fehlerpfad: Geraet in Deutschland auf Englisch gestellt (`Locale.current == en_DE`), gespeicherte Transkriptionssprache `de-DE`. Meldet `SpeechTranscriber.supportedLocales` in einem OS-Build keinen deutschen Eintrag (geaenderte Identifier, reduzierter Katalog, Beta), dann: (1) Zeile 26-31 findet nichts, (2) Zeile 33 nimmt `autoupdatingCurrent` = `en_DE`, (3) `equivalent` faellt auf den Sprachcode-Vergleich in Zeile 72-74 und liefert `en_US`. `SpeechAnalyzerProvider.prepareTranscriber` (Zeile 179-184) wirft nur bei `nil`, also nie, solange irgendeine Sprache unterstuetzt wird - deutsche Rede wird ohne Fehlermeldung als Englisch transkribiert, und `TranscriptionAccumulator` schreibt `en_US` als `localeIdentifier` ins Ergebnis.

Derselbe Aufruf ueberschreibt zusaetzlich die *gespeicherte* Einstellung: `App/Sources/AppModel.swift:728-733` ruft `LocaleResolver.select(requested: locale, supported: availableLocales)` ohne `automaticCandidates` und schreibt das Ergebnis nach `selectedLanguageID`. Die ausdrueckliche Wahl des Nutzers ist damit dauerhaft weg.

Das Verhalten ist in `LocaleResolverTests.swift:24-33` als gewollt festgeschrieben - der Test zementiert genau die verbotene stille Ersetzung.

```swift
    public static func select(
        requested: Locale,
        supported: [Locale],
        automaticCandidates: [Locale] = [.autoupdatingCurrent, .current]
    ) -> Locale? {
        guard !supported.isEmpty else { return nil }

        if requested.identifier.caseInsensitiveCompare(
            Locale.transcriptionAutomatic.identifier
        ) != .orderedSame,
           let requestedMatch = equivalent(to: requested, in: supported) {
            return requestedMatch
        }

        for candidate in automaticCandidates {
            if let match = equivalent(to: candidate, in: supported) {
                return match
            }
        }
```

**Korrekturskizze:** Die automatische Kette nur betreten, wenn `requested` wirklich `auto` ist. Bei einer ausdruecklichen, nicht aufloesbaren Anfrage `nil` zurueckgeben, damit `prepareTranscriber` `TranscriptionError.noSupportedLocale` wirft und der Nutzer die Sprache neu waehlt, statt ein plausibel aussehendes falschsprachiges Transkript zu bekommen. Der Test in LocaleResolverTests.swift:24-33 muss entsprechend umgedreht werden.

**Adversariale Pruefung:** Am Code nachvollzogen: LocaleResolver.select (LocaleResolver.swift:19-46) hat den Standardparameter automaticCandidates = [.autoupdatingCurrent, .current]. Findet equivalent(to: requested,...) fuer eine ausdrueckliche Anfrage nichts (Zeile 26-31), laeuft die Funktion ohne Unterscheidung in die Kandidatenschleife (Zeile 33-37) und danach in en-US bzw. supported.first. Beide Produktionsaufrufer nutzen den Standardparameter, also steht Locale.current wirklich im Transkriptionspfad: SpeechAnalyzerProvider.prepareTranscriber (Zeile 179-184) uebergibt nur requested/supported und wirft ausschliesslich bei nil, und SystemSpeechAssets.resolve (Zeile 79-84) ebenso. Zusaetzlich reachbar ohne exotischen OS-Katalog: AppModel.selectedLanguageID ist ohne gespeicherte Wahl Locale.current.identifier (AppModel.swift:395-398), loadAvailableLocales (Zeile 707-736) reicht genau das in select hinein, und equivalent faellt ueber den Sprachcode-Zweig (Zeile 72-74) von en_DE auf en_US - der in AGENTS.md ausdruecklich benannte Fall. Ein Teil des Befunds ist aber falsch: die gespeicherte Wahl wird NICHT dauerhaft ueberschrieben. loadAvailableLocales setzt nur die In-Memory-Property; UserDefaults.set(forKey: languageDefaultsKey) steht ausschliesslich in setLanguage (AppModel.swift:754), also ueberlebt eine ausdrueckliche Wahl den Neustart. Auch der iOS-Pfad (TranscriptionLanguage.swift:119) haelt das Ergebnis bewusst getrennt in resolvedFallback und schreibt selectedID nicht um. Schwere bleibt high wegen Regel 4, die Begruendung ist aber der stille Fallback, nicht der behauptete Datenverlust.

### 11. [HIGH] Review loescht Stimm-Evidenz statt sie auszunehmen und meldet ausgenommene Proben als Eigentuemer

`StenoKit/Sources/StenoIdentity/IdentityReviewFlow.swift:269` - Subsystem speech, Kategorie rule-violation

`removePositiveEvidence` entfernt Prototypen per `removeAll` hart aus dem Person-Objekt, ohne Schnappschuss und ohne `excludedAt`. `MeetingReviewController.perform` persistiert das direkt ueber `identityStore.replacePersons(result.state.persons)` - der Verlust ist dauerhaft. Direkt daneben dokumentiert `IdentityStore.setPrototypeExcluded` (StenoLibrary/IdentityStore.swift:153-171) das Gegenteil als verbindlich, und `deletePerson`/`restorePerson` zeigt, wie ein verlustfreies Entfernen hier aussieht.

Zwei konkrete Fehlerpfade:

(1) Evidenzverlust: Person A hat den Prototyp P fuer (Meeting M, Lauf R, Kanal C, Cluster X); ein Mensch hat P ueber `setPrototypeExcluded` ausgenommen (`excludedAt` gesetzt, `isActive == false`). Bestaetigt der Mensch Cluster X danach als Person B, filtert `removeAll` in Zeile 269-274 nur nach meetingID/runID/channel/clusterID - `isActive` kommt nicht vor. P wird geloescht, die Entscheidung des Menschen ist unwiderruflich weg.

(2) Falsche Tatsachenbehauptung: `owners` (Zeile 275-278) zaehlt jeden entfernten Prototyp als Eigentuemer, auch den ausgenommenen. Folge in `assign`: `otherOwners` ist nicht leer, also wird `source` in Zeile 198-200 als `.userCorrected` statt `.userConfirmed` gespeichert, der Status wird `.reassigned` (Zeile 229-231) und `reassignedFrom: [A]` geht an die Oberflaeche - der Nutzer liest, der Sprecher sei A weggenommen worden, obwohl A nie eine aktive Zuordnung hatte. Umgekehrt laeuft `reassign` auf einem Cluster, dessen einziger frueherer Eigentuemer ausgenommen war, durch, statt `noAssignmentToReassign` zu werfen.

```swift
            let before = state.persons[index].prototypes.count
            state.persons[index].prototypes.removeAll {
                $0.meetingID == meetingID
                    && $0.runID == runID
                    && $0.channel == channel
                    && clusterIDs.contains($0.clusterID)
            }
            if state.persons[index].prototypes.count != before {
                owners.append(state.persons[index].id)
```

**Korrekturskizze:** Statt `removeAll` die betroffenen Prototypen mit `excludedAt = date` markieren (dasselbe Praedikat wie `IdentityStore.setPrototypeExcluded`), und beim Sammeln von `owners` ausschliesslich Proben zaehlen, die vorher `isActive` waren. Bereits ausgenommene Proben bleiben unangetastet und tauchen weder in `reassignedFrom` noch in der `.userCorrected`-Entscheidung auf.

**Adversariale Pruefung:** removePositiveEvidence (IdentityReviewFlow.swift:259-281) filtert nur meetingID/runID/channel/clusterID und loescht per removeAll; excludedAt bzw. isActive (StenoDomain/Identity.swift:38, 143) kommt nicht vor, ein Schnappschuss wird nicht angelegt. Der Pfad ist durchgaengig: MeetingReviewController.perform baut den State aus den vollstaendig geladenen Personen (MeetingReview.swift:239-248, IdentityStore.listPersons) und schreibt das Ergebnis mit identityStore.replacePersons(result.state.persons) (MeetingReviewController.swift:103) zurueck - replacePersons ist ein volles write(persons) (IdentityStore.swift:148-151), der Verlust ist also persistent. Ausgenommene Proben entstehen real ueber AppModel.setSampleExcluded -> setPrototypeExcluded (AppModel+People.swift:70-79, IdentityStore.swift:158-171), tragen dieselben meetingID/runID/channel/clusterID-Felder und werden von confirm/reassign/markMultiple mitgeloescht. Auch der zweite Teil stimmt: owners (Zeile 275-278) zaehlt jeden entfernten Prototyp, ohne isActive zu pruefen, also wird source .userCorrected (Zeile 198-200), status .reassigned (Zeile 229-231) und reassignedFrom meldet eine Wegnahme, die es nie gab. Kein Test schuetzt den Fall - ExcludedEvidenceTests deckt nur ausgenommene HardNegatives beim Rebuild ab. Verstoss gegen die Regel 'Stimm-Evidenz wird ausgenommen, nie geloescht', Schwere high bestaetigt.

### 12. [HIGH] rebuildHardNegatives leitet Hard Negatives aus ausgenommener Evidenz ab

`StenoKit/Sources/StenoIdentity/IdentityReviewFlow.swift:335` - Subsystem speech, Kategorie rule-violation

`rebuildHardNegatives` baut `ownedClusters` aus `person.prototypes` ohne jeden `isActive`-Filter. Ausgenommene Stimmproben zaehlen damit weiter als Besitzanspruch, obwohl `SpeakerSuggestionEngine.candidates` (SpeakerSuggestionEngine.swift:253-257) sie explizit herausfiltert. Die Funktion, die genau diese Falle fuer Negatives kennt (sie rettet `excludedAt` in Zeile 308-319), laesst sie auf der Prototyp-Seite offen.

Fehlerpfad: Person A hat einen ausgenommenen Prototyp fuer Cluster X in (M, R, C). Der Mensch bestaetigt danach im selben Kanal Cluster Y als Person B. `rebuildHardNegatives` laeuft, `ownedClusters[A]` enthaelt weiterhin X (Zeile 335-343, kein isActive-Test), und die Schleife ab Zeile 346 haengt B ein frisches `HardNegative` mit dem Embedding von X an - abgeleitet aus Evidenz, die ein Mensch ausdruecklich deaktiviert hat. Ist X in Wahrheit ein Fragment von Bs Stimme, ist B fuer diese Stimme dauerhaft blockiert, auch in fremden Meetings; genau der Schaden, vor dem StenoDomain/Identity.swift:93-97 warnt, und im spaeteren Fehlverhalten zeigt nichts auf die Ursache.

Dieselbe fehlende Pruefung in `removeParticipantsWithoutMeetingEvidence` (Zeile 288-289): eine Person bleibt allein wegen einer ausgenommenen Probe in `participantIDs` und damit in der Teilnehmerliste, die der Nutzer als Tatsache liest.

```swift
        for person in state.persons {
            var seen: Set<String> = []
            for prototype in person.prototypes where
                prototype.meetingID == meetingID
                    && prototype.runID == runID
                    && prototype.channel == channel
                    && seen.insert(prototype.clusterID).inserted {
                if let cluster = clusterByID[prototype.clusterID] {
                    ownedClusters[person.id, default: []].append(cluster)
```

**Korrekturskizze:** In beiden Schleifen ueber das gemeinsame Praedikat filtern: `for prototype in person.prototypes where prototype.isActive && ...` bzw. `prototypes.contains { $0.isActive && $0.meetingID == state.meetingID }`. Das ist dieselbe Regel, die `candidates` schon anwendet - hier fehlt sie nur auf dem Schreibpfad.

**Adversariale Pruefung:** rebuildHardNegatives (IdentityReviewFlow.swift:332-344) baut ownedClusters allein aus person.prototypes mit Filter auf meetingID/runID/channel - kein isActive/excludedAt-Test, obwohl dieselbe Funktion die Negatives-Seite ausdruecklich rettet (Zeile 308-319) und SpeakerSuggestionEngine.candidates ausgenommene Evidenz explizit vorher herausfiltert (SpeakerSuggestionEngine.swift:253-262). Die Schleife ab Zeile 346-373 haengt jedem anderen Person-Eintrag ein frisches HardNegative mit dem Embedding genau dieser Cluster an, source .userConfirmed, excludedAt nur, wenn zufaellig ein gleichnamiges Negativ vorher ausgenommen war. Damit entsteht aus einer vom Menschen deaktivierten Probe eine neue, aktive Sperre - genau der Schaden, den StenoDomain/Identity.swift:93-97 beschreibt. rebuildHardNegatives wird bei jeder Review-Aktion im Kanal aufgerufen (Zeile 120-125 und 223-228), der Pfad ist also nicht exotisch. Der Nebenbefund stimmt ebenfalls: removeParticipantsWithoutMeetingEvidence (Zeile 283-294) prueft prototypes.contains { meetingID == ... } ohne isActive, eine Person bleibt also allein wegen ausgenommener Evidenz in der Teilnehmerliste. Einschraenkung: der eigentliche Schaden setzt voraus, dass die ausgenommene Probe den Cluster falsch zuordnete - dann aber dauerhaft und meetinguebergreifend.

### 13. [MEDIUM] Capture-Original wird gelöscht, bevor die Bibliothekskopie dauerhaft auf der Platte liegt

`StenoKit/Sources/StenoAudioCore/RecordingSession.swift:319` - Subsystem audio-core, Kategorie data-loss

`finalizeStop` löscht die Capture-Datei unmittelbar nach `library.registerMediaAsset`. Dieses registriert mit einem einfachen `FileManager.copyItem` (StenoKit/Sources/StenoLibrary/Library.swift:431) - ohne `fsync` auf die Zieldatei und ohne `fsync` auf das Zielverzeichnis. Fehlerpfad: Aufnahme läuft zwei Stunden, `TrackWriter` hat jede Sekunde brav `fsync` gemacht (TrackWriter.swift:61-64), also liegt das Capture-Original stabil auf der Platte. Beim Stop wird eine 700-MB-Kopie geschrieben, deren Bytes noch im Page Cache stehen, danach wird sofort das einzige durable Exemplar entfernt. Ein Kernel-Panic oder Stromausfall in diesem Fenster (bei 700 MB durchaus mehrere Sekunden) hinterlässt eine abgeschnittene oder leere Ziel-Datei und kein Original - die Aufnahme ist vollständig weg. Dass das Projekt diesen Unterschied kennt, zeigt `AtomicFile` (StenoLibrary/AtomicFile.swift:85 fsync Datei, :119-128 fsync Verzeichnis), das für JSON-Metadaten verwendet wird, aber nicht für die Audiodatei.

```swift
assets[track] = asset
try FileManager.default.removeItem(at: writer.url)

// StenoLibrary/Library.swift:430-441
try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {
    try FileManager.default.copyItem(at: sourceURL, to: destination)
```

**Korrekturskizze:** Vor dem `removeItem` die Kopie durable machen: nach `copyItem` in `registerMediaAsset` einen Deskriptor auf `destination` öffnen, `fsync` ausführen und anschließend das Elternverzeichnis per `AtomicFile.synchronizeDirectory` synchronisieren (die Funktion existiert bereits, sie muss nur `internal`/`package` sichtbar werden). Alternativ und billiger: statt `copyItem` + `removeItem` ein `rename` innerhalb desselben Volumes verwenden, dann bleibt genau ein Inode bestehen und es gibt gar kein Fenster ohne Kopie.

**Adversariale Pruefung:** Belegt: RecordingSession.swift:311-319 registriert das Asset und loescht unmittelbar danach die Capture-Datei. Library.registerMediaAsset (Library.swift:430-441) kopiert mit FileManager.copyItem und synchronisiert die Zieldatei nie; nur die JSON-Metadaten gehen ueber JSONDocumentStore/AtomicFile (AtomicFile.swift:85 fsync Datei, 119-128 fsync Verzeichnis). Das Capture-Original dagegen war durch TrackWriter.write/close (TrackWriter.swift:61-64, 71) sekuendlich gefsynct. Das Fenster zwischen copyItem und removeItem enthaelt damit potenziell nur eine Kopie mit dirty pages und kein durables Original - bei Kernel-Panic/Stromausfall in diesem Fenster ist die Aufnahme weg. Ein Verzeichnis-fsync auf das media-Verzeichnis passiert zwar beim AtomicFile-commit der Asset-JSON, das committet aber nur den Verzeichniseintrag, nicht die Datenbloecke der kopierten CAF. Schwere medium ist angemessen: reales, aber schmales Crash-Fenster, kein Fehler im Normalbetrieb.

### 14. [MEDIUM] Vollständig volle Platte wird als "Kapazität nicht ermittelbar" behandelt, der Plattenwächter schluckt das still

`StenoKit/Sources/StenoAudioCore/DiskSpaceChecker.swift:17` - Subsystem audio-core, Kategorie correctness

`availableBytes` verwirft ein ermitteltes Ergebnis von 0 Bytes über die Bedingung `capacity > 0` und wirft stattdessen `audioSourceUnavailable("free disk capacity could not be determined")`. Null freie Bytes ist aber ein perfekt ermittelter Wert und muss `insufficientDiskSpace` ergeben. Zwei konkrete Fehlerpfade: (1) Beim Start meldet `RecordingSession.start` (Zeile 135-136) auf einer randvollen Platte "Audioquelle nicht verfügbar / freie Kapazität nicht ermittelbar" statt der Platzmeldung - der Nutzer sucht am Mikrofon statt am Speicher. (2) Im laufenden Betrieb fängt `startDiskMonitor` jeden Fehler mit `catch { continue }` ab (RecordingSession.swift:452-453). Erreicht das Volume während der Aufnahme 0 freie Bytes (etwa weil ein Time-Machine-Snapshot oder ein Download den 2-GB-Puffer zwischen zwei Sekunden-Ticks aufbraucht), wirft `availableDiskBytes` ab da bei jedem Tick, `diskSpaceDidRunLow` wird nie erreicht, und die Aufnahme läuft weiter, bis `AVAudioFile.write` scheitert - gemeldet wird dann `writerFailure` statt `lowDiskSpace`, also der falsche Grund. Dasselbe `catch { continue }` macht auch ein weggefallenes Volume (externe Platte abgezogen) für den Wächter dauerhaft unsichtbar.

```swift
if let capacity = capacities.max(), capacity > 0 { return capacity }
throw AudioRecordingError.audioSourceUnavailable(
    "free disk capacity could not be determined"
)

// RecordingSession.swift:450-454
} catch is CancellationError {
    return
} catch {
    continue
}
```

**Korrekturskizze:** In `availableBytes` zwischen "kein Wert lesbar" und "Wert ist 0" trennen: `guard let capacity = capacities.max() else { throw ... }` und danach `return max(0, capacity)`. Damit fließt 0 regulär in `validate` und liefert `insufficientDiskSpace`. Zusätzlich im Plattenwächter nicht jeden Fehler blind fortsetzen: aufeinanderfolgende Fehler zählen und nach n Fehlversuchen den Nutzer über den Weg von `terminalError` informieren, statt still weiterzulaufen.

**Adversariale Pruefung:** Pfad (1) ist am Code eindeutig: DiskSpaceChecker.swift:17 verwirft ein ermitteltes Ergebnis von 0 ueber 'capacity > 0' und wirft audioSourceUnavailable('free disk capacity could not be determined') statt insufficientDiskSpace; RecordingSession.start (135-136) reicht diesen Fehler unveraendert nach oben, der Nutzer bekommt auf einer randvollen Platte eine Mikrofon-Fehlermeldung. Pfad (2) ist code-seitig ebenfalls real: startDiskMonitor (RecordingSession.swift:450-454) schluckt jeden Nicht-Cancellation-Fehler mit 'continue', diskSpaceDidRunLow wird dann nie erreicht, und ein dauerhaft werfendes availableDiskBytes (weggefallenes Volume) macht den Waechter permanent blind. Einschraenkung, die die Schwere deckelt: der Waechter loest schon bei available < 2 GB aus (Zeile 446), also muesste die Platte innerhalb eines 1-Sekunden-Ticks von >2 GB auf exakt 0 fallen, damit die falsche Abbruchmeldung entsteht - schmal. Und es geht keine Aufnahme verloren: bei einer scheiternden Kopie in finalizeStop bleibt die Capture-Datei liegen (removeItem wird nicht erreicht) und wird beim naechsten Start ueber RecoverySweep/CaptureRecovery adoptiert. Also Fehldiagnose gegenueber dem Nutzer und ein blinder Waechter, kein Datenverlust: medium, eher am unteren Rand.

### 15. [MEDIUM] Unbegrenzter Stille-Schub in den 64-Slot-Ring, dessen Überlauf die ganze Aufnahme beendet

`StenoKit/Sources/StenoAudioCore/TrackContinuity.swift:186` - Subsystem audio-core, Kategorie data-loss

`fillSilence(toFrame:)` schiebt in einer einzigen synchronen Schleife beliebig viele 250-ms-Stillepuffer über `yieldToWriter` in den Writer-Stream. Dieser Stream hat `bufferingPolicy: .bufferingOldest(ringCapacity)` mit ringCapacity 64 (RecordingSession.swift:155-158), also verwirft er bei vollem Ring die neuen Elemente und liefert `.dropped`. `yieldToWriter` eskaliert jedes `.dropped` an `writerOverflowHandler` -> `RecordingSession.writerRingDidOverflow` -> `requestAutomaticStop(reason: .ringBufferOverflow)`, also Abbruch der gesamten Aufnahme. Damit gilt: mehr als 64 * 250 ms = 16 s Stille, die in einem Rutsch nachgezogen werden müssen, beenden ein laufendes Meeting - obwohl dabei nur generierte Stille verloren geht, in der per Definition kein Ton steckt. Erreichbarer Zustand: die Mac-Session setzt `sessionStart` beim Anlegen des System-Writers und gibt der Mikrofonspur `alignFirstBufferToSessionStart: true` (RecordingSession.swift:152-168). Die Mikrofoneinrichtung darf danach laut ihren eigenen Timeouts bis zu ~15 s dauern (MicRecorder.stableSelectedInput 5 s Deadline, MicEngineCapture.perform 5 s für prepare und 5 s für start) plus die Systemspur-Einrichtung. Der erste Mikrofonpuffer trifft dann mit `needsHostRealignment == true` ein, `writtenFrames == 0` und `targetFrame` bei mehr als 16 s -> die Schleife erzeugt über 64 Puffer am Stück und der Ring läuft über, sofern der Writer-Task nicht schnell genug abräumt. Zweiter Defekt an derselben Stelle: `writtenFrames` wird in Zeile 193 und 203 auch dann hochgezählt, wenn der yield verworfen wurde - die Zeitachse behauptet Frames, die nie in der Datei landen.

```swift
while writtenFrames < targetFrame {
    let remaining = targetFrame - writtenFrames
    let frameCount = AVAudioFrameCount(
        min(remaining, AVAudioFramePosition(maximumSilenceFrames))
    )
    guard let silence = makeSilence(frameCount: frameCount) else { return }
    yieldToWriter(silence)
    writtenFrames += AVAudioFramePosition(frameCount)
}

// Zeile 206-215
private func yieldToWriter(_ buffer: sending AVAudioPCMBuffer) {
    switch writerContinuation.yield(buffer) {
    case .dropped:
        writerOverflowHandler()
```

**Korrekturskizze:** Stille und echtes Audio beim Überlauf unterschiedlich behandeln: `yieldToWriter(_:isSilence:)` einführen und bei verworfener Stille den Überlaufhandler nicht auslösen, sondern `writtenFrames` schlicht nicht hochzählen (die Zeitachse bleibt konsistent, die Lücke wird beim nächsten fillSilence nachgezogen). Ergänzend `writtenFrames` nur bei `.enqueued` erhöhen, damit Dateiinhalt und Zeitachse nie auseinanderlaufen. Optional die Stillegröße pro Aufruf an die verbleibende Ringkapazität koppeln, statt sie fest auf 250 ms zu stellen.

**Adversariale Pruefung:** Mechanismus am Code nachvollzogen: fillSilence(toFrame:) (TrackContinuity.swift:185-195) schiebt unbegrenzt viele 250-ms-Puffer synchron ueber yieldToWriter; der Writer-Stream hat bufferingOldest(64) (RecordingSession.swift:155-158, ringCapacity 64 auch in RecordingSession+Mac.swift:21), jedes .dropped eskaliert ueber writerOverflowHandler -> writerRingDidOverflow (337-348) -> requestAutomaticStop(.ringBufferOverflow) und beendet die laufende Aufnahme. Ueber 64 * 250 ms = 16 s Stille am Stueck koennen den Ring also sprengen, sofern der Writer-Task nicht mithaelt - was bei einer engen synchronen Erzeugungsschleife gegen einen Consumer mit Pegelmessung, Actor-Hop und Dateischreiben unwahrscheinlich ist. Erreichbare Zustaende: (a) die vom Reviewer genannte Erstausrichtung - Mac-sourceOrder ist [.system, .microphone] (RecordingSession+Mac.swift:43), sessionStart wird beim System-Writer gesetzt, die Mikrofonspur bekommt alignFirstBufferToSessionStart: true, und die Mic-Einrichtung kann sich aus stableSelectedInput (MicRecorder.swift:93, 5 s) plus zwei perform-Timeouts (MicRecorder.swift:781, 795, je 5 s) auf bis zu ~15 s summieren, ausserdem tickt der Continuity-Monitor waehrend start() noch gar nicht (er startet erst Zeile 221), es wird also nichts inkrementell nachgefuellt - 16 s sind damit knapp, aber genau am Rand; (b) staerker und vom Reviewer nicht genannt: nach einer Systemschlafphase oder einem laengeren Stall faellt in tick() zuerst detectStall (137-143) und unmittelbar danach fillSilence(until:) (124-126) an - ContinuousClock ist mach_continuous_time und laeuft im Schlaf weiter, sodass Minuten in einem Rutsch nachgezogen werden und der Ring sicher ueberlaeuft. Der zweite Teilbefund stimmt ebenfalls: writtenFrames wird in Zeile 193 und 203 auch bei verworfenem yield hochgezaehlt. Schwere medium ist richtig: die Aufnahme bricht vorzeitig ab, das bis dahin Aufgenommene wird aber in finalizeStop noch registriert.

### 16. [MEDIUM] Doppelte oder fehlende IDs in folders.json/config.json lassen den Legacy-Import hart abstuerzen

`StenoKit/Sources/StenoExchange/LegacyImporter.swift:188` - Subsystem exchange, Kategorie correctness

`readFolderNames()` und `readCustomTemplateNames()` bauen ein Dictionary mit `Dictionary(uniqueKeysWithValues:)`. Diese Initialisierung ist eine Praekondition und ruft `fatalError` auf, sobald ein Schluessel doppelt vorkommt. Die Schluessel stammen ungeprueft aus fremden Legacy-Dateien: `LegacyFolder.id = legacyString(object, "id") ?? ""` (LegacyFolders.swift:15) und `LegacyCustomTemplate(id: legacyString($0, "id") ?? "", ...)` (LegacyPersonProfiles.swift:71). Konkreter Fehlerpfad: eine `folders.json` mit zwei Ordner-Objekten, denen das Feld `id` fehlt (oder das kein String ist), liefert zweimal den Schluessel `""` -> `Swift/NativeDictionary.swift:792: Fatal error: Duplicate values for key: ''`. Ich habe das Verhalten lokal mit `swift dup.swift` (zwei Paare mit Schluessel "") reproduziert. Genauso reicht in `config.json` ein zweites `custom_templates`-Objekt ohne `id`, oder schlicht zwei Ordner mit derselben id. Ergebnis ist kein Fehler, den der Import melden koennte, sondern ein Prozessabbruch der App - fremde Daten duerfen den Import nicht zum Absturz bringen.

```swift
LegacyImporter.swift:188  return Dictionary(uniqueKeysWithValues: try LegacyFolders.read(
                from: url,
                timestampParser: timestampParser
            ).folders.map { ($0.id, $0.name) })

LegacyImporter.swift:267  return Dictionary(uniqueKeysWithValues: try LegacyPersonProfiles.read(
                from: url
            ).customTemplates.map { ($0.id, $0.name) })

LegacyFolders.swift:15    id = legacyString(object, "id") ?? ""
LegacyPersonProfiles.swift:71  id: legacyString($0, "id") ?? "",
```

**Korrekturskizze:** Beide Stellen auf `Dictionary(pairs, uniquingKeysWith: { first, _ in first })` umstellen (oder leere IDs vorher herausfiltern) und die verworfenen Duplikate als Warnung in den `ImportReport` schreiben.

**Adversariale Pruefung:** Der Pfad ist am Code nachvollziehbar. LegacyFolder.init (LegacyFolders.swift:12) und der custom_templates-Zweig (LegacyPersonProfiles.swift:71-76) setzen die id ohne jede Pruefung auf legacyString(...) ?? "", und keine der beiden read()-Funktionen filtert oder dedupliziert. LegacyImporter.readFolderNames (Zeile 188) und readCustomTemplateNames (Zeile 267) geben diese Paare direkt an Dictionary(uniqueKeysWithValues:), dessen Duplikatspruefung eine Precondition ist und im Release-Build in einen Trap laeuft (kein throw). Zwei folders-Objekte ohne "id" (oder mit gleicher id) liefern denselben Schluessel und beenden den Prozess. Beide Aufrufe liegen ausserdem vor der Importschleife (Zeile 64-65), lassen sich also nicht durch eine spaetere Absicherung entschaerfen; im App-Pfad (App/Sources/LegacyImportView.swift:61) gibt es nichts, was einen Trap abfangen koennte. Schwere von high auf medium korrigiert: es ist ein Robustheitsfehler auf lokal gelesenen Altdaten, kein Verstoss gegen die Kernregeln, und er passiert bevor irgendetwas geschrieben wurde - die Altinstallation wird nur gelesen, es gehen keine Aufnahmen oder Bibliotheksdaten verloren. Ausloeser ist zudem eine beschaedigte oder handverbogene folders.json/config.json, nicht der Normalfall.

### 17. [MEDIUM] Eine einzige beschaedigte Legacy-Beidatei bricht den gesamten Import ab, dauerhaft

`StenoKit/Sources/StenoExchange/LegacyImporter.swift:105` - Subsystem exchange, Kategorie correctness

Fuer Audio faengt `prepareLegacyMeeting` Fehler pro Datei ab und sammelt sie als Warnung (LegacyMeetingPreparation.swift:101-106). Fuer alle uebrigen Beidateien passiert das nicht: `try entry.speakers.map(LegacySpeakersFile.read(from:))` (Zeile 59), `try LegacyOverrides.read` (109), `try LegacyReportsFile.read` (112) und `try ImportedLegacySummary.read` (23) werfen direkt nach aussen. `LegacyImporter.performImport` faengt nichts ab, also verlaesst der Fehler die ganze Schleife und `performImport` liefert keinen `ImportReport` zurueck. Konkreter Fehlerpfad: ein `<stem>_speakers.json`, dem `created_at` fehlt (etwa abgeschnitten beim Kopieren), fuehrt zu `LegacyExchangeError.invalidFormat("Missing speakers created_at")` (LegacySpeakersFile.swift:81). Alle Stems, die alphabetisch nach diesem Stem kommen, werden nie importiert, und der Bericht ueber die bereits importierten geht verloren. Ein erneuter Lauf scannt dieselbe Datei wieder und scheitert an derselben Stelle: der Import kann ohne manuelles Loeschen der Datei nie durchlaufen. Dasselbe gilt fuer `readFolderNames`/`readCustomTemplateNames`, die vor der Schleife werfen.

```swift
LegacyImporter.swift:105
            let prepared = try await prepareLegacyMeeting(
                entry: entry,
                ...
            )

LegacyMeetingPreparation.swift:59
    let speakers = try entry.speakers.map(LegacySpeakersFile.read(from:))

LegacySpeakersFile.swift:80
        guard let createdAt = legacyDouble(object, "created_at") else {
            throw LegacyExchangeError.invalidFormat("Missing speakers created_at")
        }

// Gegenbeispiel, wie es sein sollte - LegacyMeetingPreparation.swift:101
        } catch {
            warnings.append("Stem \(entry.stem) audio ... could not be converted: \(error)")
        }
```

**Korrekturskizze:** Die Vorbereitung je Stem in ein do/catch legen, das den Stem ueberspringt und eine Warnung in den `ImportReport` schreibt (analog zum Audio-Pfad), statt die gesamte Schleife abzubrechen. Optional die Beidateien einzeln kapseln, damit ein defektes `_reports.json` nicht das Meeting selbst verhindert.

**Adversariale Pruefung:** Nachvollzogen: LegacyStore.scan sortiert die Eintraege nach Stem (LegacyStore.swift:130), die Schleife in performImport (Zeile 80-159) faengt nichts ab, und nur der Audioteil in prepareLegacyMeeting kapselt Fehler als Warnung (LegacyMeetingPreparation.swift:79-107). Die uebrigen Beidateien werfen ungeschuetzt nach aussen: LegacySpeakersFile.read (Zeile 59, throw bei fehlendem created_at, LegacySpeakersFile.swift:80-82), LegacyOverrides.read (109), LegacyReportsFile.read (112), ImportedLegacySummary.read (23) sowie pairTranscriptLines mit transcriptLineCountMismatch. Damit verlaesst der Fehler performImport, der ImportReport entfaellt, und LegacyImportModel.runImport landet in .failed (App/Sources/LegacyImportView.swift:79-81). Da bereits importierte Meetings ueber den provenanceKey uebersprungen werden (Zeile 82-84), scheitert jeder erneute Lauf an derselben Datei: die nachfolgenden Stems kommen ohne manuellen Eingriff nie durch. Kein Test deckt tolerantes Verhalten fuer beschaedigte Nicht-Audio-Beidateien ab. Schwere von high auf medium: die Altinstallation wird nur gelesen, bereits committete Meetings bleiben in der Bibliothek, es geht keine Aufnahme verloren, und der Nutzer bekommt eine Fehlermeldung statt eines stillen Datenverlusts. Verloren geht nur der Bericht und der Rest des Laufs.

### 18. [MEDIUM] validateOwnedSnapshot verschluckt den Validierungsfehler und gibt keinen Cleanup-Handle heraus

`StenoKit/Sources/StenoExchange/MeetingTransferArchiveReader.swift:393` - Subsystem exchange, Kategorie error-handling

Im catch von `validateOwnedSnapshot` wird die innere `error`-Bindung des zweiten `do/catch` verwendet, die den aeusseren `validationError` verdeckt. Schlaegt sowohl die Validierung als auch das anschliessende `session.cleanup()` fehl, wird der *Cleanup*-Fehler geworfen und der eigentliche Grund (z. B. `hashMismatch`, `parserDifferential`, `contentDigestMismatch`) faellt ersatzlos weg. Die beiden Schwesterpfade `validate` (Zeile 271-282) und `revalidate` (328-339) machen es richtig und werfen `MeetingTransferCleanupRequired(originalError:session:)`. Konkreter Fehlerpfad: `MeetingTransferArchiveWriter.write` ruft `validateOwnedSnapshot` auf dem gerade geschriebenen Staging-Archiv auf; liegt dort ein Hashfehler vor und schlaegt zugleich das Aufraeumen der Sitzung fehl (etwa weil das Verzeichnis inzwischen nicht mehr schreibbar ist), meldet der Export `cleanupFailed(...)` statt `hashMismatch(...)`. Ausserdem bekommt der Aufrufer anders als in den anderen beiden Pfaden keinen `MeetingTransferCleanupHandle`, kann also das im Zielordner liegengebliebene Sitzungsverzeichnis samt entpackter Eintraege nicht gezielt entfernen.

```swift
MeetingTransferArchiveReader.swift:388
        } catch {
            let validationError = error
            do {
                try session.cleanup()
            } catch {
                throw error          // <- innerer (Cleanup-)Fehler, verdeckt validationError
            }
            throw validationError
        }

// Vergleich, validate() Zeile 271:
        } catch {
            let validationError = error
            do { try session.cleanup() } catch {
                throw MeetingTransferCleanupRequired(originalError: validationError, session: session)
            }
            throw validationError
        }
```

**Korrekturskizze:** Den Block an `validate`/`revalidate` angleichen: im inneren catch `throw MeetingTransferCleanupRequired(originalError: validationError, session: session)` werfen, damit der urspruengliche Fehler erhalten bleibt und der Aufrufer das Sitzungsverzeichnis nachtraeglich aufraeumen kann.

**Adversariale Pruefung:** Am Code bestaetigt: in validateOwnedSnapshot (MeetingTransferArchiveReader.swift:388-396) verdeckt die implizite error-Bindung des inneren catch die des aeusseren, also wird bei fehlgeschlagenem session.cleanup() der Cleanup-Fehler geworfen und die in validationError festgehaltene Ursache (hashMismatch, parserDifferential, contentDigestMismatch) faellt ersatzlos weg. Die beiden Schwesterpfade validate (271-282) und revalidate (328-339) werfen an derselben Stelle korrekt MeetingTransferCleanupRequired(originalError:session:). Einschraenkung zur Begruendung des Reviewers: der einzige Produktivaufrufer ist MeetingTransferArchiveWriter.write (Zeile 178-183), und dessen catch (205-218) reicht den Fehler nur weiter; MeetingTransferCleanupRequired wird ausschliesslich im Importpfad ausgewertet (MeetingTransferImportService.swift:180, 251). Der fehlende Cleanup-Handle wuerde dort also ohnehin niemand nutzen - der belegbare Schaden ist die verlorene Fehlerursache und das liegengebliebene Sitzungsverzeichnis. Medium ist dafuer richtig: der Fall verlangt zwei gleichzeitige Fehlschlaege, und betroffen ist der Export, nicht die Aufnahme.

### 19. [MEDIUM] Mehrdeutige Cluster-Schluessel aus Legacy-Sprecherdaten koennen den Import abstuerzen lassen

`StenoKit/Sources/StenoExchange/LegacyMeetingPreparation.swift:190` - Subsystem exchange, Kategorie correctness

`segmentsByClusterID` wird mit `Dictionary(uniqueKeysWithValues:)` aus dem zusammengesetzten Schluessel `"\(channel)/\(speakerID)"` gebaut. Channel- und Sprecher-Schluessel kommen ungeprueft aus dem fremden `_speakers.json` (`LegacySpeakersFile.read`, `channelObjects.mapValues(...)`, `clusterObjects.mapValues(...)`) und duerfen selbst Schraegstriche enthalten. Konkreter Fehlerpfad: `channels = {"a/b": {clusters: {"c": ...}}, "a": {clusters: {"b/c": ...}}}` erzeugt zweimal den Schluessel `"a/b/c"` -> `Fatal error: Duplicate values for key` und damit ein Prozessende statt einer Fehlermeldung. Dieselbe Mehrdeutigkeit macht auch die `clusterID` in `IdentityCluster` (Zeile 179) und in `prefixedClusterID` (Zeile 440-443) nicht eindeutig, sodass Sprecher-Evidenz dem falschen Cluster zugeordnet werden kann - das beruehrt die Regel, dass ueber Sprecher nichts geraten werden darf.

```swift
LegacyMeetingPreparation.swift:190
    let segmentsByClusterID = Dictionary(uniqueKeysWithValues:
        file.channels.flatMap { channel, value in
            value.clusters.map { speakerID, cluster in
                ("\(channel)/\(speakerID)", cluster.segments)
            }
        }
    )

LegacySpeakersFile.swift:43
        let clusterObjects = object["clusters"] as? [String: [String: Any]] ?? [:]
        clusters = clusterObjects.mapValues(LegacySpeakerCluster.init(object:))
```

**Korrekturskizze:** `uniquingKeysWith:` verwenden statt `uniqueKeysWithValues:` und den Schluessel eindeutig machen - Channel- und Sprecher-ID getrennt halten (Tupel/Struct als Key) oder Schraegstriche in beiden Komponenten beim Einlesen ablehnen bzw. escapen.

**Adversariale Pruefung:** Der Trap ist am Code nachvollziehbar: LegacySpeakersFile.read uebernimmt Kanal- und Clusterschluessel unveraendert aus dem JSON (LegacySpeakersFile.swift:43-44, 93), und makeDiarizationImport baut daraus in LegacyMeetingPreparation.swift:190-196 einen Dictionary(uniqueKeysWithValues:) ueber den zusammengesetzten Schluessel "channel/speakerID". Enthaelt ein Kanal- oder Clustername einen Schraegstrich, koennen zwei verschiedene Paare denselben Schluessel ergeben, und die Precondition traptet den Prozess. Nichts im Pfad normalisiert oder prueft die Schluessel. Die Erreichbarkeit ist aber deutlich schwaecher als beim Befund 0: die alte App schreibt feste Kanalnamen ("mic", "system") und Cluster der Form "SPEAKER_0" (LegacySpeakersFileTests.swift:14-17), ein Schraegstrich entsteht dort nicht von selbst. Der Zusatzvorwurf, dadurch werde Sprecher-Evidenz dem falschen Cluster zugeordnet und Regel 3 verletzt, haengt an derselben unrealistischen Eingabe und ist kein eigenstaendiger Regelverstoss; die Zuordnung ueber prefixedClusterID (LegacyImporter.swift:440-443) ist bei den tatsaechlich vorkommenden Namen eindeutig. Medium ist damit eher die Obergrenze.

### 20. [MEDIUM] Der response_format-Rueckfall feuert bei jedem 4xx und schickt das komplette Transkript ein zweites Mal

`StenoKit/Sources/StenoIntelligence/OpenAICompatibleProvider.swift:186` - Subsystem intelligence, Kategorie correctness

`completionData` behandelt jeden Status im Bereich 400..<500 als Beleg dafuer, dass der Endpunkt `response_format`/`json_schema` nicht kann, und wiederholt die Anfrage sofort ohne `response_format`. Der Bereich umfasst aber auch 401, 403, 404, 413 und 429. Fehlerpfad: Der Endpunkt lehnt den Schluessel ab und antwortet 401. Statt `authenticationRejected` zu werfen, baut der Code die Anfrage erneut auf (Zeile 189-195) und sendet Transkript, Teilnehmerliste, Notizen und den Bearer-Token ein zweites Mal an denselben Endpunkt; erst die Antwort des zweiten Versuchs wird auf 2xx geprueft (Zeile 198). Dasselbe bei 429: Ein ratenbegrenzter Server bekommt sofort eine zweite volle Anfrage nachgeschoben. Zwei Auswirkungen: (a) die ausgehende Datenmenge verdoppelt sich pro Chunk gegenueber dem, was `ExternalModelNotice` dem Nutzer angekuendigt hat - bei einem Meeting mit 20 Chunks 40 statt 20 Uebertragungen des Gespraechsinhalts; (b) `usedResponseFormatFallback` wird auf `true` gesetzt, obwohl gar nichts ueber die Schemafaehigkeit des Endpunkts bekannt ist, wodurch der Reparaturversuch in `generate` (Zeile 88) das Schema unnoetig weglaesst und die Antwort mit hoeherer Wahrscheinlichkeit unstrukturiert zurueckkommt.

```swift
Zeile 185-197:
```
if startsWithResponseFormat,
   (400..<500).contains(result.response.statusCode)
{
    try Task.checkCancellation()
    result = try await completion(... includesResponseFormat: false)
    usedResponseFormatFallback = true
}
```
Zeile 260-267 zeigt, dass 401/403/404 eigene, aussagekraeftige Fehler haetten: `case 401, 403: .authenticationRejected`
```

**Korrekturskizze:** Den Rueckfall auf die Status beschraenken, die eine Schemaablehnung anzeigen (400 und 422), und alle anderen 4xx sofort ueber `mappedHTTPError` werfen. Zusaetzlich 429 nie automatisch wiederholen.

**Adversariale Pruefung:** Der Code ist wie beschrieben: completionData (Zeile 185-197) behandelt jeden Status in 400..<500 als Schema-Ablehnung und schickt die vollstaendige Anfrage sofort erneut. Bestaetigt wird das vom bestehenden Test selbst: OpenAICompatibleProviderTests.swift:524-553 (`401 and 403 responses map to a rejected API key`) erwartet ausdruecklich `recorder.requests.count == 2` - der Doppelversand bei 401/403 ist also reproduziert und getestet, nicht hypothetisch. Zwei Korrekturen an der Darstellung: (a) Der Nutzer bekommt am Ende trotzdem den richtigen Fehler (`authenticationRejected`, Zeile 198-203 + 260-267), es geht nur um die verdoppelte Uebertragung. (b) Die Rechnung `40 statt 20 Uebertragungen` ist ueberzogen: bei dauerhaftem 401/429 scheitert schon der erste Chunk und der Lauf bricht ab, die Verdopplung trifft real den ersten Chunk. Auch (b) des Befundes - falsch gesetztes `usedResponseFormatFallback` - ist nur erreichbar, wenn der zweite Versuch 2xx liefert (etwa nach transientem 429), sonst wirft completionData vorher. Bleibt ein echter Mangel: Transkript, Teilnehmer, Notizen und Bearer-Token gehen bei jedem 401/403/404/413/429 ein zweites Mal raus, obwohl der Status nichts ueber json_schema-Faehigkeit aussagt. Medium ist angemessen - der Zielhost bleibt der vom Nutzer gewaehlte, Regel 6 ist nicht verletzt.

### 21. [MEDIUM] Format-Cache wird nie invalidiert: zweiter Metering-Lauf installiert den Tap mit dem Format des alten Geraets

`iOS/StenoiOSKit/Sources/StenoiOSAudio/MicrophoneCapture.swift:57` - Subsystem ios, Kategorie correctness/absturz

`prepare()` legt das Hardwareformat in `format` ab (Zeile 37); `stop()` (Zeile 76-81) raeumt es nicht wieder weg. `start()` benutzt in Zeile 57 `try format ?? prepare()`, nimmt also beim zweiten Start immer das gecachte Format statt neu zu lesen.

RecordingModel ist davon nicht betroffen, weil es pro Aufnahme eine frische `MicrophoneCapture()` erzeugt (RecordingModel.swift:180). `AudioReadinessModel` haelt dagegen genau eine Instanz ueber die gesamte Lebensdauer des Bildschirms (AudioReadinessView.swift:432, `private let capture = MicrophoneCapture()`) und startet sie ueber `toggleMetering` beliebig oft.

Fehlerpfad: Audio readiness oeffnen -> "Start metering" (prepare cached z. B. 48 kHz / 1 Kanal des eingebauten Mikrofons) -> "Stop metering" -> USB-Interface oder ein Headset anstecken, dessen Eingang mit 44,1 kHz bzw. anderer Kanalzahl laeuft -> "Start metering". Jetzt ruft Zeile 58-62 `engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: <altes Format>)` auf, waehrend der inputNode ein anderes Format meldet. AVAudioEngine wirft dabei eine ObjC-Ausnahme (`required condition is false: format sample rate/channel count`), die in Swift nicht abfangbar ist - das `do/catch` in Zeile 66-73 greift dafuer nicht, die App stuerzt ab. Selbst wo die Ausnahme ausbleibt, misst der Pegel nach dem falschen Format, also ausgerechnet auf dem Bildschirm, der beweisen soll, dass der Audioweg stimmt.

```swift
MicrophoneCapture.swift:31-39
    public func prepare() throws -> AVAudioFormat {
        ...
        format = nativeFormat

MicrophoneCapture.swift:56-62
        guard !isRunning else { throw MicrophoneCaptureError.alreadyRunning }
        let nativeFormat = try format ?? prepare()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nativeFormat) { ... }

MicrophoneCapture.swift:76-81 - stop() setzt `format` nicht zurueck.

AudioReadinessView.swift:432  private let capture = MicrophoneCapture()
```

**Korrekturskizze:** `format = nil` in `stop()` setzen, oder `start()` das Format grundsaetzlich neu ueber `prepare()` lesen lassen (der Cache spart nichts Messbares). Zusaetzlich in `AudioReadinessModel` pro Metering-Lauf eine frische `MicrophoneCapture` erzeugen, wie es RecordingModel pro Aufnahme tut.

**Adversariale Pruefung:** Der Cache-Defekt ist am Code eindeutig: `prepare()` setzt `format` (MicrophoneCapture.swift:37), `start()` nimmt `try format ?? prepare()` (57), `stop()` (76-81) setzt `format` nicht zurueck. AudioReadinessView.swift:432 haelt genau eine `MicrophoneCapture` ueber die Lebensdauer des Bildschirms, `toggleMetering` (475-482) startet sie beliebig oft, und auch `observeEvents` (524-539) ruft beim Routenwechsel nur `stopMetering`, setzt also den Cache ebenfalls nicht zurueck. RecordingModel ist wie behauptet nicht betroffen (RecordingModel.swift:180 erzeugt pro Aufnahme eine neue Instanz). Nicht am Code beweisbar ist der Absturz selbst - dass `installTap` mit einem zum Bus-Format abweichenden Format eine ObjC-Ausnahme wirft, ist Framework-Verhalten; die zweite Folge (Pegelmessung mit falschem Format ausgerechnet auf dem Diagnosebildschirm) folgt schon aus dem Code. Schwere von HIGH auf MEDIUM korrigiert: der Pfad existiert nur auf dem Readiness-Bildschirm und nur solange keine Aufnahme laeuft (AudioReadinessView.swift:54-68 blendet das Metering waehrend einer Aufnahme aus), es geht also kein Aufnahmematerial verloren.

### 22. [MEDIUM] Metering wird beim Verlassen des Bildschirms nie gestoppt - zweiter Tap auf dem Input-Node und dauerhaft aktive Audiosession

`iOS/App/Sources/AudioReadinessView.swift:316` - Subsystem ios, Kategorie ressourcen-leck/regel-1

`AudioReadinessView` haengt nur `.task { await model.start() }` an; ein `onDisappear` gibt es nicht. `start()` endet in `observeEvents()`, das ueber den Ereignisstrom laeuft; wird der `.task` beim Verlassen abgebrochen, endet nur diese Schleife. `stopMetering()` (Zeile 510) wird ausschliesslich aus `toggleMetering`, aus dem Fehlerpfad von `startMetering` und aus `observeEvents` gerufen - nie beim Verschwinden der View und nie, wenn woanders eine Aufnahme startet.

Fehlerpfad A (iPhone): Audio readiness -> "Start metering" -> in der Seitenleiste "Record" waehlen -> Record druecken. Die Readiness-View verschwindet, aber weder wird `capture` gestoppt noch die Session deaktiviert. `RecordingModel.start()` legt nun eine zweite `AVAudioEngine` an und installiert einen zweiten Tap auf demselben Eingang der gemeinsamen Session. Genau davor warnt der Code an zwei Stellen selbst (AudioLevel.swift:31-33 und RecordingModel.swift:507-508: "two taps on one input node is how you get a silent recording"). Ob der alte Tap noch existiert, haengt allein am Deallokationszeitpunkt des `@State`-Modells - also am Zufall, nicht an einer Zusicherung.

Fehlerpfad B (iPad, `UIApplicationSupportsMultipleScenes: true`, ein prozessweites AppModel laut AppModel.swift:17-19): Fenster A steht auf Audio readiness mit laufendem Metering, Fenster B startet die Aufnahme. Der Metering-Knopf in A verschwindet zwar (Zeile 54-60), das laufende Metering wird aber nicht beendet - die zwei Taps bestehen parallel.

Unabhaengig davon bleibt `AVAudioSession` nach `setActive(true)` prozessweit aktiv, wenn niemand `deactivate()` ruft: Mikrofonindikator und Session-Besitz bleiben stehen, obwohl nichts mehr aufgenommen wird.

```swift
AudioReadinessView.swift:309-317
        .onChange(of: app.language.selectedID) { ... }
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.start() }   // kein .onDisappear

AudioReadinessView.swift:510-517
    private func stopMetering() async {
        levelTask?.cancel()
        levelTask = nil
        await capture.stop()
        try? await controller.deactivate()

AudioReadinessView.swift:54-60 - waehrend einer Aufnahme wird nur der Knopf ausgeblendet, laufendes Metering nicht beendet.
```

**Korrekturskizze:** `.onDisappear { Task { await model.stopMetering() } }` ergaenzen (bzw. `start()` per `defer`/`withTaskCancellationHandler` aufraeumen lassen) und `stopMetering` internal machen. Zusaetzlich in `AudioReadinessModel` auf `recording.isActive` reagieren und laufendes Metering beenden, sobald eine Aufnahme beginnt - sonst bleibt Fehlerpfad B offen. `AudioReadinessModel.start()` sollte `controller.configure()` ausserdem nicht bedingungslos auf der geteilten Session ausfuehren, waehrend eine Aufnahme laeuft (`.categoryChange` gilt in dieser App als aufnahmebeendend).

**Adversariale Pruefung:** Der Kern stimmt: AudioReadinessView.swift:308-317 haengt nur `.task { await model.start() }` an, kein `.onDisappear`; `stopMetering` (510-517) wird ausschliesslich aus `toggleMetering`, dem Fehlerzweig von `startMetering` (506) und `observeEvents` (534, 537) gerufen. Wer den Bildschirm mit laufendem Metering verlaesst, stoppt weder `capture` noch die Session - `deactivate()` steht nur in `stopMetering`, die prozessweite Session bleibt also aktiv (Mikrofonindikator). Fehlerpfad B ist ohne Zufall erreichbar und ich habe die Voraussetzungen geprueft: `UIApplicationSupportsMultipleScenes: true` (iOS/project.yml:72, iOS/App/Info.plist:51) und ein prozessweites `AppModel` (StenoApp.swift:7, AppModel.swift:12-19); AudioReadinessView.swift:54-60 blendet bei laufender Aufnahme nur den Knopf aus, `isMetering` und der Tap laufen weiter. Fehlerpfad A haengt dagegen tatsaechlich am Deallokationszeitpunkt des `@State`-Modells, weil ContentView.swift:102-123 den Detailbereich per switch ersetzt - das raeumt in der Regel Modell, Capture und Engine ab. Ob zwei AVAudioEngines auf derselben Session eine stille Aufnahme ergeben, ist Betriebssystemverhalten und nicht am Code belegbar; belegt sind nur die eigenen Warnungen (AudioLevel.swift, RecordingModel.swift:507-508). Deshalb MEDIUM statt HIGH.

### 23. [MEDIUM] Unterbrechungen im Zustand .preparing werden verworfen - die App meldet danach eine Aufnahme, die nicht laeuft

`iOS/App/Sources/RecordingModel.swift:553` - Subsystem ios, Kategorie correctness/regel-1

`handleInterruption` verlaesst sich auf `guard case .recording = state`. `state` wird aber erst in Zeile 205 gesetzt, also nach `activate()` (165), `createRecordingMeeting()` (169), `session.start()` (191) und `liveAudioEvents` (197). Alles dazwischen ist Datei-I/O und laeuft auf einem belasteten Geraet messbar lange.

Verschaerfend: `observeSessionEvents()` (533) meldet den Strom erst innerhalb eines neu erzeugten Tasks an (`await self?.audioSession.events()`), also fruehestens beim naechsten Aktorwechsel. Zwischen `activate()` und dieser Anmeldung existiert gar kein Abnehmer - `AudioSessionController.emit` gibt an die dann noch leere `continuations`-Menge weiter, und AsyncStream puffert nichts nach.

Fehlerpfad: Nutzer tippt Record, unmittelbar danach kommt ein Anruf. iOS deaktiviert die Session und stoppt die Engine. Das `interruptionBegan` faellt entweder in das Anmeldeloch oder in den `.preparing`-Guard. `start()` laeuft zu Ende, setzt `state = .recording`, roter Punkt und Laufzeit laufen. `RecordingSession.state` wird nicht terminal (kein Writer-Fehler, nur ausbleibende Buffer), also greift auch `tick()`s Terminal-Pruefung nicht. Die Spur besteht ab Sekunde null aus der Stille, die `TrackContinuity.fillSilence` nachschiebt. Einziger Hinweis ist der SilenceMonitor nach 20 s.

```swift
RecordingModel.swift:552-562
    private func handleInterruption(_ reason: String) async {
        guard case .recording = state else { return }

RecordingModel.swift:164-205
            try await audioSession.activate()
            observeSessionEvents()
            let meeting = try await createRecordingMeeting(...)
            ...
            try await session.start()
            ...
            state = .recording

RecordingModel.swift:533-536
        sessionEventTask = Task { [weak self] in
            guard let stream = await self?.audioSession.events() else { return }
```

**Korrekturskizze:** Den Guard auf `.preparing` ausweiten (bei `.preparing` das Ereignis vormerken und direkt nach `state = .recording` anwenden, bzw. den Start abbrechen und die bereits geschriebene Spur regulaer ueber `tearDown` schliessen). Den Ereignisstrom ausserdem synchron vor `activate()` anmelden - `events()` gibt den Strom sofort zurueck, nur die Task-Erzeugung darf danach kommen.

**Adversariale Pruefung:** Beide behaupteten Luecken sind im Code vorhanden. `handleInterruption` verlangt `guard case .recording = state` (RecordingModel.swift:553), `state = .recording` steht erst in Zeile 205, also nach `activate()` (166), `createRecordingMeeting()` (169), `session.start()` (191) und `liveAudioEvents` (197). Das Anmeldeloch stimmt ebenfalls: `observeSessionEvents` (533-535) holt den Strom erst im neu erzeugten Task ueber `await self?.audioSession.events()`, waehrend `AudioSessionController.activate()` (AudioSessionController.swift:54-57) die Beobachter sofort startet und `emit` (98-102) an die dann noch leere `continuations`-Menge verteilt - AsyncStream puffert dafuer nichts. Folgekette wie bei Befund 0: kein terminaler RecordingSession-Zustand, also greift RecordingModel.swift:500 nicht, und TrackContinuity schreibt Stille. Eine Teilabsicherung besteht allerdings: faellt die Unterbrechung vor `session.start()`, scheitert der Engine-Start sehr wahrscheinlich und der `catch` (210-214) setzt `.failed`. Das echte Fenster ist damit schmal (zwischen 191 und 205 sowie das Anmeldeloch). Tests dafuer gibt es keine (kein Treffer auf `interruptionBegan`/`handleInterruption` in iOS/App/Tests). MEDIUM ist angemessen.

### 24. [MEDIUM] Meeting-Mutatoren lesen ausserhalb der Sperre und schreiben das ganze meeting.json zurueck

`StenoKit/Sources/StenoLibrary/Library.swift:344` - Subsystem library, Kategorie concurrency

`renameMeeting` laedt das Meeting in Zeile 344 ungesperrt und schreibt in Zeile 357-359 innerhalb der exklusiven Sperre das komplette Dokument inklusive `status: old.status` zurueck. Dasselbe Muster in `updateMeetingParticipants` (233/235), `updateAdditionalMeetingParticipants` (249/252), `setMeetingParticipants` (383/386) und `setMeetingFolders` (281, plus je Meeting eine eigene Sperr-Nahme in 286/294). Nur `updateMeetingStatus` (187-197) macht es richtig und liest innerhalb der Transaktion. Konkreter Fehlerpfad ohne zweiten Prozess: Der Library-Actor fuehrt `renameMeeting` aus und liest status = .ready. Gleichzeitig haelt `PipelineCoordinator` (PipelineCoordinator.swift:315-348) die exklusive Sperre und ruft die nonisolated `library.updateMeetingStatus(_:to:.processing,transaction:)` - das laeuft auf einem anderen Executor als der Library-Actor. `renameMeeting` blockiert am flock, bekommt es nach Freigabe und schreibt `status: .ready` zurueck. Das Meeting steht danach auf .ready, obwohl der finalASR-Job laeuft; `RecoverySweep` und die Oberflaeche leiten ihren Zustand aus genau diesem Feld ab. Ueber `setMeetingFolders` geht zusaetzlich der Rollback-Pfad (restore in 293-300) mit demselben veralteten Original zurueck und macht fremde Aenderungen mit.

```swift
let old = try loadMeeting(meetingID)            // Zeile 344, ungesperrt
let renamed = Meeting(schemaVersion: old.schemaVersion, id: old.id, title: trimmed,
                      createdAt: old.createdAt, status: old.status, ...)
try LibraryMutationCoordination.withExclusiveAccess(layout: layout) {   // Zeile 357
    try JSONDocumentStore.write(renamed, to: layout.meetingMetadata(meetingID))
}
```

**Korrekturskizze:** Alle Meeting-Mutatoren auf `withExclusiveTransaction` umstellen und das Meeting INNERHALB der Transaktion laden (wie `updateMeetingStatus(_:to:transaction:)`), statt einen vorher gelesenen Snapshot zurueckzuschreiben. Fuer `setMeetingFolders` die gesamte Stapelaenderung in genau eine Transaktion legen, damit auch der Kompensationspfad denselben Stand sieht.

**Adversariale Pruefung:** Muster am Code bestaetigt: `renameMeeting` liest in Library.swift:344 ausserhalb, schreibt in 357-359 innerhalb der Sperre das ganze Dokument inklusive `status: old.status`; dasselbe in updateMeetingParticipants (233/235), updateAdditionalMeetingParticipants (249/252), setMeetingParticipants (383/386), setMeetingFolders (281/286/294). Nur updateMeetingStatus (187-197) liest via `loadMeeting(_:transaction:)` innerhalb der Transaktion.

Der Nebenlaeufigkeitspfad ist real: `Library` ist ein Actor (Library.swift:23), aber `updateMeetingStatus(_:to:transaction:)` ist `nonisolated` (204-215) und wird von PipelineCoordinator.setMeetingStatus (PipelineCoordinator.swift:338-350 ueber withCurrentMeetingGeneration:311-336) auf dessen eigenem Executor unter gehaltener exklusiver Sperre ausgefuehrt. flock-Sperren haengen an der Open-File-Description, zwei `open()`-Aufrufe im selben Prozess konkurrieren also tatsaechlich - der Actor-Leser blockiert am flock und schreibt danach seinen veralteten Stand zurueck.

Schwere von high auf medium korrigiert: Ich habe geprueft, welche off-Actor-Schreiber es fuer `meeting.json` ueberhaupt gibt - nur `updateMeetingStatus(transaction:)` (MeetingTransferStateStore.swift:529 liest nur). Verloren gehen kann also ausschliesslich ein Statusuebergang, kein Titel, keine Teilnehmer, keine transferReceipt-Metadaten. Der Schaden heilt zudem meist von selbst, weil die Pipeline am Laufende erneut schreibt, und der beschriebene RecoverySweep-Folgeschaden (RecoverySweep.swift:14-37) ist durch `containsJob(kind:.finalASR)` gegen Doppel-Jobs abgesichert. Die Sperrdisziplin ist trotzdem eindeutig verletzt und in fuenf Methoden gleich falsch.

### 25. [MEDIUM] Nach fehlgeschlagenem Laden ueberschreibt die erste Eingabe die vorhandene Notiz

`StenoKit/Sources/StenoLibrary/MeetingNotesEditingSession.swift:69` - Subsystem library, Kategorie data-loss

Schlaegt `performInitialLoad` fehl (Zeile 62-66), bleiben `text` und `savedText` auf "", `hasLoaded` bleibt false, und es wird nur `errorMessage` gesetzt. `update(_:)` und `persist` pruefen diesen Fehlerzustand nicht: sobald der Benutzer im (leer wirkenden) Editor ein Zeichen tippt, gilt `value != savedText`, der Autosave laeuft nach einer Sekunde und `MeetingNotesStore.setNotes` schreibt den einzelnen Buchstaben atomar ueber `notes/user-notes.md`. Der vorhandene Notizinhalt ist damit weg - AtomicFile ersetzt die Datei vollstaendig, es gibt keine Revision und keinen Papierkorb (anders als bei Transkripten, MeetingNotesStore.swift:9-15 begruendet das bewusst). Ausloeser fuer den fehlgeschlagenen Load sind in `MeetingNotesStore.read` (74-87) alle nicht-`fileNoSuchFile`-Fehler von `attributesOfItem`/`Data(contentsOf:)` sowie `CocoaError(.fileReadCorruptFile)` bei nicht-UTF-8-Bytes. `flush()` (116-130) hat denselben Weg und schreibt sogar ausdruecklich, wenn `errorMessage != nil`.

```swift
} catch {                                   // performInitialLoad, Zeile 62
    guard generation == loadGeneration else { return }
    isSaving = false
    errorMessage = error.localizedDescription   // hasLoaded bleibt false, text bleibt ""
}
...
public func update(_ value: String) {        // Zeile 69 - kein Schutz gegen "nie geladen"
    text = value
    ...
    guard value != savedText else { ... }     // savedText == "" -> es wird gespeichert
```

**Korrekturskizze:** Eine `loadFailed`-Kennzeichnung fuehren und in `update`, `appendMarker`, `flush` und `persist` jedes Schreiben verweigern, solange `hasLoaded == false`. Die Oberflaeche sollte den Editor in diesem Zustand als nicht bearbeitbar zeigen statt als leere Notiz.

**Adversariale Pruefung:** Am Code nachvollzogen und in der Oberflaeche gegengeprueft. Nach einem fehlgeschlagenen Laden (MeetingNotesEditingSession.swift:62-66) bleiben `text` und `savedText` auf "", `hasLoaded` bleibt false; `update(_:)` (69-92) und `persist` (132-145) kennen keinen Ladefehler-Zustand. NotesSection.swift:33-55 deaktiviert den TextEditor nur bei `session == nil`, nicht bei `errorMessage != nil` - der Editor ist also tippbar und sieht leer aus, und der Autosave schreibt ueber `MeetingNotesStore.setNotes` (MeetingNotesStore.swift:52-72) via AtomicFile das gesamte `notes/user-notes.md` neu. Es gibt dort bewusst keine Revision und keinen Papierkorb (Kommentar 9-15).

Der Reviewer unterschaetzt den Pfad sogar: `flush()` (116-130) hat die Bedingung `value != savedText || errorMessage != nil`. Nach einem Ladefehler ist `value == savedText == ""`, aber `errorMessage != nil`, also wird `persist("")` ausgefuehrt - und `setNotes` loescht bei leerem Text die Datei (MeetingNotesStore.swift:59-64). Es genuegt also, das Meeting zu oeffnen und wegzuklicken (NotesSection.swift:57-64 `.task(id:)`/`.onDisappear`, AppModel.swift:976-978), um die Notiz zu verlieren - ohne einen einzigen Tastendruck.

Ausloeser sind alle Nicht-`fileNoSuchFile`-Fehler in `MeetingNotesStore.read` (74-87), inklusive `CocoaError(.fileReadCorruptFile)` bei Nicht-UTF-8. Die Tests decken nur Schreibfehler ab (MeetingNotesEditingSessionTests.swift:119 `writeFailureLeavesTextVisibleForRetry`), keinen Lesefehler - dort kommt die `errorMessage != nil`-Klausel her, und genau die schlaegt im Ladefall ins Gegenteil um. Schwere medium bleibt, weil der Ausloeser (Lesefehler auf einer eigenen, zuvor selbst geschriebenen UTF-8-Datei) selten ist.

### 26. [MEDIUM] FolderStore schreibt folders.json ganz ohne Bibliothekssperre

`StenoKit/Sources/StenoLibrary/FolderStore.swift:402` - Subsystem library, Kategorie concurrency

`write` ruft direkt `JSONDocumentStore.write` auf, ohne `LibraryMutationCoordination` - anders als der strukturgleiche `IdentityStore.write` (IdentityStore.swift:341). Gelesen wird ausserdem in `readDocument` (390) ausserhalb jeder Sperre, und jede Mutation (createFolder:127, renameFolder:168, moveFolder:188, deleteFolder:248, reorderFolders:311, adoptLegacyFolders:344, markLegacyFoldersAdopted:384) ist ein Read-Modify-Write des Gesamtdokuments. Konkreter Fehlerpfad: In AGENTS.md ist festgehalten, dass sich alle Mac-Builds dieselbe Bibliothek unter ~/Library/Application Support/Steno/Library teilen. Build A legt Ordner X an (liest F0, schreibt F0+X), Build B benennt zeitgleich Ordner Y um (liest F0, schreibt F0'). Wer zuletzt schreibt, gewinnt; die andere Aenderung ist verschwunden, und bei `deleteFolder` verschwindet zusaetzlich die bereits angewandte Promotion der Kindordner. Auch die Migration in `prepare` (71-90) schreibt das migrierte Dokument ungesperrt zurueck (JSONDocumentStore.migrateAndRead:89), waehrend ein zweiter Prozess bereits v2 schreibt.

```swift
private func write(_ document: FoldersDocument) throws {
    try JSONDocumentStore.write(document, to: layout.folders)
}
// zum Vergleich IdentityStore.swift:341-348 nimmt fuer denselben Dokumenttyp withExclusiveAccess
```

**Korrekturskizze:** `readDocument`/`write` in eine gemeinsame `LibraryMutationCoordination.withExclusiveTransaction` einschliessen, sodass Lesen, Pruefen und Schreiben einer Ordneraenderung unter einer Sperre stehen; die Migration in `prepare` ebenfalls unter die exklusive Sperre nehmen.

**Adversariale Pruefung:** Faktenlage stimmt: `FolderStore.write` (FolderStore.swift:402-404) ruft `JSONDocumentStore.write` direkt auf, `readDocument` (390-400) liest ungesperrt, und alle Mutatoren sind Read-Modify-Write des Gesamtdokuments (127, 168, 188, 248, 311, 344, 384). Ein grep ueber alle Quellen bestaetigt: `LibraryMutationCoordination` kommt in FolderStore.swift kein einziges Mal vor, waehrend IdentityStore, Library, MeetingNotesStore, RevisionStore, MeetingTransferStateStore und PreparedMeetingImport es nutzen. Auch `prepare` (63-91) schreibt die v1->v2-Migration ueber `JSONDocumentStore.migrateAndRead` (JSONDocumentStore.swift:88) ungesperrt zurueck.

Einschraenkung, die der Befund nicht nennt: `FolderStore` ist ein Actor und wird pro Laufzeit genau einmal erzeugt (App/Sources/AppModel.swift:674; der iOS-Pfad ersetzt die Instanz in AppModel+Folders.swift:143 ueber `adoptFolderStore`, benutzt also nie zwei parallel). Alle Mutatoren sind synchron innerhalb des Actors, in einem Prozess ist das RMW damit serialisiert. Der Befund ist folglich ausschliesslich prozessuebergreifend erreichbar - genau das ist aber die ausdrueckliche Zusage der Sperrschicht: "Serializes snapshot-sensitive library mutations across actors and Steno processes that opened the same library root" (LibraryMutationCoordination.swift:5-11). Die Zusage gilt fuer folders.json nicht. Schwere medium bleibt angemessen, eher am unteren Rand.

### 27. [MEDIUM] claimNext und transition laufen ohne Bibliothekssperre - derselbe Job kann zweimal beansprucht werden

`StenoKit/Sources/StenoLibrary/JobStore.swift:465` - Subsystem library, Kategorie concurrency

`claimNext` listet alle Jobs und schreibt danach ueber `transition` (349-370, ebenfalls Read-Modify-Write ohne Sperre) den Statuswechsel. Keiner der beiden Pfade nimmt `LibraryMutationCoordination`, obwohl andere Job-Pfade das ausdruecklich tun (`ensureEnqueued(_:transaction:)`:82, `enqueueOrExistingEquivalentJob(_:blockingStatuses:transaction:)`:173) und obwohl `enqueue` sonst mit `commitWithoutReplacing` (RENAME_EXCL) gegen Rennen abgesichert ist. Konkreter Fehlerpfad: Zwei gleichzeitig laufende Steno-Builds auf derselben Bibliothek. Beide fuehren `claimNext(kind: .templateRender)` aus, sehen denselben Job im Status .queued, beide bestehen `allowsTransition(.queued -> .running)` und schreiben `status = .running`. Der Job laeuft doppelt: zwei Laeufe, zwei `TemplateResult`-Schreibvorgaenge auf `reports/<runID>.json` und - bei einem gewaehlten externen Textmodell - zwei Netzwerkanfragen mit demselben Transkript. Dasselbe Rennen trifft `recoverAtLaunch` (372-378) und `requeueFailedJobs` (385-408): ein gerade von Prozess A auf .running gesetzter Job wird von Prozess B beim Start auf .queued zurueckgesetzt.

```swift
public func claimNext(kind: Job.Kind) throws -> Job? {
    guard let job = try list().first(where: { $0.kind == kind && $0.status == .queued }) else { return nil }
    return try transition(job.id, to: .running)   // keine Sperre zwischen Auswahl und Schreiben
}
// transition:355  var job = try load(jobID) ... 368  try JSONDocumentStore.write(job, to: layout.job(jobID))
```

**Korrekturskizze:** `claimNext`, `transition`, `recoverAtLaunch` und `requeueFailedJobs` in `LibraryMutationCoordination.withExclusiveTransaction` ausfuehren und den Job innerhalb der Transaktion neu laden, sodass Auswahl und Statuswechsel prozessuebergreifend atomar sind.

**Adversariale Pruefung:** Code stimmt: `claimNext` (JobStore.swift:465-472) listet und ruft `transition` (349-370), das selbst `load` + `JSONDocumentStore.write` ohne Sperre macht; ebenso `recoverAtLaunch` (372-378) und `requeueFailedJobs` (385-408). Keiner dieser Pfade nimmt `LibraryMutationCoordination` - ein grep bestaetigt, dass JobStore.swift die Sperre nirgends verwendet.

Zwei Praezisierungen an der Begruendung des Reviewers: (a) `ensureEnqueued(_:transaction:)` (82-88) und `enqueueOrExistingEquivalentJob(_:blockingStatuses:transaction:)` (173-183) nehmen die Sperre nicht selbst, sie validieren nur eine vom Aufrufer gehaltene Transaktion - das Vorbild ist also schwaecher als behauptet, der Punkt bleibt aber; (b) `JobStore` ist ein Actor mit genau einer Instanz pro Laufzeit, `claimNext` wird nur aus PipelineCoordinator.swift:281 aufgerufen. Innerhalb eines Prozesses ist die Doppelbeanspruchung damit ausgeschlossen; erreichbar ist sie nur bei zwei gleichzeitig laufenden Steno-Prozessen auf derselben Bibliothek - was die Sperrschicht ausdruecklich abdecken soll (LibraryMutationCoordination.swift:5-11) und was AGENTS.md fuer geteilte Mac-Bibliotheken als reale Situation beschreibt. Die genannte Folge (zwei Netzanfragen mit demselben Transkript bei externem Textmodell) setzt genau diese Zwei-Prozess-Lage voraus. Schwere medium ist damit eher grosszuegig, aber vertretbar.

### 28. [MEDIUM] RevisionAppendRecovery spielt eine liegengebliebene Absicht bedingungslos ueber einen neueren Zeiger

`StenoKit/Sources/StenoLibrary/RevisionStore.swift:392` - Subsystem library, Kategorie correctness/data-consistency

`RevisionAppendRecovery.recover` schreibt `intent.resultingPointer` ohne jede Pruefung, ob `current.json` inzwischen weitergewandert ist. Gleichzeitig beruecksichtigt `adoptPendingRevision` (208-225) die Absichtsdatei nicht: es liest den Zeiger, schreibt einen neuen und laesst `transcript/append-intent.json` unangetastet. Konkreter Fehlerpfad: `appendRevisionWithoutMutationLock` schreibt die Absicht (149) und die Revision (153); der anschliessende Zeiger-Schreibvorgang (158) scheitert (z. B. ENOSPC), also bleibt die Absichtsdatei liegen und der Prozess laeuft weiter. Der Benutzer uebernimmt danach den geparkten Neulauf: `adoptPendingRevision` setzt `current.json` auf den Kandidaten. Beim naechsten `appendRevision` fuer dasselbe Meeting laeuft zuerst `recover` (82) und ueberschreibt `current.json` mit `intent.resultingPointer`, also mit dem Stand VOR der Uebernahme. Der uebernommene Neulauf ist damit still wieder abgewaehlt, und der Benutzer sieht ohne Meldung wieder den alten Text als aktuellen Stand. Dieselbe Situation entsteht prozessuebergreifend, wenn Prozess A mit liegengebliebener Absicht abstuerzt und der bereits laufende Prozess B (der `Library.init`/`recoverAll` nicht erneut durchlaeuft) den Zeiger zwischenzeitlich fortschreibt.

```swift
try JSONDocumentStore.write(
    intent.resultingPointer,
    to: layout.currentRevision(meetingID)   // Zeile 392: kein Vergleich mit dem aktuellen Zeiger
)
try FileManager.default.removeItem(at: intentURL)
// adoptPendingRevision:208-225 ruft RevisionAppendRecovery.recover nie auf
```

**Korrekturskizze:** In `recover` vor dem Schreiben den aktuellen Zeiger laden und die Absicht nur anwenden, wenn er noch dem Vorzustand entspricht (Absicht um den erwarteten Vorgaengerzeiger erweitern); andernfalls die Absicht nur entfernen. Zusaetzlich `adoptPendingRevision` - wie `appendRevision` - mit `RevisionAppendRecovery.recover` beginnen lassen, damit es nie auf einem unvollstaendigen Anhaengevorgang entscheidet.

**Adversariale Pruefung:** Beide Teilbehauptungen am Code bestaetigt: `RevisionAppendRecovery.recover` schreibt `intent.resultingPointer` in RevisionStore.swift:392-395 ohne jeden Vergleich mit dem aktuellen `current.json`, und `adoptPendingRevision` (203-226) liest den Zeiger, schreibt einen neuen (223) und fasst `transcript/append-intent.json` nicht an - `recover` wird dort nie aufgerufen. Aufrufer geprueft: `adoptPendingRevision` kommt aus AppModel+Transcript.swift:73 und MeetingDiarizationRequest.swift:78, keiner der beiden ruft vorher `recover`.

Der Fehlerpfad ist damit real: schlaegt der Zeigerschreibvorgang in 158-161 fehl (oder das `removeItem` in 162-164), bleibt die Absichtsdatei liegen, waehrend der Prozess weiterlaeuft. Ein danach vom Benutzer uebernommener geparkter Neulauf wird beim naechsten `appendRevision` durch `recover` (aufgerufen in 82) still auf den Vor-Uebernahme-Zeiger zurueckgesetzt.

Zwei Einschraenkungen, die die Schwere deckeln: Der reine Absturzfall ist abgesichert, weil `Library.init` (Library.swift:86-88) `recoverAll` unter der Sperre ausfuehrt, bevor irgendeine Uebernahme moeglich ist - es braucht also einen fehlgeschlagenen Schreibvorgang bei weiterlaufendem Prozess (ENOSPC, EIO) und einen bereits vorhandenen `pendingCandidate`. Und es gehen keine Originale verloren: alle Revisionen bleiben liegen, verstellt wird nur der Zeiger. Das verletzt aber "nichts raten, was der Nutzer als Tatsache liest": der Benutzer sieht ohne Meldung wieder den alten Text als aktuellen Stand. Schwere medium bestaetigt.

### 29. [MEDIUM] Scheitert der Stopp, bleibt das Meeting dauerhaft auf Status `.recording` und ohne finalASR-Job

`App/Sources/AppModel.swift:1005` - Subsystem macos-app, Kategorie -

Im `catch` von `performStopRecording` wird nur gemeldet; anders als im `catch` von `startRecording` (Zeilen 942-950, dort `updateMeetingStatus(failedMeetingID, to: .interrupted)`) bleibt der Meeting-Status auf `.recording`, und der `finalASR`-Job (Zeile 1000) wird nie eingereiht, weil er im selben `do`-Block hinter der Fehlerquelle steht. Konkreter Fehlerpfad: `session.stop()` scheitert (z. B. `writer.close()` oder `registerMediaAsset` wirft, RecordingSession.swift:310-317, dort auch `state = .failed`). Der Nutzer sieht "The recording could not be stopped cleanly.", die App setzt `isRecording = false` (1008) — in der Seitenleiste steht das Meeting danach dauerhaft mit dem Badge "Recording", und genau dieser Status sperrt "Transcribe Again…" (MeetingSidebarView.swift:358-361) und "Move to Trash…" (374). Der Nutzer hat also weder Transkript noch Job noch eine Möglichkeit, den Zustand selbst aufzulösen; erst ein App-Neustart repariert das über RecoverySweep/CaptureRecovery.

```swift
AppModel.swift:1000-1006  `try await runtime.jobStore.enqueue(Job(kind: .finalASR, meetingID: meetingID)) ... } catch { report(Self.message("The recording could not be stopped cleanly.", error)) }`
AppModel.swift:944-950 (Gegenbeispiel im Startpfad)  `_ = try? await runtime.library.updateMeetingStatus(failedMeetingID, to: .interrupted)`
MeetingSidebarView.swift:358-361  `.disabled(meeting.status == .recording || !model.meetingsWithAudio.contains(meeting.id))`
```

**Korrekturskizze:** Im `catch` das Meeting auf `.interrupted` setzen und den finalASR-Job separat vom Stop-Ergebnis einreihen (eigener `do`/`try?`-Block nach dem Stopp), damit ein Fehler beim Schließen der Spuren nicht auch noch die Nachverarbeitung verhindert — das ist genau die in AGENTS.md geforderte Trennung von Aufnahme und Nachverarbeitung.

**Adversariale Pruefung:** Bestaetigt. In finalizeStop steht `updateMeetingStatus(meetingID, to: .ready)` erst hinter der Schleife mit `writer.close()`/`registerMediaAsset` (RecordingSession.swift:310-320); wirft dort etwas, bleibt der Meeting-Status `.recording` und der Fehler landet im catch von performStopRecording (AppModel.swift:1004-1006), das im Unterschied zum Startpfad (944-950 setzt `.interrupted`) nichts korrigiert. `jobStore.enqueue(Job(kind: .finalASR, ...))` (1000) steht im selben do-Block hinter der Fehlerquelle und wird nie erreicht. Die UI-Sackgasse stimmt: MeetingSidebarView.swift:358-361 sperrt "Transcribe Again…" und 374 "Move to Trash…" bei `status == .recording`. Reparatur nur ueber Neustart, und die funktioniert tatsaechlich: die Capture-Dateien bleiben liegen (removeItem in RecordingSession.swift:317 wird nicht erreicht), RecoverySweep setzt `.interrupted`, CaptureRecovery adoptiert. Kein Datenverlust, deshalb medium korrekt.

### 30. [MEDIUM] Herausgeschnittener Audio-Ausschnitt bleibt im Temp-Verzeichnis liegen, wenn der Player nicht initialisiert werden kann

`App/Sources/AppModel+Review.swift:286` - Subsystem macos-app, Kategorie -

`extractClip` schreibt eine unkomprimierte Kopie des Original-Ausschnitts nach `FileManager.default.temporaryDirectory` (AppModel+Review.swift:363-364). Der Aufräumpfad ist nur für zwei Fälle gebaut: `player.play() == false` (287-290) und `stopSamplePlayback()` (328-330, über `sampleClipURL`). Wirft aber `AVAudioPlayer(contentsOf: clipURL)` in Zeile 286 — erreichbar, weil der Clip im `processingFormat` des Originals geschrieben wird und AVAudioPlayer nicht jedes CAF-Format öffnet, und ebenso bei belegtem/vollem Temp-Volume —, springt der Code direkt in den `catch` (300), bevor `sampleClipURL = clipURL` (292) gesetzt wurde. Die Datei ist damit von keiner Aufräumroutine mehr erreichbar und bleibt als unverschlüsselter Sprachausschnitt aus einer Besprechung im Temp-Verzeichnis liegen. Identisch in `togglePersonSample` (AppModel+People.swift:170, `sampleClipURL` wird erst in Zeile 177 gesetzt).

```swift
AppModel+Review.swift:280-292  `let clipURL = try Self.extractClip(...)` / `let player = try AVAudioPlayer(contentsOf: clipURL)` / `guard player.play() else { try? FileManager.default.removeItem(at: clipURL); ... }` / `samplePlayer = player` / `sampleClipURL = clipURL`
AppModel+People.swift:165-178  gleicher Aufbau
```

**Korrekturskizze:** Den Clip sofort nach `extractClip` absichern, z. B. `sampleClipURL = clipURL` direkt nach der Erzeugung setzen (und `stopSamplePlayback()` im Fehlerpfad aufrufen), oder den Abschnitt von `extractClip` bis `player.play()` in ein `do { } catch { try? FileManager.default.removeItem(at: clipURL); throw error }` klammern.

**Adversariale Pruefung:** Der Leck-Pfad ist am Code eindeutig: in AppModel+Review.swift wird `clipURL` in 280-285 erzeugt, in 286 folgt der werfende `AVAudioPlayer(contentsOf:)`, und `sampleClipURL = clipURL` erst in 292. Wirft 286, springt der Code nach 300 (`catch { reviewError = ... }`) - `stopSamplePlayback()` (327-330) kann die Datei dann nicht mehr finden, weil `sampleClipURL` nie gesetzt wurde. Gleiche Struktur in AppModel+People.swift:169-177. Zusaetzlich (vom Reviewer nicht genannt, gleiche Klasse): auch `try output.write(from: buffer)` in extractClip (AppModel+Review.swift:377) wirft nach dem Anlegen der Datei und laesst sie liegen, weil die URL nie zurueckgegeben wird. Die genannte Ursache "AVAudioPlayer oeffnet nicht jedes CAF" bleibt unbelegt - extractClip schreibt im processingFormat (PCM), das AVAudioPlayer normalerweise liest; wahrscheinlicher sind volles/gesperrtes Temp-Volume. Auslaesewahrscheinlichkeit also gering, Befund selbst aber real: unverschluesselter Besprechungsausschnitt bleibt im Temp-Verzeichnis, von keiner Aufraeumroutine mehr erreichbar.

### 31. [MEDIUM] Wiedergabefehler aus der Transkriptliste erreichen den Nutzer nie

`App/Sources/AppModel+Review.swift:301` - Subsystem macos-app, Kategorie -

`toggleSample` meldet jeden Fehlschlag ausschließlich über `reviewError` (Zeilen 268 und 301). `reviewError` wird an genau einer Stelle gerendert: in `SpeakerReviewSection` (SpeakerReviewSection.swift:34-38), und diese Sektion existiert nur, wenn `review != nil` **und** der Inspector offen ist (MeetingDetailView.swift:357-362, `showInspector`). Der Abspielknopf in der Transkriptliste hängt dagegen nur an `model.meetingsWithAudio.contains(meetingID)` (MeetingDetailView.swift:899). Konkreter Fehlerpfad: importiertes Meeting-Paket mit zwei Audiospuren und Turns ohne Cluster-Sprecher (`speaker == nil` oder `.importedTextLabel`) → `playbackChannel` liefert `""` (MeetingDetailView.swift:1037-1039) → `SpeakerPlaybackAssetSelection.asset` gibt bei `assets.count == 2` `nil` zurück (AppModel+Review.swift:14-18) → `reviewError = "No original track found for the voice sample."`. Da für dieses Meeting noch keine Diarisierung lief (`review == nil`), wird die Sektion gar nicht gebaut: Der Nutzer klickt auf Abspielen, es passiert nichts, und es steht nirgends warum. Dieselbe Unsichtbarkeit trifft "Playback failed: …" und "Playback could not be started.".

```swift
AppModel+Review.swift:267-269  `reviewError = "No original track found for the voice sample."`
AppModel+Review.swift:300-302  `} catch { reviewError = "Playback failed: \(error.localizedDescription)" }`
SpeakerReviewSection.swift:17-38  `if let review { ... if let error = model.reviewError { Label(error, ...) } }`
MeetingDetailView.swift:899-906  Abspielknopf nur an `model.meetingsWithAudio.contains(meetingID)` gebunden
```

**Korrekturskizze:** Fehler aus dem Wiedergabepfad über `report(...)` in die zentrale Meldungsleiste am Fenster schicken (die laut Kommentar in AppModel.swift:229-233 genau dafür existiert) statt in `reviewError`, oder `reviewError` zusätzlich außerhalb von `SpeakerReviewSection` anzeigen.

**Adversariale Pruefung:** Bestaetigt. `reviewError` wird laut vollstaendiger Suche ueber App/ nur an einer Stelle gerendert: SpeakerReviewSection.swift:34-38, und die gesamte View ist in `if let review` gekapselt (Zeile 17); eingebunden wird sie nur im Inspector und nur bei `review != nil` (MeetingDetailView.swift:357-362). Der Abspielknopf in der Transkriptliste haengt dagegen nur an `model.meetingsWithAudio.contains(meetingID)` (MeetingDetailView.swift:899). Der beschriebene Pfad stimmt: `playbackChannel` liefert fuer `.person`, `.importedTextLabel` und `nil` sowie fuer `.cluster` ohne `presentation.channel` "" (MeetingDetailView.swift:1028-1039), und `SpeakerPlaybackAssetSelection.asset` gibt bei leerem Channel und `assets.count != 1` nil zurueck (AppModel+Review.swift:14-18), worauf 267-269 nur `reviewError` setzt. Der Pfad ist sogar breiter als gemeldet: er trifft jede normale Aufnahme (Mikro- plus Systemspur, also `assets.count == 2`) bei Turns mit `.person`-Sprecher, auch wenn nie diarisiert wurde. Folge ist ein stiller Klick ohne Rueckmeldung, kein Datenverlust - medium passt.

### 32. [MEDIUM] Die Pipeline läuft mit einer anderen Transkriptionssprache als die Oberfläche anzeigt, und der Nutzer kann das nicht korrigieren

`App/Sources/AppModel.swift:717` - Subsystem macos-app, Kategorie -

`bootstrap` startet die Pipeline mit `locale` aus dem ungeprüften `selectedLanguageID` (Zeile 656), dessen Erstwert `Locale.current.identifier` ist (395-397). Erst danach läuft `loadAvailableLocales()` (711) und ersetzt einen nicht unterstützten Wert durch einen Fallback (725-735) — ohne die Pipeline neu zu starten und ohne den Wert zu persistieren. `PipelineCoordinator` hält seine Locale aber unveränderlich (`effectiveLocale = job.localeIdentifier.map(Locale.init) ?? locale`, PipelineCoordinator.swift:492), und die Jobs normaler Aufnahmen tragen kein `localeIdentifier` (`Job(kind: .finalASR, meetingID: meetingID)`, Zeile 1001). Konkreter Fehlerpfad: englisch eingestellter Mac in Deutschland, `Locale.current.identifier == "en_DE"`, keine gespeicherte Sprache. Pipeline startet mit `en_DE`. `loadAvailableLocales` löst `en_DE` gegen die **nach lokalisiertem Namen sortierte** Liste auf (719-722, 728-731), `SpeechAnalyzerProvider.prepareTranscriber` löst dasselbe `en_DE` später gegen die **unsortierte** `SpeechTranscriber.supportedLocales` auf (SpeechAnalyzerProvider.swift:178-182). `LocaleResolver.equivalent` endet ohne exakten Treffer und ohne Regionstreffer bei `supported.first { $0.language.languageCode == requestedLanguage }` — reihenfolgeabhängig. Die Oberfläche zeigt also z. B. "English (Australia)", transkribiert wird mit einer anderen englischen Variante; das ist genau die Klasse Fehler, die der Kommentar in LocaleResolver.swift:52-56 als real beobachtet beschreibt. Verschärfend: Wählt der Nutzer im Picker die angezeigte Sprache aus, um sie zu erzwingen, greift `guard ... identifier != selectedLanguageID else { return }` (748) und es passiert nichts — die Sitzung lässt sich nicht auf die angezeigte Sprache bringen.

```swift
AppModel.swift:395-398  `private(set) var selectedLanguageID: String = UserDefaults.standard.string(forKey: AppModel.languageDefaultsKey) ?? Locale.current.identifier`
AppModel.swift:656  `locale: locale` (in `startPipeline`, vor `loadAvailableLocales`)
AppModel.swift:711  `await loadAvailableLocales()`
AppModel.swift:719-735  `availableLocales = supported.sorted { localizedLanguageName($0) < localizedLanguageName($1) }` ... `selectedLanguageID = fallback?.identifier ?? ...` (kein `UserDefaults.set`, kein Pipeline-Neustart)
PipelineCoordinator.swift:492  `let effectiveLocale = job.localeIdentifier.map(Locale.init(identifier:)) ?? locale`
```

**Korrekturskizze:** `loadAvailableLocales()` vor dem Start der Pipeline ausführen und den aufgelösten Wert persistieren; oder nach der Korrektur die Pipeline mit dem korrigierten Wert neu aufsetzen. Zusätzlich in beiden Auflösungen dieselbe (unsortierte) `supported`-Liste an `LocaleResolver.select` übergeben, damit Anzeige und Lauf nicht auseinanderlaufen können.

**Adversariale Pruefung:** Kernaussage am Code bestaetigt. `selectedLanguageID` faellt ohne gespeicherte Wahl auf `Locale.current.identifier` zurueck (AppModel.swift:395-397), und genau dieser ungeprueete Wert geht als `locale:` in `startPipeline` (656), also in den Transkriptionspfad - Regel 4. Die Korrektur in `loadAvailableLocales` (711-735) laeuft erst danach, setzt nur `selectedLanguageID`, persistiert nichts (einziger `UserDefaults.set` ist in setLanguage, Zeile 754, laut Suche ueber App/) und startet die Pipeline nicht neu; PipelineCoordinator haelt seine Locale fest (PipelineCoordinator.swift:492) und normale Aufnahmen reihen `Job(kind: .finalASR, meetingID:)` ohne `localeIdentifier` ein (1001). Die Reihenfolgeabhaengigkeit ist ebenfalls belegt: LocaleResolver.equivalent endet fuer "en_DE" (kein exakter Treffer, keine Region DE) bei `supported.first { languageCode == en }`, die App loest gegen die nach lokalisiertem Namen sortierte Liste auf (719-722), SpeechAnalyzerProvider.prepareTranscriber gegen die unsortierte `SpeechTranscriber.supportedLocales` (SpeechAnalyzerProvider.swift:172-182). Der Onboarding-Wizard entschaerft das nicht: LanguagePage zeigt nur den Picker, ein Durchklicken ohne Aenderung ruft setLanguage nie auf. Auch die Sackgasse stimmt (`guard identifier != selectedLanguageID`, 748) - allerdings nur teilweise: der Nutzer kann sie ueber eine andere Sprache und zurueck aufloesen. Praktische Folge ist keine falsche Sprache, sondern eine falsche Regionsvariante derselben Sprache; ernster ist die daraus folgende Divergenz zur Modellpruefung (`refreshModelReadiness` arbeitet mit der korrigierten Locale), die den Finallauf mit `assetsNotInstalled` scheitern lassen kann. Kein Datenverlust - medium bleibt.

### 33. [MEDIUM] cancel() wartet unbegrenzt, wenn handle() den Statuswechsel nicht persistieren kann

`StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:196` - Subsystem pipeline, Kategorie correctness

Der Warteblock in `cancel(jobID:)` pollt `jobStore.load(jobID).status == .running` ohne Timeout und ohne `runtimeFailure` zu pruefen (anders als `waitUntilIdle()`, Zeile 231). `handle(_:for:)` hat aber einen Pfad, der den Job in `.running` stehen laesst: schlaegt im Cancel-Zweig `runStore.removeTemporaryArtifacts` oder `jobStore.transition(.cancelled)` mit einem anderen Fehler als `importedGenerationChanged` fehl, wird nur `runtimeFailure` gesetzt und zurueckgekehrt.

Konkreter Fehlerpfad: Job J laeuft, Nutzer bricht ab. `cancel` traegt J in `cancellationRequests` ein und cancelt den Task. `execute` wirft `CancellationError`. In `handle` wirft `withCurrentMeetingGeneration { removeTemporaryArtifacts }` z.B. einen POSIX-Fehler (Verzeichnis nicht loeschbar, Volume weg). Der `catch`-Zweig setzt `runtimeFailure` und kehrt zurueck - J bleibt `.running` in der JobStore-Datei. `consumeQueue` setzt `activeTask`/`activeJobID` auf nil und macht mit dem naechsten Job weiter, waehrend der `cancel`-Aufruf (und damit die aufrufende UI-Aktion) alle 25 ms endlos weiterpollt und nie zurueckkehrt.

```swift
cancellationRequests.insert(jobID)
activeTask?.cancel()
while try await jobStore.load(jobID).status == .running {
    try await Task.sleep(for: pollInterval)
}
return

// ... in handle(_:for:):
} catch {
    runtimeFailure = .persistenceFailure(String(describing: error))   // Job bleibt .running
}
```

**Korrekturskizze:** In der Warteschleife zusaetzlich `if let runtimeFailure { throw runtimeFailure }` pruefen (wie in `waitUntilIdle`) und/oder abbrechen, sobald `activeJobID != jobID` gilt. Zusaetzlich sollte `handle` im Fehlerfall den Job nicht in `.running` zuruecklassen, sondern mindestens einen Terminalversuch (`.failed`) unternehmen.

**Adversariale Pruefung:** Pfad am Code belegt: `cancel` pollt in Zeile 196-198 ohne Timeout und ohne `runtimeFailure`-Pruefung, waehrend `waitUntilIdle` (Zeile 231) genau diese Pruefung hat. In `handle` faengt der generische `catch` (Zeile 1110-1112) Fehler aus `withCurrentMeetingGeneration { removeTemporaryArtifacts }` bzw. aus `jobStore.transition(.cancelled)` ab, setzt nur `runtimeFailure` und kehrt zurueck - der Job bleibt in der JSON-Datei auf `.running`, niemand setzt ihn spaeter zurueck (`recoverAtLaunch` erst beim naechsten Start). `consumeQueue` raeumt `activeTask`/`activeJobID` auf und macht weiter, der `cancel`-Aufruf pollt endlos alle 25 ms. Zusatzfall gleicher Wurzel: bei `stopping == true` und nicht vorgemerkter Cancel-Anforderung tut `handle` ebenfalls nichts (Zeile 1113), Job bleibt `.running`. Voraussetzung ist ein I/O-Fehler beim Aufraeumen/Persistieren, deshalb medium und nicht hoeher; der haengende Aufruf ist eine async UI-Aktion (AppModel+Review.swift:536-548), das Fenster friert nicht ein.

### 34. [MEDIUM] Eine Review-Aktion wird in drei unabhaengigen Transaktionen persistiert und kann halb geschrieben liegenbleiben

`StenoKit/Sources/StenoPipeline/MeetingReviewController.swift:103` - Subsystem pipeline, Kategorie data-integrity

Der Doc-Kommentar sagt ausdruecklich "persistiert sie in einem Zug", der Code macht das Gegenteil: `identityStore.replacePersons`, `MeetingReviewStore.save` und `library.updateMeetingParticipants` oeffnen jeweils ihre eigene exklusive Transaktion (`MeetingReviewStore.save` -> `LibraryMutationCoordination.withExclusiveAccess`, MeetingReview.swift:70). Bei `confirmAsNewPerson` kommt davor noch `identityStore.createPerson` als vierte Transaktion.

Konkreter Fehlerpfad: Nutzer waehlt `markMultiple` fuer einen Cluster, der bisher `reviewState == .confirmed(personID)` war. `engine.markMultiple` liefert einen neuen State, in dem die Stimm-Evidenz der Person deaktiviert und `containsMultipleSpeakers = true` gesetzt ist. Schritt 1 (`replacePersons`) gelingt und schreibt persons.json. Schritt 2 (`save`) scheitert (Platte voll, Transaktion nicht erhaeltlich) oder der Prozess wird beendet. review.json traegt weiterhin `confirmed(personID)`.
Beim naechsten Laden ueberlagert `MeetingReviewAssembler.load` (MeetingReview.swift:228-236) den gespeicherten Stand, der Cluster ist wieder `confirmed(personID)` mit `containsMultipleSpeakers = false`, und `SpeakerPresentationResolver` zeigt fuer einen Cluster, den der Nutzer gerade als "mehrere Personen" markiert hat, wieder den Personennamen als Tatsache an - genau der Fall, den Regel 3 ausschliesst. Der umgekehrte Ausfall (save gelingt, replacePersons nicht) laesst Cluster-Zustand und Evidenz ebenso auseinanderlaufen.

```swift
try await identityStore.replacePersons(result.state.persons)
try MeetingReviewStore(layout: layout).save(
    MeetingReviewDocument(runID: data.runID, clusters: result.state.clusters),
    meetingID: meetingID
)
_ = try await library.updateMeetingParticipants(
    meetingID,
    participantIDs: result.state.participantIDs
)
```

**Korrekturskizze:** Alle drei Schreibvorgaenge in eine einzige `LibraryMutationCoordination.withExclusiveTransaction` klammern und die transaktionsnehmenden Varianten der Stores verwenden (die `MeetingReviewStore`/`IdentityStore`/`Library` bereits fuer den Pipelinepfad anbieten). Reihenfolge dabei so waehlen, dass ein Teilabbruch nur zu "Evidenz vorhanden, Cluster noch unbestaetigt" fuehren kann, nie zu "Cluster benannt, Evidenz fehlt".

**Adversariale Pruefung:** Nicht-Atomizitaet am Code belegt: `identityStore.replacePersons`, `MeetingReviewStore.save` (MeetingReview.swift:66-72, eigenes `withExclusiveAccess`) und `library.updateMeetingParticipants` sind drei getrennte Transaktionen, bei `confirmAsNewPerson` kommt `createPerson` (Zeile 71) als vierte davor; einen umschliessenden Transaktionsrahmen gibt es in `perform` nicht, der Doc-Kommentar Zeile 6-9 ("persistiert sie in einem Zug") behauptet mehr als der Code leistet. Die Folge stimmt ebenfalls: `MeetingReviewAssembler` uebernimmt beim Laden `reviewState` und `containsMultipleSpeakers` ausschliesslich aus review.json (MeetingReview.swift:221-236), persons.json steuert nur die Evidenz bei. Bricht Schritt 2 ab, bleibt ein Cluster, den der Nutzer als `markMultiple` markiert hat, mit `confirmed(personID)` gespeichert und wird wieder unter dem Personennamen als Tatsache angezeigt - Verstoss gegen Regel 3, wenn auch nur nach einem Schreibfehler und mit sichtbarer Fehlermeldung an den Nutzer (die Aktion wirft). Deshalb medium, nicht hoeher.

### 35. [MEDIUM] Hoerprobe waehlt die Spur ueber die Spurart statt ueber die Asset-Kennung des Laufs

`StenoKit/Sources/StenoPipeline/PersonVoiceSamples.swift:275` - Subsystem pipeline, Kategorie run-provenance

`ResolutionContext.clip` sucht die Spur mit `artifact.tracks.first(where: { $0.assetKind.rawValue == channel })`. Der Vertrag direkt darueber (Zeile 22-28, `Playback.assetID`) verlangt ausdruecklich das Gegenteil: "Genau die Spur, die der Lauf diarisiert hat - nicht 'irgendeine des gleichen Typs'. Wird eine Aufnahme spaeter erneut importiert, gibt es zwei Spuren derselben Art, und die alten Segmentzeiten passen nur auf eine davon."

Zwei Spuren gleicher Art in einem Meeting sind moeglich: `Library.registerMediaAsset` (Library.swift:401-413) bildet den Provenienzschluessel fuer `kind == .imported` aus dem SHA256 der Datei, zwei verschiedene importierte Dateien im selben Meeting sind also erlaubt.

Konkreter Fehlerpfad (aktuelles Format): Meeting M hat die importierten Assets A und B, beide im selben Diarisierungslauf. `makeDiarizationTrack` (PipelineCoordinator.swift:794) praefixt Cluster-IDs mit "<assetID>/", die Evidenz einer Person traegt also `clusterID == "<B>/speaker_0"`, `channel == "imported"`. `clip` waehlt Track A (erster mit `assetKind == .imported`), der Segmentfilter `$0.clusterID == clusterID` findet dort nichts, es wird `nil` zurueckgegeben. Fuer jede Evidenz, die nicht auf der ersten importierten Spur liegt, bietet die Personenverwaltung dauerhaft keine Hoerprobe an, obwohl Lauf, Spur und Segment existieren.

Zweiter Pfad (Altbestand): fuer Diarisierungsartefakte mit nicht-namespaced Cluster-IDs - dass es die gibt, belegt `SpeakerClusterKey.hasOpaqueNamespace` (SpeakerPresentation.swift:229), das ausdruecklich beide Formen unterscheidet - matcht "speaker_0" auch auf Track A. Dann wird `track.assetID` von A als `Playback.assetID` zurueckgegeben und unter dem Namen der Person die Stimme aus der falschen Spur abgespielt. Genau dieser Fehler ist laut Kommentar Zeile 108-111 "in der alten App passiert".

```swift
guard let artifact = artifacts[key] ?? nil,
      let track = artifact.tracks.first(where: {
          $0.assetKind.rawValue == channel        // <- Spurart, nicht Asset
      })
else { return nil }
guard let segment = track.segments
    .filter({ $0.clusterID == clusterID && $0.end > $0.start })
    .max(by: { ($0.end - $0.start) < ($1.end - $1.start) })
else { return nil }
return (track.assetID, segment)
```

**Korrekturskizze:** Statt der ersten Spur gleicher Art alle Spuren durchsuchen, deren `assetKind.rawValue == channel` ist, und diejenige nehmen, die das gesuchte Segment tatsaechlich enthaelt; findet mehr als eine Spur ein Segment mit dieser Cluster-ID, gar nichts zurueckgeben statt zu raten. Sauberer: die Asset-Kennung in der Stimm-Evidenz mitfuehren und direkt darauf matchen.

**Adversariale Pruefung:** Erster Pfad am Code nachvollzogen: `ResolutionContext.clip` waehlt die Spur ueber `assetKind.rawValue == channel` (PersonVoiceSamples.swift:274-278) und verwirft damit die Asset-Identitaet, die in der Cluster-ID steckt - `makeDiarizationTrack` praefixt jede Cluster-ID mit `"<assetID>/"` (PipelineCoordinator.swift:794-801) und `identityClusters` setzt `channel = track.assetKind.rawValue` (MeetingReview.swift:380), die Evidenz traegt also Asset-ID nur im clusterID. Der Vertrag in Zeile 24-28 verlangt ausdruecklich die Spur des Laufs. Zwei Spuren gleicher Art in einem Meeting sind real: `LegacyMeetingPreparation.swift:79-99` legt fuer `entry.recordings` mehrere Assets mit `kind: .imported` im selben Meeting an, und `Library.registerMediaAsset` erlaubt das, weil der Provenienzschluessel fuer `.imported` der Datei-SHA256 ist (Library.swift:401-413). Fuer Evidenz auf der zweiten importierten Spur findet der Segmentfilter nichts, es gibt dauerhaft keine Hoerprobe. Der macOS-Import (AppModel.swift:1188-1210) legt dagegen pro Datei ein eigenes Meeting an, das ist also nicht der Ausloeser. Den zweiten, schwereren Pfad (falsche Stimme unter einem Namen bei nicht-namespaced Alt-Cluster-IDs) konnte ich nicht belegen: `SpeakerClusterKey.hasOpaqueNamespace` (SpeakerPresentation.swift:229-237) zeigt zwar, dass beide Formen behandelt werden, aber ich habe keinen Erzeuger nicht-namespaced Diarisierungssegmente im Baum gefunden. Schwere bleibt medium: die belegte Folge ist eine stumm fehlende Hoerprobe, kein Verstoss gegen Regel 3.

### 36. [MEDIUM] Unbegrenzte Rekursion beim Zurueckverfolgen der Lauf-Kette (Stack Overflow bei beschaedigtem Artefakt)

`StenoKit/Sources/StenoPipeline/MeetingDiarizationRequest.swift:247` - Subsystem pipeline, Kategorie correctness

`transcriptSource(for runID:)` ruft sich fuer `run.kind == .diarization` mit `artifact.sourceRunID` selbst auf, ohne besuchte RunIDs zu merken und ohne Tiefenbegrenzung. Die Schwesterfunktion `transcriptSource(for initialRevision:)` (Zeile 190-211) fuehrt genau dafuer ein `visited: Set<RevisionID>`, der Lauf-Pfad hat diesen Schutz nicht.

Konkreter Fehlerpfad: In `<meeting>/runs/<R1>/diarization.json` steht `sourceRunID == R1` (oder R1 -> R2 -> R1), waehrend `<meeting>/runs/<R1>/run.json` `kind == .diarization`, `status == .finished`, `schemaVersion == 1` traegt - alle Guards in Zeile 224-243 sind erfuellt, `expectedRevisionID` ist im rekursiven Aufruf ohnehin `nil`. Die Funktion ruft sich unendlich oft auf, jeweils mit zwei vollstaendigen JSON-Dekodierungen, bis der Stack ueberlaeuft und der Prozess abstuerzt. Aufrufer ist `context(library:meetingID:)`, das aus `MeetingDiarizationRequest.status(...)` heraus fuer die normale Meeting-Ansicht laeuft - ein einzelnes beschaedigtes oder manipuliertes Artefakt legt damit die App bei jedem Oeffnen des Meetings lahm. Die Pipeline behandelt beschaedigte Artefakte sonst konsequent per Quarantaene (`RunArtifactStore.loadFinished`, Zeile 208-211), hier nicht.

```swift
case .diarization:
    let artifact = try JSONDecoder().decode(
        DiarizationArtifact.self,
        from: Data(contentsOf: layout.runDiarization(meetingID, runID: runID))
    )
    ...
    guard let source = try transcriptSource(
        for: artifact.sourceRunID,      // keine visited-Menge, keine Tiefengrenze
        expectedRevisionID: nil,
        layout: layout,
        meetingID: meetingID
    ) else { return nil }
```

**Korrekturskizze:** Wie beim Revisionspfad eine `visited: Set<RunID>` durchreichen und `nil` liefern, sobald eine RunID erneut auftaucht; zusaetzlich eine harte Tiefengrenze (die legale Kette ist genau zwei Glieder lang: diarization -> finalASR).

**Adversariale Pruefung:** Fehlende Zyklus-/Tiefenabsicherung am Code belegt: `transcriptSource(for runID:)` (MeetingDiarizationRequest.swift:236-256) ruft sich mit `artifact.sourceRunID` selbst auf, ohne `visited`-Menge und ohne Tiefengrenze, waehrend die Schwesterfunktion fuer Revisionen genau dafuer `visited: Set<RevisionID>` fuehrt (Zeile 191-193). Der rekursive Aufruf setzt `expectedRevisionID: nil`, damit faellt der einzige inhaltliche Guard (Zeile 244-246) ab dem zweiten Schritt weg; uebrig bleiben nur schemaVersion/id/meetingID/status, die ein selbstreferenzierendes Artefakt alle erfuellt. Aufrufkette bis in die normale Meeting-Ansicht bestaetigt: iOS/App/Sources/AppModel.swift:973 -> `status` -> `context`; der dortige `catch` faengt einen Stack-Overflow nicht ab. Natuerlich entsteht kein Zyklus (die Pipeline setzt `sourceRunID` immer auf den finalASR-Lauf, PipelineCoordinator.swift:741), es braucht also ein beschaedigtes oder manipuliertes diarization.json, das noch gueltiges JSON ist - reine Dekodierfehler wuerden geworfen und nicht endlos rekursieren. Deshalb medium: echte Robustheitsluecke gegenueber der sonst konsequenten Quarantaene-Behandlung (RunArtifactStore.swift:208-211), aber geringe Eintrittswahrscheinlichkeit.

### 37. [MEDIUM] Fehlgeschlagene oder abgebrochene Installation legt eine intakte, geprueft installierte Modellsammlung lahm

`StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift:148` - Subsystem speech, Kategorie correctness

`install` schreibt als allerersten Schritt die Unvollstaendigkeitsmarke und loescht sie erst nach bestandener Pruefsumme (Zeile 184). Jeder Fehler dazwischen - Netzfehler, Abbruch, `CancellationError` - laesst die Marke liegen. `missingBundleNames` (Zeile 203-205) und `modelBundleIsComplete` (Zeile 171-175) melden daraufhin alles als fehlend, obwohl saemtliche Bundles unveraendert und pruefsummengeprueft auf der Platte liegen.

Fehlerpfad: Modelle sind vollstaendig installiert und verifiziert. Der Nutzer klickt in den Einstellungen erneut auf Zustimmen/Installieren - `AppModel.allowAndInstallModels` ruft `installModels` ohne jede Readiness-Pruefung, und `ModelInstallationCoordinator.installAll` (Zeile 70-77) ruft ebenfalls jeden Installer unbedingt auf. Der Task setzt die Marke, `DownloadUtils.downloadRepo` scheitert ohne Netz schon am Dateilisting (diesen Fall benennt AppModel.swift selbst im Kommentar bei `lastCheckFoundWrongBytes`), der Task wirft, `defer` raeumt nur `activeInstall` auf - die Marke bleibt. Ab jetzt meldet `readiness` "Speaker separation fehlt", und `FluidSortformerProvider.loadModels` wirft `modelsNotInstalled` fuer jeden Lauf, bis irgendwann eine Installation komplett durchlaeuft.

Derselbe Effekt ueber `revokeModelConsent` -> `cancelAll` -> `cancelInstall`, und der widerspricht direkt der dort dokumentierten Zusage "was schon da ist, soll weiter benutzbar bleiben".

```swift
        let task = Task<Void, Error> { [baseDirectory, download, manifest, relay] in
            // The provider stays available for final ASR while this download
            // runs. Hide partially moved FluidAudio bundles from diarization
            // until the complete manifest has passed verification.
            try markDiarizationModelInstallationIncomplete(in: baseDirectory)
```

**Korrekturskizze:** Den Fehler-/Abbruchpfad aufraeumen: den Task in `do { ... } catch { if (try? manifest.verify(directory: baseDirectory)) != nil { try? clearDiarizationModelInstallationMarker(in: baseDirectory) }; throw error }` klammern - eine noch vollstaendig verifizierbare Installation darf nicht als unvollstaendig markiert zurueckbleiben. Ergaenzend in `install` frueh zurueckkehren, wenn `missingBundleNames()` leer ist und die Pruefsummen stimmen, statt eine fertige Installation ueberhaupt anzufassen.

**Adversariale Pruefung:** Am Code nachvollzogen: install() schreibt die Marke als ersten Schritt im Task (DiarizationModelInstaller.swift:148) und loescht sie erst nach bestandener Pruefsumme (Zeile 184); das defer raeumt nur activeInstall (Zeile 191). Jeder Wurf dazwischen laesst die Datei .steno-diarization-install-incomplete liegen (ModelAccess.swift:13-27), und missingBundleNames meldet dann pauschal alles als fehlend (Zeile 202-205), unabhaengig davon, dass die Bundles pruefsummengeprueft daliegen; FluidSortformerProvider.swift:172 sperrt daraufhin jeden Lauf. Die Wiederholbarkeit ist gegeben: ModelStatusView zeigt 'Allow and install' unabhaengig von der Readiness (ModelStatusView.swift:33-42), AppModel.installModels hat keine Readiness-Vorpruefung (AppModel.swift:506-575) und ModelInstallationCoordinator.installAll ruft jeden Installer unbedingt (Zeile 63-77). Der Netzfehlerfall ist belegt: FluidAudios DownloadUtils.downloadRepo listet vor jedem Download ueber die HuggingFace-API (DownloadUtils.swift:396-418), scheitert ohne Netz also, bevor irgendetwas geprueft wurde. Der Widerrufspfad (revokeModelConsent -> cancelAll -> cancelInstall, Zeile 198-200) hinterlaesst die Marke ebenso und widerspricht der Zusage in AppModel.swift:583-586. Bestehende Tests zementieren nur den korrekten Fall (Teilinstallation bleibt versteckt), nicht diesen. Schwere medium bleibt richtig: kein Datenverlust, Wiederherstellung durch einen erfolgreichen Lauf, aber eine funktionierende, verifizierte Installation wird ohne Zutun des Nutzers stillgelegt.

### 38. [MEDIUM] Maske des letzten, kuerzeren Audiofensters ist gegenueber dem Audio zeitlich verschoben

`StenoKit/Sources/StenoDiarization/SortformerEmbeddingExtraction.swift:81` - Subsystem speech, Kategorie correctness

`resampleMask` streckt die Frames des jeweiligen Fensters immer auf die volle `weSpeakerFrameCount`. Das ist richtig, solange das Fenster wirklich 160.000 Samples hat. FluidAudios `EmbeddingExtractor.getEmbeddings` interpretiert die Maske aber ueber das feste 10-Sekunden-Fenster und schneidet sie proportional zur tatsaechlichen Audiolaenge ab:

    let numMasksInChunk = min((firstMask.count * audio.count + 80_000) / 160_000, firstMask.count)

(FluidAudio/Diarizer/Extraction/EmbeddingExtractor.swift:63-66, Wellenform-Shape `[3, 160_000]` in Zeile 37.)

Fehlerpfad: Aufnahme von 95 Sekunden. Die vollen Fenster sind korrekt (`audio.count == 160_000` -> `numMasksInChunk == firstMask.count`). Das letzte Fenster hat 5 Sekunden = 80.000 Samples. Steno streckt dessen ~62 echte Frames auf alle `weSpeakerFrameCount` Eintraege, FluidAudio benutzt davon nur die erste Haelfte - die entspricht damit den ersten 2,5 Sekunden des realen Audios. Die Sprecheraktivitaet der letzten 2,5 Sekunden faellt weg, der Rest ist um Faktor 2 gestaucht, und das Fenster liefert ein Embedding aus dem falschen Zeitbereich.

Bei einer Aufnahme unter 10 Sekunden ist das das *einzige* Fenster: der komplette Stimmabdruck des Clusters, der spaeter ueber `IdentityCluster.embedding` in `SpeakerSuggestionEngine` die Personenzuordnung traegt, entsteht aus einer verschobenen Maske.

```swift
        let chunk = Array(audio[sampleStart..<sampleEnd])
        let chunkMasks = (0..<speakerCount).map {
            Array(masks[$0][frameStart..<frameEnd])
        }
        ...
        let embeddingMasks = topSlots.map {
            resampleMask(chunkMasks[$0], to: weSpeakerFrameCount)
        }
```

**Korrekturskizze:** Die Fenstermaske immer auf die volle Fensterlaenge beziehen: `chunkMasks` auf `framesPerChunk` mit Nullen auffuellen, bevor `resampleMask` sie auf `weSpeakerFrameCount` abbildet, und den Audiochunk entsprechend auf 160.000 Samples nullpolstern. Dann stimmen Masken- und Audiozeitachse in jedem Fenster ueberein und FluidAudios Abschneiden trifft nur noch die Stille am Ende.

**Adversariale Pruefung:** Beide Seiten gelesen. Steno streckt die Maske jedes Fensters immer auf weSpeakerFrameCount (SortformerEmbeddingExtraction.swift:81-83 mit resampleMask, DiarizationAlgorithms.swift:59-66) und uebergibt den kuerzeren letzten Chunk ungepolstert (Zeile 65-67, 86-89). FluidAudio erwartet die Maske dagegen auf dem festen 10-Sekunden-Raster: numMasksInChunk = min((firstMask.count * audio.count + 80_000)/160_000, firstMask.count) (EmbeddingExtractor.swift:63-66), also round(M * audio/160000) gueltige Frames, der Rest wird durch Wiederholung ersetzt (fillMaskBufferOptimized, Zeile 152-197) - passend zum ebenfalls durch Wiederholung aufgefuellten Waveform-Puffer (fillWaveformBuffer, Zeile 118-150, Shape [3, 160_000] in Zeile 37). Dass das die gemeinte Konvention ist, bestaetigt FluidAudios eigener Aufrufer: DiarizerManager uebergibt paddedChunk, also immer 160_000 Samples (DiarizerManager.swift:327-331), womit die Formel dort nie greift. Steno polstert nicht, also greift sie beim letzten Fenster: bei 5 Sekunden Rest benutzt FluidAudio nur die erste Haelfte der gestreckten Maske, was der Aktivitaet der ersten 2,5 realen Sekunden entspricht - um Faktor 2 gestaucht, die letzten 2,5 Sekunden fallen weg. Bei Aufnahmen unter 10 Sekunden ist das das einzige Fenster, und das Ergebnis traegt ueber FluidSortformerProvider.swift:64-69 direkt IdentityCluster.embedding. Zusaetzliches Risiko: ein nur am Chunkende aktiver Slot kann unter minActivityThreshold fallen und ein Nullembedding liefern. Medium ist angemessen - Qualitaetsfehler im Stimmabdruck, kein Datenverlust.

### 39. [MEDIUM] Single-Linkage-Verschmelzung kann zwei Stimmen zu einem unmarkierten Cluster verketten, der danach benannt werden darf

`StenoKit/Sources/StenoIdentity/SpeakerSuggestionEngine.swift:338` - Subsystem speech, Kategorie rule-violation

`mergeOneScope` verbindet Fragmente ueber Union-Find, prueft aber nur *paarweise* Distanzen und nie die Distanz innerhalb der entstehenden Komponente (Single Linkage). Der Schwellwert 0.10 ist laut Kommentar in Zeile 33-36 an paarweisen Messungen kalibriert ("echte Fragmente 0.02 bis 0.07, naechste verschiedene Personen 0.11") - diese Kalibrierung traegt bei Verkettung nicht mehr.

Fehlerpfad: drei Cluster im selben (Meeting, Lauf, Kanal) mit d(A,B) = 0.10 und d(B,C) = 0.10, aber d(A,C) = 0.20, also zwei verschiedene Personen. Zeile 330-339 verschmilzt A-B und B-C, `components` enthaelt {A,B,C}. Der zusammengefasste Cluster bekommt in Zeile 366-374 ein gewichtetes Mittel-Embedding aus zwei Stimmen. `mixed` in Zeile 380 wird nur `true`, wenn ein *Mitglied* schon vorher als mehrstimmig markiert war - eine durch die Verschmelzung neu entstandene Mischung erkennt niemand. `containsMultipleSpeakers` bleibt also `false`, `suggestion(for:)` laeuft an den Waechtern in Zeile 177-182 vorbei, und der Cluster kann bis zu `.confirmed` hochgestuft und mit einem Namen versehen werden. Das verletzt "ein Cluster mit mehreren Stimmen bekommt keinen Namen" und schreibt ueber `assign` zusaetzlich einen Prototyp aus zwei Stimmen in die Personenbibliothek.

```swift
                }, distance <= IdentityThresholds.sameChannelMergeDistance else {
                    continue
                }
                let leftRoot = root(left, parents: &parents)
                let rightRoot = root(right, parents: &parents)
                if leftRoot != rightRoot { parents[leftRoot] = rightRoot }
```

**Korrekturskizze:** Vor dem Vereinigen die Komponenten-Distanz pruefen (Complete Linkage): nur verschmelzen, wenn *jedes* Paar aus den beiden Wurzeln unter `sameChannelMergeDistance` liegt. Alternativ nach dem Bilden der Komponente den maximalen paarweisen Abstand ihrer Mitglieder messen und den zusammengefassten Cluster bei Ueberschreitung entweder gar nicht bilden oder mit `containsMultipleSpeakers = true` markieren, damit er benennungsgesperrt bleibt.

**Adversariale Pruefung:** mergeOneScope (SpeakerSuggestionEngine.swift:311-343) fuehrt reines Single Linkage per Union-Find: geprueft wird ausschliesslich die paarweise Distanz gegen sameChannelMergeDistance (0.10), eine Pruefung des Durchmessers der entstehenden Komponente gibt es nicht. Die Kalibrierung im Kommentar (Zeile 33-36: echte Fragmente 0.02-0.07, naechste verschiedene Personen 0.11) traegt bei Verkettung tatsaechlich nicht. Der Rest der Kette stimmt am Code: die Komponente bekommt ein dauergewichtetes Mittel-Embedding (Zeile 366-378), mixed wird nur aus members.contains { $0.containsMultipleSpeakers } abgeleitet (Zeile 380), eine erst durch die Verschmelzung entstandene Mischung markiert also niemand; suggestion(for:) blockt nur bei isSelf/containsMultipleSpeakers (Zeile 167-181) und assign wirft mixedClusterCannotBeNamed ebenfalls nur bei gesetztem Flag (IdentityReviewFlow.swift:177-179), sodass der verkettete Cluster benannt und als Prototyp in die Bibliothek geschrieben wird. Einschraenkung, deretwegen ich nicht hoeher gehe: der Auslöser ist eine Datenkonstellation (d(A,B), d(B,C) <= 0.10 bei d(A,C) > Schwelle im selben Meeting/Lauf/Kanal), die ich am Code nicht belegen kann; belegt ist die fehlende Absicherung, nicht ihr Eintreten. Medium ist richtig.

## Unsichere Befunde (Pruefer konnte weder bestaetigen noch widerlegen)

### [MEDIUM] synchronize() fsynct nur die Datei, nie das Elternverzeichnis - der Verzeichniseintrag kann nach Stromausfall fehlen

`StenoKit/Sources/StenoAudioCore/TrackWriter.swift:79` - Subsystem audio-core

`synchronize()` öffnet einen FileHandle auf die Spur und ruft `handle.synchronize()` (fsync auf den Inode). Der Verzeichniseintrag, der die Datei überhaupt erst auffindbar macht, wird nie synchronisiert. Fehlerpfad: `RecordingSession.start` legt `outputDirectory` frisch an (RecordingSession.swift:131-134) und `AVAudioFile(forWriting:)` erzeugt darin die CAF-Datei; beides bleibt als Verzeichnis-Metadatenänderung im Cache. Danach läuft die Aufnahme, jede Sekunde wird der Dateiinhalt gefsynct. Bei einem Kernel-Panic oder Stromausfall nach 40 Minuten kann APFS die Datenblöcke committet haben, während der Verzeichniseintrag des capture-Ordners es nicht war - beim nächsten Start findet `CaptureRecovery` über `contentsOfDirectory` schlicht nichts (CaptureRecovery.swift:26-31, `guard !files.isEmpty else { continue }`), und die Aufnahme ist unwiederbringlich. Die gesamte Sekunden-fsync-Strategie ist damit gegen genau das Szenario, für das sie gebaut wurde, nicht lückenlos. Dass das Projekt das Verzeichnis-fsync kennt, belegt AtomicFile.swift:119-128 und :54.

**Einschaetzung des Pruefers:** Der Code-Teil stimmt: TrackWriter.synchronize (TrackWriter.swift:79-83) fsynct nur den Inode, das Elternverzeichnis wird nie synchronisiert, waehrend AtomicFile.swift:119-128 zeigt, dass das Projekt den Unterschied kennt. Der behauptete Fehlerpfad ist aber nicht am Code entscheidbar, sondern haengt an Dateisystemsemantik, die ich hier nicht belegen kann: auf APFS (und HFS+) werden Metadaten transaktional/journaliert committet, ein fsync auf die Datei commitet den laufenden Checkpoint, und Transaktionen werden in Reihenfolge committet - der zuvor angelegte Verzeichniseintrag waere damit spaetestens mit dem ersten Sekunden-fsync durable. Ein Szenario 'Datenbloecke committet, Verzeichniseintrag nicht' konnte ich weder am Code noch an einer belastbaren Quelle nachvollziehen; es waere allenfalls auf einem fremden Dateisystem unter STENO_LIBRARY_DIR denkbar. Als Haertung (Verzeichnis-fsync nach dem Anlegen) sinnvoll, als bewiesener Defekt nicht. Nebenbefund ausserhalb der Behauptung: handle.synchronize() ist fsync, nicht F_FULLFSYNC, flusht also den Geraetecache nicht - das waere die groessere Luecke, steht aber nicht im Befund. Schwere daher hoechstens medium.

### [MEDIUM] Ein Fehler beim Aufraeumen der Medien-Klone verwirft eine bereits fertige Transkription und ueberschreibt den echten Inferenzfehler

`StenoKit/Sources/StenoPipeline/PipelineCoordinator.swift:591` - Subsystem pipeline

In `executeFinalASR` (Zeile 591) und `executeDiarization` (Zeile 734) steht `try binding.close()` VOR dem Setzen von `run.status = .finished` und vor `runStore.commit`. `PipelineMediaBinding.close()` delegiert an `PipelineMediaSnapshotSession.close()`, das jeden internen Fehler in `PipelineError.mediaCleanupRequired` umwandelt (PipelineMediaSessionStore.swift:191-193) - z.B. wenn `unlinkat` auf einem Klon scheitert, ein `fsync` fehlschlaegt oder die Exklusiv-Transaktion nicht geoeffnet werden kann.

Zwei Folgen:
1. Erfolgsfall: alle Spuren wurden erfolgreich transkribiert (`tracks` gefuellt, `inferenceError == nil`), aber `binding.close()` wirft. Der Fehler propagiert, `runStore.commit` wird nie erreicht, `persistFailure` markiert den Lauf als fehlgeschlagen. Die komplette, teure Transkription ist verloren, obwohl nur das Aufraeumen eines temporaeren COW-Klons scheiterte.
2. Fehlerfall: `inferenceError` ist gesetzt (z.B. `DiarizationError.modelsNotInstalled`), `binding.close()` wirft ebenfalls -> Zeile 592 `if let inferenceError { throw inferenceError }` wird nie erreicht. Der Nutzer sieht "Pipeline media cleanup ... must be retried" statt der eigentlichen Ursache, und `failureReason(for:job:)` kann `.diarizationModelsNotInstalled` nicht mehr setzen - damit greift auch `MissingDiarizationModelJobRetrier.requeue` nach der Modellinstallation nicht mehr fuer diesen Job.

**Einschaetzung des Pruefers:** Die Reihenfolge stimmt (Zeile 591 bzw. 734: `try binding.close()` vor `run.status = .finished`/`commit`), und `close()` verpackt jeden inneren Fehler in `PipelineError.mediaCleanupRequired` (PipelineMediaSessionStore.swift:165-193). Die erste behauptete Folge ist aber kein Defekt, sondern getestetes Sollverhalten: `PipelineCoordinatorTests.swift:11-56` ("a clone cleanup failure is visible and retried by the next startup") schreibt ausdruecklich fest, dass ein Cleanup-Fehler den erfolgreichen Job auf `.failed` setzt und der naechste Start die Sitzung wegraeumt - ein liegengebliebener COW-Klon soll sichtbar sein, und eine Transkription ist laut Repo-Regel 1 wiederholbar. Die zweite Folge ist dagegen am Code wahr und nirgends getestet: wirft `close()`, wird Zeile 592 `if let inferenceError { throw inferenceError }` nie erreicht, `failureReason(for:job:)` (Zeile 1232-1236) kann `.diarizationModelsNotInstalled` nicht mehr setzen, und `MissingDiarizationModelJobRetrier.requeue` (matcht auf genau diesen Grund bzw. die Legacy-Meldung) laesst den Job nach der Modellinstallation liegen. Das ist aber nur im Doppelfehlerfall (Modellfehler UND Cleanup-Fehler) erreichbar. Deshalb uncertain: die Ueberschrift des Befunds trifft nicht zu, der Kern (Maskierung des inferenceError) schon - fixen sollte man nur die Fehlerpriorisierung, nicht die Commit-Reihenfolge.

### [MEDIUM] Fehlgeschlagenes zweites leaseSource() hebt die Exklusivitaet des ersten Lease auf

`StenoKit/Sources/StenoExchange/MeetingTransferAudioInspector.swift:190` - Subsystem exchange

`makeLease()` wirft innerhalb des Locks `sessionInUse`, wenn bereits ein Lease aussteht (`guard let descriptor = state.descriptor, !state.isLeased`). Der zugehoerige `catch`-Block setzt aber bedingungslos `state.isLeased = false` zurueck - auch dann, wenn der Fehler gerade daher kam, dass ein anderes Lease noch aktiv ist. Konkreter Fehlerpfad: (1) `let a = try audio.leaseSource()` -> isLeased = true; (2) ein zweiter Aufruf `audio.leaseSource()` schlaegt mit `sessionInUse` fehl und setzt im catch isLeased zurueck auf false, obwohl `a` noch offen ist; (3) ein dritter Aufruf gelingt jetzt und laeuft durch `validateContents`, das `lseek(descriptor, 0, SEEK_SET)` und `read()` auf dem Basis-Deskriptor ausfuehrt. Da die Leases per `fcntl(F_DUPFD_CLOEXEC)` erzeugt werden, teilen sich Basis-Deskriptor und alle Duplikate denselben Datei-Offset; der Leser von `a` liest ab da an der falschen Stelle. Der Pfad ist erreichbar: `MeetingTransferImportService.swift:570` ruft `audio.leaseSource()` in einem `acquire`-Closure auf, das bei einem Wiederholungsversuch mehrfach laufen kann. Zusaetzlich glaubt `revalidateIntegrity()` danach, kein Lease sei aktiv, und hasht die Datei parallel zum laufenden Import.

**Einschaetzung des Pruefers:** Der Codefehler selbst ist real: der catch in makeLease (MeetingTransferAudioInspector.swift:190-194) setzt state.isLeased bedingungslos auf false, auch wenn der Fehler genau daher kam, dass die guard-Bedingung !state.isLeased verletzt war (Zeile 165-166). Danach koennte ein weiterer makeLease-Aufruf durchlaufen und validateContents mit lseek/read auf dem Basis-Deskriptor ausfuehren (Zeile 216-256), dessen Offset sich die per F_DUPFD_CLOEXEC erzeugten Leases teilen. Den behaupteten erreichbaren Aufrufpfad konnte ich aber nicht belegen: MeetingTransferImportService.swift:566-576 uebergibt das acquire-Closure an PreparedDescriptorBackedMediaSource, und der einzige Konsument PreparedMediaDescriptorCloner.clone (StenoLibrary/MeetingTransferImport.swift:1522-1523) schliesst das Lease per defer, bevor es zurueckkehrt; die Medienschleife in PreparedMeetingImport.swift:573-585 laeuft sequenziell, ein Wiederholungsversuch faende isLeased also bereits auf false vor. Ein zweiter, ueberlappender leaseSource() auf derselben ValidatedMeetingTransferAudio kommt weder in Sources noch in den Tests vor (dort wird nur validated.close() nebenlaeufig gegen ein offenes Lease gefahren, MeetingTransferArchiveSecurityTests.swift:1031-1044, und das laeuft ueber die Session, nicht ueber makeLease). Damit ist es ein latenter Invariantenbruch ohne demonstrierten Ausloeser; die genannte Folge (revalidateIntegrity haelt kein Lease fuer aktiv) haengt an derselben unbelegten Nebenlaeufigkeit. Schwere medium bleibt angemessen, weil die Exklusivitaetszusage der Klasse dennoch verletzt ist.

## Widerlegte Befunde

### Nach Widerruf der Zustimmung laufen die restlichen Modell-Downloads weiter: keine Abbruchpruefung zwischen den drei Schritten

`StenoKit/Sources/StenoDiarization/DiarizationModelInstaller.swift:62`

**Widerlegung:** Die Code-Beobachtung stimmt (kein `try Task.checkCancellation()` am Schleifenkopf, DiarizationModelInstaller.swift:61-87), die behauptete Auswirkung nicht. Ich habe den Downloader gelesen, an dem die Schleife haengt: FluidAudio/DownloadUtils.swift benutzt in `downloadRepo` ausschliesslich die async-URLSession-APIs - `sharedSession.data(for:)` fuer die HuggingFace-Baumabfrage (Zeile 404 und 469) und `session.download(for:)` in `downloadWithProgress` (Zeile 696); der Retry-Pfad `fetchHuggingFaceFile` (Zeile 846-885) wartet mit `Task.sleep`. Alle drei reagieren auf Task-Abbruch, auch wenn der Task beim Eintritt schon abgebrochen ist. Nach `activeInstall?.cancel()` scheitert Schritt 2 damit sofort an seiner ersten Netzanfrage mit `URLError.cancelled`, laeuft in den generischen catch (Zeile 75-84) und dort in `try Task.checkCancellation()` -> `CancellationError`. Genau darauf zielt der Kommentar Zeile 76-81 ab. Es werden also keine ~270 MB nachgeladen, sondern hoechstens ein bereits abgebrochener HTTP-Aufruf und ein `createDirectory` ausgefuehrt. Eine zusaetzliche Pruefung am Schleifenkopf waere billige Haertung, aber der Verstoss gegen Regel 5 (Laden ohne gueltige Zustimmung) laesst sich am Code nicht nachvollziehen; als Befund mittlerer Schwere traegt er nicht.

## Abdeckung

- **audio-core**: Vollständig gelesen: StenoAudioCore/TrackWriter.swift, TrackContinuity.swift, RecordingSession.swift, CaptureRecovery.swift, DiskSpaceChecker.swift, AudioSource.swift, AudioErrors.swift, AudioBufferTransfer.swift, AudioLevelMeter.swift, LiveAudioEvent.swift, RecordingActivity.swift; StenoMacAudio/SystemAudioRecorder.swift, MicRecorder.swift, CoreAudioInputDevice.swift, AudioPermissions.swift, AudioBufferConverter.swift, RecordingActivityManager.swift, RecordingSession+Mac.swift, MicrophoneDiscovery.swift. Ergänzend zum Beleg der Fehlerpfade gelesen: StenoLibrary/Library.swift (registerMediaAsset), RecoverySweep.swift, AtomicFile.swift, LibraryLayout.swift sowie die Aufrufstellen in App/Sources/AppModel.swift (startRecording, performStopRecording, abortRecordingCleanup, CaptureRecovery-Aufruf) und iOS/App/Sources/RecordingModel.swift. Bewusst nicht geprüft: die Transkriptions-, Diarisierungs- und Protokollpfade, die iOS-Audiosession (StenoiOSKit), die UI-Schichten und die Testsuiten - sie liegen ausserhalb des Scopes. Ein Verdacht wurde vor der Meldung experimentell widerlegt und deshalb nicht aufgenommen: der fehlende `size > 0`-Guard vor `bytes.baseAddress!` in CoreAudioInputDevice.availableDevices():50-58 (analog zu MicrophoneDiscovery.swift:283 und CoreAudioInputDevice.swift:109) traptnicht, weil `Array(repeating:count:0).withUnsafeMutableBytes` auf dieser Toolchain eine Nicht-nil-Basisadresse liefert (per Swift-Snippet verifiziert). Nicht als Befund gemeldet, weil ohne belegbaren Fehlerpfad: Locks und AVAudioPCMBuffer-Allokationen im CoreAudio-IO-Callback (AudioBufferConverter.convert, realtime-unsicher, funktioniert aber), die 5-Sekunden-Timeout-Tasks in MicEngineCapture.perform, die nach Rückkehr nicht gecancelt werden, und die Blockidentitaet beim AudioObjectRemovePropertyListenerBlock in MicRecorder.removeDeviceListeners. Der Ruhezustandsschutz ist im geprueften Umfang lueckenlos: `activityManager.begin()` in RecordingSession.start:141 und `endActivityIfNeeded()` sowohl im Erfolgs- als auch im Fehlerzweig von finalizeStop (322, 331) und in discardPreparedRecording (517).
- **pipeline**: Vollstaendig gelesen: PipelineCoordinator.swift (1323 Z.), PipelineMediaLease.swift, PipelineMediaSessionStore.swift, RunArtifactStore.swift, ImportedMeetingProcessingReconciler.swift, MeetingReview.swift, MeetingReviewController.swift, MeetingDiarizationRequest.swift, PersonVoiceSamples.swift, SpeakerPresentation.swift, SpeakerSampleSelector.swift, TemplateRenderInputAssembler.swift, TemplateRenderRequest.swift, TemplateResultStore.swift, TemplateParticipants.swift, TranscriptEdit.swift, MeetingMarkdown.swift, PipelineArtifactValidator.swift, StablePipelineIdentifiers.swift, PipelineError.swift, PipelineStartup.swift, MeetingProcessingJobRequest.swift, MissingDiarizationModelJobRetrier.swift, ModelInstallationCoordinator.swift, OnboardingFlow.swift, alle Artefakt-Typen, MeetingTransferImportService.swift, MeetingTransferExportService.swift. Zur Absicherung ausserhalb des Scopes gelesen: StenoLibrary/LibraryMutationCoordination.swift (flock-Semantik, Reentranz), StenoLibrary/JobStore.swift (Aktor-Isolation, erlaubte Statuswechsel, claimNext/recoverAtLaunch), StenoLibrary/Library.swift (registerMediaAsset/Provenienz), StenoExchange/MeetingTransferLimits.swift und MeetingTransferAudioInspector.prepareCAFSource (Groessengrenzen).\n\nGeprueft und NICHT als Befund gemeldet, weil abgesichert: (a) Regel 4 - kein `Locale.current` im Transkriptionspfad, `effectiveLocale` kommt aus `job.localeIdentifier` bzw. dem injizierten Locale; `Locale(identifier: \"en_US_POSIX\")` in MeetingMarkdown betrifft nur Datumsformatierung. (b) Regel 5 - kein eigenstaendiger Modell-Download; `ModelInstallationCoordinator.installAll` verlangt `consentGranted`. (c) Regel 6 - der einzige Netzwerkpfad ist `textModelProvider.render`, davor stehen Preflight-Fingerprint und Endpoint-Pin. (d) Die scheinbar tautologischen Validator-Argumente in `loadFinalASRSource`/`loadDiarizationSource` (`expectedJobID: artifact.jobID`, `expectedSourceRunID: artifact.sourceRunID`) sind transitiv abgedeckt, weil `StablePipelineIdentifiers.runID(for: artifact.jobID, ...) == sourceRunID` die JobID an die RunID bindet. (e) `PipelineMediaBinder`/`PipelineMediaSnapshotSession` sind gegen Symlink-, TOCTOU- und Pfad-Injektionsangriffe sehr sorgfaeltig abgesichert (openat/fstatat/AT_SYMLINK_NOFOLLOW, Inode-Vergleiche, flock, Owner-Token); ich habe dort keinen ausnutzbaren Fehler gefunden. Nicht abschliessend geprueft: die Interaktion mit den App-Schichten (App/, iOS/) und mit StenoIdentity's SpeakerSuggestionEngine, die ausserhalb des Scopes liegen - Befund 4 haengt am dortigen Verhalten von `markMultiple`, die Nicht-Atomaritaet der drei Schreibvorgaenge ist davon aber unabhaengig.
- **speech**: Vollstaendig gelesen: alle 25 Dateien in StenoKit/Sources/StenoTranscription (LocaleResolver, SpeechAnalyzerProvider, SpeechLiveTranscriptionSession, TranscriptDiarizationAligner, TranscriptMapper, TranscriptionAccumulator, PCMBufferConverter, SpeechResultConverter, BoundedAsyncBuffer, TranscriptionContracts, SpeechAssetInstaller, SystemSpeechAssets), StenoDiarization (DiarizationAlgorithms, SortformerEmbeddingExtraction, FluidSortformerProvider, AVAudioSampleLoader, DiarizationModelInstaller, ModelChecksumManifest, ModelAccess, DiarizationModels) und StenoIdentity (SpeakerSuggestionEngine, IdentityReviewFlow, IdentityCluster).

Zur Verifikation ausserhalb des Scopes gelesen: StenoDomain/Identity.swift (isActive/excludedAt-Vertrag), StenoLibrary/IdentityStore.swift (Ausschluss- und Persistenzpfad), StenoPipeline/ModelInstallationCoordinator.swift, MeetingReviewController.swift, SpeakerPresentation.swift, App/Sources/AppModel.swift (Aufrufpfade fuer Locale-Wahl und Modellinstallation), StenoKit/Tests/StenoTranscriptionTests/LocaleResolverTests.swift. Zusaetzlich FluidAudio (Checkout unter ~/Dev/Repositorys/StenoEngines/.build/checkouts/FluidAudio): DiarizerTimeline.swift und Extraction/EmbeddingExtractor.swift, um Speicherlayout der Predictions (frame-major, bestaetigt korrekt) und die Maskenlaengen-Semantik zu pruefen.

Nicht als Befund gemeldet, weil geprueft und unauffaellig: buildOverlapExcludedMasks (Layout stimmt mit FluidAudio ueberein), aggregateCentroids, cosineDistance (Normierung korrekt), Union-Find-Pfadkompression, PCMBufferConverter/AVAudioSampleLoader-Konvertierungspfade, AssetInstallationSerializer, InstallProgressRelay-Sperrlogik, TranscriptMapper-Gruppierung.

Bewusst nicht geprueft: iOS/StenoiOSKit, StenoAudioCore/StenoMacAudio, StenoLLM und die UI-Schichten - ausserhalb des zugewiesenen Scopes. Kein Build und keine Tests ausgefuehrt; alle Befunde sind aus dem Quelltext belegt, nicht zur Laufzeit reproduziert.
- **library**: Vollstaendig gelesen: StenoLibrary/AtomicFile.swift, JSONDocumentStore.swift, LibraryMutationCoordination.swift, LibraryLayout.swift, Library.swift, RevisionStore.swift, IdentityStore.swift, FolderStore.swift, JobStore.swift, MeetingNotesStore.swift, MeetingNotesEditingSession.swift, MeetingNotesSessionPool.swift, RecoverySweep.swift, LegacyFolderAdoption.swift, MeetingTransferStateStore.swift, PreparedMeetingImport.swift, LibraryError.swift sowie alle 20 Dateien in StenoDomain. MeetingTransferImport.swift (1665 Zeilen) habe ich in den tragenden Abschnitten vollstaendig gelesen (Snapshot-Scan/Verify 190-540, Ownership/Token 660-966, Recovery 979-1200, PreparedMediaDescriptorCloner 1517-1665); die reinen Hilfsfunktionen 1200-1500 (Namensbildung, quarantineAndRemove-Details) habe ich nur ueberflogen. Zur Erreichbarkeitspruefung habe ich ausserhalb des Scopes gezielt nachgesehen: PipelineCoordinator.swift:303-350, TemplateRenderRequest.swift:40-105, MeetingReviewController.swift:60-125, RecordingSession.swift:280-335 sowie alle Instanziierungsstellen von IdentityStore/FolderStore/JobStore. Bewusst nicht bewertet: die Aufnahme- und Transkriptionspfade selbst (StenoAudioCore, StenoPipeline, StenoIdentity, StenoExchange) - dort liegen die Grundregeln 1, 4 und 5, aber sie sind nicht mein Scope. Nicht als Befund gemeldet, weil zu spekulativ oder selbstheilend: Library.init prueft mit contentsOfDirectory ohne .skipsHiddenFiles auf ein leeres Wurzelverzeichnis (eine .DS_Store verhindert das Anlegen); listMeetings/findMediaAsset brechen bei genau einem unlesbaren meeting.json komplett ab (korrupte Dokumente heilen sich durch die Quarantaene nach einem Fehlversuch, unsupportedSchemaVersion nicht); FolderStore.adoptLegacyFolders baut ein Dictionary(uniqueKeysWithValues:) ueber Namensschluessel, was bei zwei gleichnamigen Hauptordnern hart abstuerzen wuerde - ein solcher Zustand ist ueber die Schreibpfade aber nicht erzeugbar.
- **exchange**: Vollstaendig gelesen: MeetingTransferArchiveReader.swift, MeetingTransferArchiveWriter.swift, MeetingTransferPrivateRoot.swift, MeetingTransferAudioInspector.swift, MeetingTransferManifest.swift, MeetingTransferPayload.swift, MeetingTransferDigest.swift, MeetingTransferLimits.swift, LegacyImporter.swift, LegacyMeetingPreparation.swift, LegacySpeakersFile.swift, LegacyStore.swift, LegacyCommon.swift, LegacyAudioConversion.swift, WebMOpusReader.swift, OpusCAFWriter.swift, StereoM4AExporter.swift, LegacyTranscriptFile.swift, LegacySummaryFile.swift, LegacySummaryJSON.swift, LegacyPersonProfiles.swift, LegacyFolders.swift, LegacyOverrides.swift, LegacyReportsFile.swift, LegacyImportModels.swift. Zusaetzlich zur Einordnung gelesen: StenoDomain/Identifiers.swift (MeetingID ist eine UUID, daher kein Pfad-Injektionsrisiko im Zielnamen des Writers) sowie Ausschnitte aus StenoPipeline/MeetingTransferImportService.swift und App/Sources/MeetingTransferSharing.swift, um die Aufrufer der Reader/Writer-API zu pruefen.

Bewusst geprueft und NICHT als Befund gemeldet:
- Zip-Slip/Pfad-Traversal beim Import: `validatePath` (Reader:870) verbietet absolute Pfade, "..", ".", leere Segmente, Backslash, NUL, begrenzt die Tiefe und faengt Unicode- und Case-Kollisionen ab; `isPotentiallyAllowedPath` (908) laesst nur eine feste Whitelist plus `audio/track-<n>.{caf,json}` zu. Entpackt wird ohnehin nie unter dem Archivpfad, sondern als `entry-%04d` in einer privaten Sitzung. Kein Befund.
- Manipulierte Archive: Roh-Preflight (`preflightRawHeaders`) und AppleArchive-Decoder werden Header fuer Header byteweise gegeneinander geprueft (parserDifferential), Groessen-, Anzahl- und Gesamtbyte-Limits greifen doppelt, jeder Eintrag wird gegen `manifest.entries` in Groesse und SHA-256 geprueft, dazu `contentDigest` ueber alle Eintraege. Audio wird zusaetzlich als CAF geoeffnet und Sample-Rate/Kanaele/Dauer gegen das Metadatendokument abgeglichen. Ich habe keine Luecke gefunden.
- Netzwerk/Privacy: kein `URLSession`, kein `http`, kein `Locale.current` im Modul (nur `TimeZone.current` als Default des Legacy-Zeitstempel-Parsers, nicht im Transkriptionspfad).
- Sitzungsverzeichnisse/Quarantaene-Reste: `recoverAbandonedSessions` raeumt nur `.stenomeeting-validation-<uuid>` auf, aber die Staging- und Quarantaene-Namen des Writers werden von App/Sources/MeetingTransferSharing.swift (Zeilen 907/1360) abgedeckt; im Validierungs-Root bleiben nur leere Verzeichnisse zurueck. Kein Befund.
- `MeetingTransferArchiveReader.revalidate` haengt die neue Sitzung an eine bestehende: der Aufrufer haelt beide Pakete (`active.packages`, MeetingTransferImportService:255) und schliesst beide - kein Leck.

Nicht geprueft (ausserhalb des Scopes): StenoPipeline/MeetingTransferImportService.swift und StenoLibrary (Kollisionsbehandlung beim Commit in eine bestehende Library, Revisionsanlage), StenoIdentity, die Export-Seite, die den `MeetingTransferPackageContent` aus der Library aufbaut (dort entscheidet sich die Verlustfreiheit von Revisions- und Sprecher-Provenienz), sowie die Tests unter StenoKit/Tests/StenoExchangeTests.
- **intelligence**: Vollstaendig gelesen: alle 12 Dateien in StenoKit/Sources/StenoIntelligence (OpenAICompatibleProvider, FoundationModelsProvider, TemplateRenderer, TextModelProvider, TextModelEndpoint, TextModelEndpointPolicy, TextModelEndpointRegistryState inkl. Journal-Recovery und atomarem Dateispeicher, TextModelProbeState, ExternalModelNotice, OutboundDisclosure, ReportTextModelDisplay, TemplateRenderPinsFailureObservationLedger). Dazu vollstaendig: StenoPipeline/ModelInstallationCoordinator, StenoDiarization/DiarizationModelInstaller, ModelChecksumManifest, ModelAccess, StenoTranscription/SpeechAssetInstaller, SystemSpeechAssets, LocaleResolver, App/Sources/TextModelSettings.swift, StenoPipeline/TemplateRenderInputAssembler, TemplateParticipants. Teilweise gelesen (relevante Abschnitte): App/Sources/AppModel.swift (Modell- und Sprachbereich, Zeilen 370-760), App/Sources/TextModelSettingsView.swift und iOS/App/Sources/TextModelSettingsView.swift (Probe- und Entwurfspfad), iOS/App/Sources/TextModelSettings.swift, iOS/App/Sources/IOSModelInstallationState.swift, iOS/App/Sources/TranscriptionLanguage.swift, StenoDiarization/FluidSortformerProvider (Modell-Ladepfad), StenoTranscription/SpeechAnalyzerProvider (Asset-Abschnitt), StenoPipeline/PipelineCoordinator (executeTemplateRender und Pin-Pruefung), StenoPipeline/MeetingReview.

Repo-weite Suchen: `URLSession`, `dataTask`, `downloadTask`, `ModelInstallationCoordinator`, `DownloadUtils`, `downloadRepo`, `AssetInventory`, `Keychain`, `Locale.current`, `willPerformHTTPRedirection`, `URLSessionConfiguration`, harte `http(s)://`-Literale, Logging in StenoIntelligence/StenoPipeline. Ergebnis: die einzigen produktiven Netzwege sind der OpenAI-kompatible Textmodell-Endpunkt und FluidAudios `DownloadUtils` im Diarisierungs-Installer; kein Telemetrie- oder Update-Pfad, keine hartkodierte Fremd-URL ausser dem localhost-Vorschlag im Einstellungsformular.

Bewusst nicht geprueft: iOS/build/SourcePackages/checkouts/FluidAudio (Fremdcode, ausgecheckte Abhaengigkeit), Testziele, die Audio-/Aufnahmepfade (StenoAudioCore, StenoMacAudio), StenoExchange und StenoLibrary ausser den oben genannten Beruehrungspunkten - liegen ausserhalb des zugewiesenen Bereichs.

Geprueft und in Ordnung befunden (keine Befunde): Schluesselhaltung liegt auf beiden Plattformen ausschliesslich im Keychain, weder Endpunktdatei noch Journal noch UserDefaults enthalten Geheimnisse (TextModelEndpoint hat nur `requiresAPIKey`, kein Klartextfeld); der Schluessel wird beim Wechsel der baseURL nicht mitgenommen (TextModelSettings.swift:181-183); das Journal-Protokoll fuer Upsert/Delete ist in beiden Absturzphasen konsistent aufloesbar; `AtomicTextModelEndpointRegistryStore.persist` schreibt korrekt ueber Temp-Datei, fsync, rename und Verzeichnis-fsync mit O_EXCL/O_NOFOLLOW; der Prompt-Aufbau haelt Transkript, Notizen und Teilnehmer als Quelldaten und nimmt E-Mail-Adressen aus strukturierten Profilen ausdruecklich heraus (TemplateParticipants.swift:84-87); unbestaetigte und mehrdeutige Cluster werden generisch nummeriert statt benannt (TemplateParticipants.swift:126-145, MeetingReview.swift:96-116); `FluidSortformerProvider` laedt nichts mehr selbst nach und verweigert unvollstaendige Bundles ueber den Installationsmarker; die Pin-Pruefung im Renderjob erzwingt Endpunkt-Snapshot mit Konfigurationsrevision und Eingabe-Fingerabdruck.
- **macos-app**: Vollständig gelesen: App/Sources/AppModel.swift, AppModel+Review.swift, AppModel+Export.swift, AppModel+People.swift, AppModel+Transcript.swift, AppModel+MeetingTransfer.swift, AppModel+Folders.swift, RecordingStartState.swift, MicrophoneSelection.swift, ModelConsent.swift, AudioExportPresentation.swift, SpeakerProcessingJobSelection.swift, OperatorProfile.swift, OnboardingModel.swift, ContentView.swift, StenoApp.swift, RecordingView.swift, MeetingDetailView.swift, SpeakerReviewSection.swift, ReportsSection.swift, ParticipantsSection.swift, NotesSection.swift, PeopleSettingsView.swift, SettingsView.swift, ModelStatusView.swift, OnboardingView.swift, MicrophoneSelectionView.swift, TextModelSettings.swift, TextModelSettingsView.swift, LegacyImportView.swift, LegacyUpgradePresentation.swift, MeetingTransferExportView.swift, MeetingTransferSharing.swift, MeetingSidebar/MeetingSidebarView.swift, MeetingSidebar/MeetingSidebarState.swift; MeetingTransferImportView.swift bis auf einen mittleren Abschnitt (Zeilen 452-630 gelesen, restliche Detail-Presentation überflogen). Zur Absicherung der Befunde zusätzlich außerhalb des Scopes gelesen: StenoKit/Sources/StenoPipeline/PipelineStartup.swift, RecoverySweep.swift, CaptureRecovery.swift, PipelineCoordinator.swift (nur Locale-Stellen), StenoAudioCore/RecordingSession.swift (stop/finalizeStop), StenoTranscription/LocaleResolver.swift, SpeechAnalyzerProvider.swift (prepareTranscriber), StenoPipeline/SpeakerSampleSelector.swift. Bewusst nicht geprüft: Theme.swift, RecordingStrip.swift, MeetingSidebar/MeetingSidebarTransfer.swift, MeetingTransferDocumentType.swift (reine Präsentations-/Typdefinitionen ohne Zustandslogik); die Byte-genaue Namespace-/Deskriptor-Härtung in MeetingTransferSharing.swift (Zeilen 60-980) wurde gelesen, aber nicht gegen jede fstat/renameatx-Randbedingung durchgerechnet — dort wurde kein Befund gemeldet, das ist keine Freigabe dieses Abschnitts.
- **ios**: Vollstaendig gelesen: alle vier Dateien von iOS/StenoiOSKit/Sources/StenoiOSAudio (AudioSessionController, AudioSessionEvents, MicrophoneCapture(+AudioSource), RecordPermission, SilenceMonitor, AudioLevel) sowie im App-Ziel RecordingModel, RecordingFinalizer, AppModel, AppModel+Folders, AppModel+Reports, AppModel+MeetingTransfer, AudioReadinessView, RecordingView, ContentView, StenoApp, TranscriptionLanguage, IOSModelInstallationState, ModelConsent, TextModelSettings(+View), MeetingDetailView, MeetingReportsSection, MeetingReportsPresentation, MeetingSidebarView, IOSMeetingSidebarPresentation, MeetingNotesEditor, MeetingTransfer Import/Export/ShareSheet, LibraryLocation, LibraryBackupPolicy, RuntimeChangeSerializer, MissingSpeechModelJobRetrier, ViewIdentityGeneration, LevelMeter, RecordingStrip, MarkdownLiteView, NavigationRouter, MeetingTransferDocumentType. Zusaetzlich zur Absicherung im Kern gelesen: StenoAudioCore/RecordingSession, TrackContinuity, AudioSource, StenoPipeline/PipelineStartup, MissingDiarizationModelJobRetrier, StenoLibrary/JobStore (recoverAtLaunch/requeueFailedJobs), StenoTranscription/TranscriptionError, LocaleResolver, sowie iOS/project.yml (UIBackgroundModes: audio ist gesetzt, Backgrounding der laufenden Aufnahme ist damit gedeckt).

Bewusst nicht geprueft: iOS/App/Tests (nur punktuell per grep zur Gegenprobe), Theme.swift und rein visuelle Layoutfragen, die macOS-App unter App/Sources, und die StenoKit-Interna jenseits der oben genannten Dateien - beides liegt ausserhalb des Scopes.

Zwei Verdachtsfaelle habe ich nach Gegenpruefung wieder verworfen und melde sie deshalb nicht: (1) \"Pegel friert nach Buffer-Ausfall ein, Stille-Alarm feuert nie\" - falsch, weil TrackContinuity.fillSilence Stille-Buffer in den Writer schiebt und makeWriterTask darauf updateLevels ruft; der Alarm kommt. (2) \"Unfreiwilliger Stop laedt die Meetingliste nicht neu\" - stimmt zwar (RecordingStrip.swift:52 und RecordingModel.finishAfterSelfStop umgehen AppModel.stopRecording und damit reloadMeetings), ist aber folgenlos, weil RecordingView.swift:318 das Meeting schon beim Start in die Liste laedt und MeetingDetailView seinen Zustand selbst frisch liest.

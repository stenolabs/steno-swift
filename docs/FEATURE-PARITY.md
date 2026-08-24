# Feature-Parität: stenoai (alt) gegen Steno (neu)

Gepflegtes Abhak-Dokument.
Stand: 2026-08-19.
Legende: [x] in der neuen App vorhanden und verifiziert, [ ] offen, (M4)/(M5)/... = geplanter Meilenstein laut ARCHITECTURE.md Abschnitt 10, "bewusst nicht" = Entscheidung gegen Übernahme mit Begründung.

Der Haken steht hier für "gebaut und getestet".
Wo eine zusätzliche Hardware- oder Sichtprüfung offen ist, steht das ausdrücklich am jeweiligen Punkt oder im zugehörigen Handoff.

## Aufnahme und Import

- [x] Mikrofonaufnahme (neu: eigene unveränderliche Spur statt Stereo-Mix)
- [x] Systemaudio-Aufnahme (neu: CoreAudio Process Tap in-process, gerätewechselfest; alt: Electron-Loopback)
- [x] Getrennte Originalspuren (neu; alt hatte nur eine Stereo-WebM, Trennung erst nachträglich)
- [x] Import externer Audiodateien mit Duplikatschutz (neu: provenanceKey per SHA-256)
- [x] Crash-Sicherheit der Aufnahme (neu: kill -9 verlustfrei mit automatischer Adoption; alt: verwaiste Aufnahmen)
- [x] Mikrofonspur manuell pausieren und fortsetzen (nur die Mikrofonspur; während der Pause wird zeitkorrekte Stille geschrieben)
- [x] Laufende Mikrofonspur bei Geräteausfall erhalten (an Startgerät per UID gebunden, Stille während der Lücke, automatische Wiederaufnahme nur mit demselben Gerät; automatisiert und mit AirPods hardwaregetestet)
- [ ] Aufnahme fortsetzen / an bestehende Notiz anhängen (alt: --append-to)
- [ ] Automatische Meeting-Erkennung per Mic-Monitor samt Benachrichtigung (alt: mic_monitor-Sidecar; neu geplant als interner Dienst)
- [ ] Stille-Auto-Stopp (alt: silence-auto-stop)
- [ ] Globaler Aufnahme-Hotkey (alt: Cmd+Shift+R)
- [ ] Menüleisten-Icon / Tray-Steuerung
- [x] Mikrofonauswahl.
  Die Automatik erkennt das eindeutig von bekannten Browsern oder Meeting-Apps verwendete Eingabegerät; bei keinem, mehreren, unbekannten oder nicht vollständig auflösbaren Treffern fordert Steno die bewusste manuelle Wahl.
  Die Wahl bleibt gespeichert und wird beim Start per UID gebunden, ohne Fallback auf ein anderes Gerät.
  Automatisiert getestet; Sicht- und Meeting-App-Realtest offen.

## Transkription

- [x] Live-Transkript während der Aufnahme (neu: SpeechAnalyzer-Streaming statt 400-ms-Redecode; vorläufig/final unterscheidbar)
- [x] Finaler Transkriptionslauf mit Wortzeitstempeln (neu: je Wort; alt: Token-Ebene nur im Parakeet-Pfad)
- [x] Sprachauswahl mit Persistenz (neu: Picker aus SpeechTranscriber-Sprachen)
- [x] ASR-Benchmark und aktenkundige Engine-Entscheidung (docs/BENCH-M2-ASR.md; WER 21,3 gegen Parakeet 18,31, RTF 2,3x schneller)
- [ ] Reproduzierbares Benchmark-Setup fuer lokale ASR- und Diarisierungsmodelle: Manifest-, Hash-, WER/CER-, Eigennamen- und RTTM/dscore-Werkzeuge sind gebaut und uebernehmen den verifizierten Steno-Legacy-Scoringvertrag; offen bleiben die unveraenderlichen Audioausschnitte, manuell geprueften Referenzen sowie die M5-Air-Laeufe zu Hall, Uebersprechen, Zeitstempeln und Sprecherzuordnung.
- [ ] Benchmark-Korpus zweistufig aufbauen: das CC-BY-4.0-lizenzierte `Koelner Korpus des Kiezdeutschen` ist mit DOI und Quelldatei-Pruefsummen als separater Stresstest registriert, braucht aber noch zeitliche Ausrichtung und manuelle Ausschnittpruefung; fuer den standarddeutschen Haupttest ist OOCC wegen guter manueller Zeitstempel technisch vorgemerkt, seine CC-BY-NC-ND-4.0-Lizenz erfuellt jedoch nicht die freie Produktreferenz und die endgueltige Quelle bleibt offen.
- [ ] Automatische Spracherkennung ("auto"; alt: 13 kuratierte + 99 Passthrough-Sprachen)
- [x] Transkript-Neuberechnung aus der UI ("Transcribe Again" im Kontextmenü; das alte Transkript bleibt als Revision, der Dialog nennt den Preis: Sprecher müssen danach neu bestätigt werden)
- [ ] Fallback-Engine bei ASR-Crash (alt: whisper.cpp-Fallback; neu: Live-Revision bleibt als Rettungsnetz)
- [ ] iOS: Der vorbestehende Statuswechsel von `.unavailable` zu `.ready` oder `.modelsRequired` lädt die neue Revision nicht in jedem Fall ohne erneutes Öffnen.
- bewusst nicht: Parakeet/MLX als Primär-Engine (Provider-Grenze hält die Tür offen, Revisionsauslöser in BENCH-M2-ASR.md)
- bewusst nicht: Windows-Support (neue App ist macOS-nativ)

## Sprecher (Diarisierung und Identität)

- [x] Akustische Diarisierung je Spur (neu: Sortformer in-process, verhaltensgleich verifiziert, DER 20,34 = Alt-Basislinie)
- [x] Voiceprint-Embeddings je Cluster (WeSpeaker-Zentroide, overlap-bereinigt)
- [x] Wort-Alignment Transkript zu Sprechersegmenten (Satz-Mittelpunkt, wortweiser Split ab 5 s, nie Text verwerfen)
- [x] Personenregister mit kontextgetaggten Prototypen und Hard Negatives (13 Alt-Invarianten als Testkatalog)
- [x] Vorschlags-Engine mit den geeichten Gates (confirmed/possible/none, meetingweite Exklusivität, Run-Provenienz)
- [x] Sprecher-Review-UI: Bestätigen, Zuweisen (Many-to-one), Neue Person, "Mehrere Personen", Generisch; Namensauflösung im Transkript; Hörproben je Cluster (Zitat + Audio aus demselben Turn)
- [x] Personenverwaltung in den Einstellungen: alle Profile, Umbenennen, Zusammenführen, Löschen mit Rücknahme; je Stimmprobe Herkunft, Hörprobe und Ausschließen statt Löschen; Hard Negatives sichtbar und entschärfbar (alt: nur Liste, eine Hörprobe, Löschen; siehe docs/PLAN-PEOPLE.md)
- [ ] Selbst-Voiceprint ("Ich"-Erkennung über Meetings hinweg; alt: enroll-self; Fables Vorschlag "This is you"-Markierung gehört hierher)
- [ ] Manuelles Anlernen einer Stimme ohne Meeting (`manualEnrollment` existiert im Datenmodell, der Aufnahmeweg nicht)
- [ ] Sitzungsübergreifende Vorschläge in der UI sichtbar
- [ ] Mehr als vier Sprecher je Kanal (offene ML-Frage; VBx-Pfad gemessen unbrauchbar, siehe ARCHITECTURE.md Risiken)

## Intelligenz (Zusammenfassungen, Vorlagen, Chat)

- [x] Zusammenfassung / Besprechungsprotokoll on-device (Foundation Models, Map-Reduce über Turn-Grenzen, guided generation; Realtest an einem echten Meeting offen)
- [x] iOS-Protokollpfad mit Apple als Kaltstartstandard, optionalen OpenAI-kompatiblen Endpunkten, gepinnter Revision und Eingabe, unveränderlichen Versionen, Fortschritt, Fehler, Abbruch, Copy und Share.
  Builds, vollständige App-Suites und alle zehn StenoKit-Testtargets sind grün; der Simulator ist kein Beleg für `SystemLanguageModel` oder echte Netzwerkberechtigungen.
- [ ] Apple-Foundation-Models-Hardwareabnahme auf einem Apple-Intelligence-fähigen iPhone oder iPad im Flugmodus mit harmloser deutscher Fixture: Generate, Regenerate sowie Copy, Share und Cancel beobachten.
- [ ] iOS-LM-Studio-Abnahme, nachdem ein konkreter lokaler Endpunkt und eine nicht sensitive synthetische Fixture gewählt wurden: echte `/models`- und `/chat/completions`-Aufrufe prüfen.
- [ ] iOS-Sichtabnahme der Protokollansicht: iPhone-Hochformat, iPad Hoch- und Querformat, Sidebar sichtbar und verborgen, Darstellung und Scrollen des langen Reports, zwei Versionen und Versionsauswahl.
- [ ] iOS-Sichtabnahme der externen Auswahl mit sichtbarem Host und den exakten Datenklassen.
- [ ] iOS-Sichtabnahme, dass die alte Version während `Pending` und `Failed` sichtbar bleibt.
- [ ] iOS-Sichtabnahme von Copy für die gewählte Version.
- [ ] iOS-Sichtabnahme des geöffneten Share-Sheets und seines Inhalts.
- [ ] iOS-Sichtabnahme, dass die Einstellungen nicht selbstständig testen.
- [ ] (M4) Vorlagen/Templates (Ergebnisprotokoll, Verkaufsnotiz, kommunale Sitzung, eigene Templates)
- [ ] Direkte Gemma-Downloads für iOS.
- [x] Report-Versionen je Meeting (mehrere Fassungen nebeneinander, Revision-gepinnt, Quarantäne-Restore)
- [ ] (M4) Titel-Generierung
- [x] (M5) Optionale externe LLM-Provider mit nativen Dialekten fuer Ollama, LM Studio, OpenAI, Anthropic und Bedrock sowie einem konservativen OpenAI-kompatiblen Fallback (nie automatisch, Wahl am Job gepinnt, Provider sichtbar am Report; Realtest mit LM Studio/MLX gemma-4-e4b und mit Ollama/Gemma 4 auf Mac und iPad-Simulator bestanden; Cloud-Vertraege lokal mit HTTP-Fixtures verifiziert, keine bezahlte Cloud-Anfrage ausgefuehrt)
- [ ] Transkript-Chat / Query (alt: query, chat-global über alle Notizen)
- bewusst nicht: Ollama bündeln und dessen Prozess verwalten (Architekturentscheidung)

## Bibliothek und Verwaltung

- [x] Meetingliste mit Status
- [x] Persistente Job-Queue mit Crash-Recovery (neu; alt: größte Recovery-Lücke)
- [x] Versionierte Transkript-Revisionen, Benutzer-Edits nie stillschweigend ersetzt (neu)
- [x] Meeting löschen (Papierkorb, Bestätigungsdialog, Jobs werden storniert)
- [x] Meeting umbenennen (Kontextmenü)
- [x] Sidebar-Gruppierung nach Alter (Heute, Gestern, letzte 7/30 Tage, danach Monat, Zukünftiges eigen; Produktanforderung vom 05.08.)
- [x] Ordner / Organisation mit genau einer Zuordnung je Meeting.
  macOS und iOS verwenden denselben persistenten Baum mit Wurzelordnern und einer Kindebene.
  Auf iOS zeigt eine native, stabile Sidebar-Liste den Baum mit Disclosure und Einrückung sowie ungeordnete Meetings in Datumsabschnitten.
  Anlegen, Umbenennen, Löschen, Verschieben und Hochstufen sind über Kontextmenüs erreichbar; typisiertes Ziehen ist eine zusätzliche Touch-Interaktion.
  Bekannter iPad-Gerätefehler, im Tracker als Issue 1 geführt; der vollständige Kontextmenüweg funktioniert als Workaround.
  Alt-Ordner werden beim Import gesetzt und für den Altbestand einmalig übernommen.
- [x] Suchfeld über der Meetingliste (nativ `.searchable`, reiner Titelfilter, diakritika-unempfindlich; die Volltextsuche bleibt vertagt).
  Auf iOS öffnet ein Suchtreffer seine Ordner-Vorfahren nur vorübergehend und überschreibt den persistenten Disclosure-Zustand nicht.
- [x] Ordner umsortieren.
  Auf macOS und iOS stehen `Move Up` und `Move Down` im Kontextmenü zur Verfügung.
  Auf iOS können Ordner zusätzlich per Ziehen verschachtelt oder an die Wurzel hochgestuft werden.
- bewusst nicht auf iOS: Mehrfachauswahl und Sammelverschieben bleiben macOS-spezifisch.
- bewusst nicht: eigener Sidebar-Kopf mit App-Namen und Chevron nach Vorbild der Codex-App (Produktwunsch vom 06.08., nach Fables Einspruch zurückgezogen: `.navigationTitle` rendert den Namen bereits systemseitig, es gibt nur eine Bibliothek, also keinen Kontext zum Wechseln, und "Neuer Chat" existiert als "New meeting" in der Toolbar)
- [x] Benutzernotizen während der Aufnahme und am Meeting (NotesSection in RecordingView und MeetingDetailView; Zeitmarke per Cmd-M)
- [x] Transkript-Editor (Korrektur je Zeile über den Stift; jede Korrektur wird eine `userEdit`-Revision, die erkannte Fassung bleibt lesbar. Ein Neulauf nach einer Korrektur überschreibt sie nicht, sondern wartet als geparkter Kandidat - und ist jetzt über ein Banner übernehmbar, vorher war er unerreichbar)
- [x] Suche im Transkript (eigene Leiste mit Cmd-F; bewusst kein zweites `.searchable`, weil die Seitenleiste das Suchfeld des Fensters belegt)
- [ ] Suche über Meetings (vertagt: Suchindex-Entscheidung, ARCHITECTURE.md Abschnitt 11)
- [ ] Speicherort wählbar (alt: storage_path; neu: bisher nur STENO_LIBRARY_DIR)
- bewusst nicht: "Aufnahmen nach Verarbeitung löschen"-Default (alt: keep_recordings=false; neu sind Originale unantastbar)

## Export und Austausch

- [x] (M6) Steno-Altimport (nicht destruktiv, dedupliziert über legacy:<stem>; Realtest mit einem importierten Datenbestand einschließlich Personen-Profilen, Stimmproben, Reports, Notizen und Ordner-Metadatum bestanden; Chat-Sessions bewusst nicht)
- [ ] Obsidian-Export (nur nach aktiver Freigabe, Klartext-Hinweis; als Produktentscheidung vertagt, siehe HANDOFF spätere Liste)
- [x] Markdown-Export einzelner Meetings ("Export as Markdown…" im Kontextmenü: Titel, Datum, Teilnehmer, Notiz, Berichte, Transkript mit Zeitmarken; unbestätigte Sprecher behalten ihre technische Bezeichnung statt eines geratenen Namens)
- [ ] Teilen/Share-Menü, PDF-Export (alt: share menu)
- [x] Audio-Export einzelner Spuren aus der UI ("Export Audio…" im Kontextmenü, Spurwahl im Dialog; kopiert das Original unverändert heraus statt zu konvertieren - an ihm hängt jede Zeitmarke)
- [ ] Granola-Importer über API (neu, kein Alt-Feature; Vorbild: openoeats hat einen Granola-Importer, Produkthinweis vom 05.08.)

## Plattform und Betrieb

- [x] Native macOS-App (SwiftUI, XcodeGen; alt: Electron + PyInstaller-Python + Sidecars)
- [x] App-Nap-Sperre während Aufnahme, Freier-Platz-Prüfung
- [ ] Garantierte Fertigstellung langer iOS-Nachverarbeitung im Hintergrund.
- [ ] (M7) Bibliotheksverschlüsselung als Beta (Kopie-Prüfung-Umschalten, Recovery-Code)
- [x] Onboarding/Setup-Prüfung (Erstlauf-Assistent mit Rechtshinweis, Profil, Transkriptionssprache, Modellzustand und getrennter Prüfung von Mikrofon- und Systemaudio-Berechtigung; über das Hilfe-Menü erneut erreichbar)
- [ ] Kalender-Integration (alt: calendar-auth, Pre-Meeting-Benachrichtigungen)
- [ ] Benachrichtigungen (Notiz fertig, Stille erkannt)
- [ ] Launch on Login, Dock-Icon-Präferenz
- [ ] Deep Links (alt: stenoai:// für Shortcuts)
- [ ] Signierte Distribution + Updates (vertagt, ARCHITECTURE.md Abschnitt 11)
- bewusst nicht: Telemetrie (neu: keine; falls je, opt-in und inhaltsfrei)
- bewusst nicht: Org-/Adapter-Anbindung und Cloud-Backup der alten App (nicht Teil des lokalen Produktkerns; Neubewertung frühestens nach M8)

## Pflegehinweis

Beim Abschluss eines Meilensteins die betroffenen Kästchen abhaken und das Standdatum oben aktualisieren.
Neue Alt-Features, die beim Steno-Altimport (M6) auffallen, hier nachtragen statt still zu ignorieren.

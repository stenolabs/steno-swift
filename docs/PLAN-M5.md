# Meilenstein 5: Optionale externe LLM-Provider

Umsetzungsplan zu `ARCHITECTURE.md` Abschnitt 10, Meilenstein 5.
Akzeptanz laut Architektur: LM Studio und eigenes Ollama über einen OpenAI-kompatiblen Vertrag, nie automatisch kontaktiert, Provider sichtbar am Ergebnis.
Reihenfolge verbindlich; jeder Schritt endet mit grünem `swift test` und einem Commit.

Grundsätze:

- Ein externer Endpunkt wird ausschließlich auf ausdrückliche Nutzeranforderung kontaktiert (Vorlagen laufen ohnehin nur auf Klick, M4-Entscheidung); es gibt keinen Hintergrund-Ping, keine automatische Verfügbarkeitsprüfung, kein Auto-Retry über Prozessgrenzen.
- API-Schlüssel liegen nur im Keychain, nie in UserDefaults, Job-JSON, Run-Artefakten oder Logs. Transkriptinhalte tauchen in keiner Fehlermeldung und keinem Log auf.
- Foundation Models bleiben der Standard; ohne konfigurierten Endpunkt ändert sich nichts am Verhalten der App.

## Schritt 1: OpenAICompatibleProvider in StenoIntelligence (Codex)

- `TextModelEndpoint` (StenoIntelligence, Codable/Equatable/Sendable): `id: UUID`, `name` (Anzeigename), `baseURL` (z. B. `http://localhost:1234/v1`), `modelID`, `requiresAPIKey: Bool`. Kein Schlüsselmaterial im Typ.
- Schlüssel-Beschaffung als injizierter Vertrag `TextModelSecretResolving` (`@Sendable (UUID) -> String?`); die Keychain-Implementierung kommt in Schritt 3 in die App, Tests nutzen In-Memory.
- `OpenAICompatibleProvider: StructuredTextModelProvider` gegen `POST {baseURL}/chat/completions`:
  - Instructions/Prompts wie im FoundationModelsProvider (gleiche Injektions-Härtung, gleiche Abschnitts-Spezifikation), aber mit expliziter JSON-Antwortanweisung.
  - Strukturierte Ausgabe primär über `response_format: {type: "json_schema"}` mit einem Schema, das exakt `sections: [{sectionID, markdown}]` verlangt (LM Studio und aktuelle Ollama-Versionen unterstützen das). Antwortet der Server darauf mit HTTP 4xx, denselben Request einmal ohne `response_format` wiederholen (Anweisungs-Fallback).
  - Antwort-JSON selbst parsen und validieren; bei ungültigem JSON genau ein Reparaturversuch (erneuter Aufruf mit Hinweis auf den Parserfehler), danach klarer Fehler. Die Abschnitts-ID-Validierung übernimmt weiterhin der TemplateRenderer.
  - `availability` ist für konfigurierte Endpunkte `.available`; Erreichbarkeit wird nicht im Hintergrund geprüft (Grundsatz oben). Netz- und Serverfehler entstehen erst beim Rendern und werden auf klare deutsche Meldungen abgebildet: Endpunkt nicht erreichbar (URL nennen), HTTP 401/403 als abgelehnter Schlüssel, unbekanntes Modell, ungültige Antwort. Fehlertexte enthalten nie Transkriptinhalte und nie den Schlüssel.
  - `descriptor`: `name` = Anzeigename des Endpunkts, `version` = "openai-compat", `modelVersion` = modelID; damit ist der Provider am Ergebnis und am Run sichtbar.
  - Bearer-Header nur, wenn ein Schlüssel aufgelöst wird; Timeout großzügig (lokale Modelle sind langsam, 300 s je Aufruf), Cancellation via `Task.checkCancellation` zwischen Aufrufen respektieren.
- Zusätzlich eine kleine Prüf-Funktion `probe(endpoint:)` (async): `GET {baseURL}/models`, meldet Erreichbarkeit und ob `modelID` in der Liste ist. Wird nur vom "Verbindung testen"-Knopf der Einstellungen (Schritt 3) aufgerufen, nie automatisch.
- Tests hardwarefrei über `URLProtocol`-Mock: Erfolgspfad mit json_schema, Fallback-Pfad ohne response_format, Reparaturversuch bei kaputtem JSON, Fehlerabbildungen (Verbindung, 401, Modell fehlt), Header mit/ohne Schlüssel, probe-Erfolg und -Fehlschlag.

## Schritt 2: Pipeline-Verdrahtung mit gepinntem Endpunkt (Codex)

- `Job` (StenoDomain) bekommt ein optionales Feld `textModelEndpointID: String?`; nil = Foundation Models. Beim Einreihen eines templateRender-Jobs wird die Nutzerwahl gepinnt (wie `revisionID`): das Ergebnis bleibt seinem Provider zuordenbar, auch wenn die Einstellung später geändert wird. Alte Jobs ohne Feld dekodieren zu nil; `schemaVersion` bleibt 1.
- `PipelineCoordinator` bekommt statt eines festen `textModelProvider` einen injizierten Resolver `@Sendable (String?) throws -> any TextModelProvider` (Default: liefert immer FoundationModelsProvider). `executeTemplateRender` löst den Provider aus der gepinnten ID auf; unbekannte oder inzwischen gelöschte Endpunkt-ID => Job failed mit klarer Meldung, kein stiller Fallback auf ein anderes Modell (der Nutzer hat diesen Provider gewählt).
- Run-`engine` und `TemplateResult.engine` kommen wie bisher vom tatsächlich benutzten Provider; die bestehende Konsistenzprüfung committed.run.engine == artifact.engine bleibt.
- Bestehende Aufrufer (App, steno-smoke) bleiben über den Default-Resolver quellkompatibel oder werden minimal angepasst.
- Tests mit Fake-Resolver: Pinning beim Einreihen, Ausführung mit aufgelöstem Fake-Provider, unbekannte Endpunkt-ID => failed mit Meldung, nil => Foundation-Models-Pfad unverändert, Crash-Recovery-Pfad (committed run) unverändert.

## Schritt 3: Einstellungen und Protokoll-UI (Driver, nicht Codex)

- Settings-Szene der App, Bereich "Sprachmodelle": Liste konfigurierter Endpunkte (Name, URL, Modell), Anlegen/Bearbeiten/Löschen; Persistenz der Endpunktliste als Codable-JSON in UserDefaults (`steno.textmodel.endpoints`), Schlüssel im Keychain (Service `org.steno.textmodel`, Account = Endpunkt-UUID), Keychain-Store in der App implementiert und als `TextModelSecretResolving` injiziert.
- "Verbindung testen"-Knopf je Endpunkt (ruft `probe`, zeigt Erreichbarkeit und Modellstatus); ausschließlich manuell.
- Protokoll-Bereich im Meeting-Detail: Modell-Auswahl neben der Vorlagen-Auswahl ("Apple Intelligence (Gerät)" als Standard plus konfigurierte Endpunkte). Nicht-Apple-Einträge sind klar gekennzeichnet, dass das Transkript an den konfigurierten Endpunkt übertragen wird (bei localhost/LAN: an den lokalen Server). Die Wahl wird beim Klick auf "Protokoll erstellen" in den Job gepinnt; zuletzt benutzte Wahl wird gemerkt, aber nie stillschweigend auf extern gestellt: Standard nach frischem Start ist Apple, gemerkt wird nur eine zuvor ausdrücklich getroffene Wahl.
- Ergebnisanzeige nennt den Provider (EngineDescriptor: Name + Modell) am Report, auch für ältere Ergebnisse.
- Gelöschte Endpunkte: bestehende Reports behalten ihren EngineDescriptor (reine Daten); offene Jobs mit gelöschter ID schlagen mit klarer Meldung fehl (Schritt 2).

## Schritt 4: Realtest

- LM Studio mit einem lokalen Modell (Produktkandidat: Gemma über MLX) gegen ein echtes Meeting; Vergleich desselben Meetings mit Foundation Models (zwei Reports nebeneinander, Provider sichtbar).
- Prüfen: kein Netzverkehr ohne Klick (Grundsatz), Fehlerbild bei gestopptem LM Studio, Schlüsselpfad gegen einen Cloud-Endpunkt nur nach ausdrücklicher Freigabe.

## Akzeptanz M5 (aus ARCHITECTURE.md)

1. LM Studio und eigenes Ollama funktionieren über den einen OpenAI-kompatiblen Vertrag.
2. Kein externer Endpunkt wird je automatisch kontaktiert; Foundation Models bleiben der Standard.
3. Der Provider ist am Ergebnis sichtbar (EngineDescriptor an Report und Run), auch nachträglich.

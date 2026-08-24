# Meilenstein 4: Vorlagen und Foundation Models

> Historical, non-normative milestone record retained in German. Use `ARCHITECTURE.md` and `FEATURE-PARITY.md` for current status.

Umsetzungsplan zu `ARCHITECTURE.md` Abschnitt 10, Meilenstein 4.
Reihenfolge verbindlich; jeder Schritt endet mit grünem `swift test` und einem Commit.
Grundsatz aus der Architektur: Ohne Modell bleibt alles andere vollständig nutzbar; kein externer Dienst wird je automatisch kontaktiert (Foundation Models laufen on-device).

## Schritt 1: StenoIntelligence mit FoundationModelsProvider

- Neues Target `StenoIntelligence`, keine externen Abhängigkeiten (FoundationModels ist System-Framework, macOS 26).
- `TextModelProvider`-Vertrag nach ARCHITECTURE.md Abschnitt 6: `render(template:transcript:) async throws -> TemplateResult`, plus `EngineDescriptor` und eine Verfügbarkeitsabfrage (`SystemLanguageModel.default.availability`), die Unverfügbarkeit (Apple Intelligence aus, Modell lädt noch) als klaren, benannten Zustand liefert statt als Fehler.
- `Template` als Domänentyp in StenoDomain: id, Name, Beschreibung, Abschnittsstruktur (z. B. Zusammenfassung, Teilnehmer, Kernthemen, Entscheidungen, Aufgaben), Prompt-Bausteine. Erste gebaute Vorlage: **Besprechungsprotokoll**; die Struktur muss weitere Vorlagen (Ergebnisprotokoll, Verkaufsnotiz, kommunale Sitzung) tragen können, ohne dass der Provider sie kennt.
- **Chunking ist Pflicht, nicht Kür**: Das Foundation-Models-Kontextfenster ist klein (Größenordnung 4k Tokens); ein 70-Minuten-Meeting hat ~9k Wörter. Map-Reduce: Transkript in überlappungsfreie Abschnitte entlang von Turn-Grenzen teilen (Zielgröße konfigurierbar, konservativ wählen), je Abschnitt eine Zwischenzusammenfassung (map), dann die Vorlage über den Zwischenergebnissen rendern (reduce). Bei Überlänge der Zwischenergebnisse rekursiv weiter reduzieren. Sprechernamen aus der Revision (aufgelöste Personen, sonst generische Labels) fließen in die Abschnitte ein.
- Strukturierte Ausgabe über `@Generable`-Typen (guided generation), nicht über Freitext-Parsing.
- `TemplateResult` (StenoDomain): Markdown-Ergebnis, verwendete Vorlage, EngineDescriptor, Revision-Referenz, Zeitstempel.
- Tests hardwarefrei über einen Fake-TextModelProvider: Chunking-Grenzen (Turn-Grenzen respektiert, nichts verworfen, Überlappung null), Map-Reduce-Rekursion, Namensauflösung in den Abschnitten; der echte FoundationModels-Pfad wird manuell und per Smoke verifiziert, nicht unit-getestet.

## Schritt 2: Pipeline-Job templateRender

- Job-Kind `templateRender` (existiert in Job.Kind): Eingabe meetingID + templateID + Revision (aktuelle), Ausgabe atomar als `runs/<id>/template.json` plus abgelegtes `TemplateResult` unter `reports/` des Meetings (mehrere Ergebnisse je Meeting möglich, jüngstes zuerst; kein Überschreiben).
- Kein Auto-Enqueue nach der Diarisierung: Vorlagen laufen nur auf Nutzeranforderung (Architekturentscheidung: LLM-Nutzung ist immer bewusst).
- Wiederholung idempotent, Cancel/Fehlerpfade wie gehabt; Modell nicht verfügbar => Job failed mit der klaren Verfügbarkeitsmeldung des Providers.
- Tests mit Fake-Provider: Erfolg, Nichtverfügbarkeit, Crash mid-run, mehrere Ergebnisse nebeneinander.

## Schritt 3: App-UI (Driver, nicht Codex)

- Meeting-Detail bekommt einen Protokoll-Bereich: Vorlage wählen, "Protokoll erstellen", Fortschritt am Job, Ergebnis als gerendertes Markdown mit Kopieren-Knopf; ältere Ergebnisse abrufbar.
- Verfügbarkeits-Hinweis, wenn Apple Intelligence aus ist (mit Verweis auf die Systemeinstellung), ohne den Rest der App zu beeinträchtigen.

## Akzeptanz M4 (aus ARCHITECTURE.md)

1. Besprechungsprotokoll-Vorlage läuft on-device über einem echten Meeting (einem echten Meeting als Realtest).
2. Ohne verfügbares Modell bleibt alles andere nutzbar; die App erklärt den Zustand.
3. Ergebnisse sind versioniert (mehrere Läufe nebeneinander), tragen EngineDescriptor und Revision-Referenz.

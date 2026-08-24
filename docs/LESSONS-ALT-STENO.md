# Übergabe: Sprecher-Erkennung für die Swift/macOS-Fassung

Kontext für die neue Session: Du baust eine macOS-only Swift-Version von stenoAI.
Was hier steht, stammt aus dem Python/Electron-Original — es sind **gemessene
Ergebnisse und Entwurfsentscheidungen, die dort Wochen gekostet haben**, nicht
allgemeine Ratschläge. Alles, was als „gemessen" markiert ist, wurde an echten
Aufnahmen oder am AMI-Korpus belegt; alles andere ist ausdrücklich als offen
oder ungeprüft gekennzeichnet. Übernimm nichts davon als Behauptung in Code
oder Doku, ohne es in deinem Stack nachzuprüfen — die Zahlen gelten für die
Modelle und Versionen, die unten genannt sind.

Code, Kommentare und alles Nutzersichtbare in Englisch.

---

## 1. Diarisierung: was schon gemessen ist

**Sortformer (über FluidAudio, CoreML) hat einen harten 4-Slot-Deckel.**
Steht als Architekturkonstante im Modell, nicht als Konfiguration. Gemessen auf
einem M5 gegen AMI: bis 4 Sprecher DER 3-5, **ab 5 Sprechern liefert es immer
genau 4 Cluster**, 8,5-12,7 Punkte über dem echten Boden. Ein Eingabefeld für
die Sprecherzahl wäre wirkungslos — es gibt keinen Parameter dafür. Von einem
Nutzer per Ohr in einer 6-Personen-Aufnahme bestätigt.

**Lokale Basislinie zum Vergleich:** AMI IS1008a DER 8,60 / IS1008b 9,36,
Schnitt **8,98**, Clusterzahl 4,0 bei Referenz 4, RTFx 50-61.
**Falle:** eine früher zitierte Zahl von 29,24 ist der Schnitt über 16
AMI-*test*-Meetings **inklusive solcher mit mehr als 4 Sprechern**. Die beiden
Zahlen sind nicht vergleichbar. Vergleiche nur auf denselben Meetings.

**Der Offline-Pfad in FluidAudio (VBx/AHC + SpeakerCountConstraints) ist
gemessen und NICHT auslieferbar.** In FluidAudio 0.15.2 (Revision `7f963cdc`)
ist er bereits enthalten, inklusive `minSpeakers`/`maxSpeakers` — es sieht also
so aus, als könnte man den 4-Sprecher-Deckel damit lösen. Messung über 18
AMI-Meetings: **DER 40 gegen Sortformers 20**, und der Constraint-Pfad ist
**nicht deterministisch** (ungeseedetes KMeans, zweimal derselbe Input liefert
verschiedene Ergebnisse). Nicht nochmal ausprobieren, ohne zu messen.

**Der offene Kandidat ist LS-EEND.** Attraktorbasiert statt fester Slots, laut
Paper „up to 8 and flexible number of speakers", MIT-lizenziert
(`Audio-WestlakeU/FS-EEND`), ONNX-Exporte existieren. Papierzahl AMI 20,76 DER
ohne Oracle-VAD — **nicht** mit den 8,98 oben vergleichbar (anderer Subset,
anderer Collar). Ungeprüft in unserem Kontext; die Entscheidung braucht einen
Kopf-an-Kopf-Lauf auf denselben Meetings.

**Laufzeit Sortformer:** rund 33-fache Echtzeit über beide Kanäle, und
**37-45 s Segmentierung, bevor der erste Fortschrittswert kommt**. Wenn deine
UI einen Watchdog hat, ist das das Fenster, das ihn fälschlich auslösen lässt.

---

## 2. Kontamination ist nicht messbar — das ist eine Produktentscheidung

Ein Cluster, der zwei Personen enthält, ist in keiner Zahl sichtbar. Gemessen an
einem echten Dreier-Call: der durch kurzes Reinreden verunreinigte Cluster lag
bei **Cosinus-Distanz 0,8270** zum Verursacher — eine völlig gewöhnliche
Distanz zwischen zwei fremden Stimmen, weit weg von jedem Schwellwert.

Folgen für den Entwurf:

- Es gibt **keinen** Schwellwert, der das findet. Nur ein Mensch, der beide
  Stimmen hört, stellt es fest. Plane eine explizite Markierung ein
  („mehr als eine Person"), die ein Mensch setzt, und leite sie **nie** ab.
- Ein so markierter Cluster muss aus **allem** raus: Vorschläge, Kandidaten,
  Bestätigung, und vor allem als **Quelle negativer Evidenz**. Sonst erbt der
  nächste bestätigte Sprecher eine gemischte Einbettung als Hard Negative.
- Damit ein Mensch es überhaupt hören kann, braucht die Review-Oberfläche
  **mehrere Hörproben pro Cluster, chronologisch verteilt** — nicht eine.
  Ein Ausschnitt ist ein Würfelwurf; zwei verschiedene Stimmen in einer Liste
  sind der einzige Weg, wie die Kontamination sichtbar wird.

---

## 3. Die teuerste Entwurfsentscheidung: Cluster-IDs sind nur innerhalb eines Laufs gültig

Der Diarizer nummeriert bei jedem Lauf von `SPEAKER_0` an, ohne Erinnerung
daran, wer die ID vorher hatte. Jede erneute Diarisierung derselben Aufnahme
(Neu-Transkription, Backfill, Reprocess) vergibt dieselben IDs an andere
Stimmen.

**Wenn du irgendwo „Person X = Cluster N von Meeting M" speicherst, musst du
den LAUF mitspeichern.** Ohne das passiert Folgendes, still und ohne Fehler:
nach einer Neu-Diarisierung zeigt der neue `SPEAKER_0` „Bestätigt als X" von
einer Bestätigung, die gegen eine ganz andere Stimme gemacht wurde. Es sieht
für den Nutzer aus wie seine eigene Eingabe.

Bewährter Zuschnitt aus dem Original:

- Der Sidecar/Datensatz einer Diarisierung trägt eine **Lauf-ID** (uuid),
  vergeben genau an der einen Stelle, die eine frische Diarisierung schreibt.
  Ein Rewrite desselben Dokuments ist **kein** neuer Lauf.
- Jede gespeicherte Stimm-Evidenz trägt die Lauf-ID, gegen die sie bestätigt
  wurde.
- **Ein einziges gemeinsames Prädikat** entscheidet „ist diese Evidenz noch
  aktuell". Lese- und Schreibpfad rufen dasselbe auf. Zwei Kopien der Regel
  driften garantiert auseinander.
- Fehlende IDs auf beiden Seiten heißen „Altbestand, alles gültig". Fehlt sie
  nur auf einer Seite, ist die Evidenz veraltet.
- **Nichts löschen.** Ein veralteter Prototyp ist immer noch echte Stimm-Evidenz
  einer echten Person und soll weiter Kandidaten bewerten — er verliert nur das
  Recht, einen Cluster zu beanspruchen. Der akzeptierte Preis: eine *falsche*
  alte Bestätigung lässt sich dann nicht mehr durch erneutes Bestätigen
  korrigieren. Das ist die bessere Richtung: Evidenz still zu zerstören ist der
  schlimmere Fehler.

**Was dabei fast immer übersehen wird:** es sind mehr Leser als man denkt. Im
Original waren es sieben, die Spec listete vier. Die zwei gefährlichsten waren
nicht die offensichtlichen: ein Backfill, der einen **Namen ins Transkript
schreibt**, und ein Reparaturbefehl, der zwei Läufe für Duplikate hielt und den
*neueren* Eintrag löschte. Greppe alle Stellen, die Evidenz per
(Meeting, Cluster-ID) auflösen.

**Gegenstück, ebenso wichtig:** Anwesenheit ist **meeting-**, nicht
laufbezogen. „War in diesem Meeting" bleibt wahr, egal wie oft neu diarisiert
wird. Wenn du die Teilnehmerliste laufbezogen filterst, leerst du sie bei jedem
Reprocess. Schreib den Grund in den Code, sonst „repariert" das jemand.

---

## 4. Die Fehlerklasse, die viermal wiederkam

**Immer dieselbe Form:** eine Regel lautet „nie eine fremde Stimme unter einem
Namen", und der Rückfallweg bekommt die Prüfung nicht, die der Hauptweg hat.

Konkrete Ausprägungen, alle real aufgetreten:

- Ein „überspringe jede `[You]`-Zeile"-Filter — auf dem Mic-Kanal sind das
  genau die eigenen Zeilen. Gemessen an einer echten Aufnahme: von elf
  Owner-Zeilen lag **keine einzige** in einem reinen Mic-Segment. Invertiert,
  nicht verrauscht.
- Zitattext per **Zeitstempel-Nähe** dem Cluster zuordnen. Das trägt nicht: bei
  nachträglich erzeugten Diarisierungen stammen die Segmentzeiten aus einem
  anderen Lauf als die Zeitmarken im gespeicherten Transkript. Ergebnis:
  fremde Sätze unter der eigenen Stimme. **Konsequenz: Zitattext kommt
  ausschließlich aus einem beim Schreiben aufgezeichneten Zeilen-Manifest
  (welche Transkriptzeile gehört zu welchem Cluster). Ohne Manifest kein Text —
  Zeitstempel und Abspielknöpfe bleiben.**
- Ein Turn fasst mehrere Segmente zusammen und trägt nur EINEN Zeitstempel. Wer
  „das längste Segment" wählt und darin einen Zeilenanfang sucht, findet bei
  jedem Nicht-ersten Segment garantiert keinen.
- Zwei Turns in derselben Sekunde rendern denselben `[MM:SS]`-Wert. Jede
  Begrenzung, die darauf beruht, läuft leer — und der Rettungszweig schnitt
  dann ein blindes Fenster über die nächste Person.

**Regel daraus:** wo eine Zuordnung nicht sicher ist, wird **nichts** gezeigt
und **nichts** abgespielt. Kein Rettungszweig, der rät.

---

## 5. Weitere Entwurfspunkte, die im Original Geld gekostet haben

- **Der Sidecar hält die einzige Kopie der Stimm-Einbettungen.** Die Aufnahme
  wird standardmäßig gelöscht, also ist ein zerrissener Schreibvorgang
  endgültig. Atomar schreiben (Temp + Rename, eindeutiger Temp-Name), und so
  spät wie möglich vor dem Schreiben neu einlesen. Zwei überlappende Schreiber,
  die beide von derselben Kopie ausgingen, haben real die Markierung des
  jeweils anderen verworfen.
- **Bestätigte Personen überleben das Löschen des Meetings, unbenannte Cluster
  nicht** — und die sind danach endgültig unbenennbar, weil Benennen Hören
  voraussetzt und Hören die Audiodatei. Der letzte sinnvolle Zeitpunkt zum
  Benennen ist **vor** dem Löschen. Ein Hinweis genau dort ist billig und
  wertvoll.
- **Ein Diarizer teilt eine Stimme über mehrere Cluster.** Führe sie vor der
  Anzeige zusammen (im Original bei Distanz ≤ 0,10), und lass **jede**
  Nutzerentscheidung den ganzen Fragment-Satz erfassen — sonst überlebt eine
  Markierung auf einem Fragment, das niemand anklicken kann.
- **Hard Negatives sind dauerhafte Unterdrückung.** Ein falsches Negativ
  verhindert eine echte Erkennung in Meetings, die mit diesem nichts zu tun
  haben, und nichts im späteren Fehlverhalten zeigt zurück auf die Ursache.
  Behandle sie strenger als Positive.
- **Umbenennen im Transkript braucht ein Rückgängig.** Merkt sich das
  Ursprungslabel je Manifest-Eintrag **vor** dem Umbenennen (first-write-wins),
  sonst bleibt der falsche Name stehen, wenn der Cluster später als gemischt
  markiert wird.
- **Erstkontakt-Loch:** bei leerer Stimm-Datenbank liefert die Vorschlagslogik
  für jeden Cluster „keine Kandidaten". Wenn deine Oberfläche daraus „nichts
  anzuzeigen" ableitet, gibt es **keinen Weg zum ersten Profil**. Cluster immer
  anzeigen, mit Freitextfeld.
- **Der Review-Fortschritt muss persistent sein.** „Diesen lasse ich generisch"
  ist die einzige Review-Entscheidung, die sonst keine Spur hinterlässt — hält
  man sie nur im View-State, ist sie beim nächsten Öffnen weg und der Nutzer
  sortiert dieselben Zeilen nochmal durch.

**Was Swift/macOS-only dir schenkt:** FluidAudio läuft in-process statt über
einen Subprozess mit JSON-Vertrag. Damit fällt die ganze Fehlerklasse
„Sidecar wurde auf Pfad X gar nicht geschrieben" weg — im Original gab es
**drei** Rückgabepfade, die die fertig berechneten Einbettungen verworfen
haben, und das Symptom war „wer automatische Notizen abschaltet, bekommt nie
eine Sprecher-Ansicht". Prüfe trotzdem einmal explizit: jeder Weg, der eine
Aufnahme abschließt, muss die Einbettungen persistieren. Die Rechenzeit ist zu
dem Zeitpunkt längst bezahlt.

---

## 6. Testfallen, die dort echte Bugs durchgelassen haben

- **Fixtures teilen die Blindstellen des Codes.** Jede Sprecher-Fixture benutzte
  `[Speaker 2]`; der schwerste Bug brauchte `[You]` auf dem Mic-Kanal. 857
  grüne Tests, und der Fehler war in der echten App in 30 Sekunden sichtbar.
  **Teste einmal mit echten Aufnahmen, bevor du dich auf die Suite verlässt.**
- **Ein Test, der „nichts ist passiert" behauptet, kann aus dem falschen Grund
  grün werden.** Zwei solche Tests wurden erst grün, weil ein neuer Guard den
  Eingabewert schon vorher verwarf — die geprüfte Eigenschaft kam nie zum
  Zuge. Bei jedem Negativ-Test nachsehen, *warum* er grün ist.
- **Ein Test darf nicht auf einen Zustand prüfen, dessen Lebensdauer von einer
  Fixture abhängt.** Real: ein Wiedergabe-Test prüfte auf „spielt gerade",
  während der Test-Clip eine Dauer von 0 s hatte und das Ende ~300 ms nach dem
  Klick feuerte. Grün auf dem Entwicklerrechner, rot auf CI, tagelang als
  „flaky" abgetan.
- **Mutationsprobe.** Nach jedem Fix den Guard entfernen und sehen, ob ein Test
  fällt — und ob er aus dem **richtigen** Grund fällt. Ein leeres Testergebnis
  (Syntaxfehler durch die Mutation) ist kein Grün.
- **Ein Review über den ganzen Diff findet, was ein Review pro Aufgabe nicht
  kann.** Zuletzt: drei Felder, jedes für sich korrekt gesetzt, ergaben eine
  Zeile, die gleichzeitig „du hast entschieden, diesen nicht zu benennen" sagte
  und drei Knöpfe zum Benennen anbot.

---

## 7. Was offen ist

- **LS-EEND gegen Sortformer messen**, auf denselben Meetings. Das entscheidet,
  ob der 4-Sprecher-Deckel fällt. Ohne diese Messung keine Entscheidung.
- **Custom Keywords:** zwei Ansätze. Nachträgliche Textersetzung im Transkript
  (im Original gebaut, hängt an einem Release-Blocker: das Ersetzen überschreibt
  das kanonische Transkript, eine falsche Regel wie `United States: US` macht
  aus „let us know" dauerhaft „let United States know") gegen Biasing im
  Erkenner (kann per Konstruktion nichts zerstören, was schon richtig war).
  Biasing ist der bessere Entwurf; ob dein Parakeet-Weg es anbietet, ist zu
  prüfen — `parakeet-mlx` hatte, gemessen im installierten Paket, **null**
  Treffer für hotword/boost/biasing. NeMo kann es seit 2.5.0, ist aber ein
  anderer Stack.
- **Segment-Einbettungen statt nur Cluster-Zentroide** wären die Grundlage, um
  Kontamination überhaupt automatisch sichtbar zu machen. Aufwandsschätzung aus
  dem Original, an einer echten Bibliothek geerdet: Sidecar wächst von ~300 KB
  auf ~6 MB, mit weniger Nachkommastellen und einer 1-Sekunden-Untergrenze auf
  ~2 MB.

## Nachtrag 2026-08-06: Audioformat der Altaufnahmen (gemessen)

Die alte App nahm Systemaudio als WebM/Opus auf. macOS kann den WebM-Container in keiner Variante oeffnen (CoreAudio `AudioFileOpenURL failed`, AVFoundation `Cannot Open`), den Opus-Codec aber sehr wohl.
Steno packt solche Dateien beim Import verlustfrei in einen CAF-Container um (`WebMOpusReader` + `OpusCAFWriter`).

An einem lokalen Realimport ist belegt, dass Opus-in-CAF fuer alle Verarbeitungswege taugt:

- Wiedergabe: `AVAudioEngine` + `AVAudioPlayerNode.scheduleSegment` positioniert framegenau.
- Transkription: SpeechAnalyzer liest die Datei direkt und liefert Wortzeitstempel.
- Diarisierung: FluidSortformer ueber `AVAudioFile` liefert Segmente, Cluster und Embeddings.

**Falle, teuer erkauft:** `AVAudioPlayer` kann in Opus-in-CAF nicht springen.
Er nimmt ein gesetztes `currentTime` an und meldet es korrekt zurueck, spielt aber weiter vom Anfang - der Fehler sieht im Code wie ein korrekter Sprung aus.
Nachgewiesen ueber den Pegelmesser an einer nachweislich stillen Passage, die als Ton gemessen wurde.
Fuer Wiedergabe an Zeitpositionen deshalb nie `AVAudioPlayer` verwenden.

**Kein Transkodieren nach AAC/PCM:** Umpacken ist verlustfrei und groessengleich; eine AAC-Fassung waere eine zweite verlustbehaftete Generation ueber Material, das ASR und Diarisierung speisen soll, PCM waere rund zwanzigmal so gross.
Wenn eine Audiodatei einmal an fremde Werkzeuge gehen soll, gehoert das Transkodieren in einen Export, nicht in die Bibliothek.

## Nachtrag 2026-08-06: Mikrofon-Abfrage beim reinen Abspielen

Symptom: Die App fragte beim Abspielen einer Hoerprobe nach Mikrofon-Zugriff, obwohl nur ausgegeben wird.

Zwei Ursachen, beide nachgewiesen:

1. **AVAudioEngine fasst auf macOS die Eingangsseite an**, auch wenn nur ein Player-Node auf den Mixer spielt. Wiedergabe an Zeitpositionen laeuft deshalb ueber AVAudioFile (Ausschnitt lesen) plus AVAudioPlayer auf einer Temp-Kopie - nie ueber die Engine.
2. **Das getestete Standard-Ausgabegeraet ist ein Audio-Interface mit Eingaengen.** Wird ein Geraet mit Eingangsstroemen geoeffnet, verlangt macOS die Mikrofon-Berechtigung - auch fuer reine Wiedergabe.

Verstaerkend: Die Debug-App ist **ad-hoc signiert** (`Signature=adhoc`, keine Signaturidentitaet auf der Maschine). TCC erkennt die App am Code-Hash, der sich bei **jedem** Build aendert; erteilte Berechtigungen gelten danach nicht mehr und werden neu abgefragt. Bei mehreren Builds pro Stunde wirkt das wie ein Fehler in der App.

Abhilfe, falls es stoert: eine stabile (auch selbst ausgestellte) Signaturidentitaet fuer den Debug-Build; dann fragt macOS einmal und nie wieder.

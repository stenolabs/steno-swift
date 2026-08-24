# Arbeitspaket: Datenklassen und was die Maschine verlassen darf

Produktvorschlag 2026-08-06: eine Stelle in den Einstellungen, an der steht, was
in die Cloud darf und was on-device bleiben muss.
Architekt-Zweitmeinung (Fable) eingeholt, weil es ein sicherheitsrelevantes
Design ist.
Ihre Empfehlung und die Begruendungen sind hier eingearbeitet.

## Der Anlass

Steno ist lokal.
Inhalt kann die Maschine nur in zwei getrennten, jeweils ausdruecklich bestaetigten Handlungen verlassen: fuer einen Protokolllauf mit einem externen Sprachmodell oder als einzelnes Meeting-Paket ueber die lokale Systemfreigabe.
Audio ist vom Modellpfad ausgeschlossen und wird nur dann in genau dieses Paket aufgenommen, wenn der Benutzer es fuer diesen einzelnen Transfer lokal einschaltet.
Audio wird niemals automatisch, fuer Cloud-Sync oder fuer ein Modell uebertragen.
Das `.stenomeeting`-Paket ist eine unverschluesselte Datei, und die Systemfreigabe fordert zwar zur Auswahl von AirDrop auf, garantiert technisch aber keinen ausschliesslich auf AirDrop begrenzten Transport.
Im Lauf eines Abends sind fuenf Einzelfallregeln an fuenf Codestellen
entstanden - jede begruendet, zusammen ohne erkennbare Linie und nirgends
nachlesbar.

## Entscheidung: ein Register, kein Schalterbrett

**Ja zu einer Stelle, nein zu Schaltern.** Null globale Toggles.
Zwei getrennte echte Entscheidungen bleiben dort, wo sie in den jeweiligen Handlungsmoment gehoeren: die Modellwahl pro Protokollerstellung und die lokale Auswahl eines einzelnen Meeting-Pakets samt ausdruecklicher Audiofreigabe fuer genau diesen Transfer.
Der Modellpfad und der Paketpfad teilen weder einen globalen Schalter noch eine gemeinsame Allowlist.

Der Grund ist nicht Bequemlichkeit, sondern dass der Entscheidungsraum fast leer
ist.
E-Mail nie, Dokumente Dritter nie, das Transkript extern zu rendern **ist** der
Zweck der externen Wahl, und Notizen sind der Kontextkanal, ohne den externes
Rendern schlechter ist als lokales.
Ein Schalterbrett bestuende aus Schaltern, die entweder nichts entscheiden
duerfen oder deren Aus-Stellung das Feature entwertet - und jeder waere ein
Set-and-forget-Versprechen, das im Moment der Uebertragung niemand mehr prueft.

Was der Nutzer braucht, ist Uebersicht, nicht Konfiguration: ein Register, das die
Regeln zeigt, statt sie zu setzen.

## Die Klassen

**Verlaesst die Maschine nicht ueber Modell- oder automatische Pfade, nicht verhandelbar:**

- Audio-Aufnahmen werden on-device transkribiert und nie an ein Modell oder einen Cloud-Sync gesendet.
  Die einzige Ausnahme ist ein vom Benutzer lokal bestaetigter Einzeltransfer, bei dem Audio fuer genau dieses Meeting ausdruecklich eingeschaltet wurde.
- E-Mail-Adressen an Personen (bereits hart, mit Test).
- Beigebrachte Dokumente Dritter: PDF-Volltext und der per Vision-OCR aus
  eingefuegten Bildern gezogene Text. Dieselbe Klasse, dieselbe Grenze.
- API-Schluessel (Keychain, existiert).
- **Alles Nichtdeklarierte: Default-deny.** Eine Klasse, die im Manifest nicht
  vorkommt, geht nicht raus. Das ist die wichtigste harte Regel, weil sie als
  einzige zukuenftige Klassen abdeckt.

## Lokale Speicherung der Modellendpunkte

Die Endpunktliste und ihr Wiederherstellungsjournal liegen als secret-freie Registrydatei unter `Application Support/Steno/TextModelEndpoints/registry-state.json`.
Die Datei enthaelt nur die sichtbare Konfiguration wie Name, URL, Modell-ID, Schluesselanforderung und Konfigurationsrevision.
API-Schluessel bleiben ausschliesslich in revisionsgebundenen Keychain-Slots und gelangen weder in die Registrydatei noch in UserDefaults, Jobs oder Journale.
Registrydatei und Verzeichnis sind nur fuer den lokalen Benutzer lesbar, und das Verzeichnis ist vom Systembackup ausgeschlossen.
Nach einer Wiederherstellung aus einem Geraetebackup muss die oeffentliche Endpunktkonfiguration deshalb gegebenenfalls erneut eingerichtet werden.
Bestehende UserDefaults-Konfigurationen werden einmalig erst dann entfernt, wenn die atomar geschriebene Registrydatei frisch gelesen und inhaltlich verifiziert wurde.

**Geht mit, wenn und nur wenn fuer diesen Lauf ein externes Modell gewaehlt ist:**

- Transkript samt bestaetigter Sprechernamen.
- Teilnehmerliste, Namen und Firmen.
- Die eigenen Notizen zum Meeting.

**Geht mit, wenn und nur wenn der Benutzer den lokalen Export genau dieses Meeting-Pakets ausloest:**

- Die eigenen Notizen samt Zeitmarkern.
- Das portable Transkript samt bestaetigten sichtbaren Sprechernamen und generischen Sprecherlabels.
- Audio nur dann, wenn es fuer diesen einzelnen Transfer lokal ausdruecklich eingeschaltet wurde.

Teilnehmerliste, Personenbibliothek, E-Mail-Adressen, Embeddings, Review- und Diarisierungslaeufe, Reports und Ordnerzuordnungen gehoeren nicht zur Paket-Allowlist.

Im Modellpfad waeren Firma und Notizen prinzipiell verhandelbar, bleiben aber fest und werden nur ausgewiesen.
Kommt je ein realer Fall auf, etwa Notizen mit privaten Randbemerkungen, gehoert die Abwahl als Haekchen neben den Uebertragungshinweis in den Moment des Renderns und nie in die Einstellungen.
Dasselbe gilt, falls PDF-Inhalte je extern gewollt werden: Das waere eine neue
Entscheidung mit Zustimmung pro Handlung und wuerde die Grenze aus
PLAN-CONTEXT.md Schritt 4 ausdruecklich aufheben.

## Wo was hingehoert

**Einstellungen = Register.** Das Register bleibt in den Sprachmodell-Einstellungen ueber der Endpunktliste, weil dort der externe Modellpfad konfiguriert wird und die getrennte Paketregel sichtbar danebenstehen muss.
Eine eigene Datenschutzseite wuerde uebersehen.
Zwei Spalten, keine Interaktion.

**Moment der Handlung = Entscheidung.** Der Hinweis vor der Protokollerstellung nennt die Klassen, die dieser Modelllauf tatsaechlich enthaelt, und wird nicht von Hand gepflegt, sondern aus derselben Quelle erzeugt wie die Prompt-Zusammenstellung.
Der Meeting-Export ist eine davon getrennte Handlung mit eigener Paket-Allowlist und eigener ausdruecklicher Audioauswahl fuer genau diesen Transfer.

Eine Ehrlichkeitsgrenze bleibt: Der Hinweis nennt Klassen zum Anzeigezeitpunkt.
Wer zwischen Hinweis und Klick noch Notizen tippt, hat beim Klick Notizen im
Lauf. Das ist vertretbar, weil der Hinweis Klassen ausweist, nicht Inhalte.

## Wie Anzeige und Verhalten zusammengekettet bleiben

Das ist der Kern. Eine Datenschutzanzeige, die luegt, ist schlimmer als keine.

**Struktur: Provider bleiben bibliotheksblind.** `OpenAICompatibleProvider` hat
keine Library-Referenz und sieht nur, was ihm uebergeben wird. Diese Eigenschaft
ist der eigentliche Schutzwall und wird als Invariante festgeschrieben: Ein
externer Provider bekommt nie eine `Library`, ein `LibraryLayout` oder einen
Store. Damit gibt es fuer den externen Modellpfad genau einen Engpass, an dem ausgehende Daten entstehen:
`executeTemplateRender` im `PipelineCoordinator`.
Neue Kontextdaten erreichen den Prompt ausschliesslich als neues Feld von
`RenderContext`.

**Herleitung: die Anzeige ist eine Funktion der Nutzlast, keine zweite
Buchfuehrung.** Ein `PromptDataClass`-Enum (CaseIterable) ist das Manifest: jede
Klasse mit Politik und Benutzer-Namen. Eine Funktion
`OutboundDisclosure.classes(transcript:participants:context:)` liefert die in
diesem Lauf tatsaechlich vorhandenen ausgehenden Klassen. Der Hinweistext wird
daraus formatiert.

**Tests, drei Sorten:**

1. **Sentinel-Test**, der staerkste: eine Fixture-Bibliothek, in der jede Klasse
   einen unverwechselbaren Marker traegt. Ein aufzeichnender Mock-Provider
   empfaengt den kompletten Renderaufruf. Verbotene Sentinels duerfen in nichts
   vorkommen, was der Provider je gesehen hat; erlaubte muessen vorkommen; und
   die von `OutboundDisclosure` gemeldete Liste muss exakt den angetroffenen
   Sentinels entsprechen. Damit ist "die Anzeige luegt" in beide Richtungen
   getestet: Sie darf weder zu wenig noch zu viel behaupten.
2. **Mirror-Tripwire**: ein Test, der die gespeicherten Properties von
   `RenderContext` gegen eine bekannte Liste prueft. Wer ein Feld hinzufuegt,
   bricht den Test, und dessen Meldung sagt, was zu tun ist. Das faengt den
   gefaehrlichsten Fehler: das schweigende Hinzufuegen.
3. **Compiler-Zwang**: `PromptDataClass` ist CaseIterable, Disclosure und
   Politik sind erschoepfende switches. Ein neuer Fall ohne Entscheidung
   kompiliert nicht.

**Was keine Schicht abfaengt** und deshalb als Regel dasteht: Aus Dokumenten
Dritter abgeleiteter Text (PDF-Extrakt, Bild-OCR) darf **nie** in ein Feld
fliessen, dessen Klasse "geht mit" ist - etwa in `userNotes`. Das ist die
naheliegendste Implementierung des Bild-Features und wuerde die PDF-Grenze durch
die Hintertuer schleifen. Der zugehoerige Sentinel-Test entsteht am selben Tag
wie das Bild-Feature.

## Benennung fuer die Oberflaeche

- "Audio recordings" - "Stay on this device unless you explicitly include them in one meeting transfer."
- "Transcript with speaker names" - "Sent with the minutes when you choose an external model; a portable transcript with confirmed visible names and generic labels is also included in a meeting package."
- "Participants: names and companies" - "Sent only with the minutes when you choose an external model, never in a meeting package."
- "Your meeting notes" - "Sent with the minutes when you choose an external model and included when you export one meeting package."
- "Email addresses" - "Never included, they only organize your speaker library."
- "Documents and pasted images" - "Used on this Mac to improve recognition, never sent."

Bewusst vermieden: Codebegriffe wie "RenderContext" oder "Prompt", und
Sammelbegriffe wie "Metadaten", unter denen sich niemand etwas vorstellt.
Jede Zeile benennt ein Ding, das der Benutzer selbst angefasst hat.

## Stand

Erledigt: Der Hinweis vor dem Erzeugen nennt nicht mehr nur das Transkript,
sondern auch Teilnehmerliste und Notizen, sofern vorhanden, und benennt was
bleibt.
Das war der dringendste Einzelbefund - die Anzeige war seit dem Einbau von
Notizen und Firmen schlicht unwahr.

Offen: das Manifest (`PromptDataClass`), `OutboundDisclosure` als gemeinsame
Quelle fuer Anzeige und Zusammenstellung, das Register in den Einstellungen,
und die drei Testsorten.

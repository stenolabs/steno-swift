# Report- und Endpoint-Crash-Recovery-Design

Datum: 2026-08-19

Status: von `/root` am 2026-08-19 zur Umsetzung freigegeben

## Ziel

Ein alter externer Reportjob darf niemals mit heutiger Eingabe oder heutiger Endpointkonfiguration ausgefuehrt werden.

Endpoint- und Secret-Mutationen muessen nach jedem Prozessabbruch auf beiden Plattformen deterministisch in einen konsistenten Zustand zurueckkehren.

## Legacy-Reportjobs

Ein `templateRender`-Job mit externer `textModelEndpointID` ist nur ausfuehrbar, wenn er einen nicht leeren SHA-256-Eingabefingerabdruck und einen vollstaendigen Endpoint-Snapshot mit derselben UUID und nicht leerer Konfigurationsrevision besitzt.

Die Pipeline prueft diesen Vertrag vor Template-Inputassembly, Resolver, Providerkonstruktion und URLRequest.

Ein unvollstaendiger externer Job endet mit dem typisierten Grund `templateRenderPinsRequired` und einer Aufforderung, den aktuellen Preflight zu pruefen und eine neue Generation ausdruecklich zu starten.

Die macOS- und iOS-Praesentationen behandeln diesen Grund wie `templateRenderInputChanged` und erneuern den sichtbaren Preflight unmittelbar.

Ein alter Apple-Job ohne externe ID behaelt den bisherigen Kompatibilitaetsweg, auch wenn Fingerprint und Endpoint-Snapshot fehlen.

## Kanonischer RegistryState

`StenoIntelligence` stellt einen gemeinsamen codierbaren `TextModelEndpointRegistryState` bereit.

Der State enthaelt ausschliesslich die oeffentlichen Endpointkonfigurationen und optional ein secret-freies Mutationsjournal.

Registry und Journal werden als ein einzelnes codiertes UserDefaults-Objekt geschrieben, damit keine Cross-Key-Reihenfolge rekonstruiert werden muss.

Der bisherige Endpoint-Defaults-Key bleibt nur als Migrationsquelle erhalten und wird nach erfolgreichem kanonischem Write entfernt.

## Upsert-Zustandsmaschine

Die vorbereitete Phase persistiert alte Endpoints plus Journal mit altem und neuem oeffentlichen Endpoint, bevor ein neuer Secret-Slot geschrieben wird.

Ein Cold Start in dieser Phase entfernt den neuen Slot idempotent, behaelt die alte Registry und loescht danach das Journal.

Nach erfolgreichem Secret-Write persistiert die committed Phase neue Endpoints plus dasselbe Journal in einem Write.

Ein Cold Start in dieser Phase behaelt die neue Registry, entfernt den alten Slot idempotent und loescht danach das Journal.

Der In-Memory-State wechselt erst nach dem erfolgreichen committed Write.

## Delete-Zustandsmaschine

Die vorbereitete Phase persistiert Registry plus Journal vor dem Secret-Delete.

Recovery einer vorbereiteten Delete-Mutation entfernt den Secret-Slot idempotent, persistiert danach Registry ohne Endpoint als committed Phase und loescht abschliessend das Journal.

Damit wird ein bereits geloeschtes Secret niemals wieder als sichtbarer erforderlicher Endpoint geladen.

Eine stale macOS-Auswahl wird beim Cold Start entfernt, wenn ihr Endpoint nicht mehr in der kanonischen Registry steht.

## Fehlervertrag

Registry- sowie Keychain-Lese-, Schreib- und Loeschfehler bleiben werfend und sichtbar.

Kann Cold Recovery nicht abgeschlossen werden, zeigt `TextModelSettings` keine Endpoints, stellt eine sichtbare Recoveryfehlermeldung bereit und der Resolver wirft vor einer Providerkonstruktion.

Das Journal enthaelt weder Secretwerte noch Transkript-, Notiz- oder sonstige Meetingdaten.

## Tests

Pipeline-Tests decken queued und recovered-running Schema-1-External-Jobs mit fehlendem Fingerprint, fehlendem Snapshot, fehlender Snapshotrevision, beiden fehlenden Pins und widerspruechlicher Snapshotidentitaet ab.

Sie aendern Endpointkonfiguration und Notizen und pruefen Resolver-, Provider- und URLRequest-Zaehler jeweils auf null.

Ein separater Test belegt den unveraenderten Apple-Legacyvertrag.

macOS- und iOS-Settings-Tests simulieren jeden Journal-, Secret-, Registry- und Cleanup-Checkpoint, starten eine neue `TextModelSettings`-Instanz und pruefen Recovery erneut auf Idempotenz.

Mutationstests pruefen zusaetzlich UserDefaults-Writefehler, Keychainfehler, Legacy-Migration und die exakte Slotnutzung alter und neuer Jobs.

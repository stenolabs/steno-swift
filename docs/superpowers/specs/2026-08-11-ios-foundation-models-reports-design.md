# iOS-Protokolle mit Apple und OpenAI-kompatiblen Modellen

Stand: 2026-08-11.
Verfasser: Codex, nach Produktentscheidung fuer Apple als Standard und optionale OpenAI-kompatible Endpunkte.

## Ziel

Die iPhone- und iPad-App kann aus einem vorhandenen Transkript ein strukturiertes Besprechungsprotokoll erzeugen, anzeigen, erneut erzeugen, versionieren, kopieren und teilen.
Apple Foundation Models bleibt der Standard und verarbeitet vollstaendig auf dem Geraet.
Optional kann die Person pro Protokolljob einen selbst konfigurierten OpenAI-kompatiblen Endpunkt wie LM Studio, Ollama oder eine Cloud-API auswaehlen.
Ein fehlendes oder nicht verfuegbares Apple-Modell beeintraechtigt weder Aufnahme noch Transkription, Diarisierung oder Sprecherpruefung.

## Die sechs Produktpunkte

1. Steno zeigt Apple Foundation Models als Standard sowie bewusst konfigurierte OpenAI-kompatible Endpunkte an.
2. Ein ausdruecklicher Befehl `Generate minutes` erzeugt ein Protokoll fuer die aktuelle Transkriptrevision mit dem sichtbar ausgewaehlten Modell.
3. Die Ansicht zeigt laufende Verarbeitung, Fehler und alle gespeicherten Protokollversionen.
4. `Regenerate` erzeugt eine neue Version, ohne die bisherige Version zu ersetzen oder auszublenden.
5. Das ausgewaehlte Protokoll kann als Text kopiert und ueber das iOS-Share-Sheet geteilt werden.
6. Der Apple-Pfad wird auf einem geeigneten echten iPhone oder iPad im Flugmodus und der OpenAI-kompatible Pfad gegen einen realen Endpunkt abgenommen.

Steno integriert dabei kein bestimmtes Netzwerk oder Serverprodukt.
Ob eine URL direkt auf LM Studio im LAN, ueber ein VPN wie Tailscale oder auf eine Cloud-API zeigt, ist fuer den OpenAI-kompatiblen Vertrag unerheblich.

## Bestehender Stand

Der gemeinsame Kern besitzt bereits den vollstaendigen Protokollpfad.
`FoundationModelsProvider` verwendet Apples `SystemLanguageModel`, bildet dessen Verfuegbarkeitszustand ab und unterstuetzt strukturierte Ausgabe sowie die Aufteilung langer Transkripte.
`OpenAICompatibleProvider` verwendet `GET /models` fuer einen ausdruecklichen Verbindungstest und `POST /chat/completions` fuer die Generierung.
`TextModelEndpoint` beschreibt Anzeigename, Basis-URL, Modell-ID und Schluesselbedarf, enthaelt aber kein Schluesselmaterial.
`TemplateRenderRequest` pinnt die aktuelle Transkriptrevision und legt einen Hintergrundjob der Art `templateRender` an.
Es pinnt bereits auch die optionale Endpunkt-ID, damit ein Job niemals still auf ein anderes Modell faellt.
`PipelineCoordinator` verarbeitet diesen Job und `TemplateResultStore` bewahrt die Ergebnisse als unveraenderliche Versionen auf.
Die Standardvorlage `meeting-minutes` erzeugt die bereits auf dem Mac verwendete Protokollstruktur.

Die iOS-Laufzeit startet den gemeinsamen Pipeline-Kern bereits mit `FoundationModelsProvider` als Standardanbieter, besitzt aber noch keinen Resolver fuer konfigurierte Endpunkte.
Der iOS-Oberflaeche fehlen ausserdem die AppModel-Zugaenge fuer Protokolljobs sowie Einstellungen und Darstellungen fuer Modellwahl, Verfuegbarkeit, Fortschritt, Ergebnisse, Versionen, Kopieren und Teilen.
Die macOS-Ansicht `ReportsSection` dient als fachliche Referenz, wird aber nicht als plattformspezifische View kopiert.

## Architektur

Der iOS-Pfad verwendet unveraendert die gemeinsamen Typen `FoundationModelsProvider`, `OpenAICompatibleProvider`, `TextModelEndpoint`, `TemplateRenderRequest`, `JobStore`, `PipelineCoordinator` und `TemplateResultStore`.
Es entsteht kein zweiter Protokollgenerator und kein iOS-eigenes Ergebnisformat.

Eine iOS-eigene `TextModelSettings`-Schicht uebernimmt das vorhandene Mac-Muster:

- Die Endpunktliste liegt ohne Geheimnisse als Codable-Daten in `UserDefaults`.
- API-Schluessel liegen ausschliesslich im Keychain, mit der Endpunkt-UUID als Account.
- Der Pipeline-Resolver liefert bei fehlender Endpunkt-ID `FoundationModelsProvider` und sonst genau den gepinnten `OpenAICompatibleProvider`.
- Eine geloeschte oder unbekannte Endpunkt-ID fuehrt zum sichtbaren Jobfehler und niemals zum stillen Apple-Fallback.

Steno kennt keine Tailnet-, LAN- oder Cloud-Sonderlogik.
Der konfigurierte Endpunkt ist eine URL mit einem OpenAI-kompatiblen Vertrag.
Die Infrastruktur hinter dieser URL bleibt ausserhalb von Steno.

`AppModel` erhaelt einen kleinen Protokollzugang fuer:

- den aktuellen Verfuegbarkeitszustand von Apple Foundation Models,
- die lokal konfigurierten OpenAI-kompatiblen Endpunkte und die sichtbare Auswahl,
- das Laden aller gespeicherten Protokollversionen eines Meetings,
- das ausdrueckliche Einreihen eines `meeting-minutes`-Jobs,
- das Laden und Beobachten des zugehoerigen Jobs,
- das Abbrechen eines noch abbrechbaren Jobs.

Ein reiner Presentation-Typ bildet die Apple-Framework-Zustaende und die konfigurierten externen Optionen auf Titel, Erklaerung und Bedienbarkeit ab.
Die UI darf aus einem unbekannten Zustand niemals selbst ableiten, dass das Modell wahrscheinlich funktioniert.

OpenAI-kompatible Endpunkte werden nicht automatisch kontaktiert.
Ihre Erreichbarkeit wird nur durch `Test connection` oder durch eine ausdruecklich gestartete Protokollerstellung geprueft.

Der Erzeugen-Befehl liest die Nutzernotizen vor dem Einreihen fail-closed.
Eine vorhandene, aber nicht lesbare Notizdatei fuehrt zu einer sichtbaren Fehlermeldung und keinem Job.
Die Audioaufnahme, das Transkript und bereits erzeugte Protokolle bleiben davon unberuehrt.

## Datenfluss

Der Ablauf ist:

1. Die Person tippt `Generate minutes` oder `Regenerate`.
2. Steno prueft die Voraussetzungen des sichtbar ausgewaehlten Modells, die Transkriptrevision und lesbare Nutzernotizen.
3. Bei einem externen Modell zeigt Steno vor dem Start Zielhost und tatsaechliche Datenklassen an.
4. `TemplateRenderRequest` pinnt die aktuelle Revision und die optionale Endpunkt-ID und legt genau einen Job an.
5. Der vorhandene `PipelineCoordinator` loest exakt den gepinnten Provider auf und erzeugt das Protokoll.
6. Das Ergebnis wird als neue, unveraenderliche Version im `TemplateResultStore` gespeichert.
7. Die iOS-Ansicht beobachtet den Job und laedt nach dessen Abschluss die Versionen neu.

Mehrfaches schnelles Tippen darf keine doppelten Jobs fuer dieselbe Aktion erzeugen.
Die UI setzt deshalb vor dem ersten `await` ein synchrones In-Flight-Gate und gleicht danach den persistenten Jobzustand ab.
Ein bereits laufender passender Protokolljob wird weiter beobachtet, statt ein zweites Mal eingereiht zu werden.

Die Generierung und jeder externe Netzwerkzugriff starten ausschliesslich nach einer ausdruecklichen Aktion.
Steno erzeugt kein Protokoll automatisch nach einer Aufnahme oder Transkription.

## Oberflaeche

`MeetingDetailView` erhaelt vor dem Transkript einen Abschnitt `Minutes`.
Das Protokoll ist ein primaeres Meeting-Ergebnis und gehoert deshalb nicht in den optionalen Inspector.
Auf dem iPhone erscheint der Abschnitt vertikal im bestehenden Detailfluss.
Auf dem iPad nutzt er die verfuegbare Inhaltsbreite, waehrend Notizen, Teilnehmer und Sprecherpruefung im Inspector bleiben.

Der Abschnitt zeigt:

- `Apple Intelligence (on device)` als Standard und die konfigurierten externen Endpunkte in einer Modellauswahl,
- den Apple-Foundation-Models-Zustand, wenn Apple ausgewaehlt ist,
- einen klaren Uebertragungshinweis, wenn ein externer Endpunkt ausgewaehlt ist,
- `Generate minutes`, wenn noch kein Ergebnis vorhanden ist,
- `Regenerate`, wenn mindestens eine Version vorhanden ist,
- Fortschritt beziehungsweise einen klaren laufenden Zustand,
- `Cancel`, solange der persistente Job abbrechbar ist,
- eine sichtbare Fehlermeldung mit erneut versuchbarer Aktion,
- Erstellungszeitpunkt und verwendete Engine der ausgewaehlten Version,
- eine Versionsauswahl bei mehreren Ergebnissen,
- den Markdown-Inhalt,
- `Copy` und `Share`.

Eine laufende Neuerzeugung laesst die bisher ausgewaehlte Version sichtbar.
Ein Fehler entfernt oder ersetzt keine vorhandene Version.
Die Versionsauswahl springt nach erfolgreicher Neuerzeugung auf das neue Ergebnis, erlaubt danach aber weiterhin den Wechsel zu frueheren Versionen.

`Copy` schreibt den Markdown-Text in `UIPasteboard`.
`Share` verwendet SwiftUIs `ShareLink` mit dem Markdown-Text und benoetigt keine temporaere Datei.
Beide Aktionen beziehen sich immer auf die sichtbar ausgewaehlte Version.

Die ausgewaehlte Ergebnisversion zeigt immer den tatsaechlich verwendeten Provider und dessen Modell-ID.
Die aktuelle Auswahl aendert die Herkunft aelterer Versionen nicht.
Apple ist nach einem kalten App-Start erneut ausgewaehlt.
Eine externe Auswahl bleibt innerhalb der laufenden App-Sitzung sichtbar, wird aber nicht unbemerkt zum dauerhaften Standard.

Vor der Generierung weist Steno darauf hin, wenn Sprechercluster noch nicht bestaetigt sind.
Dieser Hinweis blockiert die Generierung nicht, er darf unbestaetigte Vermutungen aber niemals als Personennamen darstellen.

## Endpunkteinstellungen

Die iOS-Einstellungen erhalten den Bereich `Language models` mit einer Liste konfigurierter OpenAI-kompatibler Endpunkte.
Ein Endpunkt besitzt Anzeigename, Basis-URL, Modell-ID und einen optionalen API-Schluessel.
Anlegen, Bearbeiten und Loeschen sind lokale Einstellungen auf diesem Geraet.

`Test connection` ist die einzige Probe-Aktion ausserhalb einer Protokollerstellung.
Sie ruft den vorhandenen `/models`-Pfad auf, zeigt Erreichbarkeit und Modellstatus und speichert keine Antwortinhalte.
Steno testet Endpunkte weder beim App-Start noch beim Oeffnen eines Meetings.

Allgemeines HTTPS ist erlaubt.
Unverschluesseltes HTTP ist nur fuer Loopback, `.local`, unqualifizierte Hostnamen sowie private, link-lokale und Tailnet-IP-Bereiche zulaessig.
Die iOS-App verwendet dafuer eine enge lokale Netzfreigabe mit erklaerender `NSLocalNetworkUsageDescription`, aber niemals `NSAllowsArbitraryLoads`.
Ein HTTP-Endpunkt ausserhalb dieser lokalen Bereiche wird bereits beim Speichern abgelehnt.

## Verfuegbarkeitszustaende

Die Darstellung unterscheidet mindestens:

- verfuegbar,
- Apple Intelligence auf diesem Geraet nicht unterstuetzt,
- Apple Intelligence deaktiviert,
- Systemmodell noch nicht bereit,
- unbekannter oder kuenftig hinzukommender Framework-Zustand.

Nur `verfuegbar` aktiviert `Generate minutes` und `Regenerate`.
Bei einem noch nicht bereiten Modell fordert Steno keinen eigenen Modelldownload an, weil Installation und Lebenszyklus des Systemmodells Apple gehoeren.
Die Meldung erklaert stattdessen den Zustand und laesst eine erneute Pruefung zu.

Ein konfigurierter OpenAI-kompatibler Endpunkt gilt nicht aufgrund einer Hintergrundannahme als erreichbar.
Die Erzeugen-Aktion ist fuer eine syntaktisch gueltige Konfiguration verfuegbar und meldet Netzwerk-, Authentifizierungs-, Modell- oder Antwortfehler aus dem echten Job.
`Test connection` prueft nur nach einem ausdruecklichen Tipp die Erreichbarkeit und ob die konfigurierte Modell-ID angeboten wird.

Ein Verfuegbarkeitswechsel waehrend einer laufenden Generierung wird als Jobfehler dargestellt.
Die bereits gespeicherten Protokolle bleiben lesbar, kopierbar und teilbar.

## Datenschutz und Wahrheitsschutz

Apple Foundation Models bleibt der Startzustand der App und verarbeitet auf dem Geraet.
Ein externer Endpunkt wird nur kontaktiert, wenn die Person ihn sichtbar auswaehlt und anschliessend `Generate minutes` oder `Regenerate` antippt.
Es gibt keinen automatischen externen Fallback, keinen Hintergrund-Ping und keine automatische Anbieterwahl.

Vor einer externen Generierung nennt Steno den Anzeigenamen und Host des Endpunkts sowie die fuer diesen Lauf vorhandenen Datenklassen:

- Transkript mit bestaetigten Sprechernamen,
- Teilnehmernamen und Firmen, soweit vorhanden,
- eigene Meetingnotizen, soweit vorhanden.

Audioaufnahmen, E-Mail-Adressen, angehaengte Dokumente und Bilder werden nicht an den Textmodellprovider uebergeben.
Der Hinweis wird aus derselben typisierten Nutzlastbeschreibung erzeugt wie der Render-Kontext und nicht als unabhaengiger UI-Text gepflegt.
Sentinel- und Exhaustivitaetstests muessen brechen, wenn eine neue Kontextklasse die Anzeige und die wirkliche Nutzlast auseinanderlaufen laesst.

Steno behauptet nicht, dass ein Endpunkt lokal oder vertrauenswuerdig ist, nur weil seine URL wie LAN, Tailnet oder LM Studio aussieht.
Die Person entscheidet selbst, wer die konfigurierte URL betreibt.
HTTPS ist fuer entfernte und Cloud-Endpunkte erforderlich.
Direktes unverschluesseltes HTTP ist nur fuer ausdruecklich konfigurierte lokale Netze vorgesehen und wird sichtbar als unverschluesselt gekennzeichnet.

API-Schluessel werden nie in `UserDefaults`, Jobdateien, Run-Artefakten, Fehlermeldungen oder Logs geschrieben.
URLs mit eingebetteten Zugangsdaten werden abgelehnt, weil Geheimnisse ausschliesslich in das Keychain-Feld gehoeren.

Das Modell erhaelt das gepinnte Transkript, bestaetigte Sprecher- und Teilnehmerinformationen sowie die lesbaren Nutzernotizen.
Die unveraenderlichen Audiooriginale werden nicht an das Textmodell uebergeben.

Unbestaetigte Sprecher bleiben generische Sprecher.
Cluster mit mehreren Stimmen erhalten keinen Personennamen.
Eine Zusammenfassung darf nicht als Ersatz fuer das Transkript dargestellt werden und besitzt immer ihre eigene Versions- und Engineangabe.

## Fehler- und Wiederanlaufverhalten

Folgende Fehler werden getrennt sichtbar gemacht:

- Apple Foundation Models nicht verfuegbar,
- Endpunkt nicht erreichbar,
- API-Schluessel abgelehnt,
- konfigurierte Modell-ID nicht vorhanden,
- ungueltige oder unvollstaendige Modellantwort,
- gepinnter Endpunkt inzwischen geloescht,
- noch keine verwertbare Transkriptrevision,
- nicht lesbare Nutzernotizen,
- Einreihen des Jobs fehlgeschlagen,
- Generierung fehlgeschlagen,
- Abbruch zu spaet, weil der Job bereits abgeschlossen ist,
- Ergebnis nach vermeintlichem Abschluss nicht lesbar.

Ein UI-Task ist nicht die Besitzgrenze des persistenten Jobs.
Navigation oder View-Abbau darf den Job nicht versehentlich abbrechen.
Beim erneuten Oeffnen des Meetings liest die Ansicht JobStore und ResultStore neu und setzt den sichtbaren Zustand daraus wieder zusammen.

Die vorhandene Jobwiederaufnahme darf nach einem App-Neustart weiterarbeiten.
Dieses Paket verspricht jedoch noch keine ununterbrochene Fertigstellung waehrend langer Hintergrundzeit.
Die Hardwareabnahme fuer Punkt 6 haelt Steno deshalb bis zum Ergebnis im Vordergrund.

## Tests

Reine Presentation-Tests decken jeden Verfuegbarkeitszustand und die Aktivierung der Aktionen ab.
Sie pruefen ausserdem die Zustaende ohne Ergebnis, mit Ergebnis, waehrend Neuerzeugung und nach einem Fehler.

iOS-App-Integrationstests mit temporaerer Bibliothek und injizierbarem Textmodell pruefen:

- genau einen gepinnten Job trotz schneller Mehrfachaktion,
- kein Einreihen bei nicht lesbaren Notizen,
- die bisherige Version bleibt waehrend einer Neuerzeugung sichtbar,
- eine erfolgreiche Neuerzeugung erzeugt eine weitere Version,
- fruehere Versionen bleiben auswaehlbar,
- Fehler entfernen kein Ergebnis,
- Abbruch und anschliessendes Neuladen,
- Copy- und Share-Nutzlast entsprechen der sichtbaren Version,
- Navigation oder View-Cancellation beendet keinen persistenten Job.

Endpunkt- und Datenschutztests pruefen:

- Endpunktkonfiguration round-tript ohne Schluesselmaterial,
- Keychain-Lesen, Aendern und Loeschen bleibt von `UserDefaults` getrennt,
- URLs mit eingebetteten Zugangsdaten werden abgelehnt,
- `Test connection` laeuft nur auf ausdrueckliche Aktion,
- Apple bleibt ohne Endpunkt-ID der Standard,
- eine externe Auswahl wird zusammen mit der Revision im Job gepinnt,
- geloeschte Endpunkte fallen nicht still auf Apple zurueck,
- der Provider und die Modell-ID bleiben an jeder Ergebnisversion sichtbar,
- Disclosure und tatsaechliche Provider-Nutzlast enthalten exakt dieselben erlaubten Datenklassen,
- verbotene Audio-, E-Mail-, Dokument- und Bild-Sentinels erreichen den Provider nicht.

Die vorhandenen StenoKit-Tests bleiben die Quelle fuer strukturierte Ausgabe, lange Transkripte, Teilnehmerkontext, Revisionspinning und unveraenderliche Ergebnisversionen.
Falls fuer diesen Schnitt gemeinsamer Kerncode geaendert wird, laeuft die vollstaendige Kette aus XcodeGen, macOS-Build, iOS-Build und allen StenoKit-Tests.
Ohne Kernaenderung laufen mindestens die fokussierten iOS-App-Tests, die vollstaendige iOS-App-Suite, der iPad-Simulatorbuild und der macOS-Build als Gegenprobe.

## Manuelle Abnahme

Im iPad-Simulator werden Darstellung, Split-View-Verhalten, Fortschritt, Versionen, Fehler, Kopieren und Share-Sheet mit kontrollierten Testdaten geprueft.
Der Simulator gilt nicht als Nachweis fuer das echte `SystemLanguageModel`.

Auf einem Apple-Intelligence-faehigen echten iPhone oder iPad wird geprueft:

1. Apple Intelligence ist aktiviert und das Systemmodell ist bereit.
2. Das Geraet wird in den Flugmodus versetzt.
3. Ein deutsches Meeting mit fertigem Transkript erzeugt ein strukturiertes Protokoll.
4. `Regenerate` erzeugt eine zweite Version und die erste bleibt auswaehlbar.
5. Copy und Share geben exakt die ausgewaehlte Version weiter.
6. Ein Abbruch und ein erneuter Versuch hinterlassen einen verstaendlichen, konsistenten Zustand.

Zusaetzlich wird auf einem nicht geeigneten oder deaktivierten Zustand geprueft, dass nur die Protokollerzeugung gesperrt ist.
Aufnahme, Transkript, Diarisierung, Sprecherpruefung und vorhandene Protokolle bleiben bedienbar.

Der OpenAI-kompatible Pfad wird zuerst gegen LM Studio mit einem lokalen Modell geprueft.
Die Basis-URL kann dabei direkt, ueber ein privates Netz oder ueber einen vorgeschalteten HTTPS-Endpunkt erreichbar sein, ohne dass Steno den Transport unterscheidet.
Geprueft werden Verbindungstest, echte Generierung, Provideranzeige, gestoppter Server, falsche Modell-ID und abgelehnter Schluessel.
Ein Test gegen eine Cloud-API findet nur nach ausdruecklicher Freigabe der konkreten Uebertragung statt.

## Nicht in diesem Paket

- Gemma oder ein anderes direkt in die iOS-App gebuendeltes beziehungsweise von Steno heruntergeladenes Sprachmodell.
- LM-Link-, Tailscale-, VPN-, Bonjour- oder LAN-Erkennung in Steno.
- Automatische Endpunktsuche oder Modellinstallation auf einem fremden Server.
- Synchronisation der Endpunktkonfiguration zwischen Mac und iPhone beziehungsweise iPad.
- benutzerdefinierte Protokollvorlagen.
- automatische Titel, Chat ueber Meetings oder Live-Zusammenfassungen.
- garantierte Weiterverarbeitung ueber lange iOS-Hintergrundzeiten.
- Uebersetzung oder allgemeine Lokalisierung der derzeit englischen App-Oberflaeche.

## Abnahmekriterien

- Ein geeignetes echtes iPhone oder iPad erzeugt im Flugmodus ein Protokoll mit Apple Foundation Models.
- Ein konfigurierter OpenAI-kompatibler Endpunkt kann dasselbe Meeting ueber denselben Protokollpfad verarbeiten.
- Die Aktion ist ausdruecklich und startet nie automatisch.
- Apple bleibt der Standard und ein externer Provider wird pro Job sichtbar ausgewaehlt.
- Ein Job ist an die aktuelle Transkriptrevision und die optionale Endpunkt-ID gebunden und schnelle Mehrfachaktionen erzeugen keinen Doppeljob.
- Jede erfolgreiche Neuerzeugung ist eine neue unveraenderliche Version.
- Eine laufende oder fehlgeschlagene Neuerzeugung laesst vorhandene Versionen sichtbar und intakt.
- Die UI zeigt Verfuegbarkeit, Fortschritt, Fehler, Engine und Erstellungszeitpunkt wahrheitsgemaess.
- Die sichtbare Version kann kopiert und ueber das System-Share-Sheet geteilt werden.
- Nicht lesbare Notizen verhindern unvollstaendige Protokolle, ohne Aufnahme oder Transkript zu gefaehrden.
- Unbestaetigte oder mehrdeutige Sprecher werden nicht als bestaetigte Personen ausgegeben.
- Der Apple-Pfad verlaesst das Geraet nicht.
- Vor jedem externen Lauf stimmen Zielhost, angezeigte Datenklassen und tatsaechliche Provider-Nutzlast ueberein.
- Steno enthaelt keine transport- oder produktspezifische Sonderbehandlung fuer LM Studio, Tailscale oder Cloud-Anbieter.

## Konsolidierungsnachtrag vom 18. August 2026

Die Umsetzung wird auf dem gemeinsamen macOS/iOS-Stand nach Sidebar-, Meetingtransfer- und iOS-Diarisierungsintegration neu aufgebaut.
Die fruehere Implementierung aus `8f95cfa..5435e85` ist Referenz und Testquelle, wird aber nicht als Gesamtbranch gemergt.

Der Preflight ist ein unveraenderlicher Schnappschuss der tatsaechlichen Prompt-Eingabe.
Er enthaelt Meeting-ID, gepinnte Revisions-ID, `OutboundDisclosure` und einen deterministischen SHA-256-Fingerabdruck ueber das aufgeloeste Transkript, beide Teilnehmerdarstellungen und die Nutzernotizen.
Der Erzeugen-Befehl nimmt genau diesen sichtbaren Preflight entgegen und speichert Revisions-ID sowie Fingerabdruck am Job.
Die Pipeline baut die Eingabe vor jedem Provideraufruf erneut auf und vergleicht den Fingerabdruck.
Bei einer Abweichung wird der Lauf vor jedem externen Zugriff fail-closed beendet und die UI fordert einen neuen Preflight an.
Damit fuehren Aenderungen an Notizen, Teilnehmern, Personen oder Sprecherbestaetigungen zwischen Hinweis und Ausfuehrung niemals zu einer still abweichenden Nutzlast.

Vor dieser Erweiterung gespeicherte Jobs besitzen keinen Fingerabdruck und bleiben lesbar.
Neue Jobs besitzen immer einen Fingerabdruck.
Der Fingerabdruck wird ohne zusaetzliche Klartextkopie im Job gespeichert und ist kein Ersatz fuer die spaetere Bibliotheksverschluesselung.

Die Gleichwertigkeitspruefung blockierender Jobs beruecksichtigt mindestens Meeting-ID, Jobart, Quelllauf, Template-ID, Revisions-ID, Textmodell-Endpunkt-ID, Eingabefingerabdruck und Importgeneration.
Zwei Anforderungen mit abweichendem Template, Transkriptstand, Provider oder Promptmaterial duerfen niemals denselben persistenten Job erhalten.

Die bereits integrierten Korrekturen `736d321` und `6dc7339` fuer vollstaendige strukturierte Antworten und den LM-Studio-Fallback bleiben unveraendert erhalten.
Die iOS-Oberflaeche wird in die aktuelle `ContentView`, das aktuelle `AppModel` und den aktuellen Meetingdetailfluss integriert, ohne die neuere Meetingtransfer-, Diarisierungs- oder Sprecherlogik zurueckzusetzen.

# iOS Meeting-Aktionen und Jobstatus

## Ziel

iOS macht die beiden haeufigen Meeting-Aktionen ohne Long-Press auffindbar, verschiebt ein Meeting sicher in den Papierkorb und zeigt die tatsaechliche lokale Verarbeitung nach einer erneuten Transkription an.

## Sichtbare Aktionen

Die Meeting-Detailansicht erhaelt in der oberen Toolbar ein Menue mit der zugaenglichen Bezeichnung `Meeting actions`.
Es enthaelt `Transcribe Again...` und `Move to Trash...`.
Das bestehende Kontextmenue der Seitenleiste bleibt als Abkuerzung erhalten und erhaelt dieselben Aktionen.
Eine laufende Aufnahme kann weder erneut transkribiert noch geloescht werden.

Beide Oberflaechen verwenden die bestehende Rueckfrage fuer die erneute Transkription.
Sie nennt die neue Diarisierung, neu vergebene Cluster-Kennungen, die erneut noetige Sprecherbestaetigung und den Erhalt eines bereits vorhandenen Transkripts als fruehere Revision.

Der Loeschdialog sagt ausdruecklich, dass das komplette Meeting mit Originalaufnahme, Transkriptrevisionen, Notizen und Reports in den System-Papierkorb verschoben wird.
Es gibt bewusst keine separate Audio-only-Loeschung.

## Loeschablauf

Das AppModel schuetzt den Ablauf auch unabhaengig von deaktivierten Buttons.
Es lehnt das aktuell aufgenommene Meeting ab, sichert und sperrt eine vorhandene Notizsitzung, bricht aktive Jobs ab und verschiebt anschliessend den Meeting-Ordner mit `Library.trashMeeting`.
Wenn ein Job bereits sein Ergebnis schreibt und nicht mehr abgebrochen werden kann, bleibt das Meeting bestehen und die UI bittet um einen erneuten Versuch.

Eine vorbereitete Notizsitzung wird bei einem Fehler wieder freigegeben.
Nach erfolgreichem Verschieben wird sie dauerhaft ungueltig, damit ein spaeter `onDisappear`-Autosave keinen neuen Geisterordner erzeugt.
Jobdateien werden danach entfernt.
Schlaegt nur diese regenerierbare Bereinigung fehl, gilt das Meeting trotzdem als verschoben und die UI zeigt eine Warnung.

Nach erfolgreichem Verschieben veroeffentlicht das AppModel die entfernte Meeting-ID in einer prozessweit monotonen Menge, entfernt das Meeting sofort aus seinem publizierten Zustand und laedt die Bibliothek neu.
Jede offene Detailansicht, deren Meeting-ID diese explizite Entfernungsmarkierung enthaelt, navigiert zur Aufnahmeansicht; eine voruebergehend leere Meeting-Liste reicht dafuer nicht aus.

## Verarbeitungsstatus

Der vorhandene Sekunden-Loop der Detailansicht liest neben dem Diarisierungszustand auch die Meeting-Jobs.
Eine Zustandsaenderung laedt die Meeting- und Revisionsdaten neu.
Damit werden auch Jobs sichtbar, die nach einem App-Neustart bereits in der Queue lagen.

Ein kompakter Banner zeigt ausschliesslich echte persistierte Zustaende und keine erfundenen Prozentwerte:

- `finalASR`: Transkription, Schritt 1 von 3
- `diarization`: Sprechertrennung, Schritt 2 von 3
- `identitySuggestion`: Stimmenabgleich, Schritt 3 von 3

Fuer jeden Schritt unterscheidet der Banner `queued` und `running`.
Report- und Exportjobs bleiben in ihren vorhandenen Oberflaechen.
Solange ein Pipelinejob aktiv ist, ersetzt der Jobbanner den alten Diarisierungsbanner, damit keine Aktion fuer eine alte Revision angeboten wird.

Nach dem Einreihen aus dem Detail wird die Jobliste sofort aktualisiert.
Nach dem Einreihen aus der Seitenleiste wird das Meeting ausgewaehlt, sodass der sichtbare Banner erscheint.

## Fehler und Nachweis

AppModel-Fehler werden in der ausloesenden Oberflaeche angezeigt.
Tests decken Notizsitzungs-Sperre und -Freigabe, den Loeschschutz, Jobabbruch und Papierkorbablauf sowie die Praesentationsmatrix fuer Queue und laufende Schritte ab.
Die vier Projektsuiten laufen am Ende vollstaendig.
Auf iPhone und iPad wird danach manuell geprueft, dass Menue, Rueckfragen und Jobbanner sichtbar sind.
Die genaue Darstellung des System-Papierkorbs in der Dateien-App ist ein Hardwarebefund und wird nicht aus dem Quelltext abgeleitet.

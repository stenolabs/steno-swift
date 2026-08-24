# iOS i1 - Modellinstallation und Live-Revision

Stand: 2026-08-09.
Geraet und iOS-Version: iPhone 15 Pro mit iOS 26.5.2.
Build-Commit: `cb4569c`.

## Installiertes Modell

- Gewaehlte Sprache: German (Germany).
- Live-Text vor Stop sichtbar: Ja, bei der kurzen Messung nach ungefaehr 15 Sekunden.
- Provisorische Revision nach Stop sichtbar: Ja.
- Revision nach Neustart sichtbar: Ja, danach durch den segmentierten finalen ASR-Lauf ersetzt.
- Anzahl Final-ASR-Jobs fuer das Meeting: Genau ein Job.

## Fehlendes Modell

- Gewaehlte Sprache: French (France).
- Download vor Zustimmung beobachtet: Nein.
- Audio ohne Modell erhalten: Ja, eine CAF-Datei mit 1,7 MB und die zugehoerigen Metadaten.
- Angezeigte Quelle und Groesse: Apple, 142,6 MB.
- Modellbedingt gescheiterter Job erneut verarbeitet: Ja, derselbe Final-ASR-Job endete nach zwei Versuchen mit Status `finished`.
- Diarisierungsdownload beobachtet: Nein.

## Grenzen

Nur die oben genannten kurzen Ablaeufe wurden auf echter Hardware geprueft.
Die ungefaehr 15 Sekunden bis zum deutschen Live-Text sind eine Einzelbeobachtung und kein belastbarer Leistungswert.
Eine lange Aufnahme, Thermik, Akku, Hintergrundbetrieb und Unterbrechungen waren nicht Teil dieser Messung.
Der Diarisierungsjob wurde eingereiht und scheiterte erwartungsgemaess an den noch fehlenden Modellen Sortformer, pyannote und WeSpeaker.
Es wurde kein automatischer Diarisierungsdownload beobachtet.

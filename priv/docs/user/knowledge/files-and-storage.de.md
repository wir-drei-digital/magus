---
title: Dateien & Speicher
description: Dateien hochladen, verwalten und mit deinen Agenten teilen
order: 4
---

# Dateien & Speicher

Mit Magus kannst du Dateien an Unterhaltungen anhängen, sodass deine Agenten sie lesen und darauf verweisen können. Du kannst auch auf Dateien aus früheren Unterhaltungen zugreifen, Dateien innerhalb eines Ordners oder Workspace teilen und deinen gesamten Speicher in den Kontoeinstellungen verwalten.

## Dateien hochladen

### Im Chat

Am einfachsten lädst du eine Datei direkt in einer Unterhaltung hoch:

- **Drag & Drop:** Ziehe eine Datei von deinem Desktop in das Chat-Fenster und lasse sie im Nachrichteneingabebereich fallen
- **Dateiauswahl:** Klicke auf das Anhang-Symbol (Büroklammer) im Nachrichteneingabebereich und wähle eine Datei von deinem Gerät aus

Die Datei wird an deine Nachricht angehängt. Sobald die Nachricht gesendet wurde, kann der Agent die Datei abrufen und ihren Inhalt in seiner Antwort referenzieren.

### Über den Datei-Browser

Für Dateien, die du in mehreren Unterhaltungen verwenden möchtest, öffne den **Datei-Browser** über das Files-Symbol in der Seitenleiste, oder rufe direkt `/files` auf. Über die obere Leiste des Browsers:

- Klicke auf **Upload**, um Dateien von deinem Gerät auszuwählen. Sie werden in die aktuelle Ansicht hochgeladen (in den geöffneten Ordner oder in deine Stammdateien, falls keiner offen ist).
- Ziehe Dateien an eine beliebige Stelle des Rasters, um sie direkt dort hochzuladen.

Hier hochgeladene Dateien sind sofort verfügbar und bleiben über eine einzelne Unterhaltung hinaus erhalten.

## Der Datei-Browser

Der Datei-Browser ist eine Drive-artige Ansicht für alles, was du hochgeladen hast oder was für dich generiert wurde. Klicke auf das Files-Symbol in der Workbench-Seitenleiste, um ihn zu öffnen.

### Einstiegspunkte in der Seitenleiste

Die Seitenleiste listet Orte auf, von denen aus du starten kannst:

- **My Files**: deine persönlichen Dateien und Ordner.
- **Shared with me**: in einem Team-Workspace die Dateien, die andere mit dem Team geteilt haben.
- **Recent**: Dateien, die in den letzten 30 Tagen geändert wurden.
- **Templates**: Dateien, die du als Vorlagen markiert hast, um sie wiederzuverwenden.
- **Verbundene Quellen**: Sammlungen, die aus externen Diensten synchronisiert werden. Klicke auf den Pfeil, um sie einzublenden.
- **Trash**: Dateien, die du in den Papierkorb verschoben hast. In dieser Version schreibgeschützt.

Unter den Einstiegspunkten findest du drei Filter-Pills: **Type**, **Modified**, **Source**. Wähle einen Wert, um die aktuelle Ansicht einzugrenzen, oder "Any", um den Filter zu löschen.

Am unteren Rand der Seitenleiste siehst du auf einen Blick deine Speichernutzung.

### Obere Leiste

Die obere Leiste des Browsers enthält:

- **Breadcrumbs**: klicke auf ein Segment, um zu einem übergeordneten Ordner oder Bereich zurückzuspringen.
- **Suche**: filtert die aktuelle Ansicht nach Namen. Die URL aktualisiert sich beim Tippen, sodass du eine Suche als Lesezeichen speichern kannst.
- **Sortierung**: nach "Modified" (Standard), "Name" oder "Size", aufsteigend oder absteigend.
- **List- / Grid-Umschalter**: zwischen Tabellen- und Kachelansicht wechseln. Deine Wahl wird auf deinem Konto gespeichert.
- **+ New folder**: einen neuen Ordner an der aktuellen Stelle anlegen.
- **Upload**: Dateien aus dem Dateisystem auswählen.

### Ordner-Navigation

Klicke auf eine Ordnerkachel oder -zeile, um sie zu öffnen. Die Breadcrumbs aktualisieren sich, und die URL ändert sich, sodass du eine Ordneransicht als Lesezeichen speichern oder teilen kannst.

### Datei-Aktionen

Klicke auf eine Datei, um ihre Detailansicht in einem neuen Tab zu öffnen. Per Rechtsklick auf eine Datei oder einen Ordner erreichst du das Aktionsmenü:

- Open, Open in new tab, Download
- Open chat about this file
- Rename, Move to, Share to workspace
- Toggle template (nur bei Dateien)
- Move to trash

**Move to** öffnet eine Ordnerauswahl, in der du das Ziel wählst. **Rename** öffnet einen Inline-Editor.

Der Trash-Bereich ist in dieser Version schreibgeschützt. Wiederherstellen oder endgültiges Löschen kommt in einem späteren Update.

## Geltungsbereiche für Dateien

Jede Datei hat einen **Geltungsbereich**, der steuert, wer darauf zugreifen kann und in welchen Unterhaltungen.

| Geltungsbereich | Wer kann darauf zugreifen |
|-----------------|---------------------------|
| **Chat** | Nur die aktuelle Unterhaltung |
| **Folder** | Alle Unterhaltungen im selben Ordner |
| **Workspace** | Alle Mitglieder deines Workspace (Teamzugriff) |
| **Global** | Alle deine Unterhaltungen, über alle Agenten hinweg |

Wähle den passenden Geltungsbereich je nachdem, wie weit die Datei verfügbar sein soll. Für sensible Dokumente hält der Geltungsbereich **Chat** die Datei auf eine Unterhaltung beschränkt. Für Referenzmaterial, das das ganze Team nutzt, macht der Geltungsbereich **Workspace** es überall verfügbar.

## Dateien herunterladen

So lädst du eine Datei herunter:

- Klicke in einer Unterhaltung auf den Dateianhang, um ihn zu öffnen, und klicke dann auf **Herunterladen**
- Finde im Files-Tab die Datei und klicke auf das **Download**-Symbol daneben

Vom Agenten generierte Dateien (zum Beispiel Bilder, die von einem Bildgenerierungsmodell erstellt wurden, oder Ausgaben aus der Code-Ausführung) erscheinen in der Unterhaltung und können auf dieselbe Weise heruntergeladen werden.

## Unterstützte Dateitypen

Magus kann Text aus einer Vielzahl von Dateiformaten extrahieren:

- **Dokumente:** PDF, Word (.doc, .docx), RTF, EPUB, OpenDocument (.odt)
- **Tabellen:** Excel (.xls, .xlsx), CSV, OpenDocument (.ods)
- **Präsentationen:** PowerPoint (.ppt, .pptx)
- **Bilder:** JPEG, PNG, GIF, WebP, TIFF, BMP, SVG (Texterkennung per OCR)
- **Web- und Datenformate:** HTML, XML, JSON, YAML, Markdown
- **Nur-Text:** .txt und andere textbasierte Dateien

Große Dateien werden zur semantischen Suche in Abschnitte aufgeteilt. Nach dem Hochladen kann es eine kurze Verarbeitungszeit geben, bevor die Datei vollständig für deinen Agenten verfügbar ist.

## Speicherlimits

Der verfügbare Speicher hängt von deinem Abonnementplan ab:

- **Free-Plan:** Begrenzter Speicher inklusive
- **Bezahlte Pläne:** Mehr Speicher, mit höheren Upload-Limits pro Datei

Du kannst deine aktuelle Speichernutzung in den **Account Settings** unter **Storage** einsehen. Die Anzeige zeigt, wie viel du genutzt hast und wie viel dein Plan erlaubt.

Wenn du dein Speicherlimit erreichst, musst du Dateien löschen oder deinen Plan upgraden, bevor du weitere Dateien hochladen kannst.

## Speicher verwalten

### Speichernutzung einsehen

Am unteren Rand der Seitenleiste des Datei-Browsers siehst du eine kompakte Speicheranzeige mit deiner aktuellen Nutzung. Eine ausführliche Übersicht findest du in den **Account Settings** unter **Storage**.

### Dateien löschen, um Speicher freizugeben

So löschst du eine Datei:

1. Öffne den Datei-Browser unter `/files`
2. Finde die Datei (mit Suche oder Filter eingrenzen)
3. Rechtsklick auf die Datei und **Move to trash** wählen

Die Datei wandert in den **Trash** und ist aus deinen aktiven Ansichten ausgeblendet. In dieser Version zählt sie weiterhin zur Speichernutzung. Endgültiges Löschen, das Speicher tatsächlich freigibt, kommt in einem späteren Update.

### Workspace-Dateien

Wenn du Teil eines Team-Workspace bist, werden Dateien mit dem Geltungsbereich **Workspace** unter allen Mitgliedern geteilt. Nur die Person, die eine Datei hochgeladen hat (oder ein Workspace-Admin), kann sie löschen.

## Verarbeitungsstatus von Dateien

Nach dem Hochladen durchläuft eine Datei einen Verarbeitungsschritt, bei dem Magus Text extrahiert, Abschnitte für die semantische Suche erstellt und den Inhalt speichert. Öffne eine Datei im Browser, um den Status zu sehen:

- **Ausstehend:** Upload empfangen, Verarbeitung hat noch nicht begonnen
- **Wird verarbeitet:** Wird für die semantische Suche indiziert
- **Bereit:** Vollständig für deinen Agenten verfügbar
- **Fehler:** Verarbeitung fehlgeschlagen. Versuche, die Datei zu löschen und erneut hochzuladen.

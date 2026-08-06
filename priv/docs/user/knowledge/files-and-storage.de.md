---
title: Dateien & Speicher
description: Dateien hochladen, verwalten und mit deinen Agenten teilen
order: 5
---

# Dateien & Speicher

Mit Magus kannst du Dateien an Unterhaltungen anhängen, sodass deine Agenten sie lesen und darauf verweisen können. Du kannst auch auf Dateien aus früheren Unterhaltungen zugreifen, Dateien innerhalb eines Ordners oder Workspace teilen und deinen gesamten Speicher in den Kontoeinstellungen verwalten.

## Dateien hochladen

### Im Chat

Am einfachsten lädst du eine Datei direkt in einer Unterhaltung hoch:

- **Drag & Drop:** Ziehe eine Datei von deinem Desktop auf den Chat-Eingabebereich
- **Dateiauswahl:** Öffne das **+**-Menü im Nachrichteneingabebereich, wähle **Datei anhängen** und dann eine Datei von deinem Gerät

Die Datei wird an deine Nachricht angehängt. Sobald die Nachricht gesendet wurde, kann der Agent die Datei abrufen und ihren Inhalt in seiner Antwort referenzieren.

### Über den Datei-Browser

Für Dateien, die du in mehreren Unterhaltungen verwenden möchtest, wechsle in den Modus **Files** in der linken Leiste (oder rufe `/files` auf). Dann:

- Klicke auf **Upload** in der oberen Leiste des Browsers (oder auf **Dateien hochladen** in der Seitenleiste), um Dateien von deinem Gerät auszuwählen. Sie werden in die aktuelle Ansicht hochgeladen (in den geöffneten Ordner oder in deine Stammdateien, falls keiner offen ist).
- Ziehe Dateien an eine beliebige Stelle des Browsers, um sie direkt dort hochzuladen.

Hier hochgeladene Dateien sind sofort verfügbar und bleiben über eine einzelne Unterhaltung hinaus erhalten.

## Der Datei-Browser

Der Datei-Browser ist eine Drive-artige Ansicht für alles, was du hochgeladen hast oder was für dich generiert wurde. Klicke auf das Files-Symbol in der linken Leiste, um ihn zu öffnen.

### Einstiegspunkte in der Seitenleiste

Die Seitenleiste listet Orte auf, von denen aus du starten kannst:

- **My files**: deine persönlichen Dateien und Ordner.
- **Recent**: kürzlich geänderte Dateien.
- **Templates**: Dateien, die du als Vorlagen markiert hast, um sie wiederzuverwenden.
- **Shared with me**: in einem Team-Workspace die Dateien, die andere mit dem Team geteilt haben.
- **Verbundene Quellen**: Sammlungen, die aus externen Diensten synchronisiert werden, jeweils mit Anzahl und Sync-Status.
- **Trash**: Dateien, die du in den Papierkorb verschoben hast. In dieser Version schreibgeschützt.

Am unteren Rand der Seitenleiste siehst du auf einen Blick deine Speichernutzung.

### Obere Leiste

Die obere Leiste des Browsers enthält:

- **Breadcrumbs**: klicke auf ein Segment, um zu einem übergeordneten Ordner oder Bereich zurückzuspringen.
- **Suche**: filtert die aktuelle Ansicht nach Namen.
- **Sortierung**: nach "Modified" (Standard), "Name" oder "Size", aufsteigend oder absteigend.
- **Filters**: ein Popover mit den Filtern **Type**, **Modified** und **Source**. Wähle einen Wert, um die aktuelle Ansicht einzugrenzen, oder "Any", um den Filter zu löschen.
- **New folder**: einen neuen Ordner an der aktuellen Stelle anlegen.
- **Upload**: Dateien aus dem Dateisystem auswählen.
- **List- / Grid-Umschalter**: zwischen Tabellen- und Kachelansicht wechseln. Deine Wahl wird auf deinem Konto gespeichert.

### Ordner-Navigation

Klicke auf eine Ordnerkachel oder -zeile, um sie zu öffnen. Die Breadcrumbs aktualisieren sich, und die URL ändert sich, sodass du eine Ordneransicht als Lesezeichen speichern oder teilen kannst.

### Datei-Aktionen

Klicke auf eine Datei, um ihre Detailansicht zu öffnen. Fahre mit der Maus über eine Datei oder einen Ordner und klicke auf den **⋯**-Button für das Aktionsmenü:

- **Open** und **Download**
- **Rename** und **Move…** (öffnet eine Ordnerauswahl für das Ziel)
- **Mark as template** / **Remove from templates** (nur bei Dateien)
- **Share with team** / **Make private** (in einem Workspace)
- **Move to trash** (Dateien) / **Delete** (Ordner)

Der Trash-Bereich ist in dieser Version schreibgeschützt. Wiederherstellen oder endgültiges Löschen kommt in einem späteren Update.

## Geltungsbereiche für Dateien

Wo eine Datei liegt, entscheidet, wer darauf zugreifen kann und in welchen Unterhaltungen:

| Geltungsbereich | Wer kann darauf zugreifen |
|-----------------|---------------------------|
| **Chat** | Eine an eine Unterhaltung angehängte Datei gehört zu dieser Unterhaltung |
| **Folder** | Eine Datei in einem Ordner steht Unterhaltungen in diesem Ordner zur Verfügung |
| **Workspace** | Eine mit dem Team geteilte Datei steht allen Workspace-Mitgliedern zur Verfügung |
| **Bibliothek** | Eine Datei in deiner persönlichen Bibliothek steht über deine Unterhaltungen hinweg zur Verfügung |

Für sensible Dokumente hält das Anhängen an eine einzelne Unterhaltung sie isoliert. Referenzmaterial, das das ganze Team nutzt, teilst du mit dem Workspace.

## Dateien herunterladen

So lädst du eine Datei herunter:

- Fahre in einer Unterhaltung mit der Maus über den Anhang und nutze seinen Download-Button (Bilder und Videos), oder öffne den Anhang und lade von dort herunter
- Öffne im Datei-Browser das **⋯**-Menü der Datei und wähle **Download**

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

Du kannst deine aktuelle Speichernutzung unter **Einstellungen → Speicher** einsehen. Die Anzeige zeigt, wie viel du genutzt hast und wie viel dein Plan erlaubt.

Wenn du dein Speicherlimit erreichst, musst du Dateien löschen oder deinen Plan upgraden, bevor du weitere Dateien hochladen kannst.

## Speicher verwalten

### Speichernutzung einsehen

Am unteren Rand der Seitenleiste des Datei-Browsers siehst du eine kompakte Speicheranzeige mit deiner aktuellen Nutzung. Eine ausführliche Übersicht findest du unter **Einstellungen → Speicher**.

### Dateien löschen, um Speicher freizugeben

So löschst du eine Datei:

1. Öffne den Datei-Browser unter `/files`
2. Finde die Datei (mit Suche oder Filter eingrenzen)
3. Öffne das **⋯**-Menü der Datei und wähle **Move to trash**

Die Datei wandert in den **Trash** und ist aus deinen aktiven Ansichten ausgeblendet. In dieser Version zählt sie weiterhin zur Speichernutzung. Endgültiges Löschen, das Speicher tatsächlich freigibt, kommt in einem späteren Update.

### Workspace-Dateien

Wenn du Teil eines Team-Workspace bist, werden Dateien mit dem Geltungsbereich **Workspace** unter allen Mitgliedern geteilt. Nur die Person, die eine Datei hochgeladen hat (oder ein Workspace-Admin), kann sie löschen.

## Verarbeitungsstatus von Dateien

Nach dem Hochladen durchläuft eine Datei einen Verarbeitungsschritt, bei dem Magus Text extrahiert, Abschnitte für die semantische Suche erstellt und den Inhalt speichert. Öffne eine Datei im Browser, um den Status zu sehen:

- **Ausstehend:** Upload empfangen, Verarbeitung hat noch nicht begonnen
- **Wird verarbeitet:** Wird für die semantische Suche indiziert
- **Bereit:** Vollständig für deinen Agenten verfügbar
- **Fehler:** Verarbeitung fehlgeschlagen. Versuche, die Datei zu löschen und erneut hochzuladen.

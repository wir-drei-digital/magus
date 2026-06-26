---
title: Knowledge Brain
description: Ein kollaborativer Forschungsarbeitsbereich, in dem du und deine KI gemeinsam Wissen aufbauen
order: 5
---

# Knowledge Brain

Ein Knowledge Brain ist ein gemeinsamer Arbeitsbereich, in dem du und deine KI zusammen recherchieren, schreiben und Ideen rund um ein Thema organisieren. Stell es dir als ein persönliches Wiki vor, das du gemeinsam aufbaust. Anders als Memory, wo die KI Fakten automatisch speichert und abruft, ist ein Brain ein Ort, den du aktiv aufbaust. Du sammelst Quellen, schreibst Notizen und stellst Fragen, mit der KI als Denkpartner bei jedem Schritt.

Jedes Brain hat eigene Seiten, und jede Seite ist ein Dokument mit Rich-Text-Editor, das du direkt bearbeiten oder von der KI mitgestalten lassen kannst.

## Erste Schritte

### Ein Brain erstellen

Offne den **Brains**-Tab in der linken Seitenleiste. Klicke auf **New Brain** und gib ihm einen Namen, in der Regel das Thema oder Projekt, zu dem du recherchierst.

Du kannst beliebig viele Brains erstellen. Halte sie auf ein einzelnes Thema fokussiert, damit die KI klaren Kontext hat, wenn das Pane geöffnet ist.

### Seiten erstellen

Innerhalb eines Brains klicke auf **New Page**, um eine Seite zu erstellen. Seiten sind die Haupteinheit der Organisation. Du kannst eine Seite pro Unterthema haben, eine pro Quellenanalyse oder eine für allgemeine Notizen, was immer zu deiner Denkweise passt.

### Das Brain-Pane öffnen

Klicke auf eine beliebige Brain-Seite in der Seitenleiste, um sie als Seitenpanel neben deiner Unterhaltung zu öffnen. Das Pane bleibt geöffnet, waehrend du chattest, und die KI erhaelt automatisch den Inhalt der aktuellen Seite als Kontext.

## Das Brain-Pane

Das Brain-Pane oeffnet sich rechts neben deiner Unterhaltung. Oben siehst du den Seitentitel. Darunter befindet sich der Editor, und unten gibt es vier Tabs: **Outline**, **Sources**, **Related** und **Activity**.

### Im Pane bearbeiten

Der Editor ist eine vollwertige Rich-Text-Umgebung auf Basis von TipTap. Du kannst direkt tippen, Inhalte einfügen oder die KI für dich schreiben lassen.

**Verfuegbare Blocktypen:**

- Absaetze
- Ueberschriften (H1, H2, H3)
- Aufzaehlungslisten und nummerierte Listen
- Code-Bloecke
- Zitatbloecke
- Trennlinien

**Rich-Blocktypen** gehen ueber reinen Text hinaus:

- **Quellenbloecke**: eine abgerufene URL mit extrahiertem Titel, Typ und Inhalt
- **Dateibloecke**: eine angehängte Datei aus deiner Dateibibliothek
- **Nachrichtenbloecke**: eine gespeicherte Nachricht aus einer Unterhaltung
- **Callout-Bloecke**: hervorgehobene Hinweise oder Warnungen
- **Bildbloecke**: eingebettete Bilder

### Seiten verlinken

Tippe `[[` irgendwo im Editor, um eine andere Seite im selben Brain zu verlinken. Während du den Seitennamen tippst, erscheint eine Vorschlagsliste. Wähle eine Seite aus, um einen Link einzufügen. Diese Links helfen bei der Navigation verwandter Inhalte und erscheinen im **Related**-Tab.

### Untere Tabs

- **Outline**: eine strukturierte Ansicht der Ueberschriften auf der aktuellen Seite, nuetzlich für lange Seiten
- **Sources**: alle Quellenbloecke auf der aktuellen Seite im Ueberblick
- **Related**: Seiten in diesem Brain, die mit der aktuellen Seite verlinkt sind
- **Activity**: ein Protokoll der letzten Aenderungen an der Seite, einschliesslich Beitraege der KI

## Mit Quellen arbeiten

Quellen sind URLs, mit denen du (und die KI) arbeiten moechtest. Wenn du eine Quelle hinzufuegst, ruft Magus die Seite ab und extrahiert ihren Inhalt. Das Ergebnis erscheint als Quellenblock auf der Seite mit Titel, URL und Quellentyp.

### Eine Quelle hinzufügen

Klicke auf **Add Source** in der Werkzeugleiste oder fuege eine URL in den Editor ein und waehle **Add as Source**. Magus ruft den Inhalt im Hintergrund ab und extrahiert ihn. Sobald der Vorgang abgeschlossen ist, zeigt der Block den Seitentitel und einen Ausschnitt des extrahierten Textes.

Die KI kann den Quelleninhalt lesen, wenn das Brain-Pane geöffnet ist, sodass du sofort Fragen zum gerade hinzugefuegten Material stellen kannst.

### Von der KI hinzugefügte Quellen

Wenn die KI während einer Unterhaltung eine Websuche oder einen Fetch-Befehl ausführt, kann sie das Ergebnis direkt als Quellenblock auf der geöffneten Brain-Seite hinzufügen. Diese KI-Quellen werden im Activity-Log gekennzeichnet.

## Chat-Integration

Das Brain-Pane und deine Unterhaltung arbeiten eng zusammen. Mehrere Funktionen ermoeglichen es dir, Inhalte zwischen beiden zu verschieben.

### Nachrichten im Brain speichern

Wenn das Brain-Pane geöffnet ist, fahre mit der Maus über eine Nachricht, um die Aktionsschaltflächen einzublenden. Klicke auf das Brain-Icon, um die Nachricht an die aktuelle Seite anzuhängen, oder greife den Griff am Ende der Aktionsleiste, um die Nachricht an eine bestimmte Stelle im Editor zu ziehen. Der übrige Text der Nachricht bleibt markierbar, sodass du Inhalte weiterhin wie gewohnt kopieren kannst. Nützlich, um eine besonders gute KI-Antwort, eine wichtige Frage oder eine Zusammenfassung festzuhalten.

### Tool-Ergebnisse speichern

Wenn die KI ein Tool ausfuehrt (z.B. eine Websuche), hat die Ergebniskarte eine **Add Source**-Option. Diese erstellt einen Quellenblock auf der aktuellen Brain-Seite aus der URL, die das Tool abgerufen hat.

### Text als Chat-Kontext auswaehlen

Markiere beliebigen Text im Brain-Editor, und ein kleines Popup erscheint. Klicke auf **Ask Chat**, um den ausgewählten Text als Kontext für deine naechste Nachricht an den Chat zu senden. So kannst du gezielt auf einen bestimmten Abschnitt eingehen, ohne kopieren und einfügen zu muessen.

### Brain-Kontext in der KI

Wenn das Brain-Pane geöffnet ist, erhaelt die KI den Inhalt der aktuellen Seite als Teil ihres Kontexts für jede Nachricht. Du musst nicht kopieren oder erklaeren, was auf der Seite steht. Die KI sieht es bereits. Schliesse das Pane, wenn du eine Unterhaltung ohne diesen Kontext fuehren moechtest.

## KI als Denkpartner

Magus behandelt die KI als Mitarbeiterin, nicht nur als Werkzeug. Wenn das Pane geöffnet ist, kannst du die KI bitten:

- Ganze Seiten aus deinen Notizen schreiben. Teile einfach deine Gedanken im Chat und die KI erstellt eine gut strukturierte Seite mit Ueberschriften, Listen, Code-Bloecken und mehr.
- An bestehende Seiten anhängen. Wenn du Informationen teilst, die sich auf eine existierende Seite beziehen, fügt die KI sie dort hinzu, statt eine Kopie zu erstellen.
- Inhalte präzise bearbeiten. Die KI kann bestimmten Text auf einer Seite suchen und ersetzen, ohne ganze Blöcke umschreiben zu muessen.
- Quellen von URLs hinzufügen, die automatisch abgerufen und extrahiert werden.
- Verwandte Seiten verbinden. Die KI kann zwei Seiten miteinander verlinken, sodass sie in den jeweiligen Related-Tabs erscheinen.
- Alle deine Brains durchsuchen, um den richtigen Platz für neue Informationen zu finden.
- Inhalte an das richtige Brain weiterleiten, wenn du mehrere Brains hast (Arbeit, Persönliches, Recherche).

Alles, was die KI hinzufuegt, wird im Activity-Log erfasst, damit du immer weisst, was sie beigetragen hat und wann.

**Am besten für:** Rechercheprojekte, bei denen du schrittweise Verstaendnis aufbauen moechtest, statt nur eine einzelne Antwort zu bekommen.

## Notizen im Chat hinterlassen

Du musst das Brain-Pane nicht öffnen oder spezielle Befehle verwenden, um Informationen zu deinem Brain hinzuzufügen. Teile deine Notizen, Fakten oder Rechercheergebnisse einfach natuerlich im Chat. Die KI entscheidet, wohin sie gehoeren.

### Wie es funktioniert

Wenn du Wissen in einer Unterhaltung teilst, macht die KI Folgendes:

1. Durchsucht deine Brains nach Seiten zum gleichen Thema.
2. Wenn eine passende Seite existiert, hängt sie deine Inhalte dort an.
3. Wenn nichts passt, erstellt sie eine neue Seite mit einem beschreibenden Titel.
4. Verbindet die neuen Inhalte automatisch mit verwandten Seiten.
5. Sagt dir kurz, was sie getan hat: welches Brain, welche Seite, erstellt oder angehängt.

### Mehrere Brains

Wenn du mehrere Brains hast (zum Beispiel ein Arbeits-Brain und ein Persönliches Brain), leitet die KI Inhalte anhand des Themas an das richtige weiter. Wenn unklar ist, welches Brain passt, fragt sie dich.

### Markdown-Unterstuetzung

Wenn die KI in dein Brain schreibt, verwendet sie Markdown, um sauber strukturierte Inhalte zu erstellen. Ueberschriften werden zu Ueberschriften-Bloecken, Code-Abschnitte zu Code-Bloecken, Aufzaehlungslisten zu Listenelementen mit korrekter Verschachtelung und so weiter. Du erhaeltst aufgeraemte, organisierte Seiten ohne manuelles Formatieren.

## Echtzeit-Zusammenarbeit

Mehrere Teammitglieder koennen die gleiche Brain-Seite gleichzeitig anzeigen und bearbeiten.

### Präsenz

Wenn jemand anderes die gleiche Seite geöffnet hat, siehst du einen Präsenzpunkt oder Avatar oben im Pane. Ein Zaehler-Badge erscheint auch am Brain-Eintrag in der Seitenleiste.

### Live-Updates

Aenderungen von anderen Nutzern erscheinen in Echtzeit im Editor. Du musst nicht aktualisieren. Wenn du und ein Mitarbeiter gleichzeitig tippen, werden eure Aenderungen automatisch zusammengefuehrt.

## Versionshistorie

Jede Aenderung an einem Block wird aufgezeichnet. Wenn die KI oder ein Mitarbeiter eine Aenderung vornimmt, die du rueckgaengig machen moechtest, kannst du eine fruehere Version wiederherstellen.

Der **Activity**-Tab zeigt eine Versionsnummer neben Bloecken, die mehr als einmal bearbeitet wurden. Die Versionswiederherstellung ist ueber die KI verfuegbar: bitte den Agenten, einen Block auf einen frueheren Stand zurueckzusetzen, und er verwendet die Versionshistorie, um den richtigen Snapshot zu finden und anzuwenden.

## Seitenoperationen

### Eine Seite aufteilen

Wenn eine Seite zu gross wird oder mehrere Unterthemen abdeckt, kann die KI sie aufteilen. Sage zum Beispiel "teile den Abschnitt ueber Datenquellen in eine eigene Seite aus", und der Agent verschiebt die relevanten Bloecke auf eine neue Seite.

### Seiten zusammenfuehren

Zwei Seiten, die das gleiche Thema behandeln, koennen zusammengefuehrt werden. Die KI verschiebt alle Bloecke von der Quellseite in die Zielseite und entfernt dann die leere Quellseite. Sage "fuehre die Entwurfsnotizen-Seite mit der Hauptrecherche-Seite zusammen", um dies auszuloesen.

### Bloecke reorganisieren

Du kannst die KI bitten, Bloecke umzuordnen, Verschachtelungsebenen zu aendern oder eine Seite umzustrukturieren. Der Agent verwendet ein spezielles Tool, um mehrere Bloecke in einer einzigen Operation zu verschieben.

## Autonome Agenten

Benutzerdefinierte Agenten mit Brain-Zugriff koennen eigenstaendig an deinen Brains arbeiten, auch wenn du nicht in einer Unterhaltung bist.

### Zugriff gewaehren

In den Einstellungen deines benutzerdefinierten Agenten gewaehrst du dem Agenten **Editor**-Zugriff auf ein bestimmtes Brain. Der Agent bezieht dann den Inhalt dieses Brains in seine regelmaessigen Heartbeat-Sweeps ein.

### Was autonome Agenten tun koennen

Waehrend eines Heartbeat-Sweeps kann ein Agent mit Brain-Zugriff:

- Neue Quellen hinzufügen, die er entdeckt
- Zusammenfassungen neuer Informationen schreiben
- Seiten für aufkommende Unterthemen erstellen
- Verwandte Inhalte organisieren und verlinken

Alle autonomen Beitraege erscheinen im Activity-Tab mit dem Namen des Agenten, damit du immer weisst, was sich geaendert hat und wann.

## Deine Brains organisieren

Die KI hilft auch bei der Organisation. Wenn du Notizen im Chat hinterlaesst, findet sie automatisch das richtige Brain und die richtige Seite, oder erstellt bei Bedarf neue.

Halte jedes Brain auf ein einzelnes Thema oder Projekt fokussiert. Verwende Seiten innerhalb eines Brains, um das Thema in Abschnitte aufzuteilen, zum Beispiel eine Seite für Hintergrundrecherche, eine für offene Fragen und eine für Schlussfolgerungen.

Verwende `[[Seitenname]]`-Links grosszuegig, um verwandte Seiten zu verbinden. Der **Related**-Tab zeigt dir, welche Seiten aufeinander verweisen, sodass du auch grosse Brains leicht navigieren kannst.

Wenn ein Projekt abgeschlossen ist, kannst du das Brain im Brains-Tab archivieren oder loeschen.

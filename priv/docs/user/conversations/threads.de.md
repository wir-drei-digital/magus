---
title: Threads
description: Zweige von jeder Nachricht ab, um Nebenthemen zu erkunden, ohne den Kontext zu verlieren
order: 6
---

# Threads

Zweige von jeder Nachricht ab, um ein Nebenthema zu erkunden, ohne den Kontext zu verlieren oder die Hauptunterhaltung zu unterbrechen. Threads übernehmen den Kontext der übergeordneten Unterhaltung bis zum Abzweigungspunkt und laufen dann unabhängig mit ihrem eigenen Agenten.

## So funktioniert es

Ein Thread ist eine Unterunterhaltung, die von einer bestimmten Nachricht ausgeht. Er erhält den vollständigen Kontext der übergeordneten Unterhaltung bis zu dieser Nachricht, aber alles, was im Thread gesagt wird, bleibt im Thread. Die Hauptunterhaltung wird nicht beeinflusst.

Jeder Thread hat seinen eigenen Agenten-Prozess. Das bedeutet:
- Der Thread kann in eine völlig andere Richtung gehen als die Hauptunterhaltung
- Du kannst das Modell für den Thread unabhängig ändern
- Tool-Aufrufe und Antworten im Thread erscheinen nicht in der Hauptunterhaltung
- Der übergeordnete Agent hat keine Kenntnis davon, was im Thread passiert

## Einen Thread starten

### Von einer Nachricht

Fahre mit der Maus über eine Nachricht in der Unterhaltung und klicke auf das Thread-Symbol (Pfeil). Damit erstellst du einen neuen Thread, der von dieser Nachricht abzweigt.

Wenn bereits ein Thread für diese Nachricht existiert, öffnet ein Klick auf das Symbol den vorhandenen Thread, anstatt einen neuen zu erstellen.

### Vom Agenten erstellte Threads

Du kannst den Agenten bitten, einen Thread zu starten. Zum Beispiel:

> "Starte einen Thread, um die Docker-Konfiguration im Detail zu erkunden"

Der Agent wird:
1. Den Thread erstellen, der von der relevanten Nachricht abzweigt
2. Eine Ankündigung in der Hauptunterhaltung mit einem Link zum Thread posten
3. Die erste Nachricht im Thread senden, um die Diskussion zu starten

Die Ankündigung erscheint als Karte, auf die du klicken kannst, um den Thread zu öffnen.

## Thread-Panel

### Desktop

Threads öffnen sich in einem Seitenpanel neben der Hauptunterhaltung. Du kannst beide gleichzeitig sehen. Das Panel enthält:

- **Kopfzeile** mit Thread-Titel und Name der übergeordneten Unterhaltung
- **Abzweigungsreferenz**, die zeigt, von welcher Nachricht der Thread abgezweigt wurde
- **Nachrichten**, die genauso dargestellt werden wie in der Hauptunterhaltung (Markdown, Tool-Aufrufe usw.)
- **Chat-Eingabe** zum Senden von Nachrichten im Thread

Schliesse das Panel mit dem X-Button. Der Thread bleibt bestehen; du kannst ihn jederzeit wieder öffnen.

### Mobil

Auf Mobilgeräten übernimmt der Thread den gesamten Bildschirm mit einem Zurück-Button, um zur übergeordneten Unterhaltung zurückzukehren.

## Threads finden

### In Nachrichten

Nachrichten mit Threads zeigen einen Antwort-Zähler unter sich an (z.B. "3 Antworten"). Klicke darauf, um den Thread zu öffnen.

### In der Seitenleiste

Threads erscheinen verschachtelt unter ihrer übergeordneten Unterhaltung in der Seitenleiste. Klicke auf einen Thread, um zur übergeordneten Unterhaltung zu navigieren und das Thread-Panel zu öffnen. Threads sind nach Erstellungsdatum sortiert und nicht verschiebbar.

## Thread-Verhalten

### Kontext-Vererbung

Der Agent des Threads erhält alle Nachrichten der übergeordneten Unterhaltung bis zum Abzweigungspunkt. Nachrichten, die nach dem Abzweigungspunkt in der Hauptunterhaltung gesendet werden, sind nicht im Kontext des Threads enthalten.

Übergeordnete Nachrichten werden jedes Mal frisch gelesen. Wenn du eine Nachricht in der übergeordneten Unterhaltung bearbeitest oder deaktivierst, spiegelt der Thread diese änderung wider.

### Einstellungen

Threads übernehmen bei der Erstellung die Einstellungen der übergeordneten Unterhaltung:
- Modellauswahl (Chat, Bild, Video)
- Chat-Modus
- System-Prompt
- Eigener Agent
- Sampling-Einstellungen

Du kannst diese nach der Erstellung des Threads unabhängig ändern.

### Multiplayer

In Multiplayer-Unterhaltungen übernehmen Threads die Mitglieder und Sichtbarkeit der übergeordneten Unterhaltung. Alle Teilnehmer können denselben Thread öffnen und dazu beitragen oder gleichzeitig verschiedene Threads geöffnet haben. Der Thread-Panel-Status ist benutzerspezifisch.

### Einschränkungen

- **Nur eine Ebene**: du kannst keinen Thread innerhalb eines Threads erstellen
- **Ein Thread pro Nachricht**: jede Nachricht kann höchstens einen Thread haben, der von ihr abzweigt

### Löschen

Das Löschen einer übergeordneten Unterhaltung löscht automatisch alle zugehörigen Threads. Threads können nicht zu einer anderen übergeordneten Unterhaltung verschoben werden.

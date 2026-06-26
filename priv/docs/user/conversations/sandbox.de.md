---
title: Sandbox & Services
description: Code ausführen, Pakete installieren, Webservices in einer sicheren Sandbox starten und Screenshots aus der Live-Vorschau an den Chat senden
order: 10
---

# Sandbox & Services

Die Sandbox gibt der KI eine sichere Umgebung, um Code zu schreiben und auszuführen, Pakete zu installieren, Dateien zu lesen und zu schreiben und Webservices zu starten. Alles läuft in einem isolierten Container, sodass nichts deinen lokalen Rechner beeinflusst.

## Code-Ausführung

Wenn die KI etwas berechnen, Daten analysieren oder ein Skript testen muss, kann sie Code in der Sandbox ausführen. Du siehst den ausgeführten Code und die Ausgabe direkt in der Unterhaltung. Unterstützte Aufgaben sind:

- Code in einer vielzahl von Sprachen ausführen. Wenn nicht anders gewünscht wird typischerweise Python verwendet.
- Dateien innerhalb der Sandbox lesen und schreiben
- Generierte Dateien herunterladen (PDFs, Bilder, CSVs usw.)
- Webservice hosten

Die Sandbox startet automatisch, wenn die KI zum ersten Mal Code in einer Unterhaltung ausführt. Sie bleibt 15 Minuten nach der letzten Nutzung aktiv und wird dann pausiert, um Ressourcen zu sparen. Sie wird automatisch wieder aktiviert, wenn sie gebraucht wird.

## Einen Service starten

Die KI kann Webservices in der Sandbox starten, zum Beispiel eine Flask-App, einen Node.js-Server oder jeden Prozess, der auf einem Port lauscht. Wenn ein Service startet, öffnet sich rechts neben dem Chat ein **Service-Vorschau**-Panel.

Das Service-Panel zeigt:

- Eine Live-Vorschau des laufenden Service in einem eingebetteten Frame
- Den Service-Status (running, suspended, stopped oder error)
- Einen Button, um den Service in einem neuen Browser-Tab zu öffnen
- Einen Reload-Button, um den Service neu zu starten

Du kannst weiter mit der KI chatten, während der Service läuft. Bitte sie, Änderungen am Code vorzunehmen, und klicke dann auf den Reload-Button im Panel, um den Service mit dem aktualisierten Code neu zu starten.

## Das Service-Panel

Das Service-Panel funktioniert wie andere Seitenpanels (Drafts, Threads). Es öffnet sich automatisch, wenn ein Service startet, und bleibt geöffnet, während du navigierst. Wenn du es schließt, kannst du es wieder öffnen, indem du auf **Im Panel anzeigen** auf der Service-Karte im Nachrichtenverlauf klickst.

Der Panel-Zustand bleibt bei Seitenaktualisierungen erhalten. Wenn du die Seite neu lädst oder weg und zurück navigierst, öffnet sich das Service-Panel in seinem letzten Zustand.

## Einen pausierten Service neu starten

Wenn die Sandbox nach 15 Minuten Inaktivität pausiert, zeigt das Service-Panel den Status "suspended" mit einem **Service neu starten**-Button. Ein Klick darauf weckt die Sandbox auf und startet den Service mit demselben Befehl und derselben Konfiguration wie beim ursprünglichen Start.

Du kannst auch jederzeit den Reload-Button in der Panel-Kopfzeile klicken, um den Service neu zu starten, auch während er läuft. Das stoppt den aktuellen Prozess und startet einen neuen.

## Screenshots aufnehmen

Du kannst einen Screenshot der Service-Vorschau aufnehmen und an den Chat senden. Das ist nützlich, wenn du auf ein visuelles Problem hinweisen, die KI nach etwas auf dem Bildschirm fragen oder einen bestimmten Teil der Oberfläche referenzieren möchtest.

1. Klicke auf das **Kamera**-Symbol in der Kopfzeile des Service-Panels. Der Button wird hervorgehoben, um den Screenshot-Modus anzuzeigen.
2. Klicke und ziehe ein Rechteck über den Bereich, den du aufnehmen möchtest.
3. Ein **Ask**-Button erscheint neben deiner Auswahl. Klicke darauf, um den Screenshot an deine nächste Nachricht anzuhängen.
4. Der Screenshot erscheint als Vorschau-Badge im Chat-Eingabefeld. Tippe deine Frage oder deinen Kommentar ein und sende die Nachricht wie gewohnt.

Zum Abbrechen drücke **Escape** oder klicke erneut auf das Kamera-Symbol, um den Screenshot-Modus zu verlassen. Du kannst einen angehängten Screenshot auch entfernen, indem du auf das **X** an seinem Badge im Chat-Eingabefeld klickst.

Der Screenshot wird als Bild in den Nachricht-Metadaten gespeichert, sodass die KI genau sehen kann, worauf du dich beziehst.

## Einschränkungen

- Jede Unterhaltung hat eine Sandbox. Das Starten eines neuen Service ersetzt den vorherigen.
- Die Sandbox pausiert nach 15 Minuten Inaktivität und wird nach 30 Tagen beendet.
- Dateien in der Sandbox sind nicht dauerhaft. Lade alles herunter, was du behalten möchtest.
- Die Service-Vorschau-URL ist privat und nur für dich zugänglich, solange du angemeldet bist.

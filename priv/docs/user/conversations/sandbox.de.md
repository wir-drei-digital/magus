---
title: Sandbox & Services
description: Code ausführen, Pakete installieren und Webservices mit Live-Vorschau in einer sicheren Sandbox starten
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

Die KI kann Webservices in der Sandbox starten, zum Beispiel eine Flask-App, einen Node.js-Server oder jeden Prozess, der auf einem Port lauscht. Wenn ein Service startet, öffnet sich neben dem Chat ein Service-Panel mit einer Live-Vorschau.

Das Service-Panel zeigt:

- Eine Live-Vorschau des laufenden Service in einem eingebetteten Frame
- Einen **Reload**-Button, um die Vorschau zu aktualisieren
- Einen **Open**-Button, um den Service in einem neuen Browser-Tab zu öffnen

Du kannst weiter mit der KI chatten, während der Service läuft. Bitte sie, Änderungen am Code vorzunehmen, und klicke dann auf **Reload** im Panel, um das aktualisierte Ergebnis zu sehen.

## Das Service-Panel

Das Service-Panel funktioniert wie andere Seitenpanels (Drafts, Threads). Es öffnet sich automatisch, wenn ein Service startet. Wenn du es schliesst, kannst du es wieder öffnen, indem du auf **View in Pane** auf der Service-Karte im Nachrichtenverlauf klickst.

## Pausierte Services

Wenn die Sandbox nach 15 Minuten Inaktivität pausiert, zeigt die Vorschau eine Fehlerseite statt deines Service. Führe die Unterhaltung einfach fort: Die Sandbox wacht automatisch auf, sobald die KI sie wieder nutzt, und du kannst die KI bitten, den Service erneut zu starten.

## Einschränkungen

- Jede Unterhaltung hat eine Sandbox. Das Starten eines neuen Service ersetzt den vorherigen.
- Die Sandbox pausiert nach 15 Minuten Inaktivität und wird nach 30 Tagen beendet.
- Dateien in der Sandbox sind nicht dauerhaft. Lade alles herunter, was du behalten möchtest.
- Die Service-Vorschau-URL ist privat und nur für dich zugänglich, solange du angemeldet bist.

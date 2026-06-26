---
title: Kontextfenster
description: Was das Kontextfenster ist, wie es sich füllt und wie du es mit den Strategien Rollierend und Automatisch komprimieren steuerst.
order: 1
---

# Kontextfenster

Jedes KI-Modell kann nur eine begrenzte Menge Text auf einmal lesen. Diese Grenze heißt **Kontextfenster** und wird in **Tokens** gemessen (ein Token entspricht etwa vier Zeichen oder ungefähr drei Vierteln eines Wortes). Jedes Mal, wenn du eine Nachricht sendest, packt Magus die Unterhaltung und alles, was der Agent braucht, in dieses Fenster und schickt es an das Modell.

Wenn eine Unterhaltung über das Fenster hinauswächst, muss etwas weichen: Die ältesten Inhalte werden entweder verworfen oder zusammengefasst, damit die neuesten Nachrichten weiterhin hineinpassen. Die Kontextanzeige neben dem Eingabefeld zeigt dir, wie voll das Fenster ist, und lässt dich steuern, wie dieses Kürzen abläuft.

## Die Anzeige

Der kleine Ring neben dem Senden-Knopf füllt sich, während sich das Fenster füllt. Er wird gelb, wenn du dich der Grenze näherst, und rot, wenn es fast voll ist. Öffne ihn, um Folgendes zu sehen:

- **Genutzte / gesamte Tokens** und den Prozentsatz des belegten Fensters.
- Eine **Aufschlüsselung**, was Platz belegt, größtes zuerst. Typische Abschnitte:
  - **Nachrichten**: der Verlauf der Unterhaltung.
  - **Werkzeuge**: die Definitionen der Werkzeuge, die der Agent aufrufen kann.
  - **System-Prompt / Persona**: die Grundanweisungen des Agenten.
  - **Erinnerungen, Dateien, Brain**: Kontext, der abgerufen wird, um deine Nachricht zu beantworten.
  - **Freier Platz**: wie viel Platz noch übrig ist.
- **Aus dem Cache**: Tokens, die der Anbieter aus seinem Cache geliefert hat und die günstiger und schneller sind.

## Strategien

Die Strategie entscheidet, was passiert, wenn die Unterhaltung nicht mehr ins Fenster passt. Du kannst sie pro Unterhaltung über die Anzeige festlegen, und die hervorgehobene Option ist die gerade aktive (der Standard der App, wenn du keine gewählt hast).

### Rollierend (Standard)

Behält die neuesten Runden vollständig und verwirft die ältesten, während sich das Fenster füllt. Nichts wird umgeschrieben, der aktuelle Kontext bleibt also exakt. Das ist für die meisten Chats die beste Wahl, bei denen die neuesten Nachrichten am wichtigsten sind.

### Automatisch komprimieren

Wenn das Fenster voll wird, werden ältere Runden automatisch zu einer kurzen Zusammenfassung **komprimiert**, statt verworfen zu werden. Du behältst einen roten Faden der früheren Diskussion, verlierst aber etwas Detail. Das eignet sich für lange, sich entwickelnde Unterhaltungen, bei denen frühere Entscheidungen noch wichtig sind.

## Manuelle Steuerung

- **Jetzt komprimieren**: fasst die älteren Nachrichten sofort zusammen, ohne zu warten, bis das Fenster voll ist. Praktisch vor einer langen Aufgabe.
- **Leeren**: setzt das Live-Kontextfenster zurück. Ältere Nachrichten bleiben im Transkript und auf dem Bildschirm, werden aber nicht mehr an das Modell gesendet. Nutze das, um in derselben Unterhaltung neu zu starten.

Keine dieser Aktionen löscht deine Nachrichten aus dem Transkript. Sie ändern nur, was das Modell in der nächsten Runde sieht.

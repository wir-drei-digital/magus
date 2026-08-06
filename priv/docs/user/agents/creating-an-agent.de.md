---
title: Einen Agenten erstellen
description: Schritt-für-Schritt-Anleitung zum Erstellen deines eigenen Agenten
order: 2
---

# Einen Agenten erstellen

Eigene Agenten ermöglichen es dir, einen spezialisierten Assistenten zu bauen, der auf eine bestimmte Aufgabe oder einen bestimmten Workflow zugeschnitten ist. So erstellst du einen.

## Schritt 1: Zu Agents wechseln

Wechsle in den Modus **Agents** in der linken Leiste. Die Seitenleiste listet alle Agenten, die du bereits erstellt hast.

## Schritt 2: Auf Neuer Agent klicken

Klicke oben in der Seitenleiste auf **Neuer Agent**. Ein kleiner Dialog fragt nach einem Namen und optionalen Anweisungen. Klicke auf **Erstellen**, und die Konfigurationsseite des Agenten öffnet sich.

## Schritt 3: Das Profil ausfüllen

Auf der Agenten-Seite enthält der Bereich **General** das Profil:

- **Name und Beschreibung**: Gib deinem Agenten einen klaren Namen, der beschreibt, was er tut, zum Beispiel "Code-Reviewer", "Recherche-Assistent" oder "Support-Bot".
- **Bild**: Lade ein eigenes Bild hoch oder klicke auf **Generieren**, beschreibe, was du dir vorstellst, und lass Magus ein Bild für deinen Agenten erstellen. So bekommt er eine einzigartige visuelle Identität ohne Designarbeit.
- **Icon**: Alternativ ein einzelnes Emoji, das in Listen und Menüs angezeigt wird, wenn kein Bild gesetzt ist.

## Schritt 4: Die Anweisungen schreiben

Die Anweisungen sind der wichtigste Teil deines Agenten. Sie sind ein System-Prompt, der der KI sagt:

- Was ihre Rolle ist ("Du bist ein erfahrener Code-Reviewer...")
- Welchen Ton sie verwenden soll (prägnant, freundlich, förmlich usw.)
- Worauf sie sich konzentrieren oder was sie vermeiden soll
- Welches Hintergrundwissen sie im Kopf behalten soll
- Wie sie mit bestimmten Situationen umgehen soll

Schreibe das, als würdest du einem neuen Teammitglied ein Briefing geben. Sei konkret. Je klarer du den Kontext erklärst, desto zuverlässiger wird sich der Agent so verhalten, wie du es möchtest.

Ein paar Tipps:

- Beginne mit einem Satz, der die Rolle beschreibt.
- Liste alle festen Regeln auf, die der Agent immer einhalten soll.
- Gib Beispiele für gute Antworten, wenn das gewünschte Verhalten subtil ist.
- Halte die Anweisungen fokussiert: Ein Agent, der eine Sache gut macht, ist besser als einer, der alles versucht.

## Schritt 5: Standard-Chat-Modus festlegen

Wähle im Bereich **Tools** des Agenten den **Standard-Modus** für Unterhaltungen, die diesen Agenten verwenden:

- **Chat**: Normaler Unterhaltungsmodus.
- **Search**: Der Agent durchsucht das Web, bevor er antwortet.
- **Reasoning**: Der Agent nimmt sich mehr Zeit, um komplexe Probleme durchzudenken.
- **Image generation** / **Video generation**: Der Agent erzeugt Bilder oder Videos aus Beschreibungen.

Du kannst den Modus jederzeit pro Unterhaltung ändern. Der Standard ist nur der Ausgangspunkt des Agenten.

## Schritt 6: Speichern

Jeder Bereich hat einen eigenen **Speichern**-Button für Textfelder; Umschalter greifen sofort. Dein Agent ist nun einsatzbereit.

## Den Agenten verwenden

Klicke oben auf der Seite des Agenten auf **Chat starten**, um eine Unterhaltung mit ihm zu öffnen, oder erwähne ihn in einer beliebigen Unterhaltung mit **@** gefolgt von seinem Handle. Die Anweisungen, Tools und Integrationen des Agenten sind ab der ersten Nachricht aktiv.

Du kannst deinen Agenten jederzeit bearbeiten, indem du zu **Agents** zurückgehst und auf seinen Namen klickst.

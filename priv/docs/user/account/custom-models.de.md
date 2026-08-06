---
title: Eigene Modelle
description: Verbinde dein eigenes KI-Anbieter-Konto und nutze eigene Modelle
order: 3
---

# Eigene Modelle

Neben dem eingebauten Modellkatalog kannst du dein eigenes KI-Anbieter-Konto verbinden und Modelle hinzufügen, die über deinen Schlüssel laufen. Praktisch, wenn du ein eigenes API-Abo hast, ein Modell brauchst, das nicht im Katalog ist, oder die Nutzung direkt über deinen Anbieter abrechnen willst.

## Einen Anbieter hinzufügen

1. Gehe zu **Einstellungen** > **Anbieter** und füge einen Anbieter hinzu.
2. Wähle den Anbietertyp, gib ihm einen Namen und füge deinen API-Schlüssel ein. Manche Typen brauchen zusätzlich eine Basis-URL (für OpenAI-kompatible Endpunkte).
3. Magus prüft den Schlüssel mit einem Live-Check, bevor er gespeichert wird.

Dein Schlüssel wird verschlüsselt, nach dem Speichern nie wieder angezeigt und nur für deine eigenen Anfragen verwendet.

## Modelle hinzufügen

Öffne deinen Anbieter und füge ein Modell hinzu. Wo die API des Anbieters es unterstützt, listet Magus die verfügbaren Modell-IDs zur Auswahl auf; sonst gib die Modell-ID von Hand ein.

Du kannst auch vom Katalog ausgehen: Wähle bei einem Katalogmodell **Als Vorlage verwenden**, um das Formular vorauszufüllen (Name, Modell-ID, Kontextfenster, Kosten) und es an deinen Anbieter zu hängen.

## Deine Modelle verwenden

Deine Modelle erscheinen in der Modellauswahl neben dem Katalog, als deine markiert. Nur du kannst sie auswählen. Die Nutzung läuft über deinen Schlüssel und wird von deinem Anbieter abgerechnet; sie zählt nicht gegen dein Magus-Ausgabenlimit.

## Wenn ein Modell nicht mehr funktioniert

Wenn ein von dir explizit gewähltes Modell nicht mehr nutzbar ist (zum Beispiel weil du es gelöscht hast), wechselt die Unterhaltung nicht stillschweigend das Modell. Stattdessen bekommst du einen Hinweis mit dem Button **Zurücksetzen und erneut senden**, der die kaputte Auswahl löscht und deine Nachricht mit deinem Standardmodell erneut sendet.

## Grenzen

Die Anzahl an Anbietern und Modellen ist begrenzt. Beim Löschen deines Kontos werden deine Anbieter, Modelle und Schlüssel entfernt.

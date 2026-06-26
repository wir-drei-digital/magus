---
title: Wie RAG funktioniert
description: Wie Magus deine Daten nutzt, um deinen Agenten bessere Antworten zu geben
order: 1
---

# Wie RAG funktioniert

RAG steht für Retrieval-Augmented Generation. Einfach gesagt: Statt sich nur auf das zu stuetzen, womit die KI trainiert wurde, kann dein Agent deine eigenen Daten durchsuchen und relevante Informationen in seine Antworten einbeziehen.

## Was Magus mit deinen Inhalten macht

Wenn du eine Datei hochlädst, eine Datenquelle verbindest oder eine Web-Quelle hinzufuegst, verarbeitet Magus den Inhalt im Hintergrund:

1. Der Inhalt wird in kleine, überlappende Abschnitte (Chunks) aufgeteilt.
2. Jeder Abschnitt wird in eine numerische Darstellung (ein Embedding) umgewandelt, die seine Bedeutung erfasst.
3. Diese Embeddings werden gespeichert und für schnelle ähnlichkeitssuche indiziert.

Wenn du deinen Agenten etwas fragst, durchsucht er deine indizierten Inhalte nach den Abschnitten, die für deine Frage am relevantesten sind, und bezieht sie als Kontext in die Antwort ein. Das passiert automatisch.

## Was das in der Praxis bedeutet

- Dein Agent kann Fragen zu hochgeladenen Dokumenten beantworten, auch wenn die KI nie damit trainiert wurde.
- Er kann spezifische Details aus langen PDFs, Webseiten oder Logs referenzieren, statt zu raten.
- Verbundene Quellen wie RSS-Feeds oder Web-Quellen bleiben aktuell, sodass die Antworten deines Agenten aktuelle Informationen widerspiegeln.

Der Agent liest nicht jedes Mal alle Dateien. Er ruft nur die Abschnitte ab, die für deine aktuelle Frage relevant sind. Das hält die Antworten schnell und fokussiert.

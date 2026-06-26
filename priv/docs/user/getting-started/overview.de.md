---
title: Erste Schritte
description: Erste Schritte mit Magus - deinem KI-gesteuerten Assistenten
order: 1
---

# Erste Schritte mit Magus

Magus ist eine KI-gesteuerte Chat-Plattform, mit der du vielseitige Unterhaltungen mit KI-Assistenten führen kannst. Ob du Hilfe beim Schreiben, Programmieren, Recherchieren oder bei kreativen Aufgaben brauchst: Magus bietet dir eine flexible Umgebung, in der du dein KI-Erlebnis an deinen Workflow anpassen kannst.

## Kernkonzepte

Im Mittelpunkt von Magus stehen **Unterhaltungen**. Jede Unterhaltung hat ihren eigenen KI-Agenten, der den Kontext während der gesamten Interaktion beibehalt. Du kannst mehrere Unterhaltungen gleichzeitig führen, jede mit unterschiedlichen Einstellungen und Zwecken. Unterhaltungen unterstützen Markdown-Darstellung, Dateianhange und Echtzeit-Streaming-Antworten.

**Agenten** sind die KI-Persönlichkeiten hinter deinen Unterhaltungen. Jede Unterhaltung verwendet einen Standard-Agenten, aber du kannst eigene Agenten mit spezifischen System-Prompts, Tool-Konfigurationen und Integrationen erstellen. Eigene Agenten sind ideal für wiederkehrende Aufgaben, zum Beispiel ein Code-Review-Agent mit Zugriff auf deine Repository-Logs oder ein Recherche-Agent, der mit RSS-Feeds verbunden ist.

**Prompts** helfen dir, das KI-Verhalten konsistent zu steuern. System-Prompts wirken als Personas, die die Antworten des Agenten formen, während Benutzer-Prompts wiederverwendbare Vorlagen für häufige Aufgaben sind. Du kannst Prompts über die öffentliche Prompt-Bibliothek durchstöbern und teilen oder deine eigene Sammlung privat halten. Wenn du einen System-Prompt in einer Unterhaltung aktivierst, wird er jeder Nachricht vorangestellt, die der Agent sieht.

## Modelle wählen

Magus unterstützt mehrere KI-Modelle verschiedener Anbieter. Du kannst für verschiedene Aufgaben unterschiedliche Modelle wählen: eines für Chat, ein anderes für Bilderzeugung und ein weiteres für Videoerzeugung. Modelle unterscheiden sich in Fähigkeiten, Geschwindigkeit und Kosten. Du kannst dein Modell jederzeit wechseln, auch mitten in einer Unterhaltung, und jede Unterhaltung (oder jeder Thread) kann unabhängig ein anderes Modell verwenden.

## Deinen Workflow erweitern

**Threads** ermöglichen es dir, von jeder Nachricht abzuzweigen, um ein Nebenthema zu erkunden, ohne die Hauptunterhaltung zu unterbrechen. Der Thread übernimmt den Kontext bis zum Abzweigungspunkt und läuft dann unabhängig weiter. Das ist nützlich, um tief in ein Unterthema einzutauchen und dabei die Hauptunterhaltung fokussiert zu halten. Siehe [Threads](../features/threads.de.md) für Details.

**Datenquellen** verbinden externe Datenstreams wie Anwendungslogs und RSS-Feeds mit deinen Agenten. Dein Agent kann aufgenommene Daten durchsuchen, auf Fehler überwachen und dich benachrichtigen, wenn etwas Aufmerksamkeit erfordert. Siehe [Datenquellen](../knowledge/data-sources.de.md) für Details.

**Integrationen** verbinden Magus mit externen Diensten. Die REST-API-Integration ermöglicht es dir, Magus-Agenten in deine eigenen Anwendungen einzubetten und programmatisch Nachrichten zu senden und Antworten zu empfangen. Siehe [API-Integration](../integrations/api-integration.de.md) für Details.

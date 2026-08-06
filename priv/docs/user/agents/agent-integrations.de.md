---
title: Agenten-Integrationen
description: Verbinde externe Dienste mit deinem Agenten, von Telegram bis Google Kalender
order: 4
---

# Agenten-Integrationen

Integrationen verbinden deinen Agenten mit externen Diensten. Einmal verbunden, kann dein Agent über diese Dienste Nachrichten senden und empfangen, externe Daten lesen und auf Ereignisse reagieren, die außerhalb von Magus stattfinden.

## Verfügbare Integrationen

### Telegram

Verbindet deinen Agenten mit einem Telegram-Bot. Nutzer können den Bot in Telegram anschreiben und der Agent antwortet. Ideal, um deinen Agenten für Personen verfügbar zu machen, die keine Magus-Nutzer sind, oder um Antworten in einer Telegram-Gruppe zu automatisieren.

### Google Kalender

Gibt deinem Agenten Zugang zu deinem Google Kalender. Der Agent kann bevorstehende Termine lesen, beim Planen helfen und deine Verfügbarkeit berücksichtigen, wenn er Aufgaben plant.

### API

Stellt deinen Agenten als REST-Endpunkt bereit. Externe Anwendungen können Nachrichten an den Agenten senden und programmatisch Antworten empfangen. Nützlich, um Agenten-Funktionalität in deine eigenen Tools oder Workflows einzubetten. Siehe den [API-Integrationsleitfaden](../integrations/api-integration.de.md) für Details.

### RSS

Verbindet deinen Agenten mit einem oder mehreren RSS-Feeds. Der Agent kann Artikel aus diesen Feeds lesen und durchsuchen, was ihn nützlich macht, um Neuigkeiten zu verfolgen, Blogs zu lesen oder Updates von einer Website zu tracken.

### Log-Quelle

Verbindet deinen Agenten mit einem Anwendungs-Log-Stream. Der Agent kann nach Fehlern suchen, Muster erkennen und dich benachrichtigen, wenn etwas Aufmerksamkeit erfordert. Besonders nützlich für Bereitschafts- oder Incident-Response-Agenten.

## Eine Integration verbinden

1. Öffne die Seite deines Agenten.
2. Gehe zum Bereich **Integrations**.
3. Klicke auf **+ Neu verbinden**.
4. Ein Einrichtungs-Assistent öffnet sich: Wähle den Dienst und folge seinen Schritten. Die meisten erfordern, dass du Magus den Zugriff auf den externen Dienst genehmigst (z. B. Anmeldung mit Google für Kalender oder Angabe eines Bot-Tokens für Telegram).
5. Schliesse den Assistenten ab. Die Integration erscheint als verbunden in der Liste.

Jede Integration kann nach dem Verbinden zusätzliche Einstellungen auf ihrer Karte anzeigen.

## Integrationsspezifische Einstellungen

Jede verbundene Integration wird als Karte mit Anbietername und Status angezeigt. Je nach Dienst bietet die Karte:

- **Tools**: Einzelne Umschalter für die Tools, die diese Integration dem Agenten gibt. Schalte aus, was der Agent nicht nutzen soll.
- **Konfigurationsfelder**: Anbieterspezifische Einstellungen, direkt auf der Karte editierbar.

## Eine Integration trennen

1. Öffne die Seite des Agenten und gehe zum Bereich **Integrations**.
2. Suche die Integration, die du entfernen möchtest.
3. Klicke auf **Trennen** und bestätige.

Das Trennen entzieht dem Agenten sofort den Zugriff auf diesen Dienst. Deine Daten im externen Dienst bleiben davon unberührt.

## Hinweise

- Integrationen gelten pro Agent. Wenn zwei Agenten denselben externen Dienst nutzen sollen, musst du ihn bei jedem Agenten separat verbinden.
- Einige Integrationen (wie Telegram) erfordern zusätzlich, dass du die Tool-Kategorie Integrations unter **Tools** aktivierst, damit der Agent auf eingehende Ereignisse reagieren kann.

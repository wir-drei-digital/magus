---
title: Workspaces
description: Gemeinsame Team-Umgebungen für die Zusammenarbeit mit deinen Kolleginnen und Kollegen
order: 3
---

# Workspaces

> **Enterprise-Funktion.** Workspaces sind ausschliesslich in Enterprise-Plänen verfügbar. Kontaktiere [support@magus.digital](mailto:support@magus.digital) für weitere Informationen.

Ein Workspace ist eine gemeinsame Umgebung für ein Team. Er gibt allen eine gemeinsame Anlaufstelle für Unterhaltungen und macht es einfach, zusammenzuarbeiten, Kontext zu teilen und die Arbeit an einem Ort organisiert zu halten.

## Einen Workspace erstellen

1. Klicke auf deinen Kontonamen oder Avatar in der Seitenleiste, um das Konto-Menü zu öffnen.
2. Wähle **Neuer Workspace**.
3. Gib einen **Namen** für den Workspace ein (z. B. "Design-Team" oder "Engineering").
4. Wähle einen **URL-Slug**: Das ist die kurze Kennung, die in der URL des Workspaces verwendet wird (z. B. `design-team`). Slugs dürfen nur Kleinbuchstaben, Zahlen und Bindestriche enthalten.
5. Klicke auf **Workspace erstellen**.

Du bist der Owner des neuen Workspaces.

## Teammitglieder einladen

1. Gehe zur **Einstellungen**-Seite des Workspaces.
2. Wähle den Tab **Mitglieder**.
3. Gib die E-Mail-Adresse der Person ein, die du einladen möchtest.
4. Wähle ihre Rolle (siehe unten).
5. Klicke auf **Einladen**.

Eingeladene Mitglieder erhalten eine E-Mail. Haben sie bereits ein Magus-Konto, können sie die Einladung sofort annehmen und beitreten. Neue Nutzer werden zuerst aufgefordert, ein Konto zu erstellen.

## Mitglieder-Rollen

| Rolle | Kann chatten | Unterhaltungen erstellen | Mitglieder verwalten | Workspace-Einstellungen |
|-------|-------------|--------------------------|----------------------|-------------------------|
| Owner | Ja | Ja | Ja | Ja |
| Editor | Ja | Ja | Nein | Nein |
| Member | Ja | Nein | Nein | Nein |
| Observer | Nur lesen | Nein | Nein | Nein |

**Owner** hat volle Kontrolle über den Workspace, einschließlich Abrechnung, Einstellungen und Mitgliederverwaltung. Es kann mehrere Owner geben.

**Editor** kann neue Unterhaltungen erstellen und an allen Team-Unterhaltungen teilnehmen.

**Member** kann an Team-Unterhaltungen teilnehmen, aber keine neuen erstellen.

**Observer** kann Team-Unterhaltungen lesen, aber keine Nachrichten senden.

## Team-Unterhaltungen vs. persönliche Unterhaltungen

Innerhalb eines Workspaces gibt es zwei Arten von Unterhaltungen:

**Team-Unterhaltungen** sind für alle Workspace-Mitglieder sichtbar (entsprechend ihren Rollen). Sie erscheinen in der gemeinsamen Seitenleiste. Nutze diese für Diskussionen, die das gesamte Team sehen soll.

**Persönliche Unterhaltungen** sind nur für dich sichtbar. Andere Workspace-Mitglieder können sie nicht sehen. Nutze diese für individuelle Arbeit, die du von der gemeinsamen Team-Aktivität getrennt halten möchtest.

Wenn du eine neue Unterhaltung erstellst, kannst du wählen, ob sie zum Workspace (Team) oder zu dir persönlich gehört.

## Workspace-Einstellungen

Rufe die Workspace-Einstellungen über **Einstellungen** im Workspace-Menü auf. Von dort kannst du:

- Den Workspace **umbenennen** oder den URL-Slug ändern.
- **Mitglieder verwalten**: neue Mitglieder einladen, Rollen ändern oder Mitglieder entfernen.
- **Inhaberschaft übertragen** an ein anderes Mitglied.
- **Den Workspace löschen**: Das entfernt dauerhaft alle Team-Unterhaltungen und kann nicht rückgängig gemacht werden.

## Zwischen Workspaces wechseln

Wenn du mehreren Workspaces angehörst, kannst du mit dem Workspace-Selektor oben in der Seitenleiste zwischen ihnen wechseln. Jeder Workspace zeigt seine eigene Sammlung von Team-Unterhaltungen und Mitgliedern.

## Memory-Isolation über Workspaces hinweg

Jeder Workspace ist ein eigener Pool für KI-Memory. Die Benutzer-Memories des Agenten — deine geäusserten Präferenzen, Fakten, die die KI über deine Arbeitsweise aufgeschnappt hat, Dinge, an die du sie erinnern lässt — sind pro Workspace getrennt und laufen nie ineinander über.

Konkret: Bist du im Work-Workspace und sagst dem Agenten "merke dir, ich bevorzuge knappe Antworten", gilt diese Präferenz in Work-Unterhaltungen, taucht aber nicht auf, wenn du in einen Personal-Workspace oder einen anderen Workspace wechselst, dem du angehörst. Jeder Workspace baut sich sein eigenes Bild von dir auf. Deine Memories aus dem persönlichen Modus (wenn du dich in keinem Workspace befindest) sind ebenfalls ein eigener Pool.

Das gilt für alle drei Memory-Geltungsbereiche:

- **Unterhaltungs-Memories** sind von Haus aus an eine einzelne Unterhaltung gebunden, die selbst zu einem Workspace gehört.
- **Agenten-Memories** gehören zum Workspace, in dem der Custom-Agent lebt.
- **Benutzer-Memories** sind nach `(dein Benutzer, aktueller Workspace)` partitioniert. Andere Mitglieder des Workspaces können sie nicht sehen. Sie sind privat für dich, beschränkt auf diesen Workspace.

Wird ein Workspace gelöscht, wird jede Memory, die darin gelebt hat, mit ihm gelöscht. Deine anderen Workspaces und deine Memories aus dem persönlichen Modus bleiben unberührt.

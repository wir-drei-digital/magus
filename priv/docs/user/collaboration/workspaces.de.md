---
title: Workspaces
description: Gemeinsame Team-Umgebungen für die Zusammenarbeit mit deinen Kolleginnen und Kollegen
order: 3
---

# Workspaces

> **Enterprise-Funktion.** Workspaces sind ausschliesslich in Enterprise-Plänen verfügbar. Kontaktiere [support@magus.digital](mailto:support@magus.digital) für weitere Informationen.

Ein Workspace ist eine gemeinsame Umgebung für ein Team. Er gibt allen eine gemeinsame Anlaufstelle für Unterhaltungen und macht es einfach, zusammenzuarbeiten, Kontext zu teilen und die Arbeit an einem Ort organisiert zu halten.

## Einen Workspace erstellen

1. Klicke auf den Workspace-Umschalter oben in der Seitenleiste.
2. Wähle **Neuer Workspace**.
3. Gib einen **Namen** für den Workspace ein (z. B. "Design-Team" oder "Engineering").
4. Passe bei Bedarf den **URL-Slug** an: Das ist die kurze Kennung, die in der URL des Workspaces verwendet wird (z. B. `design-team`). Er wird automatisch aus dem Namen abgeleitet und darf nur Kleinbuchstaben, Zahlen und Bindestriche enthalten.
5. Klicke auf **Workspace erstellen**.

Du bist der Admin des neuen Workspaces.

## Teammitglieder einladen

1. Öffne den Workspace-Umschalter und wähle **Workspace-Einstellungen**.
2. Gehe zum Bereich **Mitglieder**.
3. Gib die E-Mail-Adresse der Person ein, die du einladen möchtest.
4. Klicke auf **Einladen**.

Eingeladene Mitglieder erhalten eine E-Mail. Haben sie bereits ein Magus-Konto, können sie die Einladung sofort annehmen und beitreten. Neue Nutzer werden zuerst aufgefordert, ein Konto zu erstellen.

## Mitglieder-Rollen

Es gibt zwei Rollen in einem Workspace:

**Admin** hat volle Kontrolle über den Workspace: Einstellungen, Mitgliederverwaltung und implizite Owner-Rechte auf jede geteilte Ressource im Workspace. Der Admin kann die Inhaberschaft an ein anderes Mitglied übertragen.

**Member** hat Standardzugriff: Sie können an geteilten Unterhaltungen teilnehmen, eigene erstellen und Ressourcen mit dem Team teilen.

(Nur-Lesen-Beteiligung gibt es auf Unterhaltungsebene: siehe die Observer-Rolle unter [Multiplayer](./multiplayer.de.md).)

## Team-Unterhaltungen vs. persönliche Unterhaltungen

Innerhalb eines Workspaces gibt es zwei Arten von Unterhaltungen:

**Geteilte Unterhaltungen** sind für alle Workspace-Mitglieder sichtbar. Sie erscheinen im Bereich **Shared** der Seitenleiste. Nutze diese für Diskussionen, die das gesamte Team sehen soll.

**Persönliche Unterhaltungen** sind nur für dich sichtbar. Andere Workspace-Mitglieder können sie nicht sehen. Nutze diese für individuelle Arbeit, die du von der gemeinsamen Team-Aktivität getrennt halten möchtest.

Neue Unterhaltungen starten persönlich. Um eine mit dem Team zu teilen, fahre in der Seitenleiste mit der Maus darüber und klicke auf den Teilen-Umschalter (**Mit Team teilen**); derselbe Umschalter macht sie wieder privat.

## Workspace-Einstellungen

Öffne den Workspace-Umschalter und wähle **Workspace-Einstellungen**. Von dort kannst du:

- Den Workspace **umbenennen** und ihn aktiv oder inaktiv schalten.
- Einen **Standard-Agenten** für den Workspace festlegen.
- **Mitglieder verwalten**: neue Mitglieder einladen, Einladungen erneut senden oder Mitglieder entfernen.
- **Inhaberschaft übertragen** an ein anderes Mitglied.
- **Den Workspace löschen**: Das entfernt dauerhaft den Workspace mit allen Unterhaltungen, Dateien, Prompts und Agenten. Zur Bestätigung tippst du den Workspace-Namen ein. Das kann nicht rückgängig gemacht werden.

Der URL-Slug wird beim Erstellen des Workspaces festgelegt und bleibt danach fix.

## Zwischen Workspaces wechseln

Wenn du mehreren Workspaces angehörst, kannst du mit dem Workspace-Umschalter oben in der Seitenleiste zwischen ihnen (und deinem persönlichen Bereich) wechseln. Jeder Workspace zeigt seine eigene Sammlung von Unterhaltungen und Mitgliedern.

## Memory-Isolation über Workspaces hinweg

Jeder Workspace ist ein eigener Pool für KI-Memory. Die Benutzer-Memories des Agenten — deine geäusserten Präferenzen, Fakten, die die KI über deine Arbeitsweise aufgeschnappt hat, Dinge, an die du sie erinnern lässt — sind pro Workspace getrennt und laufen nie ineinander über.

Konkret: Bist du im Work-Workspace und sagst dem Agenten "merke dir, ich bevorzuge knappe Antworten", gilt diese Präferenz in Work-Unterhaltungen, taucht aber nicht auf, wenn du in einen Personal-Workspace oder einen anderen Workspace wechselst, dem du angehörst. Jeder Workspace baut sich sein eigenes Bild von dir auf. Deine Memories aus dem persönlichen Modus (wenn du dich in keinem Workspace befindest) sind ebenfalls ein eigener Pool.

Das gilt für alle drei Memory-Geltungsbereiche:

- **Unterhaltungs-Memories** sind von Haus aus an eine einzelne Unterhaltung gebunden, die selbst zu einem Workspace gehört.
- **Agenten-Memories** gehören zum Workspace, in dem der Custom-Agent lebt.
- **Benutzer-Memories** sind nach `(dein Benutzer, aktueller Workspace)` partitioniert. Andere Mitglieder des Workspaces können sie nicht sehen. Sie sind privat für dich, beschränkt auf diesen Workspace.

Wird ein Workspace gelöscht, wird jede Memory, die darin gelebt hat, mit ihm gelöscht. Deine anderen Workspaces und deine Memories aus dem persönlichen Modus bleiben unberührt.

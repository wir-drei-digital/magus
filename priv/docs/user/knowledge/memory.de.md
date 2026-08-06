---
title: Memory
description: Wie der Agenten-Memory funktioniert und wie du verwaltest, was deine Agenten sich merken
order: 4
---

# Memory

Magus-Agenten können sich Dinge über Unterhaltungen hinweg merken. Memories bleiben zwischen Sitzungen erhalten, sodass dein Agent Präferenzen, Fakten und Kontext abrufen kann, ohne dass du dich jedes Mal wiederholen musst. Du kannst die KI automatisch Memories aufbauen lassen oder sie im Chat direkt bitten, sich etwas zu merken.

## Memory-Geltungsbereiche

Jede Memory hat einen **Geltungsbereich**, der steuert, welche Agenten darauf zugreifen können.

### Unterhaltungs-Geltungsbereich (Lokal)

Lokale Memories leben innerhalb einer einzelnen Unterhaltung. Der Agent nutzt sie für Projektkontext, Aufgabenlisten und Arbeitsstränge, die anderswo nicht relevant sind. Wechselst du zu einer anderen Unterhaltung, kommen sie nicht mit. Hier landet alles, was die KI von selbst aufschnappt.

### Agenten-Geltungsbereich

Memories im Agenten-Geltungsbereich sind nur für einen bestimmten Agenten sichtbar. Nutze diesen Bereich für Dinge, die für den Zweck eines Agenten relevant sind, aber nicht für andere, zum Beispiel, wenn sich ein Code-Review-Agent die Namenskonventionen deines Teams merkt.

### Benutzer-Geltungsbereich

Memories im Benutzer-Geltungsbereich sind deine persönlichen Fakten und Präferenzen (Name, Standort, Kommunikationsstil, Code-Stil und so weiter). Sie begleiten dich über Unterhaltungen hinweg.

Der Agent legt eine Benutzer-Memory nur dann an, wenn du ausdrücklich sagst, dass etwas überall gelten soll, etwa mit Formulierungen wie "immer", "generell" oder "merke dir das für alle meine Projekte". Alles andere, was ihm auffällt, bleibt in der Unterhaltung, in der es aufkam.

**Benutzer-Memories sind pro Workspace isoliert.** Gehörst du mehreren Workspaces an (zum Beispiel einem Work-Workspace und einem Personal-Workspace), hat jeder Workspace seinen eigenen Pool an Benutzer-Memories, und sie laufen nie in einen anderen über. Deine Memories aus dem persönlichen Modus (wenn du dich in keinem Workspace befindest) sind ebenfalls ein eigener Pool. Konkret heisst das:

- Wenn du im Work-Workspace sagst "merke dir, ich bevorzuge immer TypeScript", taucht diese Präferenz im Personal-Workspace nicht auf.
- Jeder Workspace kann seine eigene Version einer Memory mit demselben Namen haben (zum Beispiel kann "current_project" in verschiedenen Workspaces Verschiedenes bedeuten).
- Andere Workspace-Mitglieder sehen deine Benutzer-Memories nie. Sie sind privat für dich, beschränkt auf diesen einen Workspace.

Diese Isolation läuft automatisch. Der Agent speichert und lädt Benutzer-Memories immer im Pool der Unterhaltung, in der du dich gerade befindest.

## Memory-Arten

Jede Memory hat eine **Art**, die beschreibt, welchen Typ von Information sie enthält. Die Art hilft der KI einzuschätzen, wie viel Gewicht sie einer Memory beimessen soll.

| Art | Was sie enthält |
|-----|-----------------|
| **Allgemein** | Sammelkategorie für Informationen, die nicht woanders passen |
| **Fakt** | Verifizierte, konkrete Informationen (z. B. "Benutzer ist in Berlin ansässig") |
| **Hypothese** | Etwas, das der Agent geschlussfolgert hat, aber nicht sicher ist |
| **Beobachtung** | Ein Muster, das der Agent im Laufe der Zeit bemerkt hat |
| **Zusammenfassung** | Eine komprimierte Zusammenfassung einer längeren Unterhaltung oder eines Themas |
| **Präferenz** | Wie du Dinge erledigt haben möchtest (z. B. "Bevorzugt kurze Antworten") |
| **Ziel** | Etwas, worauf hingearbeitet wird |
| **Thema** | Ein Wissensgebiet für Recherche oder Lernen (z. B. "Farbtheorie") |
| **Gewohnheit** | Eine wiederkehrende Praxis zum Verfolgen (z. B. "30 Minuten Zeichnen täglich") |
| **Reflexion** | Eine zeitlich eingeordnete Bewertung oder Rückschau, oft verknüpft mit Zielen |

## Wie die KI Memories erstellt

Agenten legen während Unterhaltungen automatisch Memories an. Nach euren Nachrichten schaut sich die KI die Gesprächsrunden an und speichert Fakten, Entscheidungen und Kontext, die es wert sind, als unterhaltungsbezogene Memories behalten zu werden. Sie ist dabei wählerisch: Hypothetisches und Flüchtiges überspringt sie und konzentriert sich auf das, was die Unterhaltung später brauchen wird.

Jede Unterhaltung behält eine begrenzte Zahl an Memories (rund 20). Wenn neue Memories eine Unterhaltung über dieses Limit bringen, werden die am längsten nicht aktualisierten entfernt, um Platz zu machen.

Wenn du den Agenten direkt bittest, sich etwas zu merken ("Merke dir, die Deadline ist Freitag"), speichert er die Memory sofort mit seinem Memory-Werkzeug, und du siehst diesen Schritt in der Unterhaltung.

## Dein Profil

Dauerhafte Fakten über dich erreichen jede Unterhaltung über dein **Profil**: eine kurze, lebende Zusammenfassung, die Magus einmal täglich aus deinen letzten Unterhaltungs-Memories destilliert. Jeder Workspace-Pool hat sein eigenes Profil, dein persönlicher Modus ebenfalls.

Du findest das Profil unter **Einstellungen** > **Memory**. Dort kannst du außerdem:

- Das Profil ein- oder ausschalten (es setzt voraus, dass Memory eingeschaltet ist).
- Die destillierte Zusammenfassung für den ausgewählten Workspace lesen.
- Das Profil zurücksetzen. Es baut sich dann mit der Zeit aus deinen Memories neu auf.

Das Profil ersetzt nichts, was du ausdrücklich gesagt hast: Memories, die der Agent auf deine Bitte hin überall behalten soll, bleiben einzelne Einträge im Benutzer-Geltungsbereich, die du einzeln löschen kannst.

## Deine Memories verwalten

Unter **Einstellungen** > **Memory** siehst du deine Benutzer-Memories. Mit der Pool-Auswahl wechselst du zwischen deinem persönlichen Pool und deinen Workspaces. Klappe einen Eintrag auf, um Geltungsbereich und gespeicherten Inhalt zu sehen, und lösche Einträge, die du nicht mehr behalten möchtest.

Die Memories eines eigenen Agenten findest du im Agenten-Editor: Öffne **Agents**, wähle den Agenten und gehe zum Bereich **Memory**. Dort kannst du jede Memory ansehen, Zusammenfassung und Art bearbeiten oder sie löschen.

Du kannst auch einfach im Chat fragen. "Was weißt du noch über dieses Projekt?" lässt den Agenten seine Memories durchsuchen, und "Vergiss bitte, dass ich kurze Antworten bevorzuge" lässt ihn den passenden Eintrag entfernen.

## Memories vergessen

Das Löschen einer Memory ist endgültig. Es gibt für Memories keinen Papierkorb und kein Rückgängig, ein gelöschter Eintrag ist also dauerhaft weg. Offene Unterhaltungen bekommen die Löschung sofort mit.

Wird ein Workspace gelöscht, werden alle Benutzer-, Agenten- und Unterhaltungs-Memories, die in diesem Workspace gelebt haben, mit ihm gelöscht. Deine Memories aus dem persönlichen Pool und aus deinen anderen Workspaces bleiben unberührt.

Magus löscht deine Memories nie von sich aus im Hintergrund. Abgesehen vom oben beschriebenen Limit pro Unterhaltung verschwinden Memories nur, wenn du oder dein Agent sie ausdrücklich löscht.

## Memory ausschalten

Wenn du Unterhaltungen lieber ohne automatisches Memory führst, gehe zu **Einstellungen** > **Memory** und schalte das globale Memory aus. Die KI speichert dann keine neuen Memories und ruft auch keine bestehenden ab. Deine gespeicherten Memories bleiben erhalten und sind wieder da, sobald du es erneut einschaltest.

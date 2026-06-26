---
title: Memory
description: Wie der Agenten-Memory funktioniert und wie du verwaltest, was deine Agenten sich merken
order: 3
---

# Memory

Magus-Agenten können sich Dinge über Unterhaltungen hinweg merken. Memories bleiben zwischen Sitzungen erhalten, sodass dein Agent Präferenzen, Fakten und Kontext abrufen kann, ohne dass du dich jedes Mal wiederholen musst. Du kannst die KI automatisch Memories aufbauen lassen oder sie selbst über die Agenteneinstellungen hinzufügen.

## Memory-Geltungsbereiche

Jede Memory hat einen **Geltungsbereich**, der steuert, welche Agenten darauf zugreifen können.

### Unterhaltungs-Geltungsbereich (Lokal)

Lokale Memories leben innerhalb einer einzelnen Unterhaltung. Der Agent nutzt sie für Projektkontext, Aufgabenlisten und Arbeitsstränge, die anderswo nicht relevant sind. Wechselst du zu einer anderen Unterhaltung, sind sie dort nicht mehr sichtbar.

### Agenten-Geltungsbereich

Memories im Agenten-Geltungsbereich sind nur für einen bestimmten Agenten sichtbar. Nutze diesen Bereich für Dinge, die für den Zweck eines Agenten relevant sind, aber nicht für andere, zum Beispiel, wenn sich ein Code-Review-Agent die Namenskonventionen deines Teams merkt.

### Benutzer-Geltungsbereich

Memories im Benutzer-Geltungsbereich sind deine persönlichen Fakten und Präferenzen (Name, Standort, Kommunikationsstil, Code-Stil und so weiter). Sie begleiten dich über Unterhaltungen hinweg.

**Benutzer-Memories sind pro Workspace isoliert.** Gehörst du mehreren Workspaces an (zum Beispiel einem Work-Workspace und einem Personal-Workspace), hat jeder Workspace seinen eigenen Pool an Benutzer-Memories — sie laufen nie in einen anderen über. Deine Memories aus dem persönlichen Modus (wenn du dich in keinem Workspace befindest) sind ebenfalls ein eigener Pool. Konkret heisst das:

- Wenn du im Work-Workspace sagst "merke dir, ich bevorzuge TypeScript", taucht diese Präferenz im Personal-Workspace nicht auf.
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
| **Ziel** | Etwas, worauf hingearbeitet wird, mit optionaler Fortschrittsverfolgung und Fristen |
| **Thema** | Ein Wissensgebiet für Recherche oder Lernen (z. B. "Farbtheorie") |
| **Gewohnheit** | Eine wiederkehrende Praxis zum Verfolgen (z. B. "30 Minuten Zeichnen täglich") |
| **Reflexion** | Eine zeitlich eingeordnete Bewertung oder Rückschau, oft verknüpft mit Zielen |

### Strukturierte Daten

Einige Memory-Arten können zusätzliche strukturierte Informationen neben ihrem Freitext-Inhalt speichern. Zum Beispiel kann eine Ziel-Memory eine Frist und einen Fortschrittsprozentsatz verfolgen, während eine Gewohnheits-Memory einen Streak-Zähler und das letzte Abschlussdatum speichern kann. Diese strukturierten Daten werden als flexible Metadaten gespeichert, die die KI nutzt, um bei Coaching- und Planungssitzungen fundiertere Entscheidungen zu treffen.

## Konfidenzwerte

Jede Memory hat einen Konfidenzwert zwischen 0 und 1. Ein Wert von 1,0 bedeutet, dass der Agent sich bei der Memory sicher ist. Niedrigere Werte zeigen Unsicherheit an, was häufig bei Hypothesen oder Schlussfolgerungen vorkommt. Du kannst Konfidenzwerte beim manuellen Bearbeiten von Memories einsehen und anpassen.

Wenn die KI Memories abruft, um eine Antwort zu formulieren, berücksichtigt sie die Konfidenzwerte. Memories mit niedrigem Konfidenzwert werden vorsichtiger verwendet, während solche mit hohem Wert als zuverlässig gelten.

## Wie die KI Memories erstellt

Agenten können während Unterhaltungen automatisch Memories anlegen. Wenn die KI etwas Erinnernswertes bemerkt, zum Beispiel eine geäußerte Präferenz, einen nützlichen Fakt oder ein Muster, speichert sie es, ohne die Unterhaltung zu unterbrechen. Du siehst möglicherweise eine kurze Benachrichtigung, wenn das passiert.

Die KI nutzt semantisches Verständnis, um zu entscheiden, was es wert ist, gespeichert zu werden. Sie vermeidet es, jedes Detail zu speichern, und konzentriert sich stattdessen auf Informationen, die in zukünftigen Unterhaltungen wahrscheinlich nützlich sein werden.

## Memories manuell hinzufügen

Du kannst Memories direkt auf der Einstellungsseite eines Agenten hinzufügen:

1. Gehe zu **Agents** und öffne den Agenten, den du konfigurieren möchtest
2. Navigiere zum Tab **Memory**
3. Klicke auf **Memory hinzufügen**
4. Wähle einen Geltungsbereich (Agenten, Benutzer oder Lokal), eine Art, und gib den Inhalt ein
5. Setze optional einen Konfidenzwert
6. Speichern

Benutzer-Memories, die aus einer Workspace-Unterhaltung erstellt werden, gehören zum Pool dieses Workspaces. Memories aus Unterhaltungen im persönlichen Modus gehören zu deinem persönlichen Pool.

Manuell hinzugefügte Memories werden genauso behandelt wie vom Agenten erstellte. Sie erscheinen in der Suche und können während Unterhaltungen abgerufen werden.

## Memories durchsuchen

Über den Memory-Tab eines Agenten kannst du gespeicherte Memories mit Stichwörtern durchsuchen. Die Suche verwendet semantische Ähnlichkeit, sodass du keine exakten Phrasen eingeben musst. Die Ergebnisse zeigen den Inhalt der Memory, die Art, den Geltungsbereich, den Konfidenzwert sowie das Erstellungs- oder letzte Aktualisierungsdatum.

Du kannst jede Memory direkt aus den Suchergebnissen heraus bearbeiten oder löschen.

## Memories vergessen

Um eine Memory zu entfernen, findest du sie im Memory-Tab und klickst auf **Löschen**. Du kannst deinen Agenten auch während einer Unterhaltung bitten, etwas zu vergessen: "Vergiss bitte, dass ich kurze Antworten bevorzuge." Der Agent wird das Werkzeug "Memory vergessen" verwenden, um den entsprechenden Eintrag zu entfernen.

Wenn du alle Memories eines Agenten löschen möchtest, nutze die Option **Alle löschen** im Memory-Tab. Dies entfernt nur Memories im Agenten-Geltungsbereich. Memories im Benutzer- und Unterhaltungs-Geltungsbereich sind davon nicht betroffen.

Wird ein Workspace gelöscht, werden alle Benutzer-, Agenten- und Unterhaltungs-Memories, die in diesem Workspace gelebt haben, mit ihm gelöscht. Deine Memories aus dem persönlichen Pool und aus deinen anderen Workspaces bleiben unberührt.

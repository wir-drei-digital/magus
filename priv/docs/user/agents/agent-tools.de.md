---
title: Agenten-Tools & Modelle
description: Konfiguriere, welche Tools dein Agent nutzen kann und welches KI-Modell er verwendet
order: 3
---

# Agenten-Tools & Modelle

Tools geben deinem Agenten Fähigkeiten, die über einfache Textgenerierung hinausgehen. Wenn du eine Tool-Kategorie aktivierst, kann der Agent diese Tools während einer Unterhaltung nutzen, wann immer sie hilfreich sind. Du kannst auch wählen, welches KI-Modell deinen Agenten antreibt.

## Tool-Kategorien

### Web

Ermöglicht dem Agenten, das Internet zu durchsuchen und Inhalte von URLs abzurufen. Nützlich für Rechercheaufgaben, das Nachschlagen aktueller Informationen und das Lesen von Dokumentation oder Artikeln, mit denen das Modell nicht trainiert wurde.

### Code

Gibt dem Agenten Zugang zu einer Sandbox-Umgebung für die Code-Ausführung. Der Agent kann Python-Code schreiben und ausführen, Pakete installieren, Dateien lesen und schreiben sowie Dienste starten. Das ist leistungsstark für Datenanalyse, Automatisierungsskripte und alle Aufgaben, die von echter Berechnung profitieren, anstatt zu raten.

### Memory

Ermöglicht dem Agenten, Informationen über Unterhaltungen hinweg zu merken. Er kann Fakten, Präferenzen und Beobachtungen speichern und sie später abrufen, wenn sie relevant sind. Ideal für Agenten, die du regelmäßig nutzt und die dich mit der Zeit "kennenlernen" sollen.

### Files

Ermöglicht dem Agenten, Dokumente zu durchsuchen, die du hochgeladen hast. Wenn du Dateien an eine Unterhaltung anhängst oder eine Sammlung verbunden hast, kann der Agent mit diesem Tool relevante Abschnitte finden und lesen, ohne alles auf einmal zu laden.

### Skills

Gibt dem Agenten Zugang zu einer Bibliothek spezialisierter Anweisungssets für bestimmte Aufgabentypen, wie z. B. Gedichte schreiben, strukturierte Daten generieren oder einem bestimmten Workflow folgen. Der Agent lädt die relevante Skill automatisch, wenn die Aufgabe passt.

### Tasks

Ermöglicht dem Agenten, Aufgaben im integrierten Aufgaben-Manager zu erstellen und zu verwalten. Nützlich für Agenten, die dir helfen, Arbeit zu verfolgen, Projekte in Schritte aufzuteilen und den Fortschritt im Blick zu behalten.

### Integrations

Ermöglicht dem Agenten, mit externen Diensten zu interagieren, die du verbunden hast, z. B. Einträge aus einer Datenquelle zu durchsuchen oder den Status einer Integration zu prüfen. Erfordert mindestens eine konfigurierte Integration am Agenten.

## Tool-Kategorien aktivieren und deaktivieren

Im Agenten-Editor findest du einen Bereich **Tools** mit jeder Kategorie und einem Schalter. Schalte eine Kategorie ein oder aus, um dem Agenten diese Fähigkeit zu gewähren oder zu entziehen.

Als Faustregel gilt: Aktiviere nur die Tools, die der Agent wirklich braucht. Ein fokussiertes Tool-Set verringert die Chance, dass der Agent zum falschen Tool greift, und macht sein Verhalten vorhersehbarer.

## Ein Modell auswählen

Öffne im Agenten-Editor den Bereich **Modell**. Du kannst:

- **Automatisch auswählen**: Lass den Agenten für jede Aufgabe das beste Modell wählen, basierend auf dem Chat-Modus und der Frage. Das ist ein guter Standard, wenn dein Agent verschiedene Aufgaben erledigt.
- **Bestimmtes Modell**: Lege den Agenten auf ein bestimmtes Modell fest. Nutze das, wenn du konsistentes Verhalten, vorhersehbare Kosten oder ein Modell mit spezifischen Fähigkeiten benötigst (z. B. eines mit sehr langem Kontext oder starkem Reasoning).

Du kannst separate Modelle für Chat, Bildgenerierung und Videogenerierung festlegen, wenn dein Agent mehrere Modi nutzt.

## Maximale Iterationen

Die Einstellung **Maximale Iterationen** steuert, wie viele Tool-Nutzungszyklen der Agent in einer einzelnen Antwort durchlaufen darf. Jede Iteration umfasst einen Tool-Aufruf durch den Agenten und das Lesen des Ergebnisses, bevor er entscheidet, was als nächstes zu tun ist.

Ein höheres Limit ermöglicht komplexere Aufgaben (z. B. mehrere Quellen recherchieren, bevor er antwortet), bedeutet aber auch längere Wartezeiten und höheren Ressourcenverbrauch. Der Standardwert ist für die meisten Aufgaben geeignet. Erhöhe ihn nur, wenn dein Agent regelmäßig viele Schritte hintereinander ausführen muss.

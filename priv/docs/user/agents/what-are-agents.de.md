---
title: Was sind Agenten
description: Verstehe, wie Agenten deine Unterhaltungen antreiben und was eigene Agenten können
order: 1
---

# Was sind Agenten

Jede Unterhaltung in Magus wird von einem Agenten angetrieben. Der Agent ist das KI-"Gehirn" hinter der Unterhaltung: Er liest deine Nachrichten, entscheidet, wie er antwortet, führt bei Bedarf Tools aus und merkt sich Dinge über deine Chats hinweg.

## Der Standard-Agent

Wenn du eine neue Unterhaltung startest, verwendet sie den **Standard-Agenten**. Der Standard-Agent ist ein leistungsfähiger Allzweck-Assistent mit einer breiten Auswahl an verfügbaren Tools. Er funktioniert gut für die meisten alltäglichen Aufgaben: Schreiben, Recherche, Programmierhilfe, Fragen beantworten und vieles mehr.

Du musst dir über Agenten keine Gedanken machen, wenn du einfach nur chatten möchtest. Der Standard-Agent erledigt alles automatisch.

## Was einen Agenten ausmacht

Ein Agent wird durch einige wesentliche Dinge definiert:

- **Anweisungen**: Ein System-Prompt, der der KI sagt, wie sie sich verhalten soll, welchen Ton sie verwenden soll und worauf sie sich konzentrieren soll.
- **Tools**: Fähigkeiten, die der Agent nutzen kann, wie z. B. das Durchsuchen des Internets, das Ausführen von Code oder das Lesen von Dateien.
- **Integrationen**: Verbindungen zu externen Diensten, wie Telegram oder Google Kalender.
- **Modell**: Das KI-Modell, das der Agent standardmäßig verwendet (oder er wählt automatisch basierend auf der Aufgabe).
- **Wissen**: Datenquellen und Erinnerungen, auf die der Agent zurückgreifen kann.

## Eigene Agenten

Eigene Agenten ermöglichen es dir, spezialisierte Assistenten zu erstellen, die auf bestimmte Zwecke zugeschnitten sind. Anstatt eines allgemeinen Helfers könntest du zum Beispiel erstellen:

- Einen **Code-Review-Agenten**, der deine Konventionen kennt und deine Fehler-Logs lesen kann.
- Einen **Schreibassistenten** mit eingebetteten spezifischen Stilrichtlinien.
- Einen **Recherche-Agenten**, der mit RSS-Feeds und Web-Suche verbunden ist.
- Einen **Kundensupport-Agenten**, der mit deinem Telegram-Bot integriert ist.

Eigene Agenten ersparen dir, denselben Kontext jedes Mal neu erklären zu müssen. Die Anweisungen, Tools und Integrationen sind immer vorhanden und einsatzbereit.

## Wo du Agenten findest

Besuche [deine Agenten-Seite](/agents), um alle von dir erstellten Agenten zu sehen, Beispiele zu durchstöbern und neue zu erstellen. Von dort aus kannst du auch festlegen, welcher Agent in einer Unterhaltung verwendet wird.

## Einer Unterhaltung einen Agenten zuweisen

Beim Erstellen einer neuen Unterhaltung oder über das Einstellungs-Panel der Unterhaltung kannst du auswählen, welcher Agent verwendet werden soll. Die Unterhaltung nutzt dann die Anweisungen, Tools und Integrationen dieses Agenten für jede Nachricht.

## Agenten mit @ erwähnen

Du kannst einen eigenen Agenten in jede Unterhaltung einbinden, indem du **@handle** in deiner Nachricht eingibst, wobei "handle" der eindeutige Handle des Agenten ist. Wenn du zum Beispiel einen Agenten mit dem Handle `researcher` hast, routet `@researcher finde aktuelle Paper zu BEAM Concurrency` diese Nachricht direkt an den Researcher-Agenten.

So funktioniert es:

- Der erwähnte Agent empfängt die Nachricht in seiner eigenen Home-Unterhaltung, verarbeitet sie mit seinen eigenen Anweisungen und seinem Modell und sendet die Antwort zurück in deine aktuelle Unterhaltung.
- Der Hauptunterhaltungs-Agent antwortet nicht auf die Nachricht. Nur der erwähnte Agent antwortet.
- Du kannst mehrere Agenten in einer Nachricht erwähnen. Jeder erhält die Nachricht unabhängig voneinander.
- Wenn du einen Agenten erwähnst, während du dich bereits in dessen Home-Unterhaltung befindest, bearbeitet der Agent die Nachricht einfach normal (kein separater Versand nötig).

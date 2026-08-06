---
title: Agenten-Wissen & Datenschutz
description: Steuere, woran sich dein Agent erinnern und worauf er zugreifen kann, und verbinde ihn mit Sammlungen
order: 6
---

# Agenten-Wissen & Datenschutz

Du hast feinkörnige Kontrolle darüber, was dein Agent sehen und sich merken kann. Diese Seite erklärt die Datenschutz-Steuerungen für den Speicherzugriff, wie du Sammlungen verbindest und wie du die eigenen Erinnerungen eines Agenten verwaltest.

## Datenschutz-Steuerungen

Im Agenten-Editor hat der Bereich **Datenschutz** drei Schalter, die das Verhältnis des Agenten zu globalem Speicher und Dateien steuern.

### Globale Erinnerungen lesen

Wenn aktiviert, kann der Agent Erinnerungen lesen, die alle deine Unterhaltungen übergreifen. So kann er auf Dinge zurückgreifen, die du der KI in anderen Kontexten gesagt hast, wie deine Präferenzen, deinen Hintergrund oder wiederkehrende Themen.

Wenn deaktiviert, sieht der Agent nur Erinnerungen, die speziell auf ihn selbst beschränkt sind. Nutze das für spezialisierte Agenten, bei denen du nicht möchtest, dass persönlicher Kontext einfließt.

### In globale Erinnerungen schreiben

Wenn aktiviert, kann der Agent neue Erinnerungen in deinem globalen Speicher ablegen und sie so für andere Agenten und künftige Unterhaltungen verfügbar machen.

Wenn deaktiviert, werden alle Erinnerungen, die der Agent speichert, nur auf ihn selbst beschränkt. Nutze das für experimentelle oder aufgabenspezifische Agenten, bei denen du die Dinge getrennt halten möchtest.

### Auf globale Dateien zugreifen

Wenn aktiviert, kann der Agent Dateien durchsuchen, die du in allen Unterhaltungen hochgeladen hast, nicht nur Dateien, die an die aktuelle Unterhaltung angehängt sind.

Wenn deaktiviert, kann der Agent nur Dateien sehen, die direkt an die aktuelle Unterhaltung angehängt sind. Nutze das für Agenten, die sich auf das konzentrieren sollen, was du ihnen explizit zur Verfügung stellst.

## Sammlungen

Sammlungen sind kuratierte Sätze von Datenquellen, die dein Agent durchsuchen kann. Anstatt das gesamte Internet oder alle deine Dateien zu durchsuchen, gibt eine Sammlung dem Agenten einen fokussierten, relevanten Inhaltspool.

### Eine Sammlung verbinden

1. Öffne im Agenten-Editor den Bereich **Sammlungen**.
2. Klicke auf **Sammlung hinzufügen**.
3. Wähle aus deinen verfügbaren Sammlungen aus oder erstelle eine neue.
4. Speichere.

Sobald verbunden, kann der Agent diese Sammlung mit dem Files-Tool durchsuchen.

### Eine Sammlung erstellen

Sammlungen werden von der Seite [Verbundene Quellen](/settings/knowledge) aus verwaltet. Du kannst Dokumente, Webseiten und andere Datenquellen zu einer Sammlung hinzufügen, und Magus indiziert sie für die semantische Suche.

## Agentenspezifische Erinnerungen

Agenten bauen ihre eigenen Erinnerungen auf: Fakten, Beobachtungen oder Präferenzen, die sie im Kopf behalten sollen, unabhängig davon, was in einer einzelnen Unterhaltung besprochen wurde. Um einem Agenten eine Erinnerung mitzugeben, sag es ihm einfach im Chat. Zum Beispiel:

- "Merke dir, dass ich Antworten in Stichpunkten bevorzuge."
- "Merke dir, dass dieser Agent vom Engineering-Team bei Acme Corp verwendet wird."
- "Empfehle immer, die Sicherheits-Checkliste vor dem Deployment zu überprüfen."

### Eine Erinnerung bearbeiten oder entfernen

Erinnerungen werden im Bereich **Memory** des Agenten-Editors aufgelistet. Klicke auf eine Erinnerung, um Zusammenfassung und Art zu bearbeiten, oder lösche sie. Das Löschen einer Erinnerung ist endgültig.

Agentenspezifische Erinnerungen bleiben über alle Unterhaltungen hinweg bestehen, die den Agenten verwenden. Halte sie kurz und relevant: Der Agent lädt die passendsten in seinen Kontext, und eine lange Liste kann den Token-Verbrauch erhöhen.

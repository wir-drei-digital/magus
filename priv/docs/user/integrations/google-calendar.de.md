---
title: Google Calendar
description: Verbinde Google Calendar, damit dein Agent deinen Kalender verwalten kann
order: 3
---

# Google Calendar

> **Hinweis:** Die Google-Verifizierung steht noch aus. Wenn du in der Zwischenzeit Zugang zur Google Calendar-Integration benötigst, kontaktiere [support@magus.digital](mailto:support@magus.digital). Wenn du an weiteren Integrationen interessiert bist, melde dich ebenfalls bei uns.

Verbinde deinen Google Calendar mit einem Magus-Agenten, damit er deinen Terminplan einsehen, Ereignisse erstellen und deinen Kalender aktuell halten kann. Sobald die Verbindung hergestellt ist, kannst du deinen Agenten in natürlicher Sprache befragen, zum Beispiel "Was steht heute in meinem Kalender?" oder "Plane ein Treffen mit Sarah für Freitag um 14 Uhr."

## Was dein Agent tun kann

Sobald Google Calendar verbunden ist, kann dein Agent:

- **Ereignisse auflisten:** Anstehende Termine anzeigen, nach Datumsbereich filtern oder nach Titel suchen
- **Ereignisse erstellen:** Neue Termine mit Titel, Datum, Uhrzeit, Ort und optionaler Beschreibung hinzufügen
- **Ereignisse aktualisieren:** Uhrzeit, Titel, Beschreibung oder andere Details bestehender Termine ändern
- **Ereignisse löschen:** Termine aus deinem Kalender entfernen

Alle Aktionen werden in deinem Namen mit deinem Google-Konto ausgeführt. Der Agent bestätigt Änderungen, bevor er sie durchführt, es sei denn, du bittest ihn ausdrücklich, direkt fortzufahren.

## Google Calendar verbinden

1. Gehe zu **Agents** und öffne den Agenten, den du verbinden möchtest
2. Navigiere zum Tab **Integrations**
3. Klicke auf **Integration hinzufügen** und wähle **Google Calendar**
4. Klicke auf **Mit Google verbinden**
5. Google fordert dich auf, dich anzumelden (sofern noch nicht geschehen) und Magus den Zugriff auf deinen Kalender zu erlauben
6. Nach der Genehmigung wirst du zurück zu Magus weitergeleitet, und die Integration ist aktiv

Magus fordert nur die Berechtigungen an, die es benötigt: Lesen und Schreiben in deinem Kalender. Es greift nicht auf dein Gmail, Drive oder andere Google-Dienste zu.

## Zeitzonenbehandlung

Google Calendar speichert Ereignisse in der Zeitzone deines Kontos. Magus liest diese Zeitzoneneinstellung automatisch aus deinem Google-Konto aus.

Wenn du deinen Agenten bittest, etwas "um 14 Uhr" zu planen, verwendet er die Zeitzone deines Google-Kontos, es sei denn, du gibst etwas anderes an. Du kannst jederzeit konkretisieren: "Plane einen Anruf um 14 Uhr MEZ" oder "Erstelle eine Erinnerung für 9 Uhr morgens bei mir."

Dein Magus-Konto hat ebenfalls eine Zeitzoneneinstellung (unter **Account Settings**). Für beste Ergebnisse stelle sicher, dass beide Einstellungen mit deiner tatsächlichen Zeitzone übereinstimmen.

## Im Gespräch nutzen

Hier sind einige Beispiele, was du fragen kannst:

**Kalender einsehen:**
- "Was steht heute in meinem Kalender?"
- "Habe ich diese Woche irgendwelche Termine?"
- "Bin ich Donnerstagnachmittag frei?"
- "Wann ist mein nächstes Meeting mit dem Design-Team?"

**Ereignisse erstellen:**
- "Plane einen Zahnarzttermin für nächsten Dienstag um 10 Uhr"
- "Füge jeden Montag um 9 Uhr ein Team-Standup hinzu"
- "Erstelle eine Erinnerung, den Bericht Freitagmorgen zu überprüfen"

**Ereignisse aktualisieren:**
- "Verschiebe meinen Anruf um 15 Uhr auf 16 Uhr"
- "Ändere den Ort des morgigen Meetings auf Konferenzraum B"

**Ereignisse löschen:**
- "Sage mein Freitagsmittagessen ab"
- "Entferne das 14-Uhr-Meeting aus meinem Kalender"

Der Agent versteht deine Absicht durch natürliche Sprache, du brauchst keine speziellen Befehle oder Formate.

## Verbindung verwalten

Um die Google Calendar-Integration einzusehen oder zu entfernen:

1. Öffne den Tab **Integrations** deines Agenten
2. Finde die Google Calendar-Integration
3. Klicke auf **Verwalten**, um den Verbindungsstatus einzusehen, oder auf **Trennen**, um sie zu entfernen

Beim Trennen wird Magus der Zugriff auf dein Google-Konto entzogen. Bereits in deinem Kalender erstellte Ereignisse bleiben erhalten; das Trennen löscht sie nicht.

Wenn die Anmeldedaten deines Google-Kontos abgelaufen sind oder aktualisiert werden müssen, siehst du eine Warnung im Integrationspanel und eine Aufforderung, die Verbindung erneut herzustellen.

## Mehrere Kalender

Google-Konten haben oft mehrere Kalender (persönlich, Arbeit, gemeinsame Teamkalender). Standardmäßig arbeitet dein Agent mit deinem primären Kalender. Wenn du einen bestimmten Kalender verwenden möchtest, sag es ihm einfach: "Füge das zu meinem Arbeitskalender hinzu" oder "Prüfe die Verfügbarkeit in meinem Team-Events-Kalender."

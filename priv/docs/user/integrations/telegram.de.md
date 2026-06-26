---
title: Telegram
description: Verbinde einen Telegram-Bot mit deinem Agenten und chatte von überall mit ihm
order: 2
---

# Telegram

Verbinde einen Telegram-Bot mit deinem Magus-Agenten, um Nachrichten direkt in Telegram zu senden und zu empfangen. Das ist praktisch, um von unterwegs auf deine Agenten zugreifen zu können, bestimmten Personen Zugang zu gewähren oder einfache Bots für dein Team zu bauen.

## So funktioniert es

Du erstellst einen Telegram-Bot über BotFather (das offizielle Bot-Erstellungstool von Telegram) und verbindest ihn dann mit einem Magus-Agenten über das Bot-Token. Sobald die Verbindung hergestellt ist, durchläuft jede Person, die deinem Bot schreibt, einen Freigabeprozess, bevor sie mit deinem Agenten interagieren kann. Du hast die volle Kontrolle darüber, wer Zugang erhält.

## Schritt 1: Bot in Telegram erstellen

1. Öffne Telegram und suche nach **@BotFather**
2. Sende den Befehl `/newbot`
3. Folge den Anweisungen: Wähle einen Anzeigenamen und dann einen Benutzernamen (muss auf `bot` enden, z. B. `meinassistent_bot`)
4. BotFather antwortet dir mit deinem **Bot-Token**: eine lange Zeichenkette wie `123456789:ABCdefGhijKlmnopQrsTuvwxyz`

Kopiere dieses Token und bewahre es an einem sicheren Ort auf. Du benötigst es im nächsten Schritt.

## Schritt 2: Bot mit deinem Agenten verbinden

1. Gehe zu **Agents** und öffne den Agenten, den du verbinden möchtest
2. Navigiere zum Tab **Integrations**
3. Klicke auf **Integration hinzufügen** und wähle **Telegram**
4. Füge dein Bot-Token in das Feld ein
5. Speichere und aktiviere die Integration

Magus überprüft das Token und registriert einen Webhook bei Telegram. Dein Bot ist jetzt aktiv.

## Schritt 3: Das Freigabesystem

Wenn jemand deinem Bot zum ersten Mal eine Nachricht schickt, leitet Magus sie nicht sofort an deinen Agenten weiter. Stattdessen erhältst du eine Benachrichtigung, in der du entscheiden kannst, ob du den Zugang dieser Person genehmigst oder ablehnst.

**Chat genehmigen:** Klicke in der Benachrichtigung auf **Genehmigen**. Die Nachricht der Person wird an deinen Agenten weitergeleitet, und sie kann die Unterhaltung normal fortsetzen. Ihr Chat steht nun auf der Erlaubtenliste.

**Chat ablehnen:** Klicke auf **Ablehnen**. Die Person erhält eine Nachricht, dass ihre Anfrage nicht genehmigt wurde, und weitere Nachrichten von diesem Chat werden nicht mehr verarbeitet.

Dieser Freigabeschritt schützt deinen Agenten vor unerwünschtem Zugriff. Wenn dein Bot-Benutzername öffentlich ist, könnte ihn jede beliebige Person finden und versuchen, ihm zu schreiben. Das Freigabesystem stellt sicher, dass nur die Personen, denen du Zugang gewährt hast, mit deinem Agenten interagieren können.

## Erlaubte Chats verwalten

Du kannst alle genehmigten Chats in den Integrationseinstellungen einsehen und verwalten:

1. Öffne den Tab **Integrations** deines Agenten
2. Klicke auf die Telegram-Integration
3. Im Abschnitt **Erlaubte Chats** siehst du alle genehmigten Benutzer und Gruppen

Von hier aus kannst du:
- Sehen, wann jeder Chat genehmigt wurde
- Den Zugang eines Chats entziehen, indem du auf **Widerrufen** klickst

## Chat-Zugang entziehen

Um jemandem den Zugang zu entziehen, findest du seinen Chat in der Liste der erlaubten Chats und klickst auf **Widerrufen**. Künftige Nachrichten dieser Person werden stillschweigend ignoriert. Sie erhält keine Benachrichtigung darüber, dass ihr Zugang entzogen wurde, es sei denn, du teilst es ihr mit.

## Hinweise

- **Gruppenchats:** Du kannst deinen Bot zu einer Telegram-Gruppe hinzufügen. Wenn jemand aus der Gruppe dem Bot schreibt, gilt derselbe Freigabeprozess.
- **Bot-Datenschutzmodus:** Standardmäßig sehen Telegram-Bots in Gruppen nur Nachrichten, die den Bot direkt erwähnen. Das wird über die Datenschutzeinstellungen von BotFather gesteuert, nicht von Magus.
- **Token wechseln:** Wenn dein Bot-Token kompromittiert wurde, generiere ein neues in BotFather (`/mybots` → Bot auswählen → **API Token** → **Aktuelles Token widerrufen**) und aktualisiere es in den Integrationseinstellungen.
- **Verbindung trennen:** Um die Telegram-Integration vollständig zu entfernen, lösche sie im Integrations-Tab. Magus hebt die Webhook-Registrierung auf und der Bot hört auf zu antworten.

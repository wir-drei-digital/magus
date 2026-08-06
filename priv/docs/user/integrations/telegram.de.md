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
2. Gehe zum Bereich **Integrations**
3. Klicke auf **+ Neu verbinden** und wähle **Telegram**
4. Füge dein Bot-Token in das Feld ein und schliesse den Assistenten ab

Magus überprüft das Token und registriert einen Webhook bei Telegram. Dein Bot ist jetzt aktiv.

## Schritt 3: Das Freigabesystem

Wenn jemand deinem Bot zum ersten Mal eine Nachricht schickt, leitet Magus sie nicht sofort an deinen Agenten weiter. Stattdessen landet die Anfrage in einer Liste ausstehender Freigaben, die du unter **Einstellungen → Integrationen** prüfst.

**Chat genehmigen:** Klicke neben der ausstehenden Anfrage auf **Genehmigen**. Die Person kann jetzt mit deinem Agenten interagieren, und ihr Chat steht auf der Erlaubtenliste.

**Chat ablehnen:** Klicke auf **Ablehnen**. Weitere Nachrichten von diesem Chat werden nicht mehr verarbeitet.

Dieser Freigabeschritt schützt deinen Agenten vor unerwünschtem Zugriff. Wenn dein Bot-Benutzername öffentlich ist, könnte ihn jede beliebige Person finden und versuchen, ihm zu schreiben. Das Freigabesystem stellt sicher, dass nur die Personen, denen du Zugang gewährt hast, mit deinem Agenten interagieren können.

## Erlaubte Chats verwalten

Du kannst alle genehmigten Chats unter **Einstellungen → Integrationen** einsehen und verwalten. Der Abschnitt **Erlaubte Chats** der Telegram-Integration listet alle genehmigten Benutzer und Gruppen.

## Chat-Zugang entziehen

Um jemandem den Zugang zu entziehen, findest du seinen Chat in der Liste der erlaubten Chats und klickst auf den Entfernen-Button daneben. Künftige Nachrichten dieser Person werden stillschweigend ignoriert. Sie erhält keine Benachrichtigung darüber, dass ihr Zugang entzogen wurde, es sei denn, du teilst es ihr mit.

## Hinweise

- **Gruppenchats:** Du kannst deinen Bot zu einer Telegram-Gruppe hinzufügen. Wenn jemand aus der Gruppe dem Bot schreibt, gilt derselbe Freigabeprozess.
- **Bot-Datenschutzmodus:** Standardmäßig sehen Telegram-Bots in Gruppen nur Nachrichten, die den Bot direkt erwähnen. Das wird über die Datenschutzeinstellungen von BotFather gesteuert, nicht von Magus.
- **Token wechseln:** Wenn dein Bot-Token kompromittiert wurde, generiere ein neues in BotFather (`/mybots` → Bot auswählen → **API Token** → **Aktuelles Token widerrufen**) und aktualisiere es in den Integrationseinstellungen.
- **Verbindung trennen:** Um die Telegram-Integration vollständig zu entfernen, klicke im Bereich Integrations des Agenten auf **Trennen**. Magus hebt die Webhook-Registrierung auf und der Bot hört auf zu antworten.

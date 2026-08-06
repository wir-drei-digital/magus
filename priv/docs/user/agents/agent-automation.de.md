---
title: Agenten-Automatisierung
description: Richte deinen Agenten ein, um regelmäßig nach Arbeit zu suchen, ohne dass du ihn anstoßen musst
order: 5
---

# Agenten-Automatisierung

Automatisierung ermöglicht es deinem Agenten, nach eigenem Zeitplan zu arbeiten. Anstatt auf eine Nachricht von dir zu warten, wacht der Agent in regelmäßigen Abständen auf, prüft, ob es etwas zu tun gibt, und handelt bei Bedarf.

## Der Heartbeat

Der **Heartbeat** ist ein wiederkehrender Auslöser, der deinen Agenten in einem festgelegten Intervall aufweckt. Wenn der Heartbeat ausgelöst wird, führt der Agent seine Heartbeat-Anweisungen aus und entscheidet, ob er eine Aktion durchführen soll.

Stell dir das wie einen regelmäßigen Check-in vor: "Gibt es gerade etwas, was ich tun sollte?"

## Das Heartbeat-Intervall einstellen

Öffne auf der Seite des Agenten den Bereich **Automation**. Gib das **Intervall in Minuten** ein (mindestens 5), um festzulegen, wie oft der Heartbeat ausgelöst wird.

Wähle ein Intervall, das dazu passt, wie zeitkritisch die Arbeit des Agenten ist. Ein Log-Überwachungs-Agent braucht vielleicht alle 15 Minuten (Intervall 15); ein täglicher Digest-Agent braucht nur einmal am Tag (Intervall 1440).

Um den Heartbeat zu deaktivieren, schalte den Umschalter **Heartbeat aktiviert** aus. Der Agent stoppt dann die automatische Ausführung und antwortet nur noch, wenn du eine Nachricht sendest. Es gibt ausserdem einen Umschalter **Pausiert**, der den Agenten komplett anhält.

## Heartbeat-Anweisungen

Die Heartbeat-Anweisungen sagen dem Agenten, wonach er suchen und was er tun soll, wenn der Heartbeat ausgelöst wird. Schreibe sie als klare, konkrete Anleitung. Zum Beispiel:

- "Prüfe die RSS-Feeds auf Artikel über [Thema]. Wenn es neue gibt, fasse die wichtigsten zusammen und sende mir eine Nachricht."
- "Schau dir die Fehler-Logs an. Wenn es seit der letzten Prüfung neue kritische Fehler gibt, erstelle eine Aufgabe und benachrichtige mich."
- "Überprüfe meinen Kalender für morgen. Wenn ich aufeinanderfolgende Meetings habe, verfasse eine Vorwarnung für mein Team."

Gute Heartbeat-Anweisungen sind spezifisch in Bezug auf die Bedingung ("wenn es neue kritische Fehler gibt") und die Aktion ("erstelle eine Aufgabe und benachrichtige mich"). Vage Anweisungen führen zu unvorhersehbarem Verhalten.

## Sicherheitsgrenzen

Die Automatisierung umfasst Sicherheitsgrenzen, um unkontrollierte Kosten oder unerwartetes Verhalten zu verhindern.

**Max. tägliche Ausführungen**: Die maximale Anzahl von Malen, die der Heartbeat an einem Tag tatsächlich Arbeit erledigen darf, einstellbar im Bereich Automation. Auch wenn das Intervall häufiger auslösen würde, stoppt der Agent nach dieser Anzahl aktiver Ausführungen. Das schützt vor Grenzfällen, bei denen jeder Heartbeat Arbeit findet.

Zusätzlich erzwingt Magus ein Token-Budget pro Ausführung und deine Abo-Limits, damit eine automatisierte Ausführung nie unbegrenzt Kosten verursachen kann.

Stelle das Tageslimit zu Beginn konservativ ein und passe es dann an, je nachdem, wie sich der Agent verhält.

## Jetzt ausführen

Der Button **Jetzt ausführen** oben auf der Seite des Agenten startet den Heartbeat sofort, ohne auf das nächste geplante Intervall zu warten. Nutze ihn, um deine Heartbeat-Anweisungen zu testen oder eine Ausführung auf Abruf zu starten.

Eine manuelle Auslösung zählt nicht gegen das Limit der maximalen täglichen Ausführungen.

## Automatisierungsverlauf anzeigen

Jedes Aufwachen hinterlässt eine Verlaufsnachricht in der Home-Unterhaltung des Agenten, und der Bereich **Activity** des Agenten listet die letzten Ausführungen und Tool-Aufrufe. Das hilft dir, das Intervall und die Anweisungen im Laufe der Zeit zu verfeinern.

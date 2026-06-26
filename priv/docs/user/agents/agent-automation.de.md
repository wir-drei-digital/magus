---
title: Agenten-Automatisierung
description: Richte deinen Agenten ein, um regelmäßig nach Arbeit zu suchen, ohne dass du ihn anstoßen musst
order: 5
---

# Agenten-Automatisierung

Automatisierung ermöglicht es deinem Agenten, nach eigenem Zeitplan zu arbeiten. Anstatt auf eine Nachricht von dir zu warten, wacht der Agent in regelmäßigen Abständen auf, prüft, ob es etwas zu tun gibt, und handelt bei Bedarf.

## Der Heartbeat

Der **Heartbeat** ist ein wiederkehrender Auslöser, der deinen Agenten in einem festgelegten Intervall aufweckt. Wenn der Heartbeat ausgelöst wird, führt der Agent seine Triage-Anweisungen aus und entscheidet, ob er eine Aktion durchführen soll.

Stell dir das wie einen regelmäßigen Check-in vor: "Gibt es gerade etwas, was ich tun sollte?"

## Das Heartbeat-Intervall einstellen

Öffne im Agenten-Editor den Bereich **Automatisierung**. Nutze den Intervall-Selektor, um festzulegen, wie oft der Heartbeat ausgelöst wird:

- 5 Minuten
- 15 Minuten
- 30 Minuten
- 1 Stunde
- 4 Stunden
- 12 Stunden
- 24 Stunden

Wähle ein Intervall, das dazu passt, wie zeitkritisch die Arbeit des Agenten ist. Ein Log-Überwachungs-Agent braucht vielleicht alle 15 Minuten; ein täglicher Digest-Agent braucht nur einmal am Tag.

Um den Heartbeat zu deaktivieren, schalte ihn mit dem Schalter aus. Der Agent stoppt dann die automatische Ausführung und antwortet nur noch, wenn du eine Nachricht sendest.

## Triage-Anweisungen

Die Triage-Anweisungen sagen dem Agenten, wonach er suchen und was er tun soll, wenn der Heartbeat ausgelöst wird. Schreibe sie als klare, konkrete Anleitung. Zum Beispiel:

- "Prüfe die RSS-Feeds auf Artikel über [Thema]. Wenn es neue gibt, fasse die wichtigsten zusammen und sende mir eine Nachricht."
- "Schau dir die Fehler-Logs an. Wenn es seit der letzten Prüfung neue kritische Fehler gibt, erstelle eine Aufgabe und benachrichtige mich."
- "Überprüfe meinen Kalender für morgen. Wenn ich aufeinanderfolgende Meetings habe, verfasse eine Vorwarnung für mein Team."

Gute Triage-Anweisungen sind spezifisch in Bezug auf die Bedingung ("wenn es neue kritische Fehler gibt") und die Aktion ("erstelle eine Aufgabe und benachrichtige mich"). Vage Anweisungen führen zu unvorhersehbarem Verhalten.

## Sicherheitsgrenzen

Die Automatisierung umfasst Sicherheitsgrenzen, um unkontrollierte Kosten oder unerwartetes Verhalten zu verhindern.

**Max. tägliche Ausführungen**: Die maximale Anzahl von Malen, die der Heartbeat an einem Tag tatsächlich Arbeit erledigen darf. Auch wenn das Intervall häufiger auslösen würde, stoppt der Agent nach dieser Anzahl aktiver Ausführungen. Das schützt vor Grenzfällen, bei denen jeder Heartbeat Arbeit findet.

**Max. Nachrichten pro Ausführung**: Die maximale Anzahl von Nachrichten, die der Agent in einer einzelnen Heartbeat-Ausführung senden darf. Das hält einzelne Ausführungen davon ab, sich zu sehr langen Unterhaltungen auszuweiten.

**Max. Token-Verbrauch**: Ein tägliches Ausgabenlimit in Tokens. Sobald der Agent diese Anzahl von Tokens über seine automatisierten Ausführungen für den Tag verbraucht hat, pausiert der Heartbeat bis zum nächsten Tag.

Stelle diese Grenzen zu Beginn konservativ ein und passe sie dann an, je nachdem, wie sich der Agent verhält.

## Jetzt auslösen

Der Button **Jetzt auslösen** startet den Heartbeat sofort, ohne auf das nächste geplante Intervall zu warten. Nutze ihn, um deine Triage-Anweisungen zu testen oder eine Ausführung auf Abruf zu starten.

Eine manuelle Auslösung zählt nicht gegen das Limit der maximalen täglichen Ausführungen.

## Automatisierungsverlauf anzeigen

Jede Heartbeat-Ausführung erscheint im Aktivitätslog des Agenten. Du kannst sehen, wann er ausgeführt wurde, was der Agent getan hat und wie viele Tokens er verbraucht hat. Das hilft dir, das Intervall und die Triage-Anweisungen im Laufe der Zeit zu verfeinern.

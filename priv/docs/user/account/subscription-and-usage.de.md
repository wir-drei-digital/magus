---
title: Abonnement & Nutzung
description: Wie Free und Pay-as-you-go funktionieren, warum es eine Grundgebühr gibt und wie Ausgabenlimits dich schützen
order: 2
---

# Abonnement & Nutzung

Magus hat genau zwei Pläne: **Free** und **Pay-as-you-go**. Es gibt keine Stufen, keine Token-Pakete und keinen Aufschlag auf die KI-Nutzung. Pay-as-you-go ist eine kleine monatliche Grundgebühr plus deine tatsächliche KI-Nutzung, abgerechnet zum Selbstkostenpreis.

## Wohin dein Geld fliesst

```
Deine Monatsrechnung
│
├── Grundgebühr ──────────────► die Plattformkosten, die wir zahlen, damit
│                               Magus läuft: Datenbank · Hosting · Datei-
│                               speicher · Such-API · weitere API-Anbieter ·
│                               Backups · Wartung
│
└── KI-Nutzung (Selbstkosten) ► geht direkt an die KI-Anbieter —
                                ohne Aufschlag, du zahlst genau, was wir zahlen
```

**Warum eine Grundgebühr?** Magus zu betreiben kostet echtes Geld, noch bevor eine einzige KI-Anfrage läuft: Datenbank, Hosting, Dateispeicher und die externen API-Anbieter, die wir integrieren (etwa die Such-API), müssen alle bezahlt werden. Die Grundgebühr existiert, um die Plattform zum Laufen zu bringen und am Laufen zu halten — **wir verdienen daran kein Geld**. Was du bekommst, ist ein online gehosteter Dienst, den wir für dich betreuen — und den wir selbst jeden Tag nutzen. Die aktuelle Grundgebühr siehst du immer unter **Account Settings → Subscription**, und sie *sinkt* für alle, je mehr Leute mitmachen, weil sich die Fixkosten auf mehr Nutzer verteilen.

## Pläne

### Free

Mit dem kostenlosen Plan kannst du Magus ohne Kosten ausprobieren. Er enthält ein **kleines einmaliges Testguthaben — genug für rund 10 typische Chat-Nachrichten** — mit Zugang zu Standardmodellen (bis zur 2x-Kostenstufe). Es kostet uns praktisch nichts und lässt dich das volle System testen: echte Unterhaltungen, Agenten und Tools. Deine Testnutzung wird unter **Account Settings → Subscription** genau wie bezahlte Nutzung angezeigt, damit du immer siehst, wie viel übrig ist. Ist das Guthaben aufgebraucht, pausieren KI-Antworten, bis du Pay-as-you-go abonnierst.

Der Speicher ist im Free-Plan begrenzt, Premium- und kostenintensive Modelle sind nicht verfügbar. Ausgaben-Einstellungen brauchst du nicht (sie sind dort auch nicht aktiv) — im Free-Plan kannst du kein Geld ausgeben.

### Pay-as-you-go

Der bezahlte Plan ist eine Grundgebühr plus Nutzung zum Selbstkostenpreis:

- **Grundgebühr** — deckt Infrastruktur und Betrieb (siehe oben). Monatlich oder jährlich; die Jahresoption enthält einen Gratismonat.
- **KI-Nutzung** — jede Anfrage wird zum echten Anbieterpreis in CHF abgerechnet, ohne Aufschlag. Was eine Anfrage tatsächlich gekostet hat, wird transparent pro Anfrage festgehalten.
- **Was kostenlos ist** — Hintergrundarbeit (Memory-Extraktion, automatische Unterhaltungstitel, Embeddings) wird nicht verrechnet.

Zur Einordnung: Eine typische Chat-Antwort kostet rund 1 Rappen. Leichte Nutzung bleibt unter CHF 5/Monat; intensive Agenten-Nutzung kann CHF 20+ erreichen.

Das sind die einzigen beiden Pläne. Die Nutzung wird über Ausgabenlimits gesteuert, nicht über vorab bezahlte Nachrichteneinheiten.

## Ausgabenlimits

Weil die Nutzung zum Selbstkostenpreis abgerechnet wird, bestimmst du selbst, wie viel du ausgeben kannst. Die Einstellungen findest du unter **Account Settings → Subscription → Spending controls** (sie setzen ein aktives Pay-as-you-go-Abo voraus).

- **Monatliches Ausgabenlimit** — eine harte Obergrenze für deine KI-Nutzung pro Abrechnungszeitraum. Setzt du keines, gilt ein Standardlimit von CHF 20. Ist das Limit erreicht, pausieren KI-Antworten bis zum nächsten Abrechnungszeitraum oder bis du das Limit erhöhst — eine Rechnung kann dich nie überraschen.
- **Eigenes Limit wählen** — per Slider, Vorgabe-Beträgen oder eigenem Wert.
- **Frühwarnung** — hast du den Grossteil deines Limits verbraucht, warnt dich die Nutzungsanzeige, bevor etwas stoppt.
- **Kein Ausgabenlimit (optional)** — wenn du nie blockiert werden willst, kannst du das Limit ganz ausschalten. Deine Nutzung wird dann nie pausiert, und was du nutzt, wird mit deiner Monatsrechnung abgerechnet. Du zahlst genau, was du nutzt.

Hast du ein Guthaben (zum Beispiel aus einer Preisanpassung beim Jahresplan), wird es zuerst aufgebraucht, bevor etwas auf dein Limit angerechnet wird.

## Speicherlimits

Dein Plan bestimmt, wie viel Dateispeicher du hast und die maximale Grösse einzelner Uploads. Deine aktuelle Nutzung siehst du in den **Account Settings** unter **Storage**.

Wenn dein Speicher knapp wird, kannst du:
- Dateien löschen, die du nicht mehr brauchst (siehe [Dateien & Speicher](../files/files-and-storage.de.md))
- Pay-as-you-go abonnieren für höhere Speicherlimits

## Aktuelle Nutzung einsehen

1. Gehe zu **Account Settings**
2. Öffne den Abschnitt **Subscription**

Du siehst, was du in diesem Abrechnungszeitraum in CHF ausgegeben hast, dein Limit, die genutzten Tokens und dein Guthaben, falls vorhanden. Die Workbench-Seitenleiste zeigt dieselben Zahlen auf einen Blick.

## Abonnieren

1. Gehe zu **Account Settings**
2. Öffne den Abschnitt **Subscription**
3. Wähle **Subscribe monthly** oder **Subscribe annually**
4. Schliesse den Stripe-Checkout ab

Dein Abo ist sofort aktiv. Du erhältst eine Bestätigungs-E-Mail von Stripe.

## Zahlungen über Stripe verwalten

Magus verwendet Stripe zur sicheren Zahlungsabwicklung. Deine Kartendaten werden bei Stripe gespeichert, nicht bei Magus.

So verwaltest du deine Zahlungsmethode oder Rechnungsinformationen:

1. Gehe zu **Account Settings**
2. Öffne den Abschnitt **Subscription**
3. Klicke auf **Manage subscription**

Das öffnet das Stripe-Kundenportal. Dort kannst du deine Zahlungsmethode aktualisieren, Rechnungen herunterladen, deinen Rechnungsverlauf einsehen oder deinen Abrechnungszyklus wechseln.

## Kündigen

Kündige jederzeit über **Manage subscription** im Stripe-Portal. Dein Plan bleibt bis zum Ende des aktuellen Abrechnungszeitraums aktiv; offene Nutzung wird mit der letzten Rechnung verrechnet. Danach wechselt dein Konto zurück auf den Free-Plan. Deine Daten (Unterhaltungen, Agenten, Prompts) bleiben erhalten — du verlierst nichts, aber es gelten wieder die Limits des Free-Plans.

## Nutzungsanpassungen

In einigen Fällen kann Magus im Rahmen einer Aktion oder Support-Vereinbarung zusätzliche Kontingente gewähren. Diese Anpassungen werden in deinem Abschnitt **Subscription** angezeigt, sofern sie aktiv sind, und können ein Ablaufdatum haben.

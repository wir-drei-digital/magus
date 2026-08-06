---
title: Cloud-Speicher
description: Synchronisiere Google Drive, OneDrive, Dropbox und mehr in deine Wissensbasis
order: 3
---

# Cloud-Speicher

Verbinde einen Cloud-Speicher und Magus hält ausgewählte Ordner mit deiner Wissensbasis synchron. Unterhaltungen und Agenten können dann den Inhalt deiner Dateien durchsuchen.

## Unterstützte Anbieter

- **Google Drive** - mit Google anmelden
- **OneDrive / SharePoint** - mit Microsoft anmelden
- **Dropbox** - mit Dropbox anmelden
- **Infomaniak kDrive** - füge einen Manager-Token ein (erstelle ihn in deinem Infomaniak-Konto mit dem Drive-Scope)
- **Nextcloud** - Server-URL, Benutzername und ein App-Passwort
- **WebDAV** - funktioniert mit ownCloud, Koofr, Hetzner Storage Share, Fastmail Files und jedem Standard-WebDAV-Server; gib die DAV-URL ein (zum Beispiel `https://cloud.example.com/remote.php/dav/files/deinname`), Benutzername und Passwort
- **Notion** - mit Notion anmelden

Bei selbst gehosteten Installationen erscheinen die Anmelde-Anbieter erst, wenn deine Administratorin oder dein Administrator sie eingerichtet hat.

## Einen Speicher verbinden

1. Öffne **Wissen** und wähle **Quelle verbinden**.
2. Wähle einen Anbieter und melde dich an oder gib deine Zugangsdaten ein.
3. Durchsuche deine Ordner und wähle aus, welche synchronisiert werden sollen. Jeder ausgewählte Ordner wird eine Sammlung.

Die erste Synchronisierung liest alles in den ausgewählten Ordnern ein. Danach synchronisiert Magus automatisch nach Zeitplan.

## So verhält sich die Synchronisierung

- Neue und geänderte Dateien werden bei der nächsten Synchronisierung übernommen; gelöschte Dateien (und gelöschte Ordner) verschwinden auch aus deiner Wissensbasis.
- Sehr große Dateien (über 100 MB) werden übersprungen.
- Deine Dateien werden in durchsuchbare Abschnitte verarbeitet. Die Originale bleiben in deinem Speicher; Magus verändert sie nie.

## Wenn der Zugriff abläuft

Wenn ein Anbieter den Zugriff widerruft (zum Beispiel nach einer Passwortänderung), wird die Quelle pausiert und du bekommst eine Benachrichtigung. Verbinde sie unter **Wissen** mit demselben Konto neu: Deine Sammlungen und ihre Inhalte bleiben erhalten und die Synchronisierung läuft weiter.

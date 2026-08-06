---
title: Cloud Drives
description: Sync Google Drive, OneDrive, Dropbox, and more into your knowledge base
order: 3
---

# Cloud Drives

Connect a cloud drive and Magus keeps selected folders synced into your knowledge base, so conversations and agents can search the files' content.

## Supported providers

- **Google Drive** - sign in with Google
- **OneDrive / SharePoint** - sign in with Microsoft
- **Dropbox** - sign in with Dropbox
- **Infomaniak kDrive** - paste a Manager token (create one in your Infomaniak account with the Drive scope)
- **Nextcloud** - server URL, username, and an app password
- **WebDAV** - works with ownCloud, Koofr, Hetzner Storage Share, Fastmail Files, and any standard WebDAV server; enter the DAV URL (for example `https://cloud.example.com/remote.php/dav/files/yourname`), username, and password
- **Notion** - sign in with Notion

On self-hosted installations, the sign-in providers only appear once your administrator has configured them.

## Connecting a drive

1. Open **Knowledge** and choose **Connect a source**.
2. Pick a provider and sign in or enter your credentials.
3. Browse your folders and select the ones to sync. Each selected folder becomes a collection.

The first sync ingests everything in the selected folders. After that, Magus syncs automatically on a schedule.

## How syncing behaves

- New and changed files are picked up on the next sync; deleted files (and deleted folders) are removed from your knowledge base too.
- Very large files (over 100 MB) are skipped.
- Your files are processed into searchable chunks. The originals stay in your drive; Magus never modifies them.

## When access expires

If a provider revokes access (for example after a password change), the source is paused and you get a notification. Reconnect it from Knowledge with the same account: your collections and their synced content are kept and syncing resumes.

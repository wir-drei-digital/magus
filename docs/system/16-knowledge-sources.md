# Knowledge Sources

Sync files from cloud drives and external services into the RAG pipeline, so
conversations and agents can search their content.

## Providers

Users connect sources from the workbench (Knowledge, "Connect a source"). Each
source syncs one or more selected folders as collections.

| Provider | Credentials | Change detection |
|---|---|---|
| Google Drive | OAuth (operator-registered app) | Changes feed (delta) |
| OneDrive / SharePoint | OAuth (operator-registered app) | Microsoft Graph delta |
| Dropbox | OAuth (operator-registered app) | Cursor delta |
| Notion | OAuth (operator-registered app) | Incremental listing |
| Infomaniak kDrive | Pasted Manager token (Drive scope) | Full listing + etag compare |
| Nextcloud | Server URL + username + app password | Full listing + etag compare |
| Generic WebDAV (ownCloud, Koofr, Hetzner Storage Share, Fastmail, ...) | Server URL + username + password | Full listing + etag compare |
| Web | URL to crawl | Re-crawl |

OAuth tokens never reach the browser: the callback stashes them server-side and
the source is created from the session. Credentials are encrypted at rest.

## Sync behavior

- Collections sync incrementally on a schedule. Delta providers (Drive,
  OneDrive, Dropbox) apply only what changed, including deletions; the others
  re-list and compare etags.
- An expired delta cursor (for example Graph `410 Gone`) self-heals: the cursor
  is cleared and one full comparison runs in the same sync, so deletions missed
  in the gap are still caught.
- Deleting a file or folder in the drive removes it (and its chunks) from the
  knowledge base on the next sync.
- Files above 100 MB are skipped.

## Reauthorization

When a provider permanently rejects a token, the source is flagged, scheduled
syncs pause, and the owner gets a notification. Reconnecting through the wizard
heals the source in place; collections and their content are kept. Expiring
OAuth tokens are refreshed proactively before each sync (including Microsoft's
rotating refresh tokens), so this normally only happens when access was revoked
on the provider side.

## Transport policy (self-hosting)

User-supplied endpoints (WebDAV and Nextcloud base URLs) must be `https://` and
must not resolve to private or reserved network ranges. Deployments that sync a
LAN NAS over plain http opt out with
`MAGUS_ALLOW_INSECURE_KNOWLEDGE_TRANSPORT=true`.

## Operator setup: OAuth apps

Each OAuth provider needs a one-time app registration; the wizard tiles work
only once the corresponding env vars are set.

**OneDrive** (Azure portal, App registrations): multitenant + personal account
types; delegated permissions `Files.Read` and `offline_access`; redirect URI
`https://<host>/oauth/onedrive_knowledge/callback`; set `ONEDRIVE_CLIENT_ID` /
`ONEDRIVE_CLIENT_SECRET`. Work/school tenants may require admin consent.

**Dropbox** (App Console): scoped app (Full Dropbox recommended for folder
browsing); permissions `files.metadata.read` and `files.content.read`; redirect
URI `https://<host>/oauth/dropbox_knowledge/callback`; set `DROPBOX_APP_KEY` /
`DROPBOX_APP_SECRET`. Production approval lifts the development-user cap.

**Google Drive**: standard OAuth client with the Drive readonly scope; redirect
URI `https://<host>/oauth/google_drive_knowledge/callback`; set
`GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`.

**Notion**: public integration; set `NOTION_CLIENT_ID` / `NOTION_CLIENT_SECRET`.

kDrive and Nextcloud/WebDAV need no registration; users paste a token or
credentials directly.

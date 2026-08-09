# SPA Action Cards

Render the agent's `action_cards` blocks in the SPA chat transcript.

## Problem

The backend half of this feature is fully alive and has been all along:

- `Magus.Agents.Context.SystemPrompts` tells the model it may end a message with
  a fenced ` ```action_cards ` block containing a JSON object.
- `Magus.Agents.Support.ActionCardExtractor` strips that block out of the reply
  text and returns the parsed map.
- `Magus.Agents.Persistence.MessagePersistence` stores it at
  `message.metadata["action_cards"]`.
- `Magus.Agents.Tools.Tasks.RequestApproval` emits a card set directly.

The only renderer was `MagusWeb.Components.ActionCards`, deleted with the
classic LiveView workbench (core `17677f59`). Nothing in `frontend/` reads the
field.

The result in production today: the model is instructed to offer clickable
choices, those choices are stripped from its reply, and nothing renders them.
Users see an answer with its options silently removed. While the message is
still streaming they see the raw JSON block, because the streaming plugin
broadcasts unmodified accumulated text and only the persisted copy is cleaned.

## Scope

Frontend only. `message.metadata` is already `public? true` and already
reaches the SPA through `events.ts` and `api.ts`, so no resource, RPC, or
generated-client changes are needed. No new dependencies. Independent of any
in-flight deploy.

## Contract

Fixed by the system prompt, which is the document the model is actually
conditioned on:

```json
{"layout":"list","cards":[{"title":"Option A","description":"Short description","action":{"type":"send_message","payload":"The message to send"}}]}
```

- `layout`: `"list"` (vertical, lettered A/B/C) or `"grid"` (compact grid)
- `action.type`: `"send_message"` | `"prefill"` | `"navigate"`
- card fields: `title` required, `description` optional, `action` required
- 2–5 cards per block

Every value here is model-authored and therefore untrusted.

## Design

### Parser — `src/lib/chat/action-cards.ts`

All validation and URL classification lives here, in plain TypeScript, because
this is where the risk concentrates and where exhaustive tests are cheapest.

`parseActionCards(metadata)` returns a validated `{layout, cards}` or `null`.
It drops individual malformed cards rather than discarding the whole set,
ignores anything past the fifth card, and requires a non-empty `title` plus a
recognised `action.type`. An unknown `layout` falls back to `"list"`.

`classifyNavigate(payload)` returns one of:

- `{kind: 'internal', path}` — a single leading `/`, no scheme, no second
  leading slash. Rejecting `//host` matters: browsers treat it as
  protocol-relative and it would leave the origin.
- `{kind: 'external', url, host}` — parses as `http:` or `https:`.
- `{kind: 'invalid'}` — anything else, including `javascript:` and `data:`.

`stripActionCardsBlock(text)` mirrors the server's
`~r/\n?```action_cards\s*\n(.*?)\n```/s`, and additionally swallows an
*unterminated* opening fence so no JSON flashes mid-stream.

### Component — `src/lib/components/chat/action-cards.svelte`

Presentational only. Props: `cards`, `layout`, `onSend`, `onPrefill`. It holds
no state and never calls the store directly, so it can be tested in isolation.

`list` renders vertical rows with A/B/C labels, honouring what the system
prompt promises the model. `grid` renders `sm:grid-cols-2`. Visual language
follows `onboarding-cards-section.svelte` (`rounded-xl border bg-secondary/40`,
hover `border-primary/60 bg-accent/50`) so the cards read as native rather than
as a transplant from the old UI.

`send_message` and `prefill` render as `<button>`. `navigate` renders as an
`<a>`: internal targets as `{base}{path}` for client-side routing, external
targets with `target="_blank" rel="noopener noreferrer"` and a visible host
label so the destination is never hidden behind model-authored link text. An
`invalid` target renders the card as inert text with no anchor.

### Wiring

`message-item.svelte` renders the block below the message text, beside the
existing citations and attachments sections. `conversation-view.svelte` passes
the callbacks down, matching the established convention there
(`onRetry={(text) => void store.send(text)}`):

- `onSend` → `store.send(text)`
- `onPrefill` → `store.requestInsertText(text)`

`requestInsertText` is the revision-armed channel the right-rail prompt inserts
already use, and `composer.svelte` already consumes it via `$effect`. The
composer needs no change.

Streamed text passes through `stripActionCardsBlock` in the render path, so the
block is hidden while streaming and the cards appear when the message settles.

### Lifecycle

Cards stay interactive indefinitely. No spent state, no expiry, no interaction
with conversation history. This is a deliberate simplification: the component
stays a pure function of the message.

The known cost is that clicking a card from far back in the transcript sends a
reply that may read as a non-sequitur. Accepted.

## Testing

Parser tests carry the weight, since that is where untrusted input lands:

- malformed JSON, `cards` not an array, missing `title`, unknown
  `action.type`, absent `action`
- more than five cards truncates; a set of only invalid cards yields `null`
- `classifyNavigate`: `/chat/x` internal; `//evil.com`, `javascript:alert(1)`,
  `data:text/html,x` invalid; `https://example.com/a` external with host
  `example.com`
- `stripActionCardsBlock` against both a complete block and a truncated
  opening fence

Component tests assert click dispatches the right callback with the right
payload, that an invalid `navigate` renders no anchor, and that an external one
carries `rel="noopener noreferrer"`.

One test pins `stripActionCardsBlock` against the same fixture strings the
core-side `ActionCardExtractor` test uses. That duplicated regex is the single
most likely thing to drift, and a shared fixture makes drift fail loudly.

## Out of scope

- Moving the strip server-side into `StreamingPlugin` (needs stream buffering
  in a hot path; the client-side mirror is the smaller change)
- Promoting `action_cards` from `metadata` to a typed resource attribute and
  RPC field
- Any change to the system prompt contract or the set of action types

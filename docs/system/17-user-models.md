# User Models (Bring Your Own Key)

Users can connect their own AI provider accounts and add custom models
alongside the admin-managed catalog.

## User providers

In Settings, Providers, a user creates a provider (name, protocol, API key,
base URL where the protocol needs one). Keys are encrypted at rest and
write-only: they are never displayed again and are released only to their
owner's requests. Creating or updating credentials runs a live probe that
validates the key and, where the API supports it, lists the provider's model
ids for a guided picker.

Owned models appear in the model picker next to catalog models. A catalog
model can be used as a template: "clone" prefills the create-model form (name,
model id, context window, costs) targeting one of the user's providers.

## Resolution and fallback

Model selection resolves with a fixed precedence: conversation pin, then the
conversation's custom agent, then the user default, then the product default.
Owned models resolve only for their owner; other members of a shared
conversation resolve their own visible models instead.

A broken explicit selection (the picked model no longer resolves, for example
after deleting an owned model) does not silently fall back: the turn stops
with an event that names the stale selection and offers a one-click "reset and
retry", which clears the broken pin and re-sends the message (attachments
included). Auto-routed and inherited selections are unaffected.

Usage of owned models is not metered against platform spend caps; the owner
pays their provider directly.

## OpenRouter provider routing (admin)

Independent of BYOK, admins control which OpenRouter compute providers may
serve requests. The admin routing page syncs OpenRouter's provider list; only
explicitly allowed providers are sent as the `only` list, and
`data_collection: deny` is always set. US/EU/CH providers ship allowed by
default; newly synced providers start disallowed. Individual models can deny
specific providers in the admin model form. Routing applies to user turns,
media generation, agent resume turns, and background LLM calls (title
generation, memory extraction, summaries).

## Limits

Per-user caps bound the number of owned providers and models. Deleting an
account removes its providers, models, and credentials.

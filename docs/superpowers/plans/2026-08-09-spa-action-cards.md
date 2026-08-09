# SPA Action Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the agent's `action_cards` blocks in the SPA chat transcript, so the clickable choices the model is told to emit stop being silently dropped.

**Architecture:** All parsing, validation and URL classification live in one pure TypeScript module that returns a fully-resolved view model. The Svelte component is a dumb switch over that view model, so every decision is unit-testable and the component needs no render test. Wiring reuses the store callbacks and insert channel that already exist.

**Tech Stack:** SvelteKit 5 (runes), TypeScript, vitest. No new dependencies.

## Global Constraints

- Frontend only. No changes to Ash resources, RPC actions, or `ash_rpc.ts`.
- No new npm dependencies.
- The SPA has **no component render tests** and no `@testing-library/svelte`. Logic goes in pure `.ts` modules tested with vitest; components stay thin. Do not add a render-testing dependency.
- Contract is fixed by `lib/magus/agents/context/system_prompts.ex` and must not be changed: layouts `list` | `grid`; action types `send_message` | `prefill` | `navigate`; cards have required `title`, optional `description`, required `action`; 2–5 cards.
- All card content is model-authored and untrusted.
- Tabs for indentation in `frontend/` (Prettier config); run `npm run format` before committing.

---

### Task 1: Parser and view model

**Files:**
- Create: `frontend/src/lib/chat/action-cards.ts`
- Create: `frontend/src/lib/chat/action-cards.test.ts`
- Modify: `test/magus/agents/support/action_card_extractor_test.exs` (add the shared-fixture parity test)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `type CardView` — discriminated union on `kind`: `'send' | 'prefill' | 'link_internal' | 'link_external' | 'inert'`
  - `type ActionCardsView = { layout: 'list' | 'grid'; cards: CardView[] } | null`
  - `actionCardsView(metadata: unknown): ActionCardsView`
  - `stripActionCardsBlock(text: string): string`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/lib/chat/action-cards.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { actionCardsView, stripActionCardsBlock } from './action-cards';

const meta = (cards: unknown, layout: unknown = 'list') => ({
	action_cards: { layout, cards }
});

const card = (overrides: Record<string, unknown> = {}) => ({
	title: 'Option A',
	description: 'First',
	action: { type: 'send_message', payload: 'hello' },
	...overrides
});

describe('actionCardsView', () => {
	it('returns null when there is nothing to render', () => {
		expect(actionCardsView(null)).toBeNull();
		expect(actionCardsView({})).toBeNull();
		expect(actionCardsView({ action_cards: 'nope' })).toBeNull();
		expect(actionCardsView(meta('not-an-array'))).toBeNull();
		expect(actionCardsView(meta([]))).toBeNull();
	});

	it('maps send_message and prefill to their kinds with letter labels', () => {
		const view = actionCardsView(
			meta([card(), card({ action: { type: 'prefill', payload: 'draft' } })])
		);

		expect(view?.layout).toBe('list');
		expect(view?.cards).toEqual([
			{
				kind: 'send',
				label: 'A',
				title: 'Option A',
				description: 'First',
				payload: 'hello'
			},
			{
				kind: 'prefill',
				label: 'B',
				title: 'Option A',
				description: 'First',
				payload: 'draft'
			}
		]);
	});

	it('drops malformed cards but keeps the valid ones', () => {
		const view = actionCardsView(
			meta([
				card({ title: '' }),
				card({ action: undefined }),
				card({ action: { type: 'explode', payload: 'x' } }),
				'not-a-card',
				card({ title: 'Good' })
			])
		);

		expect(view?.cards).toHaveLength(1);
		expect(view?.cards[0]).toMatchObject({ kind: 'send', title: 'Good', label: 'A' });
	});

	it('returns null when every card is malformed', () => {
		expect(actionCardsView(meta([card({ title: '' }), 'nope']))).toBeNull();
	});

	it('truncates to five cards', () => {
		const view = actionCardsView(meta(Array.from({ length: 9 }, () => card())));
		expect(view?.cards).toHaveLength(5);
		expect(view?.cards.at(-1)?.label).toBe('E');
	});

	it('treats a missing description as null', () => {
		const view = actionCardsView(meta([card({ description: undefined })]));
		expect(view?.cards[0].description).toBeNull();
	});

	it('accepts grid layout and falls back to list otherwise', () => {
		expect(actionCardsView(meta([card()], 'grid'))?.layout).toBe('grid');
		expect(actionCardsView(meta([card()], 'spiral'))?.layout).toBe('list');
		expect(actionCardsView(meta([card()], undefined))?.layout).toBe('list');
	});
});

describe('actionCardsView navigate classification', () => {
	const nav = (payload: unknown) =>
		actionCardsView(meta([card({ action: { type: 'navigate', payload } })]))?.cards[0];

	it('accepts a single-slash same-origin path', () => {
		expect(nav('/chat/abc')).toMatchObject({ kind: 'link_internal', path: '/chat/abc' });
	});

	it('accepts http(s) urls and exposes the host', () => {
		expect(nav('https://example.com/a')).toMatchObject({
			kind: 'link_external',
			url: 'https://example.com/a',
			host: 'example.com'
		});
	});

	it('renders dangerous or malformed targets inert', () => {
		// Protocol-relative: the browser would leave the origin.
		expect(nav('//evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('javascript:alert(1)')).toMatchObject({ kind: 'inert' });
		expect(nav('data:text/html,<script>x</script>')).toMatchObject({ kind: 'inert' });
		expect(nav('ftp://example.com')).toMatchObject({ kind: 'inert' });
		expect(nav('chat/abc')).toMatchObject({ kind: 'inert' });
		expect(nav('')).toMatchObject({ kind: 'inert' });
		expect(nav(42)).toMatchObject({ kind: 'inert' });
	});
});

describe('stripActionCardsBlock', () => {
	it('removes a complete block and keeps surrounding prose', () => {
		const text = 'Here are options.\n```action_cards\n{"cards":[]}\n```\nTrailing.';
		expect(stripActionCardsBlock(text)).toBe('Here are options.\nTrailing.');
	});

	it('removes every complete block', () => {
		const text = 'a\n```action_cards\n{"a":1}\n```\nb\n```action_cards\n{"b":2}\n```';
		expect(stripActionCardsBlock(text)).toBe('a\nb');
	});

	it('hides an unterminated fence mid-stream', () => {
		expect(stripActionCardsBlock('Thinking.\n```action_cards\n{"cards":[{"ti')).toBe('Thinking.');
		expect(stripActionCardsBlock('Thinking.\n```action_c')).toBe('Thinking.');
	});

	it('leaves unrelated code fences alone', () => {
		const text = 'See:\n```json\n{"a":1}\n```';
		expect(stripActionCardsBlock(text)).toBe(text);
	});
});
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd frontend && npx vitest run src/lib/chat/action-cards.test.ts
```

Expected: FAIL — `Failed to resolve import "./action-cards"`.

- [ ] **Step 3: Write the implementation**

Create `frontend/src/lib/chat/action-cards.ts`:

```ts
/**
 * Action cards: the clickable choices an agent may offer at the end of a
 * message.
 *
 * The model emits a fenced ```action_cards JSON block (see
 * `lib/magus/agents/context/system_prompts.ex`). The server's
 * `Magus.Agents.Support.ActionCardExtractor` strips it from the persisted text
 * and stores the parsed map at `message.metadata.action_cards`.
 *
 * Everything here treats that map as untrusted: it is model-authored, so a
 * hallucinated or prompt-injected value must never become a live link. All
 * validation happens in this module so the Svelte component can stay a dumb
 * switch over `CardView`.
 */

export type CardView =
	| { kind: 'send'; label: string; title: string; description: string | null; payload: string }
	| { kind: 'prefill'; label: string; title: string; description: string | null; payload: string }
	| { kind: 'link_internal'; label: string; title: string; description: string | null; path: string }
	| {
			kind: 'link_external';
			label: string;
			title: string;
			description: string | null;
			url: string;
			host: string;
	  }
	| { kind: 'inert'; label: string; title: string; description: string | null };

export type ActionCardsView = { layout: 'list' | 'grid'; cards: CardView[] } | null;

const MAX_CARDS = 5;

/** A/B/C… labels, matching what the system prompt promises the model. */
const labelFor = (index: number) => String.fromCharCode(65 + index);

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): string | null {
	return typeof value === 'string' && value.trim() !== '' ? value : null;
}

/**
 * Classifies a `navigate` payload. Anything that is not an in-app path or an
 * http(s) URL is refused: `//host` is protocol-relative and would leave the
 * origin, and `javascript:`/`data:` are script-execution vectors.
 */
function classifyNavigate(
	payload: unknown
): { kind: 'internal'; path: string } | { kind: 'external'; url: string; host: string } | null {
	const raw = nonEmptyString(payload);
	if (!raw) return null;

	if (raw.startsWith('/')) {
		return raw.startsWith('//') ? null : { kind: 'internal', path: raw };
	}

	let parsed: URL;
	try {
		parsed = new URL(raw);
	} catch {
		return null;
	}

	if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;
	return { kind: 'external', url: parsed.toString(), host: parsed.host };
}

function toCardView(raw: unknown, index: number): CardView | null {
	if (!isRecord(raw)) return null;

	const title = nonEmptyString(raw.title);
	if (!title) return null;

	const action = raw.action;
	if (!isRecord(action)) return null;

	const label = labelFor(index);
	const description = nonEmptyString(raw.description);
	const base = { label, title, description };

	switch (action.type) {
		case 'send_message': {
			const payload = nonEmptyString(action.payload);
			return payload ? { kind: 'send', ...base, payload } : null;
		}
		case 'prefill': {
			const payload = nonEmptyString(action.payload);
			return payload ? { kind: 'prefill', ...base, payload } : null;
		}
		case 'navigate': {
			const target = classifyNavigate(action.payload);
			if (!target) return { kind: 'inert', ...base };
			return target.kind === 'internal'
				? { kind: 'link_internal', ...base, path: target.path }
				: { kind: 'link_external', ...base, url: target.url, host: target.host };
		}
		default:
			return null;
	}
}

/**
 * Builds the render-ready view for a message's `metadata`. Individual malformed
 * cards are dropped rather than discarding the whole set; a set with nothing
 * valid left yields `null` so callers can skip the block entirely.
 */
export function actionCardsView(metadata: unknown): ActionCardsView {
	if (!isRecord(metadata)) return null;

	const block = metadata.action_cards;
	if (!isRecord(block)) return null;
	if (!Array.isArray(block.cards)) return null;

	const cards = block.cards
		.slice(0, MAX_CARDS)
		.map((raw, index) => toCardView(raw, index))
		.filter((card): card is CardView => card !== null)
		// Re-label after filtering so labels stay contiguous (A, B, C).
		.map((card, index) => ({ ...card, label: labelFor(index) }));

	if (cards.length === 0) return null;

	return { layout: block.layout === 'grid' ? 'grid' : 'list', cards };
}

// Mirrors ActionCardExtractor's ~r/\n?```action_cards\s*\n(.*?)\n```/s.
const COMPLETE_BLOCK = /\n?```action_cards[^\n]*\n[\s\S]*?\n```/g;

// An opening fence that has not closed yet, including one whose language tag is
// still being typed ("```a" … "```action_cards"). Requiring at least the "a" is
// what keeps unrelated blocks intact: a CLOSING ``` never carries a language
// tag, so it can never match here. The cost is that a bare "```" flickers for
// one frame before the tag arrives, which is the safe direction to err.
const OPEN_FENCE = /\n?```a(?:c(?:t(?:i(?:o(?:n(?:_(?:c(?:a(?:r(?:d(?:s)?)?)?)?)?)?)?)?)?)?)?[\s\S]*$/;

/**
 * Hides the action-cards block from message text.
 *
 * The persisted text already has it stripped server-side, but `StreamingPlugin`
 * broadcasts raw accumulated text, so without this the user watches the JSON
 * stream past before it is replaced by cards. The open-fence pass covers
 * exactly that window.
 *
 * Both patterns consume their own leading newline, so no trailing whitespace is
 * left behind and text that legitimately ends in whitespace is untouched.
 */
export function stripActionCardsBlock(text: string): string {
	return text.replace(COMPLETE_BLOCK, '').replace(OPEN_FENCE, '');
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd frontend && npx vitest run src/lib/chat/action-cards.test.ts
```

Expected: PASS, all cases.

- [ ] **Step 5: Add the Elixir parity test**

Append to `test/magus/agents/support/action_card_extractor_test.exs` (inside the outer `describe` or as a new one):

```elixir
  describe "shared fixtures with the SPA stripper" do
    # These exact strings are asserted in
    # frontend/src/lib/chat/action-cards.test.ts. The SPA mirrors this regex to
    # hide the block mid-stream, so the two must agree. If you change the fence
    # format here, change it there in the same commit.
    test "complete block is stripped, surrounding prose kept" do
      text = "Here are options.\n```action_cards\n{\"cards\":[]}\n```\nTrailing."
      {clean, _cards} = Magus.Agents.Support.ActionCardExtractor.extract(text)
      assert clean == "Here are options.\nTrailing."
    end

    test "an unrelated fenced block is left alone" do
      text = "See:\n```json\n{\"a\":1}\n```"
      {clean, cards} = Magus.Agents.Support.ActionCardExtractor.extract(text)
      assert clean == text
      assert cards == nil
    end
  end
```

- [ ] **Step 6: Run both suites**

```bash
cd frontend && npx vitest run src/lib/chat/action-cards.test.ts
```

```bash
MIX_ENV=test mix test test/magus/agents/support/action_card_extractor_test.exs
```

Expected: both PASS. If the Elixir assertion on `clean` disagrees about a leading or trailing newline, adjust the **TypeScript** expectation to match Elixir — the server is the source of truth — and update the vitest fixture in the same commit.

- [ ] **Step 7: Format and commit**

```bash
cd frontend && npm run format
```

```bash
git add frontend/src/lib/chat/action-cards.ts frontend/src/lib/chat/action-cards.test.ts test/magus/agents/support/action_card_extractor_test.exs
git commit -m "feat(spa): parse and validate agent action cards"
```

---

### Task 2: Component and wiring

**Files:**
- Create: `frontend/src/lib/components/chat/action-cards.svelte`
- Modify: `frontend/src/lib/components/chat/message-item.svelte` (props block ~44-80; `<Markdown>` render ~490)
- Modify: `frontend/src/lib/components/chat/conversation-view.svelte` (the `<MessageItem>` call site, near the existing `onRetry` wiring ~423)

**Interfaces:**
- Consumes: `actionCardsView`, `stripActionCardsBlock`, `CardView`, `ActionCardsView` from `$lib/chat/action-cards` (Task 1).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Create the component**

Create `frontend/src/lib/components/chat/action-cards.svelte`:

```svelte
<script lang="ts">
	import { base } from '$app/paths';
	import { ExternalLink } from '@lucide/svelte';
	import type { ActionCardsView } from '$lib/chat/action-cards';

	// Presentational only: every decision (validation, letter labels, URL
	// safety) already happened in $lib/chat/action-cards, which is unit-tested.
	let {
		view,
		onSend,
		onPrefill
	}: {
		view: ActionCardsView;
		onSend: (text: string) => void;
		onPrefill: (text: string) => void;
	} = $props();

	const CARD_CLASS =
		'flex items-start gap-3 rounded-xl border bg-secondary/40 p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/50';
</script>

{#if view}
	<div
		class={view.layout === 'grid' ? 'mt-3 grid gap-2 sm:grid-cols-2' : 'mt-3 flex flex-col gap-2'}
		data-testid="action-cards"
		data-layout={view.layout}
	>
		{#each view.cards as card (card.label)}
			{#snippet body()}
				<span
					class="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-md bg-primary/10 font-mono text-[11px] font-medium text-primary"
					>{card.label}</span
				>
				<span class="min-w-0">
					<span class="block text-sm font-medium">{card.title}</span>
					{#if card.description}
						<span class="block text-xs text-muted-foreground">{card.description}</span>
					{/if}
					{#if card.kind === 'link_external'}
						<span class="mt-0.5 flex items-center gap-1 text-xs text-muted-foreground">
							<ExternalLink class="size-3" />{card.host}
						</span>
					{/if}
				</span>
			{/snippet}

			{#if card.kind === 'send'}
				<button type="button" class={CARD_CLASS} data-testid="action-card" onclick={() => onSend(card.payload)}>
					{@render body()}
				</button>
			{:else if card.kind === 'prefill'}
				<button
					type="button"
					class={CARD_CLASS}
					data-testid="action-card"
					onclick={() => onPrefill(card.payload)}
				>
					{@render body()}
				</button>
			{:else if card.kind === 'link_internal'}
				<a href="{base}{card.path}" class={CARD_CLASS} data-testid="action-card">
					{@render body()}
				</a>
			{:else if card.kind === 'link_external'}
				<a
					href={card.url}
					target="_blank"
					rel="noopener noreferrer"
					class={CARD_CLASS}
					data-testid="action-card"
				>
					{@render body()}
				</a>
			{:else}
				<!-- Refused navigate target: shown, never clickable. -->
				<span class="{CARD_CLASS} opacity-60" data-testid="action-card">
					{@render body()}
				</span>
			{/if}
		{/each}
	</div>
{/if}
```

- [ ] **Step 2: Wire into message-item**

In `frontend/src/lib/components/chat/message-item.svelte`:

Add to the imports beside the existing `import Markdown from './markdown.svelte';`:

```ts
	import ActionCards from './action-cards.svelte';
	import { actionCardsView, stripActionCardsBlock } from '$lib/chat/action-cards';
```

Add two props to the destructuring block (after `onCreatePrompt`) and their types (after the `onCreatePrompt` type line):

```ts
		onActionCardSend,
		onActionCardPrefill,
```

```ts
		/** Sends an action card's payload as a new user message. */
		onActionCardSend?: (text: string) => void;
		/** Inserts an action card's payload into the composer at the caret. */
		onActionCardPrefill?: (text: string) => void;
```

Add derived values beside the existing `const sources = $derived(...)`:

```ts
	const cardsView = $derived(actionCardsView(message.metadata));
	// The persisted text is already clean; this covers the streaming window,
	// where StreamingPlugin broadcasts the raw accumulated text.
	const bodyText = $derived(
		message.status === 'streaming' ? stripActionCardsBlock(message.text) : message.text
	);
```

Change the `<Markdown>` call to use the stripped text:

```svelte
			<Markdown
				text={bodyText}
				citations={message.citations}
				streaming={message.status === 'streaming'}
			/>
```

Render the cards immediately after the `{#if message.status === 'streaming'}` pulse indicator block that follows `<Markdown>`:

```svelte
			{#if onActionCardSend && onActionCardPrefill}
				<ActionCards
					view={cardsView}
					onSend={onActionCardSend}
					onPrefill={onActionCardPrefill}
				/>
			{/if}
```

- [ ] **Step 3: Wire the callbacks in conversation-view**

In `frontend/src/lib/components/chat/conversation-view.svelte`, at the `<MessageItem>` call site, beside the existing `onRetry={(text) => void store.send(text)}`:

```svelte
							onActionCardSend={(text) => void store.send(text)}
							onActionCardPrefill={(text) => store.requestInsertText(text)}
```

`requestInsertText` is the revision-armed channel the right-rail prompt inserts already use; `composer.svelte` consumes it via `$effect` and needs no change.

- [ ] **Step 4: Typecheck, lint and build**

```bash
cd frontend && npm run format && npm run check
```

Expected: no errors. `npm run check` runs `svelte-check`; a `CardView` narrowing error means a branch in the component does not match the union from Task 1.

```bash
cd frontend && npm run build
```

Expected: build succeeds.

- [ ] **Step 5: Run the frontend unit suite and the Playwright smoke tests**

```bash
cd frontend && npm run test:unit
```

Expected: PASS, including Task 1's tests.

```bash
cd frontend && npm run test:e2e
```

Expected: PASS. These are the existing smoke tests; they do not cover action cards (no live agent to emit them), but they catch a broken chat render.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/chat/action-cards.svelte frontend/src/lib/components/chat/message-item.svelte frontend/src/lib/components/chat/conversation-view.svelte
git commit -m "feat(spa): render agent action cards in the transcript"
```

---

## Verification

After both tasks:

```bash
cd frontend && npm run format:check && npm run check && npm run test:unit && npm run build
```

```bash
MIX_ENV=test mix test test/magus/agents/support/action_card_extractor_test.exs
```

All must pass. `mix precommit` is not required — no Elixir source changed, only one test file.

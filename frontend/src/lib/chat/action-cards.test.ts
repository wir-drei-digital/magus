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

	it('rejects leading-slash paths that resolve off-origin via backslash or control-character normalization', () => {
		// The URL parser normalizes backslashes to "/" for special schemes and
		// strips raw tab/newline before parsing, so these all resolve to a
		// different host despite starting with a single "/" — a naive
		// string-prefix check on "//" misses every one of them.
		expect(nav('/\\evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/\\/evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/\t/evil.com')).toMatchObject({ kind: 'inert' });
	});

	it('keeps percent-encoded sequences as ordinary same-origin path segments', () => {
		// Percent-encoding is never decoded during URL parsing, so an encoded
		// control character is just literal path text, not a host escape.
		expect(nav('/%09/evil.com')).toMatchObject({ kind: 'link_internal', path: '/%09/evil.com' });
	});
});

describe('stripActionCardsBlock', () => {
	it('removes a complete block and keeps surrounding prose', () => {
		// Shared verbatim with the Elixir parity test in
		// test/magus/agents/support/action_card_extractor_test.exs — a single
		// valid card, because ActionCardExtractor only strips text once it has
		// found at least one card that passes its own validity check.
		const text =
			'Here are options.\n```action_cards\n{"cards":[{"title":"A","action":{"type":"send_message","payload":"a"}}]}\n```\nTrailing.';
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

	it('leaves a prefix-superset tag alone, matching the Elixir extractor', () => {
		// ActionCardExtractor's regex requires only whitespace between the tag
		// and the newline, so "```action_cards_backup" is a different, unknown
		// fence to it — the block must survive untouched, not get hidden.
		const text = 'See:\n```action_cards_backup\n{"x":1}\n```\nDone.';
		expect(stripActionCardsBlock(text)).toBe(text);
	});
});

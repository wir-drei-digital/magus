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

	it('truncates to five cards after dropping invalid ones, not before', () => {
		// Leading invalid cards must not consume truncation slots: the server's
		// `valid_card?` never inspects `payload`, so payload-less cards do get
		// persisted and land here. Slicing before filtering would let five of
		// them mask every valid card behind them and render nothing at all.
		const view = actionCardsView(
			meta([
				...Array.from({ length: 5 }, () => card({ action: { type: 'send_message' } })),
				...Array.from({ length: 9 }, (_, i) => card({ title: `Valid ${i}` }))
			])
		);

		expect(view?.cards).toHaveLength(5);
		expect(view?.cards.map((c) => c.title)).toEqual([
			'Valid 0',
			'Valid 1',
			'Valid 2',
			'Valid 3',
			'Valid 4'
		]);
		expect(view?.cards.at(-1)?.label).toBe('E');
	});

	it('scans at most a bounded prefix of a huge card array', () => {
		// A hallucinated 100k-element array must not cost 100k URL parses, so
		// only the first 50 entries are inspected at all. Anything valid past
		// that prefix is intentionally unreachable.
		const view = actionCardsView(
			meta([
				...Array.from({ length: 60 }, () => card({ title: '' })),
				...Array.from({ length: 5 }, () => card({ title: 'Never reached' }))
			])
		);

		expect(view).toBeNull();
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

		// Network-path references smuggled past the origin check: a single-dot
		// (or dot-dot) segment resolves entirely inside the sentinel origin, so
		// `resolved.origin` is clean, yet the SERIALIZED path still begins with
		// "//" — which the browser reads as protocol-relative and follows
		// off-origin in the same tab. Only re-resolving the emitted string
		// catches these.
		expect(nav('/.//evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/..//evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/././/evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/.\\/evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/.\t//evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/x/../..//evil.com')).toMatchObject({ kind: 'inert' });
		expect(nav('/.//evil.com/login?next=1#x')).toMatchObject({ kind: 'inert' });
	});

	it('still accepts ordinary in-app paths after the network-path recheck', () => {
		// The recheck must not cost any legitimate target: only a path whose
		// SERIALIZED form starts with "//" is refused, and an interior "//" (or
		// a percent-encoded control character) is an ordinary same-origin
		// segment that stays exactly as the parser normalized it.
		expect(nav('/chat/abc')).toMatchObject({ kind: 'link_internal', path: '/chat/abc' });
		expect(nav('/chat/abc?a=1#b')).toMatchObject({
			kind: 'link_internal',
			path: '/chat/abc?a=1#b'
		});
		expect(nav('/%09/evil.com')).toMatchObject({ kind: 'link_internal', path: '/%09/evil.com' });
		expect(nav('/x/.//evil.com')).toMatchObject({ kind: 'link_internal', path: '/x//evil.com' });
		expect(nav('/brain/page/1')).toMatchObject({ kind: 'link_internal', path: '/brain/page/1' });
		expect(nav('/')).toMatchObject({ kind: 'link_internal', path: '/' });
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

	it('never emits an href that a browser would resolve off-origin', () => {
		// A generated sweep rather than a fixed list, because the hand-picked
		// cases have twice now missed a whole class (first backslash/control
		// normalization, then dot-segment network-path references). The oracle
		// is what a browser actually does with href={path} on a real origin,
		// which is the only property that matters.
		const app = 'https://app.example';
		const dots = ['.', '..', '%2e', '%2E', '%2e%2e', '%2E%2E', '.%2e', '%2e.'];
		const seps = ['/', '\\', '/\t', '/\n', '/\r', '\t/', '//', '/./', '/%2e/'];
		const tails = [
			'evil.com',
			'evil.com/x?a=1#b',
			'evil.com:8080',
			'user@evil.com',
			'',
			'/evil.com'
		];

		const payloads: string[] = [];
		for (const dot of dots) {
			for (const sep of seps) {
				for (const tail of tails) {
					payloads.push(`/${dot}${sep}/${tail}`);
					payloads.push(`/${dot}${sep}${tail}`);
					payloads.push(`/x/${dot}/${dot}${sep}/${tail}`);
					payloads.push(`/${dot}${sep}/${dot}${sep}/${tail}`);
				}
			}
		}

		const escaped = payloads.filter((payload) => {
			const card = nav(payload);
			if (card?.kind !== 'link_internal') return false;
			try {
				return new URL(card.path, app).origin !== app;
			} catch {
				return true;
			}
		});

		expect(escaped).toEqual([]);
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

		// Mirrors the Elixir twin's stronger fixture: a superset-tagged block
		// whose JSON *would* parse into a valid card. On that side it is the
		// only form that distinguishes "the tag didn't match" from "it matched
		// but the JSON was unusable"; asserting the same string here keeps the
		// two suites checking one shared fixture rather than two lookalikes.
		const withValidCard =
			'See:\n```action_cards_backup\n{"cards":[{"title":"A","action":{"type":"send_message","payload":"a"}}]}\n```\nDone.';
		expect(stripActionCardsBlock(withValidCard)).toBe(withValidCard);
	});
});

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
	| {
			kind: 'link_internal';
			label: string;
			title: string;
			description: string | null;
			path: string;
	  }
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

// A reserved-invalid (RFC 2606) sentinel origin used only to resolve
// candidate internal paths and check the result never left it. Never a real
// host, so it can never collide with an attacker-controlled target.
const SENTINEL_ORIGIN = 'http://internal.invalid';

/**
 * Classifies a `navigate` payload. Anything that is not an in-app path or an
 * http(s) URL is refused: `javascript:`/`data:` are script-execution vectors,
 * and anything that would leave the app's origin (`//host`, and less obvious
 * variants below) is refused too.
 */
function classifyNavigate(
	payload: unknown
): { kind: 'internal'; path: string } | { kind: 'external'; url: string; host: string } | null {
	const raw = nonEmptyString(payload);
	if (!raw) return null;

	if (raw.startsWith('/')) {
		let resolved: URL;
		try {
			resolved = new URL(raw, SENTINEL_ORIGIN);
		} catch {
			return null;
		}
		// A string-prefix check on "//" is not enough: the URL parser
		// normalizes backslashes to "/" for special schemes (http/https) and
		// strips raw tab/newline characters before parsing, so inputs like
		// "/\evil.com" or "/\t/evil.com" become network-path references that
		// resolve to a different host even though they don't start with two
		// literal slashes. Resolving against a sentinel base and checking the
		// origin catches all of those uniformly. Percent-encoded sequences
		// (e.g. "/%09/evil.com") are never decoded during parsing, so they
		// stay ordinary same-origin path segments and are not rejected here.
		if (resolved.origin !== SENTINEL_ORIGIN) return null;
		return { kind: 'internal', path: resolved.pathname + resolved.search + resolved.hash };
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

// Mirrors ActionCardExtractor's ~r/\n?```action_cards\s*\n(.*?)\n```/s exactly:
// only whitespace may follow the tag before the newline, so a prefix-superset
// tag like "```action_cards_backup" does not match either side.
const COMPLETE_BLOCK = /\n?```action_cards\s*\n[\s\S]*?\n```/g;

// An opening fence that has not closed yet, including one whose language tag is
// still being typed ("```a" … "```action_cards"). Requiring at least the "a" is
// what keeps unrelated blocks intact: a CLOSING ``` never carries a language
// tag, so it can never match here. The cost is that a bare "```" flickers for
// one frame before the tag arrives, which is the safe direction to err.
//
// The trailing (?![A-Za-z0-9_]) is a boundary check, not a change to that "a"
// floor: without it, a *closed*, differently-tagged fence whose tag merely
// starts with "action_cards" (e.g. "action_cards_backup") gets swallowed all
// the way to end-of-string too, since nothing here previously distinguished
// "still typing action_cards" from "this is a longer, unrelated identifier".
// The lookahead fails (blocking the match) whenever the next character would
// continue the identifier past what "action_cards" spells out, so growing-but-
// unterminated tags keep matching (nothing follows, or a non-word char does)
// while complete unrelated tags are left for the browser to render as-is.
const OPEN_FENCE =
	/\n?```a(?:c(?:t(?:i(?:o(?:n(?:_(?:c(?:a(?:r(?:d(?:s)?)?)?)?)?)?)?)?)?)?)?(?![A-Za-z0-9_])[\s\S]*$/;

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

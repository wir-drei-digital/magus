/**
 * Pure clone/prefill logic for the "use as template" affordance.
 *
 * A catalog (non-owned) model can seed the BYOK create-model form. The curation
 * list only carries `Magus.Chat.Model`'s PUBLIC RPC surface (`ModelSummary`),
 * which does NOT expose the internal `key`. So `modelId` cannot be the real
 * `<slug>:<suffix>` key; we derive a best-effort slug from the display `name`
 * instead and let the user correct it in the form. This is snapshot-only: no
 * linkage, no auto-tracking, edits after prefill are free.
 *
 * Costs on `ModelSummary` are pre-formatted display strings (e.g. "$3",
 * "$0.15 / 1M"), not numbers. The create form takes plain per-1M-token numbers,
 * so we extract the first parseable number. Missing / non-numeric costs and a
 * missing-or-zero context window are OMITTED rather than sent as 0.
 *
 * Transport is a single URL query param on `/settings/providers`:
 * `?template=<urlencoded json>`. `parseTemplateParam` is total: it never throws
 * on malformed JSON or garbage and returns `null` when the payload is not a
 * usable template.
 */

/** The prefill payload carried across the navigation. */
export type ModelTemplate = {
	name: string;
	modelId: string;
	contextWindow?: number;
	inputCost?: number;
	outputCost?: number;
};

/** The subset of a catalog model row `toTemplate` reads. */
export type TemplateSource = {
	name: string;
	contextWindow?: number | null;
	inputCost?: string | null;
	outputCost?: string | null;
};

/**
 * Lowercase the name, collapse every run of non-alphanumeric characters into a
 * single hyphen, and trim leading/trailing hyphens. "Claude Sonnet 4" ->
 * "claude-sonnet-4"; "Llama 3.1 (405B)" -> "llama-3-1-405b".
 */
function slugify(name: string): string {
	return name
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '');
}

/** Extract the first parseable number from a display cost string, or undefined. */
function parseCost(display: string | null | undefined): number | undefined {
	if (!display) return undefined;
	const match = display.match(/-?\d+(?:\.\d+)?/);
	if (!match) return undefined;
	const value = Number(match[0]);
	return Number.isFinite(value) ? value : undefined;
}

/** Build a prefill template from a catalog model row. */
export function toTemplate(model: TemplateSource): ModelTemplate {
	const template: ModelTemplate = {
		name: model.name,
		modelId: slugify(model.name)
	};
	// Only positive context windows are meaningful; never emit a 0.
	if (typeof model.contextWindow === 'number' && model.contextWindow > 0) {
		template.contextWindow = model.contextWindow;
	}
	const inputCost = parseCost(model.inputCost);
	if (inputCost !== undefined) template.inputCost = inputCost;
	const outputCost = parseCost(model.outputCost);
	if (outputCost !== undefined) template.outputCost = outputCost;
	return template;
}

/** Coerce an unknown value to a finite number, or undefined. */
function asNumber(value: unknown): number | undefined {
	return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

/**
 * Parse a `?template=` param into a `ModelTemplate`, or `null` when it is
 * absent, malformed, or missing the required `name` / `modelId`. Accepts both
 * a URL-encoded and an already-decoded JSON string. Total: never throws.
 */
export function parseTemplateParam(raw: string | null): ModelTemplate | null {
	if (!raw) return null;

	let decoded = raw;
	try {
		decoded = decodeURIComponent(raw);
	} catch {
		// Not percent-encoded (or malformed encoding); fall back to the raw string.
		decoded = raw;
	}

	let parsed: unknown;
	try {
		parsed = JSON.parse(decoded);
	} catch {
		return null;
	}

	if (typeof parsed !== 'object' || parsed === null) return null;
	const obj = parsed as Record<string, unknown>;
	if (typeof obj.name !== 'string' || typeof obj.modelId !== 'string') return null;

	const template: ModelTemplate = { name: obj.name, modelId: obj.modelId };
	const contextWindow = asNumber(obj.contextWindow);
	if (contextWindow !== undefined) template.contextWindow = contextWindow;
	const inputCost = asNumber(obj.inputCost);
	if (inputCost !== undefined) template.inputCost = inputCost;
	const outputCost = asNumber(obj.outputCost);
	if (outputCost !== undefined) template.outputCost = outputCost;
	return template;
}

/** Build the `/settings/providers?template=…` href that carries a template. */
export function templateHref(basePath: string, template: ModelTemplate): string {
	const param = encodeURIComponent(JSON.stringify(template));
	return `${basePath}/settings/providers?template=${param}`;
}

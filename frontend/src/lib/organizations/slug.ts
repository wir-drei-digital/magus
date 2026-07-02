/**
 * Pure, DOM-free slug helper for the create-organization form. Kept separate
 * from the Svelte layout so it stays unit-testable in the node vitest
 * environment and can be reused wherever a URL slug is derived from a name.
 *
 * The server is the source of truth for slug validity and uniqueness; this only
 * shapes a friendly default as the user types the organization name.
 */

/**
 * Derive a URL-safe slug from a free-text name: lowercase, drop anything outside
 * `[a-z0-9\s-]`, collapse whitespace runs into single hyphens, and trim leading
 * and trailing hyphens. May return an empty string when nothing survives.
 */
export function slugify(value: string): string {
	return value
		.toLowerCase()
		.replace(/[^a-z0-9\s-]/g, '')
		.replace(/\s+/g, '-')
		.replace(/^-+|-+$/g, '');
}

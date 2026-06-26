/**
 * Canonical control styling for CRUD-like forms across the SPA (agents, prompts,
 * settings, workspaces). Promoted from the per-page `FIELD` literal that the
 * settings views had each duplicated, so every text input / select / textarea
 * shares one height, border, and focus treatment.
 *
 * Pair with the `Field` component for label + hint + error, or use directly on a
 * bare control when a label wrapper is unnecessary.
 */
export const CONTROL_CLASS =
	'w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none transition-colors placeholder:text-muted-foreground focus:border-primary/60 disabled:cursor-not-allowed disabled:opacity-60';

/** `CONTROL_CLASS` plus a sensible minimum height and vertical-only resize. */
export const TEXTAREA_CLASS = `${CONTROL_CLASS} min-h-24 resize-y`;

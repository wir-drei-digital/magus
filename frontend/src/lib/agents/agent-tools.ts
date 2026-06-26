/**
 * Tool-category + pre-loaded-skill helpers for the agent editor's Tools
 * section. The agent stores *disabled* categories (empty = all enabled);
 * the UI shows per-category enable switches. Pure + tested.
 *
 * Categories mirror CustomAgent.disabled_tool_categories one_of.
 */
import type { ToolCategory } from '$lib/ash/api';

export const TOOL_CATEGORIES: { key: ToolCategory; label: string }[] = [
	{ key: 'web', label: 'Web search' },
	{ key: 'code', label: 'Code execution' },
	{ key: 'memory', label: 'Memory' },
	{ key: 'files', label: 'Files' },
	{ key: 'skills', label: 'Skills' },
	{ key: 'tasks', label: 'Tasks' },
	{ key: 'integrations', label: 'Integrations' }
];

/** A category is enabled when it's NOT in the disabled list. */
export function categoryEnabled(disabled: ToolCategory[], key: ToolCategory): boolean {
	return !disabled.includes(key);
}

/** Returns the new disabled-categories list after flipping `key` to `enabled`. */
export function toggleCategory(
	disabled: ToolCategory[],
	key: ToolCategory,
	enabled: boolean
): ToolCategory[] {
	const set = new Set<ToolCategory>(disabled);
	if (enabled) set.delete(key);
	else set.add(key);
	return [...set];
}

/** Returns the new pre-loaded-skills list after flipping `name` to `on`. */
export function toggleSkill(skills: string[], name: string, on: boolean): string[] {
	const set = new Set(skills);
	if (on) set.add(name);
	else set.delete(name);
	return [...set];
}

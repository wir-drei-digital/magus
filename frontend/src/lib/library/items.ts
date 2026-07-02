import type { PromptSummary, SkillSummary } from '$lib/ash/api';

/**
 * The Library gallery's discriminated union over the two backend resources.
 * Resources stay separate (see the 2026-07-02 library-view-merge spec); this
 * module is the single place that knows how to read both uniformly.
 */
export type LibraryItem =
	| { kind: 'prompt'; id: string; prompt: PromptSummary }
	| { kind: 'skill'; id: string; skill: SkillSummary };

export function promptItem(prompt: PromptSummary): LibraryItem {
	return { kind: 'prompt', id: prompt.id, prompt };
}

export function skillItem(skill: SkillSummary): LibraryItem {
	return { kind: 'skill', id: skill.id, skill };
}

export function itemName(item: LibraryItem): string {
	return item.kind === 'prompt' ? item.prompt.name : (item.skill.displayName ?? item.skill.name);
}

export function itemDescription(item: LibraryItem): string | null {
	return item.kind === 'prompt'
		? (item.prompt.description ?? null)
		: (item.skill.description ?? null);
}

export function itemIsFavorited(item: LibraryItem): boolean {
	return item.kind === 'prompt' ? item.prompt.isFavorited : item.skill.isFavorited;
}

/** Skills carry no use count; they sort as 0 under "Most used". */
export function itemUseCount(item: LibraryItem): number {
	return item.kind === 'prompt' ? item.prompt.useCount : 0;
}

export function itemMatches(item: LibraryItem, query: string): boolean {
	const q = query.trim().toLowerCase();
	if (!q) return true;
	const haystack =
		item.kind === 'prompt'
			? [item.prompt.name, item.prompt.description ?? '', item.prompt.content]
			: [item.skill.name, item.skill.displayName ?? '', item.skill.description ?? ''];
	return haystack.some((text) => text.toLowerCase().includes(q));
}

/**
 * Merge both kinds into the rail's four scopes.
 *  - shared: prompts shared to the workspace + skills belonging to a workspace
 *  - personal: everything else (prompt not shared / skill without workspace)
 *  - favorites: the dedicated favorite lists (overlapping with the others)
 */
export function partitionLibrary(input: {
	prompts: PromptSummary[];
	favoritePrompts: PromptSummary[];
	skills: SkillSummary[];
	favoriteSkills: SkillSummary[];
}): {
	all: LibraryItem[];
	favorites: LibraryItem[];
	shared: LibraryItem[];
	personal: LibraryItem[];
} {
	const promptItems = input.prompts.map(promptItem);
	const skillItems = input.skills.map(skillItem);

	const shared = [
		...input.prompts.filter((p) => p.isSharedToWorkspace).map(promptItem),
		...input.skills.filter((s) => s.workspaceId != null).map(skillItem)
	];
	const personal = [
		...input.prompts.filter((p) => !p.isSharedToWorkspace).map(promptItem),
		...input.skills.filter((s) => s.workspaceId == null).map(skillItem)
	];
	const favorites = [
		...input.favoritePrompts.map(promptItem),
		...input.favoriteSkills.map(skillItem)
	];

	return { all: [...promptItems, ...skillItems], favorites, shared, personal };
}

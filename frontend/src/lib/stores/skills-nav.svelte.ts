import { mySkills, workspaceSkills, type SkillSummary } from '$lib/ash/api';

/**
 * Pure partition helper, exported so it is unit-testable without instantiating
 * the store or mocking Svelte's $state.
 *
 * personal  = skills with no workspaceId (owned by the user personally).
 * workspace = skills that belong to the active workspace (workspaceId is set).
 *
 * Skills have no favorites concept, so there are only two buckets.
 */
export function partitionSkills(
	skills: SkillSummary[],
	_workspaceId: string | null
): { personal: SkillSummary[]; workspace: SkillSummary[] } {
	const personal: SkillSummary[] = [];
	const workspace: SkillSummary[] = [];

	for (const skill of skills) {
		if (skill.workspaceId == null) {
			personal.push(skill);
		} else {
			workspace.push(skill);
		}
	}

	return { personal, workspace };
}

/**
 * Skills nav lists (Personal / Workspace, mirrors PromptsNav sections).
 * Cached in a singleton so the detail view can refresh the nav after
 * create/rename/share without prop drilling.
 */
class SkillsNav {
	personal = $state<SkillSummary[]>([]);
	workspace = $state<SkillSummary[]>([]);
	loading = $state(true);
	importOpen = $state(false);

	#workspaceId: string | null = null;
	#loadKey: string | null = null;

	async load(workspaceId: string | null, force = false): Promise<void> {
		const key = workspaceId ?? '';
		// Effects re-run on unrelated session changes; identical keys are
		// no-ops unless forced (refresh after a mutation).
		if (!force && this.#loadKey === key) return;
		this.#workspaceId = workspaceId;
		this.#loadKey = key;
		this.loading = true;

		const result = await (workspaceId ? workspaceSkills(workspaceId) : mySkills());

		if (this.#loadKey !== key) return;

		if (result.success) {
			const partitioned = partitionSkills(result.data, workspaceId);
			this.personal = partitioned.personal;
			this.workspace = partitioned.workspace;
		} else {
			this.personal = [];
			this.workspace = [];
		}
		this.loading = false;
	}

	refresh(): void {
		void this.load(this.#workspaceId, true);
	}
}

export const skillsNav = new SkillsNav();

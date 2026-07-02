import {
	myFavoritePrompts,
	myFavoriteSkills,
	myPrompts,
	mySkills,
	workspacePrompts,
	workspaceSkills
} from '$lib/ash/api';
import { partitionLibrary, type LibraryItem } from '$lib/library/items';

/**
 * Library-mode nav lists (All / Favorites / Shared / Personal across prompts
 * AND skills). Replaces the old prompts-nav + skills-nav pair. Cached in a
 * singleton so detail views and dialogs can refresh the nav after mutations
 * without prop drilling.
 */
class LibraryNav {
	all = $state<LibraryItem[]>([]);
	favorites = $state<LibraryItem[]>([]);
	shared = $state<LibraryItem[]>([]);
	personal = $state<LibraryItem[]>([]);
	loading = $state(true);

	/** Global dialog flags (rendered once in nav-pane). */
	importOpen = $state(false);
	createPromptOpen = $state(false);
	createSkillOpen = $state(false);

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

		try {
			const [favoritePrompts, prompts, skills, favoriteSkills] = await Promise.all([
				myFavoritePrompts(),
				workspaceId ? workspacePrompts(workspaceId) : myPrompts(),
				workspaceId ? workspaceSkills(workspaceId) : mySkills(),
				myFavoriteSkills()
			]);

			if (this.#loadKey !== key) return;

			const partitioned = partitionLibrary({
				prompts: prompts.success ? prompts.data : [],
				favoritePrompts: favoritePrompts.success ? favoritePrompts.data : [],
				skills: skills.success ? skills.data : [],
				favoriteSkills: favoriteSkills.success ? favoriteSkills.data : []
			});

			this.all = partitioned.all;
			this.favorites = partitioned.favorites;
			this.shared = partitioned.shared;
			this.personal = partitioned.personal;
		} finally {
			if (this.#loadKey === key) this.loading = false;
		}
	}

	refresh(): void {
		void this.load(this.#workspaceId, true);
	}
}

export const libraryNav = new LibraryNav();

import { myFavoritePrompts, myPrompts, workspacePrompts, type PromptSummary } from '$lib/ash/api';

/**
 * Prompts-mode nav lists (Favorites / Shared / Personal — mirrors the classic
 * PromptsModeNav sections). Cached in a store so the detail view can refresh
 * the nav after create/rename/favorite without prop drilling.
 */
class PromptsNav {
	favorites = $state<PromptSummary[]>([]);
	shared = $state<PromptSummary[]>([]);
	personal = $state<PromptSummary[]>([]);
	loading = $state(true);

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
			const [favoritesResult, listResult] = await Promise.all([
				myFavoritePrompts(),
				workspaceId ? workspacePrompts(workspaceId) : myPrompts()
			]);

			if (this.#loadKey !== key) return;

			this.favorites = favoritesResult.success ? favoritesResult.data : [];
			if (listResult.success) {
				this.shared = listResult.data.filter((prompt) => prompt.isSharedToWorkspace);
				this.personal = listResult.data.filter((prompt) => !prompt.isSharedToWorkspace);
			} else {
				this.shared = [];
				this.personal = [];
			}
		} finally {
			if (this.#loadKey === key) this.loading = false;
		}
	}

	refresh(): void {
		void this.load(this.#workspaceId, true);
	}
}

export const promptsNav = new PromptsNav();

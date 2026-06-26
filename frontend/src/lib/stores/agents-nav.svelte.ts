import { myAgents, workspaceAgents, type AgentSummary } from '$lib/ash/api';

/** Agents-mode nav lists (mirrors the classic AgentsModeNav split). */
class AgentsNav {
	shared = $state<AgentSummary[]>([]);
	personal = $state<AgentSummary[]>([]);
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

		if (workspaceId) {
			// Classic splits the WORKSPACE's agents by share state; agents from
			// other workspaces or the personal library never show here.
			const result = await workspaceAgents(workspaceId);
			if (this.#loadKey !== key) return;
			const agents = result.success ? result.data : [];
			this.shared = agents.filter((agent) => agent.isSharedToWorkspace);
			this.personal = agents.filter((agent) => !agent.isSharedToWorkspace);
		} else {
			const result = await myAgents();
			if (this.#loadKey !== key) return;
			this.shared = [];
			// Personal mode shows only no-workspace agents (classic parity).
			this.personal = result.success
				? result.data.filter((agent) => agent.workspaceId === null)
				: [];
		}

		this.loading = false;
	}

	refresh(): void {
		void this.load(this.#workspaceId, true);
	}
}

export const agentsNav = new AgentsNav();

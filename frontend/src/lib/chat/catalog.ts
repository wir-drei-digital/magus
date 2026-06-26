import {
	listActiveModels,
	mergedSlashCommands,
	myAgents,
	type AgentSummary,
	type ModelSummary,
	type RpcResult,
	type SlashCommandEntry
} from '$lib/ash/api';

/**
 * Session-scoped cache for the per-conversation chrome data. The composer,
 * conversation header, and mention dropdown each used to refetch agents and
 * models on every mount — three identical RPCs per conversation switch for
 * data that changes rarely. Failures aren't cached; a TTL keeps edits made
 * elsewhere (new agent, model toggled) from going stale for long.
 */
const TTL_MS = 5 * 60_000;

type Entry<T> = { at: number; promise: Promise<RpcResult<T>> };

function fresh<T>(entry: Entry<T> | null): entry is Entry<T> {
	return entry !== null && Date.now() - entry.at < TTL_MS;
}

let agentsEntry: Entry<AgentSummary[]> | null = null;
let modelsEntry: Entry<ModelSummary[]> | null = null;
const slashEntries = new Map<string, Entry<SlashCommandEntry[]>>();

export function cachedMyAgents(): Promise<RpcResult<AgentSummary[]>> {
	if (fresh(agentsEntry)) return agentsEntry.promise;
	const entry: Entry<AgentSummary[]> = {
		at: Date.now(),
		promise: myAgents().then((result) => {
			if (!result.success && agentsEntry === entry) agentsEntry = null;
			return result;
		})
	};
	agentsEntry = entry;
	return entry.promise;
}

export function cachedActiveModels(): Promise<RpcResult<ModelSummary[]>> {
	if (fresh(modelsEntry)) return modelsEntry.promise;
	const entry: Entry<ModelSummary[]> = {
		at: Date.now(),
		promise: listActiveModels().then((result) => {
			if (!result.success && modelsEntry === entry) modelsEntry = null;
			return result;
		})
	};
	modelsEntry = entry;
	return entry.promise;
}

export function cachedSlashCommands(
	agentId: string | null
): Promise<RpcResult<SlashCommandEntry[]>> {
	const key = agentId ?? '';
	const existing = slashEntries.get(key) ?? null;
	if (fresh(existing)) return existing.promise;
	const entry: Entry<SlashCommandEntry[]> = {
		at: Date.now(),
		promise: mergedSlashCommands(agentId).then((result) => {
			if (!result.success && slashEntries.get(key) === entry) slashEntries.delete(key);
			return result;
		})
	};
	slashEntries.set(key, entry);
	return entry.promise;
}

/** Call after creating/editing an agent so its handle and commands show up. */
export function invalidateAgentCatalog(): void {
	agentsEntry = null;
	slashEntries.clear();
}

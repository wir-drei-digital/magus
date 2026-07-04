import {
	listActiveModels,
	mergedSlashCommands,
	myAgents,
	myModelPreferences,
	mySkills,
	type AgentSummary,
	type ModelPreference,
	type ModelSummary,
	type RpcResult,
	type SkillSummary,
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
let modelPrefsEntry: Entry<ModelPreference[]> | null = null;
let userSkillsEntry: Entry<SkillSummary[]> | null = null;
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

export function cachedModelPreferences(): Promise<RpcResult<ModelPreference[]>> {
	if (fresh(modelPrefsEntry)) return modelPrefsEntry.promise;
	const entry: Entry<ModelPreference[]> = {
		at: Date.now(),
		promise: myModelPreferences().then((result) => {
			if (!result.success && modelPrefsEntry === entry) modelPrefsEntry = null;
			return result;
		})
	};
	modelPrefsEntry = entry;
	return entry.promise;
}

/** Call after a favorite/hide/order change so the picker refreshes immediately. */
export function invalidateModelPreferences(): void {
	modelPrefsEntry = null;
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

/**
 * The user's own skills, cached for the composer slash menu. Runnable skills
 * (`hasExecutableBundle`) get a sandbox badge there; the backend resolves the
 * typed `/name` server-side, so this is purely the menu affordance.
 */
export function cachedUserSkills(): Promise<RpcResult<SkillSummary[]>> {
	if (fresh(userSkillsEntry)) return userSkillsEntry.promise;
	const entry: Entry<SkillSummary[]> = {
		at: Date.now(),
		promise: mySkills().then((result) => {
			if (!result.success && userSkillsEntry === entry) userSkillsEntry = null;
			return result;
		})
	};
	userSkillsEntry = entry;
	return entry.promise;
}

/** Invalidate after skill create/import/delete so the composer reflects it. */
export function invalidateUserSkills(): void {
	userSkillsEntry = null;
}

/** Call after creating/editing an agent so its handle and commands show up. */
export function invalidateAgentCatalog(): void {
	agentsEntry = null;
	slashEntries.clear();
}

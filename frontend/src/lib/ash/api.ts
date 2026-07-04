/**
 * App-facing data layer for the SvelteKit workbench.
 *
 * Thin wrappers over the generated AshTypescript client (`./ash_rpc`,
 * `./ash_types` — regenerated via `mix ash_typescript.codegen`). This module
 * owns:
 *
 *  - the field selection each view needs (typo'd or removed fields fail the
 *    type-check against the generated `*Fields` types),
 *  - app-level types, refining JSONB blobs the schema can only describe as
 *    `Record<string, any>` (e.g. `TabSession.tabs`),
 *  - mapping HTTP 401 to an `unauthenticated` error so stores can trigger
 *    a sign-in redirect (the generated client folds every non-2xx response
 *    into a generic `network_error`).
 *
 * Components and stores import from here, never from `./ash_rpc` directly.
 */

import * as rpc from './ash_rpc';
import type { AshRpcError } from './ash_types';

export type RpcError = AshRpcError;
export type RpcResult<T> = { success: true; data: T } | { success: false; errors: RpcError[] };

const UNAUTHENTICATED: RpcError = {
	type: 'unauthenticated',
	message: 'Not signed in',
	shortMessage: 'Not signed in',
	vars: {},
	fields: [],
	path: []
};

type FetchOpts = { customFetch: typeof fetch };

/**
 * Runs a generated RPC call with a status-capturing fetch so a 401 (the
 * `:rpc` pipeline's "Authentication required" response) surfaces as an
 * `unauthenticated` error instead of a generic `network_error`.
 *
 * The single cast to `RpcResult<T>` lives here: the generated functions
 * infer their result shape from the fields literal, which matches the
 * app-level types declared in this module.
 */
async function run<T>(
	call: (opts: FetchOpts) => Promise<{ success: boolean; errors?: RpcError[] }>
): Promise<RpcResult<T>> {
	let status = 0;
	const customFetch: typeof fetch = async (input, init) => {
		const response = await fetch(input, init);
		status = response.status;
		return response;
	};

	const result = await call({ customFetch });
	if (!result.success && status === 401) {
		return { success: false, errors: [UNAUTHENTICATED] };
	}
	return result as RpcResult<T>;
}

// ─── Accounts ────────────────────────────────────────────────────────────────

export type CurrentUser = {
	id: string;
	email: string;
	displayName: string | null;
	currentWorkspaceId: string | null;
	isAdmin: boolean;
	uiPreferences: Record<string, unknown>;
	/** Allowed data regions for provider routing (e.g. ['US','EU']). */
	dataRegionPreference: string[];
	/** Region code → ISO8601 consent timestamp, for consent-gated regions. */
	dataRegionConsents: Record<string, string>;
	/** Resolved avatar URL (null when no avatar is set). */
	avatarUrl: string | null;
};

const CURRENT_USER_FIELDS: rpc.CurrentUserFields = [
	'id',
	'email',
	'displayName',
	'currentWorkspaceId',
	'isAdmin',
	'uiPreferences',
	'dataRegionPreference',
	'dataRegionConsents',
	'avatarUrl'
];

export function currentUser(): Promise<RpcResult<CurrentUser>> {
	return run((opts) => rpc.currentUser({ fields: CURRENT_USER_FIELDS, ...opts }));
}

export function updateUiPreferences(
	userId: string,
	uiPreferences: Record<string, unknown>
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.updateUiPreferences({
			identity: userId,
			input: { uiPreferences },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

/** Set the user's allowed data regions (consent-gated regions must already be granted). */
export function updateDataRegionPreference(
	userId: string,
	regions: string[]
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.updateDataRegionPreference({
			identity: userId,
			input: { regions },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

/** Record consent for a consent-gated region and add it to the allowed regions. */
export function grantDataRegionConsent(
	userId: string,
	region: string
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.grantDataRegionConsent({
			identity: userId,
			input: { region },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

/** Persists the user's current workspace (null = personal). */
export function selectWorkspace(
	userId: string,
	workspaceId: string | null
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.selectWorkspace({
			identity: userId,
			input: { currentWorkspaceId: workspaceId },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

// ─── Settings (account) ──────────────────────────────────────────────────────

/**
 * The full settings projection of the current user. Distinct from the lean
 * `CurrentUser` the session store caches: settings pages need the richer field
 * set, while the shell stays small. All mutations below return this shape so
 * the active settings page reconciles from the response without a refetch.
 */
export type UserSettings = {
	id: string;
	email: string;
	displayName: string | null;
	name: string | null;
	language: 'de' | 'en';
	timezone: string | null;
	lastTimezoneChangeAt: string | null;
	selectedModelId: string | null;
	selectedImageModelId: string | null;
	selectedVideoModelId: string | null;
	pendingEmail: string | null;
	hasPassword: boolean;
	avatarPath: string | null;
};

const USER_SETTINGS_FIELDS: rpc.CurrentUserFields = [
	'id',
	'email',
	'displayName',
	'name',
	'language',
	'timezone',
	'lastTimezoneChangeAt',
	'selectedModelId',
	'selectedImageModelId',
	'selectedVideoModelId',
	'pendingEmail',
	'hasPassword',
	'avatarPath'
];

export function userSettings(): Promise<RpcResult<UserSettings>> {
	return run((opts) => rpc.currentUser({ fields: USER_SETTINGS_FIELDS, ...opts }));
}

export function updateUserSettings(
	userId: string,
	input: { displayName?: string | null; name?: string | null; language?: 'de' | 'en' }
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.updateUserSettings({ identity: userId, input, fields: USER_SETTINGS_FIELDS, ...opts })
	);
}

/** Sends a confirmation link to the new address; sets `pendingEmail`. */
export function requestEmailChange(
	userId: string,
	newEmail: string
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.requestEmailChange({
			identity: userId,
			input: { newEmail },
			fields: USER_SETTINGS_FIELDS,
			...opts
		})
	);
}

export function changeUserPassword(
	userId: string,
	input: { currentPassword: string; password: string; passwordConfirmation: string }
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.changeUserPassword({ identity: userId, input, fields: USER_SETTINGS_FIELDS, ...opts })
	);
}

/** Initial password for magic-link-only accounts (`hasPassword === false`). */
export function setUserPassword(
	userId: string,
	input: { password: string; passwordConfirmation: string }
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.setUserPassword({ identity: userId, input, fields: USER_SETTINGS_FIELDS, ...opts })
	);
}

/** null clears the default ("Auto" — let the router pick). */
export function selectDefaultModel(
	userId: string,
	modelId: string | null
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.selectDefaultModel({
			identity: userId,
			input: { selectedModelId: modelId },
			fields: USER_SETTINGS_FIELDS,
			...opts
		})
	);
}

export function selectDefaultImageModel(
	userId: string,
	modelId: string | null
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.selectDefaultImageModel({
			identity: userId,
			input: { selectedImageModelId: modelId },
			fields: USER_SETTINGS_FIELDS,
			...opts
		})
	);
}

export function selectDefaultVideoModel(
	userId: string,
	modelId: string | null
): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.selectDefaultVideoModel({
			identity: userId,
			input: { selectedVideoModelId: modelId },
			fields: USER_SETTINGS_FIELDS,
			...opts
		})
	);
}

/** Rate-limited server-side to one change per 30 days. */
export function updateTimezone(userId: string, timezone: string): Promise<RpcResult<UserSettings>> {
	return run((opts) =>
		rpc.updateTimezone({
			identity: userId,
			input: { timezone },
			fields: USER_SETTINGS_FIELDS,
			...opts
		})
	);
}

// ─── Memory & profile settings ───────────────────────────────────────────────

/**
 * These two toggles feed `session.user` (typed `CurrentUser`), so they select
 * `CURRENT_USER_FIELDS` and return `RpcResult<CurrentUser>` rather than the
 * richer `USER_SETTINGS_FIELDS` the other settings wrappers above use.
 */
export function updateMemorySetting(
	userId: string,
	enabled: boolean
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.updateGlobalMemorySetting({
			identity: userId,
			input: { globalMemoryEnabled: enabled },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

export function updateProfileSetting(
	userId: string,
	enabled: boolean
): Promise<RpcResult<CurrentUser>> {
	return run((opts) =>
		rpc.updateProfileSetting({
			identity: userId,
			input: { profileEnabled: enabled },
			fields: CURRENT_USER_FIELDS,
			...opts
		})
	);
}

export type UserMemory = {
	id: string;
	name: string;
	summary: string | null;
	kind: string | null;
	updatedAt: string | null;
};

const USER_MEMORY_FIELDS: rpc.ListUserMemoriesFields = [
	'id',
	'name',
	'summary',
	'kind',
	'updatedAt'
];

export async function listUserMemories(
	workspaceId: string | null
): Promise<RpcResult<UserMemory[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.listUserMemories({ input: { workspaceId }, fields: USER_MEMORY_FIELDS, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: (result.data ?? []) as UserMemory[] };
}

export async function deactivateUserMemory(memoryId: string): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.deactivateUserMemory({ identity: memoryId, fields: ['id'], ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? memoryId) } };
}

export type UserProfileDoc = {
	id: string;
	document: string;
	tokenEstimate: number;
	lastDistilledAt: string | null;
};

const USER_PROFILE_FIELDS: rpc.GetUserProfileFields = [
	'id',
	'document',
	'tokenEstimate',
	'lastDistilledAt'
];

export async function getUserProfile(
	userId: string,
	workspaceId: string | null
): Promise<RpcResult<UserProfileDoc | null>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.getUserProfile({ input: { userId, workspaceId }, fields: USER_PROFILE_FIELDS, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: (result.data ?? null) as UserProfileDoc | null };
}

export async function clearUserProfile(profileId: string): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.clearUserProfile({ identity: profileId, fields: ['id'], ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? profileId) } };
}

// ─── Settings controllers (non-RPC endpoints) ───────────────────────────────

/**
 * Fetch a plain controller endpoint under `/rpc/*` that mirrors the
 * AshTypescript `{success, data | errors}` envelope. Used where a generated
 * RPC action doesn't fit: API-token plaintext (create metadata) and the
 * destructive account-delete flow.
 */
async function controllerFetch<T>(path: string, init?: RequestInit): Promise<RpcResult<T>> {
	try {
		const response = await fetch(path, { credentials: 'same-origin', ...init });
		if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
		return (await response.json()) as RpcResult<T>;
	} catch (error) {
		return {
			success: false,
			errors: [
				{
					type: 'network_error',
					message: error instanceof Error ? error.message : 'request failed',
					shortMessage: 'Network error',
					vars: {},
					fields: [],
					path: []
				}
			]
		};
	}
}

export type ApiTokenEntry = {
	id: string;
	name: string;
	keyPrefix: string;
	scope: 'read' | 'write';
	createdVia: 'settings' | 'cli_login' | 'oauth_session';
	lastUsedAt: string | null;
	expiresAt: string | null;
	revokedAt: string | null;
	workspaceId: string | null;
	insertedAt: string;
};

/** The created token plus its one-time plaintext (shown once, never re-fetchable). */
export type CreatedApiToken = ApiTokenEntry & { plaintext: string };

export function apiTokens(): Promise<RpcResult<ApiTokenEntry[]>> {
	return controllerFetch('/rpc/api-tokens');
}

export function createApiToken(input: {
	name: string;
	scope: 'read' | 'write';
	workspaceId?: string | null;
	expiresAt?: string | null;
}): Promise<RpcResult<CreatedApiToken>> {
	return controllerFetch('/rpc/api-tokens', {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify(input)
	});
}

export function revokeApiToken(id: string): Promise<RpcResult<{ id: string }>> {
	return controllerFetch(`/rpc/api-tokens/${id}`, { method: 'DELETE' });
}

// ─── Sandbox secrets (settings) ──────────────────────────────────────────────

/**
 * One entry in the per-user sandbox secret vault. The `value` is write-only:
 * the server never returns the plaintext, so it is absent from this type and
 * from `SANDBOX_SECRET_FIELDS`. Only the key (and optional description) is
 * listable; the value is injected into a skill's sandbox server-side only.
 */
export type SandboxSecretEntry = {
	id: string;
	key: string;
	description: string | null;
	insertedAt: string;
};

// Never include `value` here: it is write-only and not a readable field.
const SANDBOX_SECRET_FIELDS: rpc.MySandboxSecretsFields = [
	'id',
	'key',
	'description',
	'insertedAt'
];

export function mySandboxSecrets(): Promise<RpcResult<SandboxSecretEntry[]>> {
	return run((opts) => rpc.mySandboxSecrets({ fields: SANDBOX_SECRET_FIELDS, ...opts }));
}

export function createSandboxSecret(input: {
	key: string;
	value: string;
	description?: string;
}): Promise<RpcResult<SandboxSecretEntry>> {
	return run((opts) => rpc.createSandboxSecret({ input, fields: SANDBOX_SECRET_FIELDS, ...opts }));
}

export function destroySandboxSecret(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroySandboxSecret({ identity: id, ...opts }));
}

// ─── MCP registry discovery (settings) ───────────────────────────────────────

/** A required header declared by a registry entry's remote (for the connect form). */
export type McpRequiredHeader = {
	name: string;
	/** Public value template, e.g. "Bearer {api_key}"; substitute `vars` client-side. */
	template: string;
	/** Template variables the user must supply, e.g. ["api_key"] for "Bearer {api_key}". */
	vars: string[];
	secret: boolean;
	required: boolean;
	description: string | null;
};

/** One importable remote server from the public MCP registry. */
export type McpRegistryEntry = {
	registryName: string;
	displayName: string;
	description: string | null;
	version: string | null;
	repositoryUrl: string | null;
	transport: 'streamable_http' | 'sse';
	authType: 'none' | 'static_header' | 'oauth';
	requiresAuth: boolean;
	requiredHeaders: McpRequiredHeader[];
};

export type McpRegistryPage = {
	entries: McpRegistryEntry[];
	nextCursor: string | null;
};

export type McpImportResult = {
	status: 'connected' | 'needs_auth' | 'error';
	alreadyImported: boolean;
	requiredHeaders: McpRequiredHeader[];
	server: {
		id: string;
		name: string;
		handle: string;
		authType: 'none' | 'static_header' | 'oauth';
		reachability: 'unknown' | 'ok' | 'error';
		workspaceId: string | null;
	};
};

/** Browse/search the public MCP registry for importable remote servers. */
export function mcpRegistryServers(params?: {
	q?: string;
	cursor?: string | null;
	limit?: number;
}): Promise<RpcResult<McpRegistryPage>> {
	const search = new URLSearchParams();
	if (params?.q) search.set('q', params.q);
	if (params?.cursor) search.set('cursor', params.cursor);
	if (params?.limit) search.set('limit', String(params.limit));
	const qs = search.toString();
	return controllerFetch(`/rpc/mcp/registry${qs ? `?${qs}` : ''}`);
}

/** Import a registry server into an MCP.Server with one click. */
export function importMcpRegistryServer(input: {
	registryName: string;
	version?: string;
	workspaceId?: string | null;
}): Promise<RpcResult<McpImportResult>> {
	return controllerFetch('/rpc/mcp/registry/import', {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify(input)
	});
}

export type McpConnectResult = {
	status: 'connected' | 'error';
	server: McpImportResult['server'];
};

/**
 * Store per-user static headers for a server and (re)run discovery. `headers` is
 * the already-resolved `{name: value}` map (templates substituted client-side).
 */
export function connectMcpServer(
	id: string,
	headers: Record<string, string>
): Promise<RpcResult<McpConnectResult>> {
	return controllerFetch(`/rpc/mcp/servers/${id}/connect`, {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ headers })
	});
}

// ─── Account data (settings) ─────────────────────────────────────────────────

export type AccountDeletionSummary = {
	activeSubscription: { plan: string | null; currentPeriodEnd: string | null } | null;
	multiplayerMembershipCount: number;
	conversationCount: number;
	brainCount: number;
	memoryCount: number;
	promptCount: number;
	draftCount: number;
	customAgentCount: number;
};

export type AccountDeletionPreflight =
	| { canDelete: true; summary: AccountDeletionSummary }
	| { canDelete: false; soleAdminWorkspaces: string[] };

/** What the user loses on delete, plus the sole-admin guard from the server. */
export function accountDeletionPreflight(): Promise<RpcResult<AccountDeletionPreflight>> {
	return controllerFetch('/rpc/account/deletion-preflight');
}

/** Hard-deletes the account; the server clears the session on success. */
export function deleteAccount(confirmEmail: string): Promise<RpcResult<{ deleted: boolean }>> {
	return controllerFetch('/rpc/account/delete', {
		method: 'POST',
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ confirmEmail })
	});
}

// ─── Search (full results route) ─────────────────────────────────────────────

export type SearchResultType =
	| 'message'
	| 'conversation'
	| 'prompt'
	| 'skill'
	| 'resource'
	| 'chunk';

/**
 * A unified search hit. `snippet` is server-escaped HTML with `<mark>`
 * highlight tags. `metadata` keys are snake_case (passed through from the
 * Elixir orchestrator) — `conversation_id` for messages, `file_id` for chunks.
 */
export type SearchResult = {
	type: SearchResultType;
	id: string;
	title: string;
	snippet: string;
	score: number;
	metadata: {
		conversation_id?: string;
		file_id?: string;
		[key: string]: unknown;
	};
};

/**
 * Unified full-text search via the /rpc/search controller (reuses the classic
 * `Magus.Search` orchestrator). Omit `type` to search all resource types.
 */
export function searchAll(
	query: string,
	type?: SearchResultType
): Promise<RpcResult<SearchResult[]>> {
	const params = new URLSearchParams({ q: query });
	if (type) params.set('type', type);
	return controllerFetch(`/rpc/search?${params.toString()}`);
}

// ─── Workbench (TabSession) ──────────────────────────────────────────────────

/**
 * Companion pane spec stored on a tab (frozen wire shape shared with the
 * classic workbench — see `MagusWeb.Workbench.Signals`). `pdf` carries a
 * pre-resolved `name` + `url`; everything else is type + resource id.
 */
export type CompanionSpec = {
	type:
		| 'brain_page'
		| 'thread'
		| 'pdf'
		| 'draft'
		| 'service'
		| 'spreadsheet'
		| 'conversation'
		| 'tasks';
	id: string;
	name?: string;
	url?: string;
	[key: string]: unknown;
};

export type WorkbenchTab = {
	id: string;
	primary: { type: string; id: string; label?: string; [key: string]: unknown };
	companion?: CompanionSpec | null;
};

export type TabSession = {
	id: string;
	mode: 'chat' | 'brain' | 'agents' | 'prompts' | 'files' | 'skills' | 'library';
	navFilter: 'all' | 'shared' | 'personal';
	tabs: WorkbenchTab[];
	activeTabId: string | null;
};

const TAB_SESSION_FIELDS: rpc.GetTabSessionFields = [
	'id',
	'mode',
	'navFilter',
	'tabs',
	'activeTabId'
];

export function getOrCreateTabSession(
	userId: string,
	workspaceId: string | null
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.getOrCreateTabSession({
			input: { userId, workspaceId },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

export function setTabSessionMode(
	sessionId: string,
	mode: TabSession['mode']
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.setTabSessionMode({
			identity: sessionId,
			input: { mode },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

export function setTabSessionNavFilter(
	sessionId: string,
	navFilter: TabSession['navFilter']
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.setTabSessionNavFilter({
			identity: sessionId,
			input: { navFilter },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

export function openWorkbenchTab(
	sessionId: string,
	primary: WorkbenchTab['primary'],
	label?: string,
	options?: { single?: boolean }
): Promise<RpcResult<TabSession>> {
	const input: { primary: WorkbenchTab['primary']; label?: string; single?: boolean } = { primary };
	if (label !== undefined) input.label = label;
	// Only sent when trimming to a single tab (tabs disabled); the server
	// defaults it to false, so omitting it preserves multi-tab behaviour.
	if (options?.single) input.single = true;
	return run((opts) =>
		rpc.openWorkbenchTab({
			identity: sessionId,
			input,
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

export function activateWorkbenchTab(
	sessionId: string,
	tabId: string
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.activateWorkbenchTab({
			identity: sessionId,
			input: { tabId },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

export function closeWorkbenchTab(
	sessionId: string,
	tabId: string
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.closeWorkbenchTab({
			identity: sessionId,
			input: { tabId },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

/** Sets (or clears, with null) a tab's companion pane. */
export function setWorkbenchCompanion(
	sessionId: string,
	tabId: string,
	companion: CompanionSpec | null
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.setWorkbenchCompanion({
			identity: sessionId,
			input: { tabId, companion },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

/**
 * Replaces the tabs array wholesale. Tabs are stored as raw maps, so passing
 * back tab objects exactly as they arrived preserves the server-managed keys
 * (`opened_at`, `label`) that the WorkbenchTab type doesn't declare.
 */
export function replaceWorkbenchTabs(
	sessionId: string,
	tabs: WorkbenchTab[],
	activeTabId: string | null
): Promise<RpcResult<TabSession>> {
	return run((opts) =>
		rpc.replaceWorkbenchTabs({
			identity: sessionId,
			input: { tabs, activeTabId },
			fields: TAB_SESSION_FIELDS,
			...opts
		})
	);
}

// ─── Workspaces ──────────────────────────────────────────────────────────────

export type WorkspaceSummary = { id: string; name: string; slug: string };

export function myWorkspaces(): Promise<RpcResult<WorkspaceSummary[]>> {
	return run((opts) => rpc.myWorkspaces({ fields: ['id', 'name', 'slug'], ...opts }));
}

export type WorkspaceDetail = {
	id: string;
	name: string;
	slug: string;
	isActive: boolean;
	storageUsageBytes: number;
	defaultAgentId: string | null;
	allowedModelIds: string[] | null;
};

const WORKSPACE_DETAIL_FIELDS = [
	'id',
	'name',
	'slug',
	'isActive',
	'storageUsageBytes',
	'defaultAgentId',
	'allowedModelIds'
] as rpc.GetWorkspaceBySlugFields;

export function getWorkspaceBySlug(slug: string): Promise<RpcResult<WorkspaceDetail>> {
	return run((opts) =>
		rpc.getWorkspaceBySlug({ getBy: { slug }, fields: WORKSPACE_DETAIL_FIELDS, ...opts })
	) as Promise<RpcResult<WorkspaceDetail>>;
}

export function createWorkspace(input: {
	name: string;
	slug: string;
}): Promise<RpcResult<WorkspaceDetail>> {
	return run((opts) =>
		rpc.createWorkspace({
			input,
			fields: WORKSPACE_DETAIL_FIELDS as rpc.CreateWorkspaceFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceDetail>>;
}

export function updateWorkspace(
	id: string,
	input: {
		name?: string;
		isActive?: boolean;
		defaultAgentId?: string | null;
		allowedModelIds?: string[] | null;
	}
): Promise<RpcResult<WorkspaceDetail>> {
	return run((opts) =>
		rpc.updateWorkspace({
			identity: id,
			input,
			fields: WORKSPACE_DETAIL_FIELDS as rpc.UpdateWorkspaceFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceDetail>>;
}

/** Soft-delete: deactivates the workspace and unwinds members + child resources. */
export function deactivateWorkspace(id: string): Promise<RpcResult<WorkspaceDetail>> {
	return run((opts) =>
		rpc.deactivateWorkspace({
			identity: id,
			fields: WORKSPACE_DETAIL_FIELDS as rpc.DeactivateWorkspaceFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceDetail>>;
}

export type WorkspaceMemberRole = 'admin' | 'member';
export type WorkspaceMemberStatus = 'invited' | 'active' | 'deactivated';

export type WorkspaceMemberEntry = {
	id: string;
	role: WorkspaceMemberRole;
	status: WorkspaceMemberStatus;
	isActive: boolean;
	inviteEmail: string | null;
	invitedAt: string | null;
	joinedAt: string | null;
	user: { id: string; email: string; displayName: string | null } | null;
};

const WORKSPACE_MEMBER_FIELDS = [
	'id',
	'role',
	'status',
	'isActive',
	'inviteEmail',
	'invitedAt',
	'joinedAt',
	{ user: ['id', 'email', 'displayName'] }
] as rpc.ListWorkspaceMembersFields;

export function listWorkspaceMembers(
	workspaceId: string
): Promise<RpcResult<WorkspaceMemberEntry[]>> {
	return run((opts) =>
		rpc.listWorkspaceMembers({ input: { workspaceId }, fields: WORKSPACE_MEMBER_FIELDS, ...opts })
	) as Promise<RpcResult<WorkspaceMemberEntry[]>>;
}

export function inviteWorkspaceMember(
	workspaceId: string,
	inviteEmail: string
): Promise<RpcResult<WorkspaceMemberEntry>> {
	return run((opts) =>
		rpc.inviteWorkspaceMember({
			input: { workspaceId, inviteEmail },
			fields: WORKSPACE_MEMBER_FIELDS as rpc.InviteWorkspaceMemberFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceMemberEntry>>;
}

export function resendWorkspaceInvite(memberId: string): Promise<RpcResult<WorkspaceMemberEntry>> {
	return run((opts) =>
		rpc.resendWorkspaceInvite({
			identity: memberId,
			fields: WORKSPACE_MEMBER_FIELDS as rpc.ResendWorkspaceInviteFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceMemberEntry>>;
}

export function changeWorkspaceMemberRole(
	memberId: string,
	role: WorkspaceMemberRole
): Promise<RpcResult<WorkspaceMemberEntry>> {
	return run((opts) =>
		rpc.changeWorkspaceMemberRole({
			identity: memberId,
			input: { role },
			fields: WORKSPACE_MEMBER_FIELDS as rpc.ChangeWorkspaceMemberRoleFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceMemberEntry>>;
}

/** Deactivates (removes) a member, or revokes a pending invite. */
export function deactivateWorkspaceMember(
	memberId: string
): Promise<RpcResult<WorkspaceMemberEntry>> {
	return run((opts) =>
		rpc.deactivateWorkspaceMember({
			identity: memberId,
			input: {},
			fields: WORKSPACE_MEMBER_FIELDS as rpc.DeactivateWorkspaceMemberFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceMemberEntry>>;
}

/** Promotes the member to admin and demotes the acting admin to member. */
export function transferWorkspaceOwnership(
	memberId: string
): Promise<RpcResult<WorkspaceMemberEntry>> {
	return run((opts) =>
		rpc.transferWorkspaceOwnership({
			identity: memberId,
			fields: WORKSPACE_MEMBER_FIELDS as rpc.TransferWorkspaceOwnershipFields,
			...opts
		})
	) as Promise<RpcResult<WorkspaceMemberEntry>>;
}

/** Per-member usage row (credits today / storage / last active), keyed by user. */
export type MemberUsageEntry = {
	userId: string;
	credits: number;
	storageBytes: number;
	lastActiveAt: string | null;
};

/**
 * Admin-only per-member usage breakdown for the workspace usage view. The
 * action returns untyped aggregate rows (snake_case); map them to a typed shape.
 */
export async function workspaceMemberUsage(
	workspaceId: string
): Promise<RpcResult<MemberUsageEntry[]>> {
	const result = await run<Record<string, unknown>[]>((opts) =>
		rpc.workspaceMemberUsage({ input: { workspaceId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: result.data.map((row) => ({
			userId: String(row.user_id ?? ''),
			credits: Number(row.credits ?? 0),
			storageBytes: Number(row.storage_bytes ?? 0),
			lastActiveAt: (row.last_active_at as string | null) ?? null
		}))
	};
}

// ─── Organizations ─────────────────────────────────────────────────────────────

export type OrgBillingInterval = 'annual' | 'monthly';
export type OrgBillingStatus = 'active' | 'canceled' | 'incomplete' | 'past_due' | 'trialing';

export type OrganizationDetail = {
	id: string;
	name: string;
	slug: string;
	billingInterval: OrgBillingInterval;
	billingStatus: OrgBillingStatus;
	currentPeriodStart: string | null;
	currentPeriodEnd: string | null;
	ownerId: string;
};

export type OrgMemberRole = 'member' | 'owner';
export type OrgMemberStatus = 'active' | 'invited' | 'removed';

export type OrgMemberEntry = {
	id: string;
	role: OrgMemberRole;
	status: OrgMemberStatus;
	spendCapCents: number | null;
	inviteEmail: string | null;
	invitedAt: string | null;
	joinedAt: string | null;
	organizationId: string;
	userId: string | null;
	user: { id: string; email: string; displayName: string | null } | null;
};

/** The signed-in user's own membership row, with the organization loaded. */
export type MyOrgMembership = OrgMemberEntry & { organization: OrganizationDetail };

const ORG_DETAIL_FIELDS = [
	'id',
	'name',
	'slug',
	'billingInterval',
	'billingStatus',
	'currentPeriodStart',
	'currentPeriodEnd',
	'ownerId'
] as rpc.CreateOrganizationFields;

const ORG_MEMBER_FIELDS = [
	'id',
	'role',
	'status',
	'spendCapCents',
	'inviteEmail',
	'invitedAt',
	'joinedAt',
	'organizationId',
	'userId',
	{ user: ['id', 'email', 'displayName'] }
] as rpc.ListOrgMembersFields;

const MY_ORG_FIELDS = [
	...(ORG_MEMBER_FIELDS as unknown[]),
	{ organization: ORG_DETAIL_FIELDS }
] as rpc.MyOrganizationFields;

/**
 * The signed-in user's org membership (0 or 1 rows) with the organization
 * loaded. Empty means "not in an org yet" — the settings shell then offers to
 * create one. This action requires an explicit `fields` selection.
 */
export function myOrganization(): Promise<RpcResult<MyOrgMembership[]>> {
	return run((opts) => rpc.myOrganization({ fields: MY_ORG_FIELDS, ...opts })) as Promise<
		RpcResult<MyOrgMembership[]>
	>;
}

export function listOrgMembers(organizationId: string): Promise<RpcResult<OrgMemberEntry[]>> {
	return run((opts) =>
		rpc.listOrgMembers({ input: { organizationId }, fields: ORG_MEMBER_FIELDS, ...opts })
	) as Promise<RpcResult<OrgMemberEntry[]>>;
}

export function inviteOrgMember(
	organizationId: string,
	inviteEmail: string
): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.inviteOrgMember({
			input: { organizationId, inviteEmail },
			fields: ORG_MEMBER_FIELDS as rpc.InviteOrgMemberFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

/** Update action: takes the member row's primary key as `identity`. */
export function changeOrgMemberRole(
	memberId: string,
	role: OrgMemberRole
): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.changeOrgMemberRole({
			identity: memberId,
			input: { role },
			fields: ORG_MEMBER_FIELDS as rpc.ChangeOrgMemberRoleFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

/** Soft-removes a member (or revokes a pending invite). */
export function removeOrgMember(memberId: string): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.removeOrgMember({
			identity: memberId,
			fields: ORG_MEMBER_FIELDS as rpc.RemoveOrgMemberFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

/** Promotes the target member to owner and demotes the acting owner to member. */
export function transferOrgOwnership(memberId: string): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.transferOrgOwnership({
			identity: memberId,
			fields: ORG_MEMBER_FIELDS as rpc.TransferOrgOwnershipFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

export function resendOrgInvite(memberId: string): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.resendOrgInvite({
			identity: memberId,
			fields: ORG_MEMBER_FIELDS as rpc.ResendOrgInviteFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

/** Sets (or clears, with `null`) the per-member monthly spend cap in cents. */
export function setMemberSpendCap(
	memberId: string,
	spendCapCents: number | null
): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.setMemberSpendCap({
			identity: memberId,
			input: { spendCapCents },
			fields: ORG_MEMBER_FIELDS as rpc.SetMemberSpendCapFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

/** The signed-in member leaves the organization (own membership row). */
export function leaveOrg(memberId: string): Promise<RpcResult<OrgMemberEntry>> {
	return run((opts) =>
		rpc.leaveOrg({
			identity: memberId,
			fields: ORG_MEMBER_FIELDS as rpc.LeaveOrgFields,
			...opts
		})
	) as Promise<RpcResult<OrgMemberEntry>>;
}

export function createOrganization(
	name: string,
	slug: string
): Promise<RpcResult<OrganizationDetail>> {
	return run((opts) =>
		rpc.createOrganization({
			input: { name, slug },
			fields: ORG_DETAIL_FIELDS,
			...opts
		})
	) as Promise<RpcResult<OrganizationDetail>>;
}

/**
 * Archives (soft-deletes) the organization: offboards every member, deactivates
 * its workspaces, and cancels billing server-side. Owner-only and irreversible.
 * Takes the organization's primary key as `identity`.
 */
export function archiveOrganization(orgId: string): Promise<RpcResult<OrganizationDetail>> {
	return run((opts) =>
		rpc.archiveOrganization({
			identity: orgId,
			fields: ORG_DETAIL_FIELDS as rpc.ArchiveOrganizationFields,
			...opts
		})
	) as Promise<RpcResult<OrganizationDetail>>;
}

/** A member's pooled-spend contribution for the org Usage tab, keyed by user. */
export type OrgUsageMember = {
	userId: string;
	displayName: string | null;
	spentCents: number;
	capCents: number | null;
	/** Prompt + completion tokens this member used this period. */
	tokens: number;
};

/** Pooled + per-member spend for the org Usage tab. */
export type OrgUsageOverview = {
	pooledSpentCents: number;
	/** Combined prompt + completion tokens across the org this period. */
	pooledTokens: number;
	seatCount: number;
	/** Whether the viewer is the org owner (owner: all member rows; member: own row only). */
	viewerOwner: boolean;
	members: OrgUsageMember[];
};

/**
 * Pooled + per-member spend for the org Usage tab. The generic map action scopes
 * the visible member set server-side (owner: all; member: own) and returns
 * untyped snake_case keys; map them to a typed shape as `billingOverview` does.
 */
export async function orgUsageOverview(orgId: string): Promise<RpcResult<OrgUsageOverview>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.orgUsageOverview({ input: { organizationId: orgId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	const rows = Array.isArray(data.members) ? (data.members as Record<string, unknown>[]) : [];
	return {
		success: true,
		data: {
			pooledSpentCents: Number(data.pooled_spent_cents ?? 0),
			pooledTokens: Number(data.pooled_tokens ?? 0),
			seatCount: Number(data.seat_count ?? 0),
			viewerOwner: data.viewer_owner === true,
			members: rows.map((row) => ({
				userId: String(row.user_id ?? ''),
				displayName: typeof row.display_name === 'string' ? row.display_name : null,
				spentCents: Number(row.spent_cents ?? 0),
				capCents: row.cap_cents == null ? null : Number(row.cap_cents),
				tokens: Number(row.tokens ?? 0)
			}))
		}
	};
}

/** Org-level billing summary for the org Billing tab (owner-only surface). */
export type OrgBillingOverview = {
	billingStatus: string;
	currentPeriodEnd: string | null;
	seatCount: number;
	/** Whether the org has started Stripe checkout (has a subscription). */
	billingSetUp: boolean;
	/** Whether the commercial billing edition is present (false = open-core self-host). */
	billingEdition: boolean;
};

/**
 * Org billing summary for the Billing tab. The generic map action returns
 * untyped snake_case keys; map them to a typed shape as `billingOverview` does.
 */
export async function orgBillingOverview(orgId: string): Promise<RpcResult<OrgBillingOverview>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.orgBillingOverview({ input: { organizationId: orgId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			billingStatus: String(data.billing_status ?? 'none'),
			currentPeriodEnd:
				typeof data.current_period_end === 'string' ? data.current_period_end : null,
			seatCount: Number(data.seat_count ?? 0),
			billingSetUp: data.billing_set_up === true,
			billingEdition: data.billing_edition === true
		}
	};
}

// ─── Chat ────────────────────────────────────────────────────────────────────

export type ChatMode = 'chat' | 'search' | 'reasoning' | 'image_generation' | 'video_generation';

export type ConversationSummary = {
	id: string;
	/** Conversation creator / owner (implicitly :owner). Used to gate owner-only
	 *  controls like the context-window donut actions (server still enforces). */
	userId: string;
	title: string | null;
	chatMode: ChatMode;
	updatedAt: string;
	selectedModelId: string | null;
	/** Per-mode model picks (image/video generation). */
	selectedImageModelId: string | null;
	selectedVideoModelId: string | null;
	/** Per-mode generation config maps (aspect ratio, size/resolution, etc.). */
	imageGenerationSettings: Record<string, unknown> | null;
	videoGenerationSettings: Record<string, unknown> | null;
	workspaceId: string | null;
	customAgentId: string | null;
	folderId: string | null;
	isFavorited: boolean;
	isSharedToWorkspace: boolean;
	isMultiplayer: boolean;
	/** Aggregate over messages; null for empty conversations. */
	lastMessageAt: string | null;
	parentConversationId: string | null;
};

const CONVERSATION_FIELDS: rpc.GetConversationFields = [
	'id',
	'userId',
	'title',
	'chatMode',
	'updatedAt',
	'selectedModelId',
	'selectedImageModelId',
	'selectedVideoModelId',
	'imageGenerationSettings',
	'videoGenerationSettings',
	'workspaceId',
	'customAgentId',
	'folderId',
	'isFavorited',
	'isSharedToWorkspace',
	'isMultiplayer',
	'lastMessageAt',
	'parentConversationId'
];

export function myConversations(): Promise<RpcResult<ConversationSummary[]>> {
	return run((opts) => rpc.myConversations({ fields: CONVERSATION_FIELDS, ...opts }));
}

export type ConversationFavoriteEntry = { id: string; conversationId: string };

export function myConversationFavorites(): Promise<RpcResult<ConversationFavoriteEntry[]>> {
	return run((opts) => rpc.myConversationFavorites({ fields: ['id', 'conversationId'], ...opts }));
}

export function favoriteConversation(
	conversationId: string
): Promise<RpcResult<ConversationFavoriteEntry>> {
	return run((opts) =>
		rpc.favoriteConversation({
			input: { conversationId },
			fields: ['id', 'conversationId'],
			...opts
		})
	);
}

export function unfavoriteConversation(
	favoriteId: string
): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.unfavoriteConversation({ identity: favoriteId, ...opts }));
}

/**
 * Unfavorite by conversation id in a single RPC (no whole-list fetch): a
 * generic action destroys the actor's favorite row for the conversation.
 */
export function removeConversationFavorite(conversationId: string): Promise<RpcResult<string>> {
	return run((opts) => rpc.removeConversationFavorite({ input: { conversationId }, ...opts }));
}

export function workspaceConversations(
	workspaceId: string
): Promise<RpcResult<ConversationSummary[]>> {
	return run((opts) =>
		rpc.workspaceConversations({
			input: { workspaceId },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

export function getConversation(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.getConversation({ getBy: { id }, fields: CONVERSATION_FIELDS, ...opts })
	);
}

/** User-owned conversations outside any workspace (classic personal-mode nav). */
export function personalConversations(): Promise<RpcResult<ConversationSummary[]>> {
	return run((opts) => rpc.personalConversations({ fields: CONVERSATION_FIELDS, ...opts }));
}

export function shareConversationToTeam(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.shareConversationToTeam({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

export function unshareConversationFromTeam(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.unshareConversationFromTeam({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

export function moveConversationToFolder(
	id: string,
	folderId: string | null
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.moveConversationToFolder({
			identity: id,
			input: { folderId },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

export function createConversation(
	input: {
		title?: string;
		workspaceId?: string | null;
		folderId?: string | null;
		customAgentId?: string | null;
	} = {}
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) => rpc.createConversation({ input, fields: CONVERSATION_FIELDS, ...opts }));
}

/**
 * Classic ?skill= deeplink: create a conversation seeded with a skill's
 * context/tools and send its start message server-side. Returns the new
 * conversation (the agent's reply streams in once the view mounts).
 */
export function startSkillConversation(input: {
	skillName: string;
	topic?: string | null;
	workspaceId?: string | null;
}): Promise<RpcResult<ConversationSummary>> {
	return run((opts) => rpc.startSkillConversation({ input, fields: CONVERSATION_FIELDS, ...opts }));
}

export function renameConversation(
	id: string,
	title: string
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.renameConversation({ identity: id, input: { title }, fields: CONVERSATION_FIELDS, ...opts })
	);
}

export function archiveConversation(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.archiveConversation({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

// ─── History view ────────────────────────────────────────────────────────────

export type HistoryEntry = ConversationSummary & { messageCount: number };

export type ConversationHistoryPage = {
	results: HistoryEntry[];
	hasMore: boolean;
	offset: number;
};

const HISTORY_FIELDS = [...CONVERSATION_FIELDS, 'messageCount'] as rpc.ConversationHistoryFields;

/** Paginated history with classic unified search (titles + message text). */
export function conversationHistory(options: {
	query?: string;
	workspaceId?: string | null;
	offset?: number;
	limit?: number;
}): Promise<RpcResult<ConversationHistoryPage>> {
	return run((opts) =>
		rpc.conversationHistory({
			input: {
				...(options.query ? { query: options.query } : {}),
				workspaceId: options.workspaceId ?? null
			},
			fields: HISTORY_FIELDS,
			page: { limit: options.limit ?? 25, offset: options.offset ?? 0 },
			...opts
		})
	) as Promise<RpcResult<ConversationHistoryPage>>;
}

export type TrashedConversation = ConversationSummary & {
	messageCount: number;
	deletedAt: string;
};

export function trashedConversations(): Promise<RpcResult<TrashedConversation[]>> {
	return run((opts) =>
		rpc.trashedConversations({
			fields: [
				...CONVERSATION_FIELDS,
				'messageCount',
				'deletedAt'
			] as rpc.TrashedConversationsFields,
			...opts
		})
	) as Promise<RpcResult<TrashedConversation[]>>;
}

export function restoreConversation(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.restoreConversation({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

export function deleteConversationPermanently(id: string): Promise<RpcResult<unknown>> {
	return run((opts) => rpc.deleteConversationPermanently({ identity: id, ...opts }));
}

// ─── Sharing ─────────────────────────────────────────────────────────────────────

export type ShareLink = {
	id: string;
	token: string;
	accessType: 'public' | 'authenticated';
	label: string | null;
	isActive: boolean;
};

const SHARE_LINK_FIELDS: rpc.ConversationShareLinksFields = [
	'id',
	'token',
	'accessType',
	'label',
	'isActive'
];

export function conversationShareLinks(conversationId: string): Promise<RpcResult<ShareLink[]>> {
	return run((opts) =>
		rpc.conversationShareLinks({
			input: { conversationId },
			fields: SHARE_LINK_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ShareLink[]>>;
}

export function createShareLink(input: {
	conversationId: string;
	accessType: 'public' | 'authenticated';
	label?: string;
}): Promise<RpcResult<ShareLink>> {
	return run((opts) =>
		rpc.createShareLink({
			input,
			fields: SHARE_LINK_FIELDS as rpc.CreateShareLinkFields,
			...opts
		})
	) as Promise<RpcResult<ShareLink>>;
}

export function revokeShareLink(id: string): Promise<RpcResult<ShareLink>> {
	return run((opts) =>
		rpc.revokeShareLink({
			identity: id,
			fields: SHARE_LINK_FIELDS as rpc.RevokeShareLinkFields,
			...opts
		})
	) as Promise<RpcResult<ShareLink>>;
}

export function enableConversationMultiplayer(id: string): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.enableConversationMultiplayer({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

export function disableConversationMultiplayer(
	id: string
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.disableConversationMultiplayer({ identity: id, fields: CONVERSATION_FIELDS, ...opts })
	);
}

// ─── Participants ────────────────────────────────────────────────────────────

export type MemberRole = 'owner' | 'member' | 'observer';

export type ConversationMemberEntry = {
	id: string;
	role: MemberRole;
	isMuted: boolean;
	acceptedAt: string | null;
	user: { id: string; email: string; displayName: string | null };
};

const MEMBER_FIELDS = [
	'id',
	'role',
	'isMuted',
	'acceptedAt',
	{ user: ['id', 'email', 'displayName'] }
] as rpc.ConversationMembersFields;

export function conversationMembers(
	conversationId: string
): Promise<RpcResult<ConversationMemberEntry[]>> {
	return run((opts) =>
		rpc.conversationMembers({ input: { conversationId }, fields: MEMBER_FIELDS, ...opts })
	) as Promise<RpcResult<ConversationMemberEntry[]>>;
}

export function changeMemberRole(
	memberId: string,
	role: Exclude<MemberRole, 'owner'>
): Promise<RpcResult<ConversationMemberEntry>> {
	return run((opts) =>
		rpc.changeMemberRole({
			identity: memberId,
			input: { role },
			fields: MEMBER_FIELDS as rpc.ChangeMemberRoleFields,
			...opts
		})
	) as Promise<RpcResult<ConversationMemberEntry>>;
}

export function muteConversationMember(
	memberId: string
): Promise<RpcResult<ConversationMemberEntry>> {
	return run((opts) =>
		rpc.muteConversationMember({
			identity: memberId,
			fields: MEMBER_FIELDS as rpc.MuteConversationMemberFields,
			...opts
		})
	) as Promise<RpcResult<ConversationMemberEntry>>;
}

export function unmuteConversationMember(
	memberId: string
): Promise<RpcResult<ConversationMemberEntry>> {
	return run((opts) =>
		rpc.unmuteConversationMember({
			identity: memberId,
			fields: MEMBER_FIELDS as rpc.UnmuteConversationMemberFields,
			...opts
		})
	) as Promise<RpcResult<ConversationMemberEntry>>;
}

export function removeConversationMember(memberId: string): Promise<RpcResult<unknown>> {
	return run((opts) => rpc.removeConversationMember({ identity: memberId, ...opts }));
}

export type ConversationInvitationEntry = {
	id: string;
	email: string;
	role: Exclude<MemberRole, 'owner'>;
};

const INVITATION_FIELDS: rpc.PendingConversationInvitationsFields = ['id', 'email', 'role'];

export function inviteToConversation(input: {
	conversationId: string;
	email: string;
	role: Exclude<MemberRole, 'owner'>;
}): Promise<RpcResult<ConversationInvitationEntry>> {
	return run((opts) =>
		rpc.inviteToConversation({
			input,
			fields: INVITATION_FIELDS as rpc.InviteToConversationFields,
			...opts
		})
	) as Promise<RpcResult<ConversationInvitationEntry>>;
}

export function pendingConversationInvitations(
	conversationId: string
): Promise<RpcResult<ConversationInvitationEntry[]>> {
	return run((opts) =>
		rpc.pendingConversationInvitations({
			input: { conversationId },
			fields: INVITATION_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationInvitationEntry[]>>;
}

export function cancelConversationInvitation(id: string): Promise<RpcResult<unknown>> {
	return run((opts) => rpc.cancelConversationInvitation({ identity: id, ...opts }));
}

export type InviteLinkEntry = {
	id: string;
	token: string;
	role: Exclude<MemberRole, 'owner'>;
	isActive: boolean;
	usesCount: number;
	maxUses: number | null;
	expiresAt: string | null;
};

const INVITE_LINK_FIELDS: rpc.ConversationInviteLinksFields = [
	'id',
	'token',
	'role',
	'isActive',
	'usesCount',
	'maxUses',
	'expiresAt'
];

export function conversationInviteLinks(
	conversationId: string
): Promise<RpcResult<InviteLinkEntry[]>> {
	return run((opts) =>
		rpc.conversationInviteLinks({
			input: { conversationId },
			fields: INVITE_LINK_FIELDS,
			...opts
		})
	) as Promise<RpcResult<InviteLinkEntry[]>>;
}

export function createConversationInviteLink(input: {
	conversationId: string;
	role?: Exclude<MemberRole, 'owner'>;
}): Promise<RpcResult<InviteLinkEntry>> {
	return run((opts) =>
		rpc.createConversationInviteLink({
			input,
			fields: INVITE_LINK_FIELDS as rpc.CreateConversationInviteLinkFields,
			...opts
		})
	) as Promise<RpcResult<InviteLinkEntry>>;
}

export function deactivateConversationInviteLink(id: string): Promise<RpcResult<InviteLinkEntry>> {
	return run((opts) =>
		rpc.deactivateConversationInviteLink({
			identity: id,
			fields: INVITE_LINK_FIELDS as rpc.DeactivateConversationInviteLinkFields,
			...opts
		})
	) as Promise<RpcResult<InviteLinkEntry>>;
}

export function setConversationModel(
	id: string,
	selectedModelId: string | null
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.setConversationModel({
			identity: id,
			input: { selectedModelId },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

/** Per-mode model setters: image/video generation pick their own model. */
export function setConversationImageModel(
	id: string,
	selectedImageModelId: string | null
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.setConversationImageModel({
			identity: id,
			input: { selectedImageModelId },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

export function setConversationVideoModel(
	id: string,
	selectedVideoModelId: string | null
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.setConversationVideoModel({
			identity: id,
			input: { selectedVideoModelId },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

/** Per-mode generation config (aspect ratio, size/resolution, duration, audio). */
export function updateConversationImageSettings(
	id: string,
	imageGenerationSettings: Record<string, unknown>
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.updateConversationImageSettings({
			identity: id,
			input: { imageGenerationSettings },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

export function updateConversationVideoSettings(
	id: string,
	videoGenerationSettings: Record<string, unknown>
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.updateConversationVideoSettings({
			identity: id,
			input: { videoGenerationSettings },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

export function setConversationMode(
	id: string,
	chatMode: ChatMode
): Promise<RpcResult<ConversationSummary>> {
	return run((opts) =>
		rpc.setConversationMode({
			identity: id,
			input: { chatMode },
			fields: CONVERSATION_FIELDS,
			...opts
		})
	);
}

// ─── Conversation settings (right-rail Settings panel) ──────────────────────

export type SamplingSettings = {
	temperature?: number;
	max_tokens?: number;
	top_p?: number;
	top_k?: number;
};

export type ConversationSettings = {
	id: string;
	systemPrompt: string | null;
	samplingSettings: SamplingSettings | null;
	activeSystemPrompt: { id: string; name: string } | null;
};

const CONVERSATION_SETTINGS_FIELDS = [
	'id',
	'systemPrompt',
	'samplingSettings',
	{ activeSystemPrompt: ['id', 'name'] }
] satisfies rpc.GetConversationFields;

export function conversationSettings(id: string): Promise<RpcResult<ConversationSettings>> {
	return run((opts) =>
		rpc.getConversation({ getBy: { id }, fields: CONVERSATION_SETTINGS_FIELDS, ...opts })
	) as Promise<RpcResult<ConversationSettings>>;
}

export function updateConversationSettings(
	id: string,
	input: { systemPrompt?: string | null; samplingSettings?: SamplingSettings | null }
): Promise<RpcResult<ConversationSettings>> {
	return run((opts) =>
		rpc.updateConversationSettings({
			identity: id,
			input,
			fields: CONVERSATION_SETTINGS_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationSettings>>;
}

export function resetConversationSettings(id: string): Promise<RpcResult<ConversationSettings>> {
	return run((opts) =>
		rpc.resetConversationSettings({
			identity: id,
			fields: CONVERSATION_SETTINGS_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationSettings>>;
}

/**
 * Activating a prompt also applies the prompt's model and chat mode to the
 * conversation server-side, so callers should refetch the conversation row.
 */
export function activateConversationPrompt(
	conversationId: string,
	promptId: string
): Promise<RpcResult<ConversationSettings>> {
	return run((opts) =>
		rpc.activateConversationPrompt({
			identity: conversationId,
			input: { promptId },
			fields: CONVERSATION_SETTINGS_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationSettings>>;
}

export function deactivateConversationPrompt(
	conversationId: string
): Promise<RpcResult<ConversationSettings>> {
	return run((opts) =>
		rpc.deactivateConversationPrompt({
			identity: conversationId,
			fields: CONVERSATION_SETTINGS_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationSettings>>;
}

// ─── Models + Agents ─────────────────────────────────────────────────────────

export type ModelSummary = {
	id: string;
	name: string;
	provider: string | null;
	shortDescription: string | null;
	contextWindow: number | null;
	inputModalities: string[] | null;
	outputModalities: string[] | null;
	supportsSearch: boolean;
	supportsReasoning: boolean;
	supportsTools: boolean;
	/** Pre-formatted per-million-token cost display strings (e.g. "$3"). */
	inputCost: string | null;
	outputCost: string | null;
	/** Approximate CHF cents for a reference request (composer cost gauge); null for image/video models. */
	requestCostCents: number | null;
};

const MODEL_SUMMARY_FIELDS: rpc.ListActiveModelsFields = [
	'id',
	'name',
	'provider',
	'shortDescription',
	'contextWindow',
	'inputModalities',
	'outputModalities',
	'supportsSearch',
	'supportsReasoning',
	'supportsTools',
	'inputCost',
	'outputCost',
	'requestCostCents'
];

export function listActiveModels(): Promise<RpcResult<ModelSummary[]>> {
	return run((opts) => rpc.listActiveModels({ fields: MODEL_SUMMARY_FIELDS, ...opts }));
}

/** Models whose output modalities include `image` (settings default picker). */
export function listImageGenerationModels(): Promise<RpcResult<ModelSummary[]>> {
	return run((opts) => rpc.listImageGenerationModels({ fields: MODEL_SUMMARY_FIELDS, ...opts }));
}

/** Models whose output modalities include `video` (settings default picker). */
export function listVideoGenerationModels(): Promise<RpcResult<ModelSummary[]>> {
	return run((opts) => rpc.listVideoGenerationModels({ fields: MODEL_SUMMARY_FIELDS, ...opts }));
}

export type ModelPreference = {
	id: string;
	modelId: string;
	favorite: boolean;
	hidden: boolean;
	position: number | null;
};

const MODEL_PREFERENCE_FIELDS: rpc.MyModelPreferencesFields = [
	'id',
	'modelId',
	'favorite',
	'hidden',
	'position'
];

/** The actor's model curation rows (favorite / hidden / position). */
export function myModelPreferences(): Promise<RpcResult<ModelPreference[]>> {
	return run((opts) => rpc.myModelPreferences({ fields: MODEL_PREFERENCE_FIELDS, ...opts }));
}

export function setModelFavorite(
	modelId: string,
	favorite: boolean
): Promise<RpcResult<ModelPreference>> {
	return run((opts) =>
		rpc.setModelFavorite({ input: { modelId, favorite }, fields: MODEL_PREFERENCE_FIELDS, ...opts })
	);
}

export function setModelHidden(
	modelId: string,
	hidden: boolean
): Promise<RpcResult<ModelPreference>> {
	return run((opts) =>
		rpc.setModelHidden({ input: { modelId, hidden }, fields: MODEL_PREFERENCE_FIELDS, ...opts })
	);
}

export function setModelPosition(
	modelId: string,
	position: number
): Promise<RpcResult<ModelPreference>> {
	return run((opts) =>
		rpc.setModelPosition({ input: { modelId, position }, fields: MODEL_PREFERENCE_FIELDS, ...opts })
	);
}

export type AgentSummary = {
	id: string;
	name: string;
	handle: string;
	icon: string | null;
	description: string | null;
	isDefault: boolean;
	workspaceId: string | null;
	isSharedToWorkspace: boolean;
	isPaused: boolean;
	updatedAt: string;
	imageUrl: string | null;
};

const AGENT_SUMMARY_FIELDS: rpc.MyAgentsFields = [
	'id',
	'name',
	'handle',
	'icon',
	'description',
	'isDefault',
	'workspaceId',
	'isSharedToWorkspace',
	'isPaused',
	'updatedAt',
	'imageUrl'
];

/** @mention autocomplete source — the actor's custom agents. */
export function myAgents(): Promise<RpcResult<AgentSummary[]>> {
	return run((opts) =>
		rpc.myAgents({
			fields: AGENT_SUMMARY_FIELDS,
			...opts
		})
	);
}

export type ChatMessage = {
	id: string;
	text: string;
	source: 'user' | 'agent';
	role: 'system' | 'user' | 'agent' | 'tool';
	messageType: 'message' | 'event' | 'job_trigger' | 'draft_event';
	status: 'pending' | 'streaming' | 'complete' | 'error';
	insertedAt: string;
	modelName: string | null;
	toolCallData: Record<string, unknown> | null;
	citations: Record<string, unknown>[] | null;
	reasoningSummary: string[] | null;
	/** Selection context, wakeup/job/draft trace data, etc. (rendered chips). */
	metadata: Record<string, unknown>;
	/** Attached file ids; resolved to chips via filesForDisplay. */
	attachments: string[];
	/** Excluded from the LLM context (classic eye toggle). */
	disabled: boolean;
};

const MESSAGE_FIELDS: rpc.MessageHistoryFields = [
	'id',
	'text',
	'source',
	'role',
	'messageType',
	'status',
	'insertedAt',
	'modelName',
	'toolCallData',
	'citations',
	'reasoningSummary',
	'metadata',
	'attachments',
	'disabled'
];

/** Newest-first from the server (`default_sort inserted_at: :desc`); callers reverse for display. */
export function messageHistory(conversationId: string): Promise<RpcResult<ChatMessage[]>> {
	return run((opts) =>
		rpc.messageHistory({
			input: { conversationId },
			fields: MESSAGE_FIELDS,
			...opts
		})
	);
}

export type MessageHistoryPage = {
	messages: ChatMessage[];
	hasMore: boolean;
};

/**
 * One page of a conversation's messages, newest-first. `before` is an ISO
 * `insertedAt` cursor (the oldest already-loaded message) for scroll-up
 * pagination, so the initial load and reconnects don't fetch the whole
 * history. `hasMore` is true when a full page came back (more may remain).
 */
export async function messageHistoryPage(
	conversationId: string,
	options: { limit: number; before?: string | null }
): Promise<RpcResult<MessageHistoryPage>> {
	const filter = options.before ? { insertedAt: { lessThan: options.before } } : undefined;
	const result = await run<{ results: ChatMessage[]; hasMore: boolean }>((opts) =>
		rpc.messageHistory({
			input: { conversationId },
			fields: MESSAGE_FIELDS,
			...(filter ? { filter } : {}),
			page: { limit: options.limit },
			...opts
		})
	);
	if (!result.success) return result;
	return {
		success: true,
		data: { messages: result.data.results, hasMore: result.data.hasMore }
	};
}

/** Flips whether the message is excluded from the LLM context. */
export function toggleMessageDisabled(messageId: string): Promise<RpcResult<ChatMessage>> {
	return run((opts) =>
		rpc.toggleMessageDisabled({
			identity: messageId,
			fields: MESSAGE_FIELDS as rpc.ToggleMessageDisabledFields,
			...opts
		})
	) as Promise<RpcResult<ChatMessage>>;
}

export type AttachedResource = { type: 'file'; id: string };

/**
 * Sends a user message; `SignalAgent` fires server-side, so the agent's
 * response arrives through the conversation channel's streaming events.
 * `resources` attach uploaded files etc. via the AttachResources change.
 */
export function sendUserMessage(
	conversationId: string,
	text: string,
	resources: AttachedResource[] = [],
	metadata: Record<string, unknown> | null = null
): Promise<RpcResult<ChatMessage>> {
	return run((opts) =>
		rpc.sendUserMessage({
			input: {
				conversationId,
				text,
				...(resources.length > 0 ? { resources } : {}),
				...(metadata ? { metadata } : {})
			},
			fields: MESSAGE_FIELDS,
			...opts
		})
	);
}

export function deleteMessage(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.deleteMessage({ identity: id, ...opts }));
}

/**
 * Enqueues a user message while the agent is mid-turn instead of starting a
 * fresh turn. The server broadcasts `queued.enqueue_message` on the
 * conversation channel, which reconciles the store's `queued` array.
 */
export function enqueueMessage(
	conversationId: string,
	text: string,
	metadata: Record<string, unknown> | null = null
): Promise<RpcResult<ChatMessage>> {
	return run((opts) =>
		rpc.enqueueMessage({
			input: { conversationId, text, ...(metadata ? { metadata } : {}) },
			fields: MESSAGE_FIELDS as rpc.EnqueueMessageFields,
			...opts
		})
	) as Promise<RpcResult<ChatMessage>>;
}

/** Flushes the conversation's queued messages into the agent's turn now. */
export function sendNowQueued(conversationId: string): Promise<RpcResult<string>> {
	return run((opts) => rpc.sendNowQueued({ input: { conversationId }, ...opts }));
}

/** Drops a single queued message before it is sent. */
export function removeQueued(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.removeQueued({ identity: id, ...opts }));
}

// ─── Uploads ─────────────────────────────────────────────────────────────────

export type UploadedFile = {
	id: string;
	name: string;
	type: string;
	mimeType: string;
	fileSize: number;
};

export type UploadTarget = {
	conversationId?: string;
	workspaceId?: string;
	folderId?: string;
};

/**
 * Multipart upload to `POST /rpc/upload` (session-authenticated; storage
 * limits enforced server-side). Returns the same RPC envelope as the
 * generated client, so callers share error handling.
 */
export async function uploadFile(
	file: File,
	target: string | UploadTarget = {}
): Promise<RpcResult<UploadedFile>> {
	// String form kept for the composer call sites: a bare conversation id.
	const { conversationId, workspaceId, folderId } =
		typeof target === 'string' ? { conversationId: target } : target;

	const form = new FormData();
	form.append('file', file);
	if (conversationId) form.append('conversation_id', conversationId);
	if (workspaceId) form.append('workspace_id', workspaceId);
	if (folderId) form.append('folder_id', folderId);

	try {
		const response = await fetch('/rpc/upload', {
			method: 'POST',
			body: form,
			credentials: 'same-origin'
		});
		if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
		return (await response.json()) as RpcResult<UploadedFile>;
	} catch (error) {
		return {
			success: false,
			errors: [
				{
					type: 'network_error',
					message: error instanceof Error ? error.message : 'upload failed',
					shortMessage: 'Network error',
					vars: {},
					fields: [],
					path: []
				}
			]
		};
	}
}

// ─── Profile images (user avatar + custom-agent image) ─────────────────────────

export type ProfileImageTarget = { kind: 'avatar' } | { kind: 'agent'; agentId: string };

/** Shared fetch for the /rpc/profile-image/* controller endpoints. */
async function profileImageRequest(
	url: string,
	init: RequestInit
): Promise<RpcResult<{ url: string | null }>> {
	try {
		const response = await fetch(url, { method: 'POST', credentials: 'same-origin', ...init });
		if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
		return (await response.json()) as RpcResult<{ url: string | null }>;
	} catch (error) {
		return {
			success: false,
			errors: [
				{
					type: 'network_error',
					message: error instanceof Error ? error.message : 'request failed',
					shortMessage: 'Network error',
					vars: {},
					fields: [],
					path: []
				}
			]
		};
	}
}

function profileImageTargetFields(target: ProfileImageTarget): Record<string, string> {
	return target.kind === 'agent' ? { kind: 'agent', agent_id: target.agentId } : { kind: 'avatar' };
}

/** Manual upload of an avatar / agent image (multipart). */
export function uploadProfileImage(
	file: File,
	target: ProfileImageTarget
): Promise<RpcResult<{ url: string | null }>> {
	const form = new FormData();
	form.append('file', file);
	for (const [key, value] of Object.entries(profileImageTargetFields(target))) {
		form.append(key, value);
	}
	return profileImageRequest('/rpc/profile-image/upload', { body: form });
}

/** AI-generate an avatar / agent image; blocks while the model renders (~10-30s). */
export function generateProfileImage(
	prompt: string,
	style: string,
	target: ProfileImageTarget
): Promise<RpcResult<{ url: string | null }>> {
	return profileImageRequest('/rpc/profile-image/generate', {
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify({ prompt, style, ...profileImageTargetFields(target) })
	});
}

/** Clear the avatar / agent image. */
export function removeProfileImage(
	target: ProfileImageTarget
): Promise<RpcResult<{ url: string | null }>> {
	return profileImageRequest('/rpc/profile-image/remove', {
		headers: { 'content-type': 'application/json' },
		body: JSON.stringify(profileImageTargetFields(target))
	});
}

// ─── Integrations (per-user external services, e.g. Telegram) ──────────────────

export type IntegrationApproval = {
	chat_id?: string;
	sender_name?: string;
	username?: string;
};

export type IntegrationConfig = {
	bot_username?: string;
	pending_approvals?: IntegrationApproval[];
	allowed_chat_ids?: string[];
	[key: string]: unknown;
};

export type UserIntegrationEntry = {
	id: string;
	providerKey: string;
	status: string;
	externalId: string | null;
	config: IntegrationConfig | null;
};

const USER_INTEGRATION_FIELDS = [
	'id',
	'providerKey',
	'status',
	'externalId',
	'config'
] as rpc.ListUserIntegrationsFields;

export function listUserIntegrations(userId: string): Promise<RpcResult<UserIntegrationEntry[]>> {
	return run((opts) =>
		rpc.listUserIntegrations({ input: { userId }, fields: USER_INTEGRATION_FIELDS, ...opts })
	) as Promise<RpcResult<UserIntegrationEntry[]>>;
}

/** Persist a replacement config map (approve/deny/remove edit it in place). */
export function updateIntegrationConfig(
	id: string,
	config: IntegrationConfig
): Promise<RpcResult<UserIntegrationEntry>> {
	return run((opts) =>
		rpc.updateIntegrationConfig({
			identity: id,
			input: { config },
			fields: USER_INTEGRATION_FIELDS as rpc.UpdateIntegrationConfigFields,
			...opts
		})
	) as Promise<RpcResult<UserIntegrationEntry>>;
}

// ─── Knowledge sources (connected ingestion providers) ─────────────────────────

export type KnowledgeSourceEntry = {
	id: string;
	name: string;
	provider: string;
	status: string;
};

const KNOWLEDGE_SOURCE_FIELDS = [
	'id',
	'name',
	'provider',
	'status'
] as rpc.ListKnowledgeSourcesFields;

export function knowledgeSources(): Promise<RpcResult<KnowledgeSourceEntry[]>> {
	return run((opts) =>
		rpc.listKnowledgeSources({ fields: KNOWLEDGE_SOURCE_FIELDS, ...opts })
	) as Promise<RpcResult<KnowledgeSourceEntry[]>>;
}

/** Disconnect (delete) a connected knowledge source. */
export function disconnectKnowledgeSource(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.disconnectKnowledgeSource({ identity: id, ...opts }));
}

/** A browsable folder in a connected source (lazy children via parentId). */
export type KnowledgeFolderNode = { id: string; name: string; path: string };

/**
 * Validate API-key/URL credentials via the provider connector, then create +
 * activate a source. OAuth providers do NOT use this — their tokens are
 * finalized server-side via {@link finalizeKnowledgeOauth}.
 */
export function connectKnowledgeSource(input: {
	provider: string;
	authConfig: Record<string, unknown>;
	name?: string | null;
	workspaceId?: string | null;
}): Promise<RpcResult<KnowledgeSourceEntry>> {
	return run((opts) => rpc.connectKnowledgeSource({ input, ...opts })) as Promise<
		RpcResult<KnowledgeSourceEntry>
	>;
}

/** Browse a connected source's folders (null parent = root; lazy on expand). */
export function knowledgeSourceFolders(
	sourceId: string,
	parentId: string | null = null
): Promise<RpcResult<KnowledgeFolderNode[]>> {
	return run((opts) =>
		rpc.knowledgeSourceFolders({ input: { sourceId, parentId }, ...opts })
	) as Promise<RpcResult<KnowledgeFolderNode[]>>;
}

/** Create + sync a collection for each selected folder. */
export function createKnowledgeCollections(
	sourceId: string,
	folders: KnowledgeFolderNode[]
): Promise<RpcResult<{ created: number }>> {
	return run((opts) =>
		rpc.createKnowledgeCollections({ input: { sourceId, folders }, ...opts })
	) as Promise<RpcResult<{ created: number }>>;
}

/**
 * Finalize an OAuth connect after the provider redirect lands back on the SPA.
 * The callback stashed the tokens in the session; this creates the source
 * server-side so the tokens never touch the browser. Returns the new source.
 */
export async function finalizeKnowledgeOauth(
	provider: string
): Promise<{ ok: true; source: KnowledgeSourceEntry } | { ok: false; error: string }> {
	try {
		const response = await fetch('/rpc/knowledge/oauth-finalize', {
			method: 'POST',
			credentials: 'same-origin',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify({ provider })
		});
		const body = (await response.json()) as { source?: KnowledgeSourceEntry; error?: string };
		if (response.ok && body.source) return { ok: true, source: body.source };
		return { ok: false, error: body.error ?? 'Could not finalize the connection.' };
	} catch (error) {
		return { ok: false, error: error instanceof Error ? error.message : 'Network error' };
	}
}

/** Ascending by inserted_at (the `:since` action sorts server-side). */
export function messagesSince(
	conversationId: string,
	since: string
): Promise<RpcResult<ChatMessage[]>> {
	return run((opts) =>
		rpc.messagesSince({
			input: { conversationId, since },
			fields: MESSAGE_FIELDS,
			...opts
		})
	);
}

// ─── Threads ─────────────────────────────────────────────────────────────────

export type ThreadSummary = {
	id: string;
	title: string | null;
	branchedAtMessageId: string | null;
	insertedAt: string;
	/** Replies in the thread (drives the chip on the branched message). */
	messageCount: number;
};

const THREAD_FIELDS: rpc.ConversationThreadsFields = [
	'id',
	'title',
	'branchedAtMessageId',
	'insertedAt',
	'messageCount'
];

/** Branches a thread conversation off a message (idempotency is the caller's concern). */
export function createThread(
	parentConversationId: string,
	branchedAtMessageId: string
): Promise<RpcResult<ThreadSummary>> {
	return run((opts) =>
		rpc.createThread({
			input: { parentConversationId, branchedAtMessageId },
			fields: THREAD_FIELDS,
			...opts
		})
	);
}

/** Threads branched off the conversation, oldest first. */
export function conversationThreads(conversationId: string): Promise<RpcResult<ThreadSummary[]>> {
	return run((opts) =>
		rpc.conversationThreads({
			input: { conversationId },
			fields: THREAD_FIELDS,
			...opts
		})
	);
}

export type ThreadNavSummary = {
	id: string;
	title: string | null;
	parentConversationId: string | null;
	insertedAt: string;
	messageCount: number;
};

const THREAD_NAV_FIELDS: rpc.ConversationsThreadsFields = [
	'id',
	'title',
	'parentConversationId',
	'insertedAt',
	'messageCount'
];

/** Threads for many parent conversations, oldest first, grouped by the caller. */
export function conversationsThreads(
	conversationIds: string[]
): Promise<RpcResult<ThreadNavSummary[]>> {
	if (conversationIds.length === 0) return Promise.resolve({ success: true, data: [] });
	return run((opts) =>
		rpc.conversationsThreads({
			input: { conversationIds },
			fields: THREAD_NAV_FIELDS,
			...opts
		})
	);
}

// ─── Brain (read-only companion) ─────────────────────────────────────────────

export type BrainPageDetail = {
	id: string;
	title: string | null;
	icon: string | null;
	body: string | null;
	updatedAt: string;
	/** `'plan'` pages render the structured task board below the editor. */
	kind: 'page' | 'plan';
	/** Scope pill: workspaceId null = personal brain. */
	brain: { id: string; workspaceId: string | null };
};

export function getBrainPage(id: string): Promise<RpcResult<BrainPageDetail>> {
	return run((opts) =>
		rpc.getBrainPage({
			getBy: { id },
			fields: [
				'id',
				'title',
				'icon',
				'body',
				'updatedAt',
				'kind',
				{ brain: ['id', 'workspaceId'] }
			],
			...opts
		})
	);
}

export type PageBacklink = {
	id: string;
	targetTitleAtLinkTime: string;
	sourcePage: { id: string; title: string | null; icon: string | null };
};

/** Pages that mention the given page (the companion's Related tab). */
export function listPageBacklinks(pageId: string): Promise<RpcResult<PageBacklink[]>> {
	return run((opts) =>
		rpc.listPageBacklinks({
			input: { pageId },
			fields: ['id', 'targetTitleAtLinkTime', { sourcePage: ['id', 'title', 'icon'] }],
			...opts
		})
	);
}

export type PageSourceEntry = {
	id: string;
	position: number;
	source: {
		id: string;
		url: string;
		title: string | null;
		sourceType: string;
		ingestStatus: string;
	};
};

/** Sources referenced from the page body, in document order. */
export function listPageSources(pageId: string): Promise<RpcResult<PageSourceEntry[]>> {
	return run((opts) =>
		rpc.listPageSources({
			input: { pageId },
			fields: ['id', 'position', { source: ['id', 'url', 'title', 'sourceType', 'ingestStatus'] }],
			...opts
		})
	);
}

/**
 * Entry shape from `Magus.Brain.PageHistory` (generic action — keys arrive
 * snake_case, untouched by the field formatter).
 */
export type BrainPageVersion = {
	version_id: string;
	inserted_at: string;
	action_name: string | null;
	contributor_id: string | null;
	preview: string | null;
};

export function listBrainPageVersions(pageId: string): Promise<RpcResult<BrainPageVersion[]>> {
	return run((opts) => rpc.listBrainPageVersions({ input: { pageId }, ...opts }));
}

// ─── Drafts (read-only companion) ────────────────────────────────────────────

export type DraftDetail = {
	id: string;
	title: string;
	/** ProseMirror document JSON. */
	content: Record<string, unknown>;
	version: number;
	updatedAt: string;
	conversationId: string;
};

const DRAFT_FIELDS: rpc.GetDraftFields = [
	'id',
	'title',
	'content',
	'version',
	'updatedAt',
	'conversationId'
];

export function getDraft(id: string): Promise<RpcResult<DraftDetail>> {
	return run((opts) => rpc.getDraft({ getBy: { id }, fields: DRAFT_FIELDS, ...opts }));
}

export function conversationDrafts(conversationId: string): Promise<RpcResult<DraftDetail[]>> {
	return run((opts) =>
		rpc.conversationDrafts({ input: { conversationId }, fields: DRAFT_FIELDS, ...opts })
	);
}

export function deleteDraft(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.deleteDraft({ identity: id, ...opts }));
}

/** Writes the full ProseMirror document; the server increments `version`. */
export function updateDraftContent(
	id: string,
	contentJson: Record<string, unknown>
): Promise<RpcResult<DraftDetail>> {
	return run((opts) =>
		rpc.updateDraftContent({ identity: id, input: { contentJson }, fields: DRAFT_FIELDS, ...opts })
	);
}

export function renameDraft(id: string, title: string): Promise<RpcResult<DraftDetail>> {
	return run((opts) =>
		rpc.renameDraft({ identity: id, input: { title }, fields: DRAFT_FIELDS, ...opts })
	);
}

export type DraftExportFormat = 'pdf' | 'docx' | 'latex' | 'markdown';

export type DraftVersion = {
	id: string;
	/** The action that produced this version (e.g. "update_content"). */
	action: string;
	insertedAt: string | null;
	title: string | null;
	/** ProseMirror document JSON at this version (for read-only preview). */
	content: Record<string, unknown> | null;
};

/** Paper-trail versions for a draft, newest first. */
export async function draftVersions(draftId: string): Promise<RpcResult<DraftVersion[]>> {
	const result = await run<Array<Record<string, unknown>>>((opts) =>
		rpc.draftVersions({ input: { draftId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: result.data.map((version) => ({
			id: String(version.id ?? ''),
			action: String(version.action ?? ''),
			insertedAt: (version.inserted_at ?? null) as string | null,
			title: (version.title ?? null) as string | null,
			content: (version.content ?? null) as Record<string, unknown> | null
		}))
	};
}

/**
 * Kicks off a draft export: the agent generates the file and streams it into
 * the conversation. Resolves once the job is enqueued (the result arrives via
 * the conversation channel, not this call).
 */
export async function exportDraft(
	draftId: string,
	conversationId: string,
	exportFormat: DraftExportFormat
): Promise<RpcResult<Record<string, never>>> {
	const result = await run<Record<string, unknown>>((opts) =>
		rpc.exportDraft({ input: { draftId, conversationId, exportFormat }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: {} };
}

/** Restores draft content + title from a paper-trail version snapshot. */
export function restoreDraftVersion(
	id: string,
	versionId: string
): Promise<RpcResult<DraftDetail>> {
	return run((opts) =>
		rpc.restoreDraftVersion({
			identity: id,
			input: { versionId },
			fields: DRAFT_FIELDS as rpc.RestoreDraftVersionFields,
			...opts
		})
	);
}

// ─── Files browser ───────────────────────────────────────────────────────────

export type FileEntry = {
	id: string;
	name: string;
	type: 'document' | 'text' | 'image' | 'video' | 'email';
	source: 'user' | 'agent' | 'connector';
	mimeType: string;
	fileSize: number;
	/** Storage path; preview URL is `/uploads/files/<filePath>` (re-authorized server-side). */
	filePath: string;
	isTemplate: boolean;
	status: 'pending' | 'processing' | 'ready' | 'error';
	updatedAt: string;
	folderId: string | null;
	workspaceId: string | null;
	userId: string;
	isSharedToWorkspace: boolean;
};

const FILE_FIELDS: rpc.MyLibraryFilesFields = [
	'id',
	'name',
	'type',
	'source',
	'mimeType',
	'fileSize',
	'filePath',
	'isTemplate',
	'status',
	'updatedAt',
	'folderId',
	'workspaceId',
	'userId',
	'isSharedToWorkspace'
];

/** Inline preview / thumbnail URL (the serve controller authorizes per request). */
export function fileUrl(file: Pick<FileEntry, 'filePath'>): string {
	return `/uploads/files/${file.filePath}`;
}

export function fileDownloadUrl(file: Pick<FileEntry, 'id'>): string {
	return `/files/${file.id}/download`;
}

export function myLibraryFiles(): Promise<RpcResult<FileEntry[]>> {
	return run((opts) => rpc.myLibraryFiles({ input: {}, fields: FILE_FIELDS, ...opts }));
}

/** Files attached to a conversation (right-rail Files panel "Chat" scope). */
export function conversationFiles(conversationId: string): Promise<RpcResult<FileEntry[]>> {
	return run((opts) =>
		rpc.conversationFiles({ input: { conversationId }, fields: FILE_FIELDS, ...opts })
	);
}

export function workspaceLibraryFiles(workspaceId: string): Promise<RpcResult<FileEntry[]>> {
	return run((opts) =>
		rpc.workspaceLibraryFiles({ input: { workspaceId }, fields: FILE_FIELDS, ...opts })
	);
}

export function folderFiles(folderId: string): Promise<RpcResult<FileEntry[]>> {
	return run((opts) => rpc.folderFiles({ input: { folderId }, fields: FILE_FIELDS, ...opts }));
}

export function recentFiles(
	workspaceId: string | null,
	since: string
): Promise<RpcResult<FileEntry[]>> {
	return run((opts) =>
		rpc.recentFiles({ input: { workspaceId, since }, fields: FILE_FIELDS, ...opts })
	);
}

export function sharedWithMeFiles(workspaceId: string): Promise<RpcResult<FileEntry[]>> {
	return run((opts) =>
		rpc.sharedWithMeFiles({ input: { workspaceId }, fields: FILE_FIELDS, ...opts })
	);
}

export function trashFiles(workspaceId: string | null): Promise<RpcResult<FileEntry[]>> {
	return run((opts) => rpc.trashFiles({ input: { workspaceId }, fields: FILE_FIELDS, ...opts }));
}

export function templateFiles(): Promise<RpcResult<FileEntry[]>> {
	return run((opts) => rpc.templateFiles({ input: {}, fields: FILE_FIELDS, ...opts }));
}

export function getFile(id: string): Promise<RpcResult<FileEntry>> {
	return run((opts) => rpc.getFile({ getBy: { id }, fields: FILE_FIELDS, ...opts }));
}

export function updateFile(
	id: string,
	input: { name?: string; isTemplate?: boolean }
): Promise<RpcResult<FileEntry>> {
	return run((opts) => rpc.renameFile({ identity: id, input, fields: FILE_FIELDS, ...opts }));
}

/** Soft delete — the file moves to the trash scope. */
export function trashFile(id: string): Promise<RpcResult<FileEntry>> {
	return run((opts) => rpc.trashFile({ identity: id, fields: FILE_FIELDS, ...opts }));
}

/** Hard delete incl. stored bytes — for discarding never-sent uploads. */
export function deleteFile(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.deleteFile({ identity: id, ...opts }));
}

export function shareFileToTeam(id: string): Promise<RpcResult<FileEntry>> {
	return run((opts) => rpc.shareFileToTeam({ identity: id, fields: FILE_FIELDS, ...opts }));
}

export function unshareFileFromTeam(id: string): Promise<RpcResult<FileEntry>> {
	return run((opts) => rpc.unshareFileFromTeam({ identity: id, fields: FILE_FIELDS, ...opts }));
}

/**
 * Moves a file between contexts: a folder, a conversation, or (both null)
 * the global library. Moving into an opposite-kind folder silently promotes
 * the folder to :mixed server-side.
 */
export function moveFile(
	id: string,
	target: { folderId?: string | null; conversationId?: string | null }
): Promise<RpcResult<FileEntry>> {
	return run((opts) =>
		rpc.moveFile({
			identity: id,
			input: { folderId: target.folderId ?? null, conversationId: target.conversationId ?? null },
			fields: FILE_FIELDS,
			...opts
		})
	);
}

// ─── Knowledge collections (Connected sources) ───────────────────────────────

export type KnowledgeCollectionSummary = {
	id: string;
	name: string;
	syncStatus: 'pending' | 'syncing' | 'synced' | 'error' | 'disabled';
	itemCount: number;
};

const COLLECTION_FIELDS: rpc.MyKnowledgeCollectionsFields = [
	'id',
	'name',
	'syncStatus',
	'itemCount'
];

export function myKnowledgeCollections(): Promise<RpcResult<KnowledgeCollectionSummary[]>> {
	return run((opts) => rpc.myKnowledgeCollections({ fields: COLLECTION_FIELDS, ...opts }));
}

export function workspaceKnowledgeCollections(
	workspaceId: string
): Promise<RpcResult<KnowledgeCollectionSummary[]>> {
	return run((opts) =>
		rpc.workspaceKnowledgeCollections({
			input: { workspaceId },
			fields: COLLECTION_FIELDS,
			...opts
		})
	);
}

/** Files belonging to a synced collection (read-only browser scope). */
export function collectionFiles(knowledgeCollectionId: string): Promise<RpcResult<FileEntry[]>> {
	return run((opts) =>
		rpc.collectionFiles({ input: { knowledgeCollectionId }, fields: FILE_FIELDS, ...opts })
	);
}

// ─── Folders ─────────────────────────────────────────────────────────────────

export type FolderKind = 'files' | 'conversations' | 'mixed';

export type FolderEntry = {
	id: string;
	name: string;
	kind: FolderKind;
	parentId: string | null;
	workspaceId: string | null;
	isSharedToWorkspace: boolean;
	userId: string;
};

const FOLDER_FIELDS: rpc.MyFoldersFields = [
	'id',
	'name',
	'kind',
	'parentId',
	'workspaceId',
	'isSharedToWorkspace',
	'userId'
];

export function myFolders(kinds?: FolderKind[]): Promise<RpcResult<FolderEntry[]>> {
	return run((opts) =>
		rpc.myFolders({ input: { kinds: kinds ?? null }, fields: FOLDER_FIELDS, ...opts })
	);
}

export function workspaceFolders(
	workspaceId: string,
	kinds?: FolderKind[]
): Promise<RpcResult<FolderEntry[]>> {
	return run((opts) =>
		rpc.workspaceFolders({
			input: { workspaceId, kinds: kinds ?? null },
			fields: FOLDER_FIELDS,
			...opts
		})
	);
}

export function folderChildren(
	parentId: string,
	kinds?: FolderKind[]
): Promise<RpcResult<FolderEntry[]>> {
	return run((opts) =>
		rpc.folderChildren({
			input: { parentId, kinds: kinds ?? null },
			fields: FOLDER_FIELDS,
			...opts
		})
	);
}

export function getFolder(id: string): Promise<RpcResult<FolderEntry>> {
	return run((opts) => rpc.getFolder({ getBy: { id }, fields: FOLDER_FIELDS, ...opts }));
}

export function createFolder(input: {
	name: string;
	kind: FolderKind;
	parentId?: string | null;
	workspaceId?: string | null;
}): Promise<RpcResult<FolderEntry>> {
	return run((opts) => rpc.createFolder({ input, fields: FOLDER_FIELDS, ...opts }));
}

export function renameFolder(id: string, name: string): Promise<RpcResult<FolderEntry>> {
	return run((opts) =>
		rpc.renameFolder({ identity: id, input: { name }, fields: FOLDER_FIELDS, ...opts })
	);
}

export function moveFolder(id: string, parentId: string | null): Promise<RpcResult<FolderEntry>> {
	return run((opts) =>
		rpc.moveFolder({ identity: id, input: { parentId }, fields: FOLDER_FIELDS, ...opts })
	);
}

export function deleteFolder(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.deleteFolder({ identity: id, ...opts }));
}

/** Shares the folder with cascade to children (classic share_folder_to_team). */
export function shareFolderToTeam(id: string): Promise<RpcResult<FolderEntry>> {
	return run((opts) => rpc.shareFolderToTeam({ identity: id, fields: FOLDER_FIELDS, ...opts }));
}

export function unshareFolderFromTeam(id: string): Promise<RpcResult<FolderEntry>> {
	return run((opts) => rpc.unshareFolderFromTeam({ identity: id, fields: FOLDER_FIELDS, ...opts }));
}

// Per-user folder expansion state for the chat nav (classic parity).

export type FolderStateEntry = { id: string; folderId: string; isExpanded: boolean };

const FOLDER_STATE_FIELDS: rpc.MyFolderStatesFields = ['id', 'folderId', 'isExpanded'];

export function myFolderStates(): Promise<RpcResult<FolderStateEntry[]>> {
	return run((opts) => rpc.myFolderStates({ fields: FOLDER_STATE_FIELDS, ...opts }));
}

export function upsertFolderExpanded(
	folderId: string,
	isExpanded: boolean
): Promise<RpcResult<FolderStateEntry>> {
	return run((opts) =>
		rpc.upsertFolderExpanded({
			input: { folderId, isExpanded },
			fields: FOLDER_STATE_FIELDS,
			...opts
		})
	);
}

// ─── Prompt library ──────────────────────────────────────────────────────────

export type PromptType = 'system' | 'user';

export type PromptSummary = {
	id: string;
	name: string;
	description: string | null;
	type: PromptType;
	isFavorited: boolean;
	isSharedToWorkspace: boolean;
	workspaceId: string | null;
	content: string;
	useCount: number;
	tags: { id: string; name: string }[];
};

export type PromptDetail = PromptSummary & {
	chatMode: string | null;
	additionalInformation: string | null;
	isPublic: boolean;
};

// The list payload now carries content + tags + useCount so the library gallery
// can render previews and counts without a per-card fetch (these are public
// fields on the same resource, so no new RPC or codegen is needed).
const PROMPT_SUMMARY_FIELDS: rpc.MyPromptsFields = [
	'id',
	'name',
	'description',
	'type',
	'isFavorited',
	'isSharedToWorkspace',
	'workspaceId',
	'content',
	'useCount',
	{ tags: ['id', 'name'] }
];

const PROMPT_DETAIL_FIELDS: rpc.GetPromptFields = [
	...PROMPT_SUMMARY_FIELDS,
	'chatMode',
	'additionalInformation',
	'isPublic'
];

export function myPrompts(): Promise<RpcResult<PromptSummary[]>> {
	return run((opts) => rpc.myPrompts({ fields: PROMPT_SUMMARY_FIELDS, ...opts }));
}

export function myFavoritePrompts(): Promise<RpcResult<PromptSummary[]>> {
	return run((opts) => rpc.myFavoritePrompts({ fields: PROMPT_SUMMARY_FIELDS, ...opts }));
}

export function workspacePrompts(workspaceId: string): Promise<RpcResult<PromptSummary[]>> {
	return run((opts) =>
		rpc.workspacePrompts({ input: { workspaceId }, fields: PROMPT_SUMMARY_FIELDS, ...opts })
	);
}

export function getPrompt(id: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) => rpc.getPrompt({ getBy: { id }, fields: PROMPT_DETAIL_FIELDS, ...opts }));
}

export function createPrompt(input: {
	name: string;
	content: string;
	type: PromptType;
	description?: string;
	additionalInformation?: string;
	workspaceId?: string | null;
}): Promise<RpcResult<PromptDetail>> {
	return run((opts) => rpc.createPrompt({ input, fields: PROMPT_DETAIL_FIELDS, ...opts }));
}

export function updatePrompt(
	id: string,
	input: {
		name?: string;
		content?: string;
		description?: string;
		additionalInformation?: string;
		type?: PromptType;
	}
): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.updatePrompt({ identity: id, input, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function destroyPrompt(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyPrompt({ identity: id, ...opts }));
}

export function publishPrompt(id: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) => rpc.publishPrompt({ identity: id, fields: PROMPT_DETAIL_FIELDS, ...opts }));
}

export function unpublishPrompt(id: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.unpublishPrompt({ identity: id, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function sharePromptToTeam(id: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.sharePromptToTeam({ identity: id, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function unsharePromptFromTeam(id: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.unsharePromptFromTeam({ identity: id, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function addPromptTags(id: string, tagIds: string[]): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.addPromptTags({ identity: id, input: { tagIds }, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function removePromptTag(id: string, tagId: string): Promise<RpcResult<PromptDetail>> {
	return run((opts) =>
		rpc.removePromptTag({ identity: id, input: { tagId }, fields: PROMPT_DETAIL_FIELDS, ...opts })
	);
}

export function incrementPromptUseCount(id: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.incrementPromptUseCount({ identity: id, fields: ['id'], ...opts }));
}

export type TagEntry = {
	id: string;
	name: string;
	userId: string | null;
	workspaceId: string | null;
};

const TAG_FIELDS = ['id', 'name', 'userId', 'workspaceId'] as const;

export function listTags(): Promise<RpcResult<TagEntry[]>> {
	return run((opts) => rpc.listTags({ fields: [...TAG_FIELDS], ...opts }));
}

/**
 * Create (or fetch) a user-defined tag. With a workspaceId the tag is shared
 * with that workspace; without one it is personal to the caller.
 */
export function getOrCreateTag(
	name: string,
	workspaceId: string | null
): Promise<RpcResult<TagEntry>> {
	return run((opts) =>
		rpc.getOrCreateTag({ input: { name, workspaceId }, fields: [...TAG_FIELDS], ...opts })
	);
}

export type PromptFavoriteEntry = { id: string; promptId: string };

export function myPromptFavorites(): Promise<RpcResult<PromptFavoriteEntry[]>> {
	return run((opts) => rpc.myPromptFavorites({ fields: ['id', 'promptId'], ...opts }));
}

export function favoritePrompt(promptId: string): Promise<RpcResult<PromptFavoriteEntry>> {
	return run((opts) =>
		rpc.favoritePrompt({ input: { promptId }, fields: ['id', 'promptId'], ...opts })
	);
}

export function unfavoritePrompt(favoriteId: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.unfavoritePrompt({ identity: favoriteId, ...opts }));
}

// ─── Agents (config + control room) ──────────────────────────────────────────

/** Disable-able tool categories on a CustomAgent (matches the backend one_of). */
export type ToolCategory =
	| 'web'
	| 'code'
	| 'memory'
	| 'files'
	| 'skills'
	| 'tasks'
	| 'integrations';

export type AgentDetail = {
	id: string;
	name: string;
	handle: string;
	description: string | null;
	icon: string | null;
	instructions: string | null;
	chatMode: string | null;
	maxIterations: number | null;
	/** Per-mode model presets for this agent's conversations. */
	modelId: string | null;
	imageModelId: string | null;
	videoModelId: string | null;
	/** Disabled tool categories (web/code/memory/files/skills/tasks/integrations). */
	disabledToolCategories: ToolCategory[];
	/** Skill names pre-loaded into every conversation. */
	preLoadedSkills: string[];
	isDefault: boolean;
	isPaused: boolean;
	pauseReason: string | null;
	isSharedToWorkspace: boolean;
	canReadGlobalMemories: boolean;
	canWriteGlobalMemories: boolean;
	canAccessGlobalFiles: boolean;
	canAccessKnowledge: boolean;
	heartbeatEnabled: boolean;
	heartbeatInstructions: string | null;
	heartbeatDefaultIntervalMinutes: number | null;
	maxDailyRuns: number | null;
	maxTokensPerRun: number | null;
	nextScheduledAt: string | null;
	updatedAt: string;
	imageUrl: string | null;
	/** Server-evaluated update permission (drives the inspect/edit split). */
	editableByActor: boolean;
};

const AGENT_DETAIL_FIELDS: rpc.GetCustomAgentFields = [
	'id',
	'name',
	'handle',
	'description',
	'icon',
	'instructions',
	'chatMode',
	'maxIterations',
	'modelId',
	'imageModelId',
	'videoModelId',
	'disabledToolCategories',
	'preLoadedSkills',
	'isDefault',
	'isPaused',
	'pauseReason',
	'isSharedToWorkspace',
	'canReadGlobalMemories',
	'canWriteGlobalMemories',
	'canAccessGlobalFiles',
	'canAccessKnowledge',
	'heartbeatEnabled',
	'heartbeatInstructions',
	'heartbeatDefaultIntervalMinutes',
	'maxDailyRuns',
	'maxTokensPerRun',
	'nextScheduledAt',
	'updatedAt',
	'imageUrl',
	'editableByActor'
];

export function workspaceAgents(workspaceId: string): Promise<RpcResult<AgentSummary[]>> {
	return run((opts) =>
		rpc.workspaceAgents({
			input: { workspaceId },
			fields: AGENT_SUMMARY_FIELDS,
			...opts
		})
	);
}

export function getCustomAgent(id: string): Promise<RpcResult<AgentDetail>> {
	return run((opts) => rpc.getCustomAgent({ getBy: { id }, fields: AGENT_DETAIL_FIELDS, ...opts }));
}

export type AvailableSkill = { name: string; description: string };

/** Skills registry for the agent editor's pre-loaded-skills picker. */
export async function listAvailableSkills(): Promise<RpcResult<AvailableSkill[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.listAvailableSkills({ ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((skill) => ({
			name: String(skill.name ?? ''),
			description: String(skill.description ?? '')
		}))
	};
}

// ─── Agent Knowledge section: memories + brain/collection grants ─────────────

/** An agent-scoped memory (confidence is 0..1). Generic action → snake-ish keys. */
export type AgentMemory = {
	id: string;
	name: string;
	summary: string | null;
	kind: string;
	confidence: number;
};

function toAgentMemory(m: Record<string, unknown>): AgentMemory {
	return {
		id: String(m.id ?? ''),
		name: String(m.name ?? ''),
		summary: typeof m.summary === 'string' ? m.summary : null,
		kind: String(m.kind ?? 'general'),
		confidence: typeof m.confidence === 'number' ? m.confidence : 1
	};
}

export async function agentMemories(agentId: string): Promise<RpcResult<AgentMemory[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.agentMemories({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: (result.data ?? []).map(toAgentMemory) };
}

export async function updateAgentMemory(input: {
	memoryId: string;
	summary: string | null;
	kind: string;
	confidence: number;
}): Promise<RpcResult<AgentMemory>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.updateAgentMemory({ input, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: toAgentMemory(result.data ?? {}) };
}

export async function deleteAgentMemory(memoryId: string): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.deleteAgentMemory({ input: { memoryId }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? memoryId) } };
}

export type AgentBrainAccess = { id: string; title: string; icon: string | null; granted: boolean };
export type AgentCollectionAccess = {
	id: string;
	name: string;
	itemCount: number;
	granted: boolean;
};
export type AgentKnowledgeAccess = {
	brains: AgentBrainAccess[];
	sources: { name: string; collections: AgentCollectionAccess[] }[];
};

export async function agentKnowledgeAccess(
	agentId: string
): Promise<RpcResult<AgentKnowledgeAccess>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.agentKnowledgeAccess({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	const brains = (Array.isArray(data.brains) ? data.brains : []) as Record<string, unknown>[];
	const sources = (Array.isArray(data.sources) ? data.sources : []) as Record<string, unknown>[];
	return {
		success: true,
		data: {
			brains: brains.map((brain) => ({
				id: String(brain.id ?? ''),
				title: String(brain.title ?? ''),
				icon: typeof brain.icon === 'string' ? brain.icon : null,
				granted: brain.granted === true
			})),
			sources: sources.map((source) => ({
				name: String(source.name ?? ''),
				collections: (
					(Array.isArray(source.collections) ? source.collections : []) as Record<string, unknown>[]
				).map((collection) => ({
					id: String(collection.id ?? ''),
					name: String(collection.name ?? ''),
					itemCount: typeof collection.item_count === 'number' ? collection.item_count : 0,
					granted: collection.granted === true
				}))
			}))
		}
	};
}

export async function setAgentResourceAccess(input: {
	agentId: string;
	resourceType: 'brain' | 'knowledge_collection';
	resourceId: string;
	granted: boolean;
}): Promise<RpcResult<{ granted: boolean }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.setAgentResourceAccess({ input, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { granted: (result.data ?? {}).granted === true } };
}

// ─── Agent Attachments section ───────────────────────────────────────────────

export type AttachmentMode = 'always' | 'search';
export type AgentAttachment = {
	id: string;
	mode: AttachmentMode;
	position: number;
	fileId: string;
	fileName: string;
	fileType: string;
	fileSize: number | null;
	/** Sum of the file's chunk token_counts; budgeted across `always` mode. */
	tokenCount: number;
	/** File processing status; the mode select is gated until `ready`. */
	status: 'pending' | 'processing' | 'ready' | 'error';
};

/** Max attachments per agent — keep in sync with Magus.Agents.AttachmentLimits. */
export const MAX_AGENT_ATTACHMENTS = 20;

export async function agentAttachments(agentId: string): Promise<RpcResult<AgentAttachment[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.agentAttachments({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((row) => ({
			id: String(row.id ?? ''),
			mode: row.mode === 'always' ? 'always' : 'search',
			position: typeof row.position === 'number' ? row.position : 0,
			fileId: String(row.file_id ?? ''),
			fileName: String(row.file_name ?? 'file'),
			fileType: String(row.file_type ?? 'file'),
			fileSize: typeof row.file_size === 'number' ? row.file_size : null,
			tokenCount: typeof row.token_count === 'number' ? row.token_count : 0,
			// Default to `ready` (enabled) when the field is absent, so a backend
			// that predates this field does not wrongly gate the mode select.
			status:
				row.file_status === 'pending' ||
				row.file_status === 'processing' ||
				row.file_status === 'error'
					? row.file_status
					: 'ready'
		}))
	};
}

export async function addAgentAttachment(
	agentId: string,
	fileId: string,
	mode: AttachmentMode
): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.addAgentAttachment({ input: { agentId, fileId, mode }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? '') } };
}

export async function setAgentAttachmentMode(
	attachmentId: string,
	mode: AttachmentMode
): Promise<RpcResult<{ id: string; mode: AttachmentMode }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.setAgentAttachmentMode({ input: { attachmentId, mode }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			id: String(data.id ?? attachmentId),
			mode: data.mode === 'always' ? 'always' : 'search'
		}
	};
}

export async function removeAgentAttachment(
	attachmentId: string
): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.removeAgentAttachment({ input: { attachmentId }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? attachmentId) } };
}

// ─── Agent Integrations section (manage-only) ────────────────────────────────

export type IntegrationTool = { key: string; name: string };
export type AgentIntegration = {
	id: string;
	providerKey: string;
	providerName: string;
	sourceType: string;
	status: string;
	enabledTools: string[];
	availableTools: IntegrationTool[];
	/** Per-provider config (feed urls, webhook secret, thresholds, key prefix). */
	config: IntegrationConfig;
};

export async function agentIntegrations(agentId: string): Promise<RpcResult<AgentIntegration[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.agentIntegrations({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((row) => ({
			id: String(row.id ?? ''),
			providerKey: String(row.provider_key ?? ''),
			providerName: String(row.provider_name ?? row.provider_key ?? ''),
			sourceType: String(row.source_type ?? 'other'),
			status: String(row.status ?? ''),
			enabledTools: Array.isArray(row.enabled_tools) ? row.enabled_tools.map(String) : [],
			availableTools: (
				(Array.isArray(row.available_tools) ? row.available_tools : []) as Record<string, unknown>[]
			).map((tool) => ({ key: String(tool.key ?? ''), name: String(tool.name ?? tool.key ?? '') })),
			config: row.config && typeof row.config === 'object' ? (row.config as IntegrationConfig) : {}
		}))
	};
}

export async function disconnectAgentIntegration(
	integrationId: string
): Promise<RpcResult<{ id: string }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.disconnectAgentIntegration({ input: { integrationId }, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: { id: String((result.data ?? {}).id ?? integrationId) } };
}

export async function setAgentIntegrationTool(
	integrationId: string,
	tool: string,
	enabled: boolean
): Promise<RpcResult<{ id: string; enabledTools: string[] }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.setAgentIntegrationTool({ input: { integrationId, tool, enabled }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			id: String(data.id ?? integrationId),
			enabledTools: Array.isArray(data.enabled_tools) ? data.enabled_tools.map(String) : []
		}
	};
}

/** A dynamic credential field a provider asks for (from its auth_fields). */
export type IntegrationAuthField = {
	name: string;
	label: string;
	type: string;
	help: string | null;
};

/** A provider the connect wizard can set up. */
export type IntegrationProviderMeta = {
	key: string;
	name: string;
	description: string;
	/** 'none' | 'api_key' | 'oauth2' | 'webhook_only' | 'imap' */
	authType: string;
	sourceType: string;
	requiresAdmin: boolean;
	authFields: IntegrationAuthField[];
};

export type ConnectedIntegration = {
	id: string;
	providerKey: string;
	status: string;
	authType: string;
	/** One-time API key (api provider only); never re-fetchable afterwards. */
	apiKey: string | null;
};

/** Providers the agent can connect (excludes knowledge sources + admin-only when not admin). */
export async function availableIntegrationProviders(
	agentId: string
): Promise<RpcResult<IntegrationProviderMeta[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.availableIntegrationProviders({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((row) => ({
			key: String(row.key ?? ''),
			name: String(row.name ?? ''),
			description: String(row.description ?? ''),
			authType: String(row.auth_type ?? 'none'),
			sourceType: String(row.source_type ?? ''),
			requiresAdmin: row.requires_admin === true,
			authFields: (
				(Array.isArray(row.auth_fields) ? row.auth_fields : []) as Record<string, unknown>[]
			).map((field) => ({
				name: String(field.name ?? ''),
				label: String(field.label ?? ''),
				type: String(field.type ?? 'text'),
				help: field.help == null ? null : String(field.help)
			}))
		}))
	};
}

/**
 * Connect a new integration for an agent. For OAuth providers this creates the
 * integration (the caller then redirects to /oauth/<key>/authorize); for the
 * api provider the returned `apiKey` is the one-time plaintext to show once.
 */
export async function connectAgentIntegration(input: {
	agentId: string;
	providerKey: string;
	credentials?: Record<string, unknown>;
	config?: Record<string, unknown>;
}): Promise<RpcResult<ConnectedIntegration>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.connectAgentIntegration({ input, ...opts })
	);
	if (!result.success) return result;
	const row = result.data ?? {};
	return {
		success: true,
		data: {
			id: String(row.id ?? ''),
			providerKey: String(row.provider_key ?? ''),
			status: String(row.status ?? ''),
			authType: String(row.auth_type ?? 'none'),
			apiKey: typeof row.api_key === 'string' ? row.api_key : null
		}
	};
}

export function createCustomAgent(input: {
	name: string;
	description?: string;
	instructions?: string;
	workspaceId?: string | null;
}): Promise<RpcResult<AgentDetail>> {
	return run((opts) => rpc.createCustomAgent({ input, fields: AGENT_DETAIL_FIELDS, ...opts }));
}

/** Section-based partial update — pass only the fields a section edited. */
export function updateCustomAgent(
	id: string,
	input: Partial<{
		name: string;
		description: string | null;
		icon: string | null;
		instructions: string | null;
		chatMode: ChatMode;
		maxIterations: number;
		modelId: string | null;
		imageModelId: string | null;
		videoModelId: string | null;
		disabledToolCategories: ToolCategory[];
		preLoadedSkills: string[];
		isPaused: boolean;
		canReadGlobalMemories: boolean;
		canWriteGlobalMemories: boolean;
		canAccessGlobalFiles: boolean;
		canAccessKnowledge: boolean;
		heartbeatEnabled: boolean;
		heartbeatInstructions: string | null;
		heartbeatDefaultIntervalMinutes: number;
		maxDailyRuns: number;
		maxTokensPerRun: number;
	}>
): Promise<RpcResult<AgentDetail>> {
	return run((opts) =>
		rpc.updateCustomAgent({ identity: id, input, fields: AGENT_DETAIL_FIELDS, ...opts })
	);
}

export function destroyCustomAgent(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyCustomAgent({ identity: id, ...opts }));
}

export function shareAgentToTeam(id: string): Promise<RpcResult<AgentDetail>> {
	return run((opts) =>
		rpc.shareAgentToTeam({ identity: id, fields: AGENT_DETAIL_FIELDS, ...opts })
	);
}

export function unshareAgentFromTeam(id: string): Promise<RpcResult<AgentDetail>> {
	return run((opts) =>
		rpc.unshareAgentFromTeam({ identity: id, fields: AGENT_DETAIL_FIELDS, ...opts })
	);
}

/** Manual wake-up ("Run now"): enqueues a :manual_trigger run. */
export function triggerAgentRun(agentId: string): Promise<RpcResult<Record<string, unknown>>> {
	return run((opts) => rpc.triggerAgentRun({ input: { agentId }, ...opts }));
}

export type AgentActivityEntry = {
	id: string;
	activityType: string;
	summary: string;
	runId: string | null;
	conversationId: string | null;
	modelUsed: string | null;
	tokensUsed: number | null;
	durationMs: number | null;
	insertedAt: string;
};

export function agentActivity(agentId: string): Promise<RpcResult<AgentActivityEntry[]>> {
	return run((opts) =>
		rpc.agentActivity({
			input: { agentId },
			fields: [
				'id',
				'activityType',
				'summary',
				'runId',
				'conversationId',
				'modelUsed',
				'tokensUsed',
				'durationMs',
				'insertedAt'
			],
			...opts
		})
	);
}

export type AgentInboxEntry = {
	id: string;
	eventType: string;
	status: string;
	urgency: string | null;
	title: string | null;
	summary: string | null;
	insertedAt: string;
};

export function agentInboxEvents(agentId: string): Promise<RpcResult<AgentInboxEntry[]>> {
	return run((opts) =>
		rpc.agentInboxEvents({
			input: { agentId },
			fields: ['id', 'eventType', 'status', 'urgency', 'title', 'summary', 'insertedAt'],
			...opts
		})
	);
}

export function dismissInboxEvent(id: string): Promise<RpcResult<AgentInboxEntry>> {
	return run((opts) =>
		rpc.dismissInboxEvent({
			identity: id,
			input: { resolutionNote: 'Dismissed by user' },
			fields: ['id', 'eventType', 'status', 'urgency', 'title', 'summary', 'insertedAt'],
			...opts
		})
	);
}

export type AgentSecretEntry = {
	id: string;
	key: string;
	scope: 'sandbox_env' | 'tool_config';
	description: string | null;
};

const SECRET_FIELDS: rpc.AgentSecretsFields = ['id', 'key', 'scope', 'description'];

/** Values are write-only from the SPA's perspective — never selected. */
export function agentSecrets(customAgentId: string): Promise<RpcResult<AgentSecretEntry[]>> {
	return run((opts) =>
		rpc.agentSecrets({ input: { customAgentId }, fields: SECRET_FIELDS, ...opts })
	);
}

export function createAgentSecret(input: {
	customAgentId: string;
	key: string;
	value: string;
	scope?: 'sandbox_env' | 'tool_config';
	description?: string;
}): Promise<RpcResult<AgentSecretEntry>> {
	return run((opts) => rpc.createAgentSecret({ input, fields: SECRET_FIELDS, ...opts }));
}

export function destroyAgentSecret(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyAgentSecret({ identity: id, ...opts }));
}

// ─── Brain mode (nav tree + markdown editing) ────────────────────────────────

export type BrainSummary = {
	id: string;
	title: string;
	description: string | null;
	icon: string | null;
	color: string | null;
	workspaceId: string | null;
	isSharedToWorkspace: boolean;
};

const BRAIN_FIELDS: rpc.MyBrainsFields = [
	'id',
	'title',
	'description',
	'icon',
	'color',
	'workspaceId',
	'isSharedToWorkspace'
];

export function myBrains(): Promise<RpcResult<BrainSummary[]>> {
	return run((opts) => rpc.myBrains({ fields: BRAIN_FIELDS, ...opts }));
}

export function workspaceBrains(workspaceId: string): Promise<RpcResult<BrainSummary[]>> {
	return run((opts) =>
		rpc.workspaceBrains({ input: { workspaceId }, fields: BRAIN_FIELDS, ...opts })
	);
}

/** Update a brain's metadata (settings modal: title/description/icon/color). */
export function updateBrain(
	id: string,
	input: {
		title?: string;
		description?: string | null;
		icon?: string | null;
		color?: string | null;
	}
): Promise<RpcResult<BrainSummary>> {
	return run((opts) => rpc.updateBrain({ identity: id, input, fields: BRAIN_FIELDS, ...opts }));
}

/** Share a workspace brain with the whole team (grant workspace access). */
export function shareBrainToTeam(id: string): Promise<RpcResult<BrainSummary>> {
	return run((opts) => rpc.shareBrainToTeam({ identity: id, fields: BRAIN_FIELDS, ...opts }));
}

/** Revoke team-wide access to a workspace brain. */
export function unshareBrainFromTeam(id: string): Promise<RpcResult<BrainSummary>> {
	return run((opts) => rpc.unshareBrainFromTeam({ identity: id, fields: BRAIN_FIELDS, ...opts }));
}

export function createBrain(input: {
	title: string;
	workspaceId?: string | null;
}): Promise<RpcResult<BrainSummary>> {
	return run((opts) => rpc.createBrain({ input, fields: BRAIN_FIELDS, ...opts }));
}

export type PageTreeNode = {
	id: string;
	title: string | null;
	icon: string | null;
	parentPageId: string | null;
};

const PAGE_NODE_FIELDS: rpc.RootBrainPagesFields = ['id', 'title', 'icon', 'parentPageId'];

export function rootBrainPages(brainId: string): Promise<RpcResult<PageTreeNode[]>> {
	return run((opts) =>
		rpc.rootBrainPages({ input: { brainId }, fields: PAGE_NODE_FIELDS, ...opts })
	);
}

export function brainPageChildren(parentPageId: string): Promise<RpcResult<PageTreeNode[]>> {
	return run((opts) =>
		rpc.brainPageChildren({ input: { parentPageId }, fields: PAGE_NODE_FIELDS, ...opts })
	);
}

export function trashedBrainPages(workspaceId: string | null): Promise<RpcResult<PageTreeNode[]>> {
	return run((opts) =>
		rpc.trashedBrainPages({ input: { workspaceId }, fields: PAGE_NODE_FIELDS, ...opts })
	);
}

export function createBrainPage(input: {
	brainId: string;
	title?: string;
	parentPageId?: string | null;
}): Promise<RpcResult<PageTreeNode>> {
	return run((opts) => rpc.createBrainPage({ input, fields: PAGE_NODE_FIELDS, ...opts }));
}

export function renameBrainPage(id: string, title: string): Promise<RpcResult<PageTreeNode>> {
	return run((opts) =>
		rpc.renameBrainPage({ identity: id, input: { title }, fields: PAGE_NODE_FIELDS, ...opts })
	);
}

export function moveBrainPage(
	id: string,
	parentPageId: string | null
): Promise<RpcResult<PageTreeNode>> {
	return run((opts) =>
		rpc.moveBrainPage({ identity: id, input: { parentPageId }, fields: PAGE_NODE_FIELDS, ...opts })
	);
}

export function trashBrainPage(id: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.trashBrainPage({ identity: id, fields: ['id'], ...opts }));
}

export function restoreBrainPage(id: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.restoreBrainPage({ identity: id, fields: ['id'], ...opts }));
}

export type BrainPageEditable = BrainPageDetail & {
	lockVersion: number;
	/** Server-converted TipTap/ProseMirror document for the rich editor. */
	prosemirror: Record<string, unknown>;
};

export function getBrainPageForEdit(id: string): Promise<RpcResult<BrainPageEditable>> {
	return run((opts) =>
		rpc.getBrainPage({
			getBy: { id },
			fields: [
				'id',
				'title',
				'icon',
				'body',
				'updatedAt',
				'kind',
				'lockVersion',
				'prosemirror',
				{ brain: ['id', 'workspaceId'] }
			],
			...opts
		})
	);
}

/** All pages of a brain — wikilink suggestion source. */
export function brainPages(brainId: string): Promise<RpcResult<PageTreeNode[]>> {
	return run((opts) => rpc.brainPages({ input: { brainId }, fields: PAGE_NODE_FIELDS, ...opts }));
}

export type SaveProsemirrorResult =
	| { status: 'saved'; lockVersion: number }
	| { status: 'conflict'; currentVersion: number | null; message: string }
	| { status: 'error'; message: string };

/**
 * Saves the rich-editor document; the server converts ProseMirror →
 * markdown and writes through the optimistic-lock update_body path
 * (classic brain_editor_save parity).
 */
export async function saveBrainPageProsemirror(
	pageId: string,
	prosemirror: Record<string, unknown>,
	baseVersion: number
): Promise<SaveProsemirrorResult> {
	const result = await run<Record<string, unknown>>((opts) =>
		rpc.saveBrainPageProsemirror({ input: { pageId, prosemirror, baseVersion }, ...opts })
	);

	if (result.success) {
		const lockVersion = result.data['lock_version'];
		return { status: 'saved', lockVersion: typeof lockVersion === 'number' ? lockVersion : 0 };
	}

	const conflict = result.errors.find((error) => error.type === 'version_conflict');
	if (conflict) {
		const current = (conflict.vars as Record<string, unknown>)?.current_version;
		return {
			status: 'conflict',
			currentVersion: typeof current === 'number' ? current : null,
			message: conflict.message
		};
	}

	return { status: 'error', message: result.errors[0]?.message ?? 'Save failed' };
}

export type SavePageResult =
	| { status: 'saved'; page: BrainPageEditable }
	| { status: 'conflict'; currentVersion: number | null; message: string }
	| { status: 'error'; message: string };

/**
 * Saves the markdown body through the optimistic-lock write path. A stale
 * `baseVersion` comes back as a typed `version_conflict` error — the caller
 * refetches and re-applies the local text on the new version.
 */
export async function updateBrainPageBody(
	id: string,
	body: string,
	baseVersion: number
): Promise<SavePageResult> {
	const result = await run<BrainPageEditable>((opts) =>
		rpc.updateBrainPageBody({
			identity: id,
			input: { body, baseVersion },
			fields: [
				'id',
				'title',
				'icon',
				'body',
				'updatedAt',
				'lockVersion',
				{ brain: ['id', 'workspaceId'] }
			],
			...opts
		})
	);

	if (result.success) return { status: 'saved', page: result.data };

	const conflict = result.errors.find((error) => error.type === 'version_conflict');
	if (conflict) {
		const current = (conflict.vars as Record<string, unknown>)?.current_version;
		return {
			status: 'conflict',
			currentVersion: typeof current === 'number' ? current : null,
			message: conflict.message
		};
	}

	return { status: 'error', message: result.errors[0]?.message ?? 'Save failed' };
}

// ─── Workflow jobs (right-rail Jobs panel) ───────────────────────────────────

export type JobEntry = {
	id: string;
	name: string;
	description: string | null;
	status: 'active' | 'paused' | 'stopped' | 'completed';
	scheduleType: 'cron' | 'one_time';
	cronExpressionLocal: string | null;
	scheduledAt: string | null;
	nextRunAt: string | null;
	lastRunAt: string | null;
};

const JOB_FIELDS: rpc.ConversationJobsFields = [
	'id',
	'name',
	'description',
	'status',
	'scheduleType',
	'cronExpressionLocal',
	'scheduledAt',
	'nextRunAt',
	'lastRunAt'
];

/** Non-stopped jobs for the conversation, newest first (server-sorted). */
export function conversationJobs(conversationId: string): Promise<RpcResult<JobEntry[]>> {
	return run((opts) =>
		rpc.conversationJobs({ input: { conversationId }, fields: JOB_FIELDS, ...opts })
	);
}

/** The full job, as the /jobs detail pane needs it (superset of JobEntry). */
export type JobDetail = JobEntry & {
	cronExpression: string | null;
	userTimezone: string | null;
	startsAt: string | null;
	endsAt: string | null;
	triggerPrompt: string;
	memoryName: string | null;
	conversationId: string;
};

const JOB_DETAIL_FIELDS: rpc.UserJobsFields = [
	'id',
	'name',
	'description',
	'status',
	'scheduleType',
	'cronExpression',
	'cronExpressionLocal',
	'userTimezone',
	'scheduledAt',
	'startsAt',
	'endsAt',
	'nextRunAt',
	'lastRunAt',
	'triggerPrompt',
	'memoryName',
	'conversationId'
];

export type JobRunEntry = {
	id: string;
	status: 'pending' | 'running' | 'success' | 'failed' | 'retrying';
	startedAt: string | null;
	completedAt: string | null;
	errorMessage: string | null;
	retryAttempt: number;
};

const JOB_RUN_FIELDS: rpc.JobRunsFields = [
	'id',
	'status',
	'startedAt',
	'completedAt',
	'errorMessage',
	'retryAttempt'
];

/** All the actor's non-stopped jobs across conversations (the /jobs route). */
export function userJobs(userId: string): Promise<RpcResult<JobDetail[]>> {
	return run((opts) => rpc.userJobs({ input: { userId }, fields: JOB_DETAIL_FIELDS, ...opts }));
}

/** Recent run history for a job, newest first. */
export function jobRuns(jobId: string, limit = 10): Promise<RpcResult<JobRunEntry[]>> {
	return run((opts) => rpc.jobRuns({ input: { jobId, limit }, fields: JOB_RUN_FIELDS, ...opts }));
}

// Lifecycle mutations return the full detail so the /jobs pane reconciles
// without a refetch; the rail panel reads only the JobEntry subset.
export function pauseJob(id: string): Promise<RpcResult<JobDetail>> {
	return run((opts) => rpc.pauseJob({ identity: id, fields: JOB_DETAIL_FIELDS, ...opts }));
}

export function resumeJob(id: string): Promise<RpcResult<JobDetail>> {
	return run((opts) => rpc.resumeJob({ identity: id, fields: JOB_DETAIL_FIELDS, ...opts }));
}

export function stopJob(id: string): Promise<RpcResult<JobDetail>> {
	return run((opts) => rpc.stopJob({ identity: id, fields: JOB_DETAIL_FIELDS, ...opts }));
}

/** Fire a job immediately, bypassing its schedule. */
export function triggerJobNow(id: string): Promise<RpcResult<JobDetail>> {
	return run((opts) => rpc.triggerJobNow({ identity: id, fields: JOB_DETAIL_FIELDS, ...opts }));
}

// ─── Notifications (shell bell) ──────────────────────────────────────────────

export type NotificationEntry = {
	id: string;
	title: string | null;
	body: string | null;
	notificationType: string;
	targetConversationId: string | null;
	metadata: Record<string, unknown> | null;
	insertedAt: string;
};

const NOTIFICATION_FIELDS: rpc.UnreadNotificationsFields = [
	'id',
	'title',
	'body',
	'notificationType',
	'targetConversationId',
	'metadata',
	'insertedAt'
];

/** Unread notifications, newest first (server-limited to 20). */
export function unreadNotifications(): Promise<RpcResult<NotificationEntry[]>> {
	return run((opts) =>
		rpc.unreadNotifications({ fields: NOTIFICATION_FIELDS, ...opts })
	) as Promise<RpcResult<NotificationEntry[]>>;
}

export function markNotificationRead(id: string): Promise<RpcResult<NotificationEntry>> {
	return run((opts) =>
		rpc.markNotificationRead({ identity: id, fields: NOTIFICATION_FIELDS, ...opts })
	) as Promise<RpcResult<NotificationEntry>>;
}

export function markAllNotificationsRead(): Promise<RpcResult<number>> {
	return run((opts) => rpc.markAllNotificationsRead({ ...opts }));
}

// ─── Credits (shell indicator) ───────────────────────────────────────────────

export type CreditStatus = {
	exempt: boolean;
	creditsUsed: number;
	creditsLimit: number | null;
	percentage: number;
	storageUsed: number;
	storageLimit: number | null;
};

/** Daily usage snapshot; generic actions return snake_case map keys. */
export async function creditStatus(): Promise<RpcResult<CreditStatus>> {
	const result = await run<Record<string, unknown> | null>((opts) => rpc.creditStatus({ ...opts }));
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			exempt: data.exempt === true,
			creditsUsed: Number(data.credits_used ?? 0),
			creditsLimit:
				data.credits_limit === null || data.credits_limit === undefined
					? null
					: Number(data.credits_limit),
			percentage: Number(data.percentage ?? 0),
			storageUsed: Number(data.storage_used ?? 0),
			storageLimit:
				data.storage_limit === null || data.storage_limit === undefined
					? null
					: Number(data.storage_limit)
		}
	};
}

/** Pay-as-you-go spend snapshot for the shell usage indicator. */
export type MoneyUsageStatus = {
	exempt: boolean;
	trial: boolean;
	delinquent: boolean;
	spentCents: number;
	/** null = uncapped (postpaid opt-out in good standing). */
	capCents: number | null;
	tokensUsed: number;
};

/** PAYG spend snapshot; generic actions return snake_case map keys. Mirrors the
 *  workbench mode-strip indicator (Calculator.get_money_usage_stats/1). */
export async function moneyUsageStatus(): Promise<RpcResult<MoneyUsageStatus>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.moneyUsageStatus({ ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			exempt: data.exempt === true,
			trial: data.trial === true,
			delinquent: data.delinquent === true,
			spentCents: Number(data.spent_cents ?? 0),
			capCents:
				data.cap_cents === null || data.cap_cents === undefined ? null : Number(data.cap_cents),
			tokensUsed: Number(data.tokens_used ?? 0)
		}
	};
}

export type ChatFeatureLimits = {
	imageGenerationEnabled: boolean;
	videoGenerationEnabled: boolean;
	/** null = uncapped. */
	maxUploadBytes: number | null;
};

/** Plan gating for the composer mode toggles; generic action → snake_case keys.
 *  Mirrors the workbench compute_usage_state (the backend still enforces). */
export async function chatFeatureLimits(): Promise<RpcResult<ChatFeatureLimits>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.chatFeatureLimits({ ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			imageGenerationEnabled: data.image_generation_enabled === true,
			videoGenerationEnabled: data.video_generation_enabled === true,
			maxUploadBytes:
				data.max_upload_bytes === null || data.max_upload_bytes === undefined
					? null
					: Number(data.max_upload_bytes)
		}
	};
}

// ─── Billing / subscription section ──────────────────────────────────────────

export type BillingOverview = {
	planKey: string | null;
	planName: string | null;
	status: string;
	currentPeriodEnd: string | null;
	lastPaymentStatus: string | null;
	noSpendCap: boolean;
	monthlySpendCapCents: number | null;
	spentCents: number;
	capCents: number | null;
	/** Platform default monthly cap (cents). Applies when `monthlySpendCapCents`
	 * is null and `noSpendCap` is false — a null cap means "use this default",
	 * not "unlimited". */
	defaultCapCents: number | null;
	tokensUsed: number;
	delinquent: boolean;
	exempt: boolean;
	isPayg: boolean;
	/** Whether the commercial billing edition is present. When false (open-core
	 * self-host), there is no Stripe surface and checkout/portal are unavailable. */
	billingEdition: boolean;
};

function toBillingOverview(data: Record<string, unknown>): BillingOverview {
	const numOrNull = (v: unknown): number | null =>
		v === null || v === undefined ? null : Number(v);
	return {
		planKey: typeof data.plan_key === 'string' ? data.plan_key : null,
		planName: typeof data.plan_name === 'string' ? data.plan_name : null,
		status: String(data.status ?? 'none'),
		currentPeriodEnd: typeof data.current_period_end === 'string' ? data.current_period_end : null,
		lastPaymentStatus:
			typeof data.last_payment_status === 'string' ? data.last_payment_status : null,
		noSpendCap: data.no_spend_cap === true,
		monthlySpendCapCents: numOrNull(data.monthly_spend_cap_cents),
		spentCents: Number(data.spent_cents ?? 0),
		capCents: numOrNull(data.cap_cents),
		defaultCapCents: numOrNull(data.default_cap_cents),
		tokensUsed: Number(data.tokens_used ?? 0),
		delinquent: data.delinquent === true,
		exempt: data.exempt === true,
		isPayg: data.is_payg === true,
		billingEdition: data.billing_edition === true
	};
}

export async function billingOverview(): Promise<RpcResult<BillingOverview>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.billingOverview({ ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: toBillingOverview(result.data ?? {}) };
}

export async function setBillingPreferences(input: {
	monthlySpendCapCents: number | null;
	noSpendCap: boolean;
}): Promise<RpcResult<BillingOverview>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.setBillingPreferences({
			input: { monthlySpendCapCents: input.monthlySpendCapCents, noSpendCap: input.noSpendCap },
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: toBillingOverview(result.data ?? {}) };
}

/** POST to a Stripe controller endpoint (session-cookie auth, no CSRF) and
 *  redirect to the returned Stripe URL. Returns false if it couldn't start. */
async function stripeRedirect(path: string, body: Record<string, unknown>): Promise<boolean> {
	try {
		const response = await fetch(path, {
			method: 'POST',
			credentials: 'same-origin',
			headers: { 'content-type': 'application/json' },
			body: JSON.stringify(body)
		});
		if (!response.ok) return false;
		const data = (await response.json()) as { url?: unknown };
		if (typeof data.url !== 'string') return false;
		window.location.href = data.url;
		return true;
	} catch {
		return false;
	}
}

/** Opens the Stripe billing portal (manage payment method, invoices, cancel). */
export function openBillingPortal(returnTo?: string): Promise<boolean> {
	return stripeRedirect('/api/stripe/portal', returnTo ? { return_to: returnTo } : {});
}

/** Starts PAYG base checkout (monthly; annual signups are disabled). */
export function startBaseCheckout(returnTo?: string): Promise<boolean> {
	return stripeRedirect('/api/stripe/base-checkout', {
		interval: 'monthly',
		...(returnTo ? { return_to: returnTo } : {})
	});
}

/** Starts org billing checkout for an organization (owner-only). */
export function startOrgCheckout(organizationId: string, returnTo?: string): Promise<boolean> {
	return stripeRedirect('/api/stripe/org-checkout', {
		organization_id: organizationId,
		...(returnTo ? { return_to: returnTo } : {})
	});
}

/** Opens the Stripe billing portal for an organization (owner-only). */
export function openOrgBillingPortal(organizationId: string, returnTo?: string): Promise<boolean> {
	return stripeRedirect('/api/stripe/org-portal', {
		organization_id: organizationId,
		...(returnTo ? { return_to: returnTo } : {})
	});
}

// ─── Context window (composer donut) ─────────────────────────────────────────

/** Per-category token split from the persisted `last_breakdown` snapshot. */
export type ContextBreakdownCategory = { label: string; tokens: number };

export type ContextCompactionStatus = 'idle' | 'pending' | 'running' | 'failed';

/**
 * Clean, composer-facing snapshot of `Magus.Chat.ContextWindow`. Refines the
 * generated `context_window` row: `breakdown` is lifted out of the JSONB
 * `lastBreakdown` map, `fill` is precomputed (clamped to <= 1), and `total` /
 * `max` are nil-coalesced for direct rendering.
 */
export type ContextWindowSnapshot = {
	total: number;
	max: number;
	/** total / max, clamped to [0, 1]. 0 when max is unknown. */
	fill: number;
	breakdown: ContextBreakdownCategory[];
	strategy: 'rolling' | 'compact' | null;
	modelKey: string | null;
	compactionStatus: ContextCompactionStatus;
	cachedTokens: number | null;
	actualInputTokens: number | null;
	windowStartAt: string | null;
	summaryMessageCount: number;
	/** Compaction summary text, revealed when the context-floor divider expands. */
	summary: string | null;
};

/**
 * Field set shared by the context-window read + mutations. All four generated
 * actions share the same `context_window` field selection type, so one cast
 * covers the read (`GetContextWindowFields`) and the mutations.
 */
const CONTEXT_WINDOW_FIELDS = [
	'strategy',
	'lastBreakdown',
	'lastTotalTokens',
	'lastMaxContext',
	'lastModelKey',
	'lastActualInputTokens',
	'lastCachedTokens',
	'compactionStatus',
	'windowStartAt',
	'summaryMessageCount',
	'summary'
] as rpc.GetContextWindowFields;

/** Default model context window when the snapshot has no `lastMaxContext`. */
const DEFAULT_MAX_CONTEXT = 128_000;

type ContextWindowRow = {
	strategy?: 'rolling' | 'compact' | null;
	lastBreakdown?: Record<string, unknown> | null;
	lastTotalTokens?: number | null;
	lastMaxContext?: number | null;
	lastModelKey?: string | null;
	lastActualInputTokens?: number | null;
	lastCachedTokens?: number | null;
	compactionStatus?: ContextCompactionStatus | null;
	windowStartAt?: string | null;
	summaryMessageCount?: number | null;
	summary?: string | null;
};

/**
 * Maps a generated `context_window` row to the composer-facing snapshot.
 * Mirrors the LiveView `ContextIndicatorComponent` derivations: fill is
 * `total / max` clamped to 1, the breakdown is the `categories` list inside
 * the JSONB `lastBreakdown` (string keys), status defaults to `idle`.
 */
function toContextWindowSnapshot(row: ContextWindowRow): ContextWindowSnapshot {
	const total = Number(row.lastTotalTokens ?? 0);
	const max = Number(row.lastMaxContext ?? DEFAULT_MAX_CONTEXT) || DEFAULT_MAX_CONTEXT;
	const fill = max > 0 ? Math.min(total / max, 1) : 0;

	const rawCategories = (row.lastBreakdown as { categories?: unknown } | null | undefined)
		?.categories;
	const breakdown: ContextBreakdownCategory[] = Array.isArray(rawCategories)
		? rawCategories.map((entry) => {
				const category = entry as Record<string, unknown>;
				return {
					label: String(category.label ?? ''),
					tokens: Number(category.tokens ?? 0)
				};
			})
		: [];

	return {
		total,
		max,
		fill,
		breakdown,
		strategy: row.strategy ?? null,
		modelKey: row.lastModelKey ?? null,
		compactionStatus: row.compactionStatus ?? 'idle',
		cachedTokens:
			row.lastCachedTokens === null || row.lastCachedTokens === undefined
				? null
				: Number(row.lastCachedTokens),
		actualInputTokens:
			row.lastActualInputTokens === null || row.lastActualInputTokens === undefined
				? null
				: Number(row.lastActualInputTokens),
		windowStartAt: row.windowStartAt ?? null,
		summaryMessageCount: Number(row.summaryMessageCount ?? 0),
		summary: row.summary ?? null
	};
}

/**
 * Persisted context-window snapshot for a conversation, or `null` when no row
 * exists yet (a brand-new conversation that has not run a turn). The read is a
 * `get_by` on `conversation_id`; a not-found read surfaces as `null` data.
 */
export async function getContextWindow(
	conversationId: string
): Promise<RpcResult<ContextWindowSnapshot | null>> {
	const result = await run<ContextWindowRow | null>((opts) =>
		rpc.getContextWindow({
			getBy: { conversationId },
			input: { conversationId },
			fields: CONTEXT_WINDOW_FIELDS,
			...opts
		})
	);
	if (!result.success) {
		// A missing window is not an error for the indicator: treat a not-found
		// read as "no snapshot yet" so the donut quietly hides.
		if (result.errors.some((error) => error.type === 'not_found')) {
			return { success: true, data: null };
		}
		return result;
	}
	return { success: true, data: result.data ? toContextWindowSnapshot(result.data) : null };
}

export async function clearContextWindow(
	conversationId: string
): Promise<RpcResult<ContextWindowSnapshot>> {
	const result = await run<ContextWindowRow>((opts) =>
		rpc.clearContextWindow({ input: { conversationId }, fields: CONTEXT_WINDOW_FIELDS, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: toContextWindowSnapshot(result.data) };
}

export async function compactContextWindow(
	conversationId: string
): Promise<RpcResult<ContextWindowSnapshot>> {
	const result = await run<ContextWindowRow>((opts) =>
		rpc.compactContextWindow({ input: { conversationId }, fields: CONTEXT_WINDOW_FIELDS, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: toContextWindowSnapshot(result.data) };
}

export async function setContextStrategy(
	conversationId: string,
	strategy: 'rolling' | 'compact' | null
): Promise<RpcResult<ContextWindowSnapshot>> {
	const result = await run<ContextWindowRow>((opts) =>
		rpc.setContextStrategy({
			input: { conversationId, strategy },
			fields: CONTEXT_WINDOW_FIELDS,
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: toContextWindowSnapshot(result.data) };
}

// ─── Slash commands (composer plus menu) ─────────────────────────────────────

export type SlashCommandEntry = { name: string; title: string; icon: string | null };

/** Globals merged with the agent's own commands; titles pre-localized. */
export async function mergedSlashCommands(
	agentId: string | null
): Promise<RpcResult<SlashCommandEntry[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.mergedSlashCommands({ input: { agentId }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((command) => ({
			name: String(command.name ?? ''),
			title: String(command.title ?? '') || String(command.name ?? ''),
			icon: (command.icon as string | null) ?? null
		}))
	};
}

// ─── Attachment display (message chips) ──────────────────────────────────────

export type DisplayAttachment = {
	id: string;
	type: string;
	name: string;
	url: string | null;
	mimeType: string | null;
	size: number | null;
};

/** Display-ready attachment maps; unreadable files are silently dropped. */
export async function filesForDisplay(ids: string[]): Promise<RpcResult<DisplayAttachment[]>> {
	const result = await run<Array<Record<string, unknown>> | null>((opts) =>
		rpc.filesForDisplay({ input: { ids }, ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((file) => ({
			id: String(file.id ?? ''),
			type: String(file.type ?? 'document'),
			name: String(file.name ?? ''),
			url: (file.url as string | null) ?? null,
			mimeType: (file.mime_type as string | null) ?? null,
			size: typeof file.size === 'number' ? file.size : null
		}))
	};
}

// ─── Companion chat ("Open chat" on files and brain pages) ───────────────────

export async function openCompanionChat(
	resourceType: 'file' | 'brain_page',
	resourceId: string
): Promise<RpcResult<{ conversationId: string; title: string | null }>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.openCompanionChat({ input: { resourceType, resourceId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			conversationId: String(data.conversation_id ?? ''),
			title: (data.title as string | null) ?? null
		}
	};
}

// ─── Brain page version history (Activity tab diff + restore) ────────────────

export type DiffToken = { kind: 'same' | 'added' | 'removed'; text: string };

export type DiffRow =
	| { kind: 'context' | 'del' | 'ins'; tokens: DiffToken[] }
	| { kind: 'gap'; count: number };

export type PageVersionDiff = {
	versionId: string;
	insertedAt: string;
	actionName: string | null;
	isLatest: boolean;
	rows: DiffRow[];
};

/** Token-level diff of a version against its predecessor. */
export async function brainPageVersionDiff(
	pageId: string,
	versionId: string
): Promise<RpcResult<PageVersionDiff>> {
	const result = await run<Record<string, unknown> | null>((opts) =>
		rpc.brainPageVersionDiff({ input: { pageId, versionId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data ?? {};
	return {
		success: true,
		data: {
			versionId: String(data.version_id ?? ''),
			insertedAt: String(data.inserted_at ?? ''),
			actionName: (data.action_name as string | null) ?? null,
			isLatest: data.is_latest === true,
			rows: (data.rows as DiffRow[]) ?? []
		}
	};
}

/** Full markdown snapshot of a version (the restore source). */
export function brainPageVersionBody(
	pageId: string,
	versionId: string
): Promise<RpcResult<string>> {
	return run((opts) => rpc.brainPageVersionBody({ input: { pageId, versionId }, ...opts }));
}

// ─── Open tasks (new-chat landing) ───────────────────────────────────────────

export type OpenTaskEntry = {
	id: string;
	title: string;
	dueAt: string | null;
	conversationId: string;
};

const OPEN_TASK_FIELDS: rpc.ListOpenTasksFields = ['id', 'title', 'dueAt', 'conversationId'];

/** The actor's open, top-level, non-dismissed tasks (max 10, due-date first). */
export function listOpenTasks(userId: string): Promise<RpcResult<OpenTaskEntry[]>> {
	return run((opts) => rpc.listOpenTasks({ input: { userId }, fields: OPEN_TASK_FIELDS, ...opts }));
}

/** Mark a task done from the landing (it stays resolved in its conversation). */
export function completeTask(id: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.completeTask({ identity: id, fields: ['id'], ...opts }));
}

/** Dismiss a task from the landing only (it stays open in its conversation). */
export function dismissTask(id: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.dismissTask({ identity: id, fields: ['id'], ...opts }));
}

// ─── In-conversation task pane (collaborative tasks companion) ───────────────

export type TaskStatus = 'open' | 'in_progress' | 'done' | 'cancelled' | 'archived' | 'blocked';

export type ConversationTask = {
	id: string;
	title: string;
	description: string | null;
	status: TaskStatus;
	position: number | null;
	dueAt: string | null;
	assignedToAgent: string | null;
};

const TASK_FIELDS = [
	'id',
	'title',
	'description',
	'status',
	'position',
	'dueAt',
	'assignedToAgent'
] satisfies rpc.ConversationTasksFields;

/** All non-archived tasks in a conversation, position-sorted. */
export function conversationTasks(conversationId: string): Promise<RpcResult<ConversationTask[]>> {
	return run((opts) =>
		rpc.conversationTasks({ input: { conversationId }, fields: TASK_FIELDS, ...opts })
	) as Promise<RpcResult<ConversationTask[]>>;
}

export function createConversationTask(
	conversationId: string,
	input: { title: string; description?: string | null }
): Promise<RpcResult<ConversationTask>> {
	return run((opts) =>
		rpc.createConversationTask({
			input: { conversationId, ...input },
			fields: TASK_FIELDS,
			...opts
		})
	) as Promise<RpcResult<ConversationTask>>;
}

export function updateConversationTask(
	id: string,
	input: Partial<{
		title: string;
		description: string | null;
		status: TaskStatus;
		position: number;
	}>
): Promise<RpcResult<ConversationTask>> {
	return run((opts) =>
		rpc.updateConversationTask({ identity: id, input, fields: TASK_FIELDS, ...opts })
	) as Promise<RpcResult<ConversationTask>>;
}

export function destroyConversationTask(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyConversationTask({ identity: id, ...opts }));
}

// ─── Plan-page task board (brain plan view) ──────────────────────────────────

export type TaskPriority = 'urgent' | 'high' | 'normal' | 'low';

/**
 * A task on a Brain plan page (`Brain.Page` with `kind === 'plan'`). Carries the
 * coordination fields the board renders: assignment (`assignedTo*`), the claim
 * timestamp + `leaseExpiresAt` (the lease the reaper reclaims once it lapses,
 * driving the freshness treatment), the `ready` calc (open + unassigned +
 * dependencies clear), and the subtask/open-dependency count aggregates.
 */
export type PlanTask = {
	id: string;
	title: string;
	status: TaskStatus;
	priority: TaskPriority;
	position: number | null;
	dueAt: string | null;
	claimedAt: string | null;
	/** When the active claim's lease expires; the reaper reclaims it once past. Null when no live lease. */
	leaseExpiresAt: string | null;
	/** Free-text label for who created the task (e.g. an external agent name). */
	createdByLabel: string | null;
	assignedToAgent: string | null;
	assignedToUserId: string | null;
	assignedToCustomAgentId: string | null;
	brainPageId: string | null;
	resultSummary: string | null;
	/** Open + unassigned + all dependencies done. Null when not selected/derivable. */
	ready: boolean | null;
	subtaskCount: number;
	completedSubtaskCount: number;
	openDependenciesCount: number;
};

const PLAN_TASK_FIELDS = [
	'id',
	'title',
	'status',
	'priority',
	'position',
	'dueAt',
	'claimedAt',
	'leaseExpiresAt',
	'createdByLabel',
	'assignedToAgent',
	'assignedToUserId',
	'assignedToCustomAgentId',
	'brainPageId',
	'resultSummary',
	'ready',
	'subtaskCount',
	'completedSubtaskCount',
	'openDependenciesCount'
] satisfies rpc.PlanTasksFields;

/** All non-archived tasks on a plan page, position-sorted. */
export function planTasks(brainPageId: string): Promise<RpcResult<PlanTask[]>> {
	return run((opts) =>
		rpc.planTasks({ input: { brainPageId }, fields: PLAN_TASK_FIELDS, ...opts })
	) as Promise<RpcResult<PlanTask[]>>;
}

/** Ready (open, unassigned, dependency-clear) tasks on a plan page, priority-sorted. */
export function readyPlanTasks(brainPageId: string): Promise<RpcResult<PlanTask[]>> {
	return run((opts) =>
		rpc.readyPlanTasks({
			input: { brainPageId },
			fields: PLAN_TASK_FIELDS as rpc.ReadyPlanTasksFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask[]>>;
}

/** Every non-archived task across all of a brain's plan pages (overview rollup). */
export function brainTasks(brainId: string): Promise<RpcResult<PlanTask[]>> {
	return run((opts) =>
		rpc.brainTasks({
			input: { brainId },
			fields: PLAN_TASK_FIELDS as rpc.BrainTasksFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask[]>>;
}

export function createPlanTask(
	brainPageId: string,
	input: {
		title: string;
		description?: string | null;
		priority?: TaskPriority;
		parentId?: string | null;
		dueAt?: string | null;
	}
): Promise<RpcResult<PlanTask>> {
	return run((opts) =>
		rpc.createPlanTask({
			input: { brainPageId, ...input },
			fields: PLAN_TASK_FIELDS as rpc.CreatePlanTaskFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask>>;
}

export function updatePlanTask(
	id: string,
	input: Partial<{
		title: string;
		description: string | null;
		status: TaskStatus;
		priority: TaskPriority;
		position: number;
		assignedToAgent: string | null;
		assignedToUserId: string | null;
		blockedReason: string | null;
		resultSummary: string | null;
		dueAt: string | null;
	}>
): Promise<RpcResult<PlanTask>> {
	return run((opts) =>
		rpc.updatePlanTask({
			identity: id,
			input,
			fields: PLAN_TASK_FIELDS as rpc.UpdatePlanTaskFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask>>;
}

/** Atomically claim an unassigned, open task for a user or an (external) agent. */
export function claimPlanTask(
	id: string,
	input: { assignedToUserId?: string | null; assignedToAgent?: string | null }
): Promise<RpcResult<PlanTask>> {
	return run((opts) =>
		rpc.claimPlanTask({
			identity: id,
			input,
			fields: PLAN_TASK_FIELDS as rpc.ClaimPlanTaskFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask>>;
}

/** Release a claim, returning the task to the open/unassigned ready pool. */
export function releasePlanTask(id: string): Promise<RpcResult<PlanTask>> {
	return run((opts) =>
		rpc.releasePlanTask({
			identity: id,
			fields: PLAN_TASK_FIELDS as rpc.ReleasePlanTaskFields,
			...opts
		})
	) as Promise<RpcResult<PlanTask>>;
}

export type TaskDependencyEntry = {
	id: string;
	taskId: string;
	dependsOnId: string;
};

const TASK_DEPENDENCY_FIELDS = [
	'id',
	'taskId',
	'dependsOnId'
] satisfies rpc.AddTaskDependencyFields;

/** Add a `task depends on dependsOn` edge (intra-plan, acyclic). */
export function addTaskDependency(
	taskId: string,
	dependsOnId: string
): Promise<RpcResult<TaskDependencyEntry>> {
	return run((opts) =>
		rpc.addTaskDependency({
			input: { taskId, dependsOnId },
			fields: TASK_DEPENDENCY_FIELDS,
			...opts
		})
	) as Promise<RpcResult<TaskDependencyEntry>>;
}

export function removeTaskDependency(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.removeTaskDependency({ identity: id, ...opts }));
}

/** Dependency edges where the given task is the dependent (its "blocked by" set). */
export function taskDependencies(taskId: string): Promise<RpcResult<TaskDependencyEntry[]>> {
	return run((opts) =>
		rpc.taskDependencies({
			input: { taskId },
			fields: TASK_DEPENDENCY_FIELDS as rpc.TaskDependenciesFields,
			...opts
		})
	) as Promise<RpcResult<TaskDependencyEntry[]>>;
}

export type TaskEventKind =
	| 'created'
	| 'claimed'
	| 'released'
	| 'status_changed'
	| 'completed'
	| 'reassigned'
	| 'lease_expired';

/** One append-only coordination/audit event for a plan task (overview activity feed). */
export type TaskEventEntry = {
	id: string;
	taskId: string;
	brainPageId: string;
	kind: TaskEventKind;
	actorLabel: string | null;
	metadata: Record<string, unknown> | null;
	insertedAt: string;
};

const TASK_EVENT_FIELDS = [
	'id',
	'taskId',
	'brainPageId',
	'kind',
	'actorLabel',
	'metadata',
	'insertedAt'
] satisfies rpc.PlanTaskEventsFields;

/** Recent task activity for one plan page, newest first. */
export function planTaskEvents(brainPageId: string): Promise<RpcResult<TaskEventEntry[]>> {
	return run((opts) =>
		rpc.planTaskEvents({ input: { brainPageId }, fields: TASK_EVENT_FIELDS, ...opts })
	) as Promise<RpcResult<TaskEventEntry[]>>;
}

/** Recent task activity across all of a brain's plan pages, newest first (max 50). */
export function brainTaskEvents(brainId: string): Promise<RpcResult<TaskEventEntry[]>> {
	return run((opts) =>
		rpc.brainTaskEvents({
			input: { brainId },
			fields: TASK_EVENT_FIELDS as rpc.BrainTaskEventsFields,
			...opts
		})
	) as Promise<RpcResult<TaskEventEntry[]>>;
}

// ─── Plan delivery lifecycle ─────────────────────────────────────────────────

/** A page's delivery lifecycle, derived server-side from the task rollup + the
 *  explicit delivery gate. `done` (every task complete but never delivered) is
 *  the stranded state the overview surfaces; `delivered` is the closed-out gate. */
export type Lifecycle = 'draft' | 'active' | 'done' | 'delivered';

/** What a page is: a normal markdown page, a structured plan board, or a spec. */
export type PageKind = 'page' | 'plan' | 'spec';

/**
 * A plan / spec page with its lifecycle fields, for the unified plan tree and the
 * overview stranded-work section. `lifecycle` is the recursive rollup calc;
 * `deliveredAt` / `deliveryRef` are the explicit gate (set by mark-delivered).
 * The string-typed `lifecycle` from the calc is narrowed to {@link Lifecycle}.
 */
export type PlanPage = {
	id: string;
	title: string | null;
	icon: string | null;
	kind: PageKind;
	parentPageId: string | null;
	specPageId: string | null;
	lifecycle: Lifecycle;
	deliveredAt: string | null;
	deliveryRef: string | null;
};

const PLAN_PAGE_FIELDS = [
	'id',
	'title',
	'icon',
	'kind',
	'parentPageId',
	'specPageId',
	'lifecycle',
	'deliveredAt',
	'deliveryRef'
] satisfies rpc.BrainPagesFields;

/** The raw row shape the generated client returns for PLAN_PAGE_FIELDS (lifecycle is the calc's loose `string | null`). */
type RawPlanPage = Omit<PlanPage, 'lifecycle'> & { lifecycle: string | null };

/** Narrow the calc's `string | null` lifecycle to the known set (defaulting to draft). */
function asLifecycle(value: string | null): Lifecycle {
	return value === 'active' || value === 'done' || value === 'delivered' ? value : 'draft';
}

function toPlanPage(row: RawPlanPage): PlanPage {
	return { ...row, lifecycle: asLifecycle(row.lifecycle) };
}

/**
 * Every page of a brain with its lifecycle fields loaded. The plan tree assembles
 * the spec -> plan -> phases hierarchy from this flat list (parentPageId / specPageId
 * are the edges); the lifecycle calc rolls up recursively server-side.
 */
export async function brainPlanPages(brainId: string): Promise<RpcResult<PlanPage[]>> {
	const result = await run<RawPlanPage[]>((opts) =>
		rpc.brainPages({ input: { brainId }, fields: PLAN_PAGE_FIELDS, ...opts })
	);
	if (!result.success) return result;
	return { success: true, data: result.data.map(toPlanPage) };
}

/**
 * Plan pages in a brain that are `done` (every task complete) but were never
 * delivered: the anti-stranding alarm. Server filters to plans whose recursive
 * lifecycle is `done` with no `deliveredAt`.
 */
export async function brainStrandedPlans(brainId: string): Promise<RpcResult<PlanPage[]>> {
	const result = await run<RawPlanPage[]>((opts) =>
		rpc.brainStrandedPlans({
			input: { brainId },
			fields: PLAN_PAGE_FIELDS as rpc.BrainStrandedPlansFields,
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: result.data.map(toPlanPage) };
}

/** Close out a `done` plan: stamps the delivery gate, with an optional reference. */
export async function markBrainPageDelivered(
	id: string,
	deliveryRef?: string | null
): Promise<RpcResult<PlanPage>> {
	const result = await run<RawPlanPage>((opts) =>
		rpc.markBrainPageDelivered({
			identity: id,
			input: { deliveryRef: deliveryRef ?? null },
			fields: PLAN_PAGE_FIELDS as rpc.MarkBrainPageDeliveredFields,
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: toPlanPage(result.data) };
}

/** Clear the delivery gate, returning the plan to its derived lifecycle (for mistakes). */
export async function undeliverBrainPage(id: string): Promise<RpcResult<PlanPage>> {
	const result = await run<RawPlanPage>((opts) =>
		rpc.undeliverBrainPage({
			identity: id,
			fields: PLAN_PAGE_FIELDS as rpc.UndeliverBrainPageFields,
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: toPlanPage(result.data) };
}

/** Link a plan page to the spec it implements (or clear it with null). */
export async function setBrainPageSpec(
	id: string,
	specPageId: string | null
): Promise<RpcResult<PlanPage>> {
	const result = await run<RawPlanPage>((opts) =>
		rpc.setBrainPageSpec({
			identity: id,
			input: { specPageId },
			fields: PLAN_PAGE_FIELDS as rpc.SetBrainPageSpecFields,
			...opts
		})
	);
	if (!result.success) return result;
	return { success: true, data: toPlanPage(result.data) };
}

// ─── Onboarding cards (new-chat landing) ─────────────────────────────────────

export type OnboardingCard = {
	key: string;
	icon: string;
	title: string;
	description: string;
	/** Deeplinks as ?skill=onboarding&topic=<topic>. */
	topic: string;
};

export type OnboardingCards = {
	cards: OnboardingCard[];
	/** True when the user has discovered none of the onboarding features yet. */
	firstTime: boolean;
};

/**
 * Undiscovered "Try it out" feature cards for the actor, localized server-side
 * to the actor's language. Returns an untyped map; coerce to a typed shape.
 */
export async function onboardingCards(): Promise<RpcResult<OnboardingCards>> {
	const result = await run<Record<string, unknown>>((opts) => rpc.onboardingCards({ ...opts }));
	if (!result.success) return result;
	const data = result.data ?? {};
	const raw = Array.isArray(data.cards) ? (data.cards as Record<string, unknown>[]) : [];
	return {
		success: true,
		data: {
			cards: raw.map((card) => ({
				key: String(card.key ?? ''),
				icon: String(card.icon ?? ''),
				title: String(card.title ?? ''),
				description: String(card.description ?? ''),
				topic: String(card.topic ?? '')
			})),
			firstTime: data.first_time === true
		}
	};
}

// ─── Announcements (new-chat landing) ────────────────────────────────────────

export type AnnouncementCard = {
	key: string;
	icon: string;
	title: string;
	description: string;
	/** Optional "Learn more" navigation target. */
	actionPayload: string | null;
};

/** Active announcements the actor hasn't dismissed, localized server-side. */
export async function unseenAnnouncements(): Promise<RpcResult<AnnouncementCard[]>> {
	const result = await run<Record<string, unknown>[]>((opts) =>
		rpc.unseenAnnouncements({ ...opts })
	);
	if (!result.success) return result;
	return {
		success: true,
		data: (result.data ?? []).map((row) => ({
			key: String(row.key ?? ''),
			icon: String(row.icon ?? ''),
			title: String(row.title ?? ''),
			description: String(row.description ?? ''),
			actionPayload: (row.action_payload as string | null) ?? null
		}))
	};
}

/** Dismiss an announcement for the actor (persists a "seen" usage event). */
export function dismissAnnouncement(key: string): Promise<RpcResult<string>> {
	return run((opts) => rpc.dismissAnnouncement({ input: { key }, ...opts }));
}

// ─── MCP Servers ─────────────────────────────────────────────────────────────

export type McpTransport = 'sse' | 'streamable_http';
export type McpAuthType = 'none' | 'oauth' | 'static_header';
export type McpReachability = 'error' | 'ok' | 'unknown';
/** Where a server came from: a manual add or a registry import. */
export type McpServerSource = 'manual' | 'registry';

/** Display entry for a user-owned MCP server (no secret fields). */
export type McpServerEntry = {
	id: string;
	name: string;
	handle: string;
	url: string;
	transport: McpTransport;
	mcpPath: string;
	enabled: boolean;
	authType: McpAuthType;
	reachability: McpReachability;
	lastError: string | null;
	lastReachableAt: string | null;
	cachedTools: Array<Record<string, unknown>>;
	toolsCachedAt: string | null;
	workspaceId: string | null;
	// Provenance (non-secret): cached from the registry on import; null/`manual` otherwise.
	source: McpServerSource;
	registryName: string | null;
	registryVersion: string | null;
	description: string | null;
	repositoryUrl: string | null;
};

export type McpCredentialStatus = 'connected' | 'disconnected' | 'error' | 'needs_auth';

/** Non-secret view of a server credential (status only). */
export type McpCredentialEntry = {
	id: string;
	mcpServerId: string;
	status: McpCredentialStatus;
};

const MCP_SERVER_FIELDS: rpc.ListMcpServersFields = [
	'id',
	'name',
	'handle',
	'url',
	'transport',
	'mcpPath',
	'enabled',
	'authType',
	'reachability',
	'lastError',
	'lastReachableAt',
	'cachedTools',
	'toolsCachedAt',
	'workspaceId',
	'source',
	'registryName',
	'registryVersion',
	'description',
	'repositoryUrl'
];

const MCP_CREDENTIAL_FIELDS: rpc.GetMcpCredentialFields = ['id', 'mcpServerId', 'status'];

export function listMcpServers(): Promise<RpcResult<McpServerEntry[]>> {
	return run((opts) => rpc.listMcpServers({ fields: MCP_SERVER_FIELDS, ...opts }));
}

export function createMcpServer(input: {
	name: string;
	handle: string;
	url: string;
	transport?: McpTransport;
	mcpPath?: string;
	authType?: McpAuthType;
	workspaceId?: string | null;
}): Promise<RpcResult<McpServerEntry>> {
	return run((opts) =>
		rpc.createMcpServer({
			input,
			fields: MCP_SERVER_FIELDS as rpc.CreateMcpServerFields,
			...opts
		})
	) as Promise<RpcResult<McpServerEntry>>;
}

export function updateMcpServer(
	id: string,
	input: {
		name?: string;
		url?: string;
		transport?: McpTransport;
		mcpPath?: string;
		enabled?: boolean;
		authType?: McpAuthType;
	}
): Promise<RpcResult<McpServerEntry>> {
	return run((opts) =>
		rpc.updateMcpServer({
			identity: id,
			input,
			fields: MCP_SERVER_FIELDS as rpc.UpdateMcpServerFields,
			...opts
		})
	) as Promise<RpcResult<McpServerEntry>>;
}

export function toggleMcpServer(id: string): Promise<RpcResult<McpServerEntry>> {
	return run((opts) =>
		rpc.toggleMcpServer({
			identity: id,
			fields: MCP_SERVER_FIELDS as rpc.ToggleMcpServerFields,
			...opts
		})
	) as Promise<RpcResult<McpServerEntry>>;
}

export function destroyMcpServer(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyMcpServer({ identity: id, ...opts }));
}

export function discoverMcpServer(id: string): Promise<RpcResult<McpServerEntry>> {
	return run((opts) =>
		rpc.discoverMcpServer({
			input: { mcpServerId: id },
			fields: MCP_SERVER_FIELDS as rpc.DiscoverMcpServerFields,
			...opts
		})
	) as Promise<RpcResult<McpServerEntry>>;
}

export function getMcpCredential(serverId: string): Promise<RpcResult<McpCredentialEntry>> {
	return run((opts) =>
		rpc.getMcpCredential({
			input: { mcpServerId: serverId },
			getBy: { mcpServerId: serverId },
			fields: MCP_CREDENTIAL_FIELDS,
			...opts
		})
	) as Promise<RpcResult<McpCredentialEntry>>;
}

export function upsertMcpStaticHeaders(
	serverId: string,
	staticHeaders: Record<string, string>
): Promise<RpcResult<McpCredentialEntry>> {
	return run((opts) =>
		rpc.upsertMcpStaticHeaders({
			input: { mcpServerId: serverId, staticHeaders },
			fields: MCP_CREDENTIAL_FIELDS as rpc.UpsertMcpStaticHeadersFields,
			...opts
		})
	) as Promise<RpcResult<McpCredentialEntry>>;
}

/**
 * Update the status on an existing credential record. Pass the credential id
 * (not the server id) — obtain it from `getMcpCredential`.
 */
export function setMcpCredentialStatus(
	credentialId: string,
	status: McpCredentialStatus
): Promise<RpcResult<McpCredentialEntry>> {
	return run((opts) =>
		rpc.setMcpCredentialStatus({
			identity: credentialId,
			input: { status },
			fields: MCP_CREDENTIAL_FIELDS as rpc.SetMcpCredentialStatusFields,
			...opts
		})
	) as Promise<RpcResult<McpCredentialEntry>>;
}

/**
 * Disconnect the actor from an OAuth MCP server: clears the stored tokens and
 * flips status to `disconnected`. The DCR-registered client is KEPT server-side
 * so a later reconnect reuses it. Pass the credential id (not the server id) —
 * obtain it from `getMcpCredential`. Sends no secret material.
 */
export function disconnectMcpCredential(
	credentialId: string
): Promise<RpcResult<McpCredentialEntry>> {
	return run((opts) =>
		rpc.disconnectMcpCredential({
			identity: credentialId,
			fields: MCP_CREDENTIAL_FIELDS as rpc.DisconnectMcpCredentialFields,
			...opts
		})
	) as Promise<RpcResult<McpCredentialEntry>>;
}

// ─── Model Providers (BYOK) ────────────────────────────────────────────────────

/** Validation state of a provider's stored credential. */
export type ProviderValidationStatus = 'pending' | 'valid' | 'invalid' | 'error';

/**
 * Display entry for a user-owned model provider. The `api_key` is input-only and
 * never returned; a row existing implies a key was set.
 */
export type ProviderEntry = {
	id: string;
	name: string;
	slug: string;
	reqLlmId: string;
	baseUrl: string | null;
	enabled: boolean;
	validationStatus: ProviderValidationStatus;
	lastValidatedAt: string | null;
};

const PROVIDER_FIELDS: rpc.ListOwnedProvidersFields = [
	'id',
	'name',
	'slug',
	'reqLlmId',
	'baseUrl',
	'enabled',
	'validationStatus',
	'lastValidatedAt'
];

export function listOwnedProviders(): Promise<RpcResult<ProviderEntry[]>> {
	return run((opts) => rpc.listOwnedProviders({ fields: PROVIDER_FIELDS, ...opts }));
}

export function createOwnedProvider(input: {
	name: string;
	reqLlmId: string;
	baseUrl?: string | null;
	apiKey?: string | null;
}): Promise<RpcResult<ProviderEntry>> {
	return run((opts) =>
		rpc.createOwnedProvider({
			input,
			fields: PROVIDER_FIELDS as rpc.CreateOwnedProviderFields,
			...opts
		})
	) as Promise<RpcResult<ProviderEntry>>;
}

export function updateOwnedProvider(
	id: string,
	input: {
		name?: string;
		baseUrl?: string | null;
		apiKey?: string | null;
		enabled?: boolean;
	}
): Promise<RpcResult<ProviderEntry>> {
	return run((opts) =>
		rpc.updateOwnedProvider({
			identity: id,
			input,
			fields: PROVIDER_FIELDS as rpc.UpdateOwnedProviderFields,
			...opts
		})
	) as Promise<RpcResult<ProviderEntry>>;
}

export function destroyOwnedProvider(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyOwnedProvider({ identity: id, ...opts }));
}

export function validateProviderCredential(id: string): Promise<RpcResult<ProviderEntry>> {
	return run((opts) =>
		rpc.validateProviderCredential({
			identity: id,
			fields: PROVIDER_FIELDS as rpc.ValidateProviderCredentialFields,
			...opts
		})
	) as Promise<RpcResult<ProviderEntry>>;
}

// ─── Owned models (BYOK) ───────────────────────────────────────────────────────

/**
 * Result of a live probe of a provider for the model-id picker. The server
 * returns a status plus the ids it could list (empty on any non-`ok` status);
 * an `ok` status with ids drives the searchable select, everything else the
 * free-text fallback.
 */
export type RemoteModelListing = {
	status: 'ok' | 'unauthorized' | 'unavailable' | 'rate_limited';
	modelIds: string[];
};

/**
 * Probe a provider's endpoint for the model ids it can serve. The generated
 * action types the result as an opaque map, so normalise the wire shape here:
 * a soft failure never rejects; it yields a non-`ok` status the picker treats
 * as "type it manually".
 */
export async function listRemoteModels(providerId: string): Promise<RpcResult<RemoteModelListing>> {
	const result = await run<Record<string, unknown>>((opts) =>
		rpc.listRemoteModels({ input: { providerId }, ...opts })
	);
	if (!result.success) return result;
	const data = result.data;
	const rawStatus = String(data.status ?? '');
	const status: RemoteModelListing['status'] =
		rawStatus === 'ok' ||
		rawStatus === 'unauthorized' ||
		rawStatus === 'unavailable' ||
		rawStatus === 'rate_limited'
			? rawStatus
			: 'unavailable';
	const rawIds = (data.modelIds ?? data.model_ids) as unknown;
	const modelIds = Array.isArray(rawIds) ? rawIds.map((id) => String(id)) : [];
	return { success: true, data: { status, modelIds } };
}

/**
 * Display entry for a user-owned model. `modelProviderId` links the model to
 * its owned provider so the settings page can group rows under each provider.
 */
export type OwnedModelEntry = {
	id: string;
	name: string;
	provider: string | null;
	modelProviderId: string | null;
	contextWindow: number | null;
	inputCost: string | null;
	outputCost: string | null;
};

const OWNED_MODEL_FIELDS: rpc.ListOwnedModelsFields = [
	'id',
	'name',
	'provider',
	'modelProviderId',
	'contextWindow',
	'inputCost',
	'outputCost'
];

export function listOwnedModels(): Promise<RpcResult<OwnedModelEntry[]>> {
	return run((opts) => rpc.listOwnedModels({ fields: OWNED_MODEL_FIELDS, ...opts })) as Promise<
		RpcResult<OwnedModelEntry[]>
	>;
}

/**
 * Create a text-only model under an owned provider. `modelId` is the
 * provider-facing id (the server mints the routing key from it); costs are
 * optional decimals expressed per-million-tokens.
 */
export function createOwnedModel(input: {
	modelId: string;
	name: string;
	modelProviderId: string;
	contextWindow?: number | null;
	inputCostValue?: number | null;
	outputCostValue?: number | null;
}): Promise<RpcResult<OwnedModelEntry>> {
	// The resource stores costs as decimals (serialised as strings); stringify the
	// numeric form inputs, leaving null/undefined untouched so they are omitted.
	const rpcInput: rpc.CreateOwnedModelInput = {
		modelId: input.modelId,
		name: input.name,
		modelProviderId: input.modelProviderId,
		...(input.contextWindow != null ? { contextWindow: input.contextWindow } : {}),
		...(input.inputCostValue != null ? { inputCostValue: String(input.inputCostValue) } : {}),
		...(input.outputCostValue != null ? { outputCostValue: String(input.outputCostValue) } : {})
	};
	return run((opts) =>
		rpc.createOwnedModel({
			input: rpcInput,
			fields: OWNED_MODEL_FIELDS as rpc.CreateOwnedModelFields,
			...opts
		})
	) as Promise<RpcResult<OwnedModelEntry>>;
}

export function destroyOwnedModel(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroyOwnedModel({ identity: id, ...opts }));
}

// ─── Skills ───────────────────────────────────────────────────────────────────

export type SkillSummary = {
	id: string;
	name: string;
	displayName: string | null;
	description: string;
	requestedTools: string[] | null;
	version: string | null;
	license: string | null;
	sourceFormat: 'agents_md' | 'goose' | 'other' | 'skill_md';
	hasExecutableBundle: boolean;
	isSharedToWorkspace: boolean | null;
	workspaceId: string | null;
	isFavorited: boolean;
	body: string | null;
};

export type SkillDetail = SkillSummary & {
	requiredSecrets: Record<string, unknown>[] | null;
	compatibility: string | null;
	icon: string | null;
	color: string | null;
	sourceUrl: string | null;
	fileManifest: Record<string, unknown>[] | null;
};

export type CreateSkillInput = rpc.CreateSkillInput;
export type UpdateSkillInput = rpc.UpdateSkillInput;

const SKILL_SUMMARY_FIELDS: rpc.MySkillsFields = [
	'id',
	'name',
	'displayName',
	'description',
	'requestedTools',
	'version',
	'license',
	'sourceFormat',
	'hasExecutableBundle',
	'isSharedToWorkspace',
	'workspaceId',
	'isFavorited',
	// body rides on the summary so the Library gallery's client-side search
	// can match skill instructions (content for prompts, body for skills).
	'body'
];

const SKILL_DETAIL_FIELDS: rpc.GetSkillFields = [
	...SKILL_SUMMARY_FIELDS,
	'requiredSecrets',
	'compatibility',
	'icon',
	'color',
	'sourceUrl',
	'fileManifest'
];

export function mySkills(): Promise<RpcResult<SkillSummary[]>> {
	return run((opts) => rpc.mySkills({ fields: SKILL_SUMMARY_FIELDS, ...opts }));
}

export function myFavoriteSkills(): Promise<RpcResult<SkillSummary[]>> {
	return run((opts) => rpc.myFavoriteSkills({ fields: SKILL_SUMMARY_FIELDS, ...opts }));
}

export function workspaceSkills(workspaceId: string): Promise<RpcResult<SkillSummary[]>> {
	return run((opts) =>
		rpc.workspaceSkills({ input: { workspaceId }, fields: SKILL_SUMMARY_FIELDS, ...opts })
	);
}

export function getSkill(id: string): Promise<RpcResult<SkillDetail>> {
	return run((opts) => rpc.getSkill({ getBy: { id }, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export function createSkill(input: CreateSkillInput): Promise<RpcResult<SkillDetail>> {
	return run((opts) => rpc.createSkill({ input, fields: SKILL_DETAIL_FIELDS, ...opts }));
}

export function updateSkill(id: string, input: UpdateSkillInput): Promise<RpcResult<SkillDetail>> {
	return run((opts) =>
		rpc.updateSkill({ identity: id, input, fields: SKILL_DETAIL_FIELDS, ...opts })
	);
}

export function destroySkill(id: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.destroySkill({ identity: id, ...opts }));
}

export function shareSkillToTeam(id: string): Promise<RpcResult<SkillDetail>> {
	return run((opts) =>
		rpc.shareSkillToTeam({ identity: id, fields: SKILL_DETAIL_FIELDS, ...opts })
	);
}

export function unshareSkillFromTeam(id: string): Promise<RpcResult<SkillDetail>> {
	return run((opts) =>
		rpc.unshareSkillFromTeam({ identity: id, fields: SKILL_DETAIL_FIELDS, ...opts })
	);
}

export async function uploadSkillBundle(
	file: File,
	workspaceId?: string
): Promise<RpcResult<{ id: string; name: string }>> {
	const form = new FormData();
	form.append('file', file);
	if (workspaceId) form.append('workspace_id', workspaceId);

	try {
		const response = await fetch('/rpc/skills/import', {
			method: 'POST',
			body: form,
			credentials: 'same-origin'
		});
		if (response.status === 401) return { success: false, errors: [UNAUTHENTICATED] };
		return (await response.json()) as RpcResult<{ id: string; name: string }>;
	} catch (error) {
		return {
			success: false,
			errors: [
				{
					type: 'network_error',
					message: error instanceof Error ? error.message : 'upload failed',
					shortMessage: 'Network error',
					vars: {},
					fields: [],
					path: []
				}
			]
		};
	}
}

export function skillDownloadUrl(skill: { id: string }): string {
	return `/skills/${skill.id}/download`;
}

export type SkillFavoriteEntry = { id: string; skillId: string };

export function mySkillFavorites(): Promise<RpcResult<SkillFavoriteEntry[]>> {
	return run((opts) => rpc.mySkillFavorites({ fields: ['id', 'skillId'], ...opts }));
}

export function favoriteSkill(skillId: string): Promise<RpcResult<SkillFavoriteEntry>> {
	return run((opts) =>
		rpc.favoriteSkill({ input: { skillId }, fields: ['id', 'skillId'], ...opts })
	);
}

export function unfavoriteSkill(favoriteId: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.unfavoriteSkill({ identity: favoriteId, ...opts }));
}

export function trustSkill(skillId: string): Promise<RpcResult<{ id: string }>> {
	return run((opts) => rpc.trustSkill({ input: { skillId }, fields: ['id'], ...opts }));
}

export function untrustSkill(trustId: string): Promise<RpcResult<Record<string, never>>> {
	return run((opts) => rpc.untrustSkill({ identity: trustId, ...opts }));
}

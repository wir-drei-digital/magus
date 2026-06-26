<script lang="ts">
	import { onMount } from 'svelte';
	import { Check, ExternalLink, Link2, Loader2, Plus, Search, ShieldAlert } from '@lucide/svelte';
	import { Button } from '$lib/components/ui/button';
	import {
		mcpRegistryServers,
		importMcpRegistryServer,
		connectMcpServer,
		type McpRegistryEntry,
		type McpRequiredHeader
	} from '$lib/ash/api';

	// Fired after a server is imported and/or connected so the parent can refresh
	// its Installed list. No payload: the parent just re-fetches.
	let { onImported }: { onImported?: () => void } = $props();

	const FIELD =
		'w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60';

	type ImportState = 'idle' | 'importing' | 'connected' | 'needs_auth' | 'already' | 'error';

	let query = $state('');
	let entries = $state<McpRegistryEntry[]>([]);
	let nextCursor = $state<string | null>(null);
	let loading = $state(true);
	let loadingMore = $state(false);
	let listError = $state<string | null>(null);

	// Per-entry import status, keyed by registryName.
	let importStates = $state<Record<string, ImportState>>({});
	let importErrors = $state<Record<string, string>>({});

	// Auth-on-import state, keyed by registryName. `serverIds` is needed for both
	// the static-header connect call and the OAuth full-page redirect.
	let serverIds = $state<Record<string, string>>({});
	let authHeaders = $state<Record<string, McpRequiredHeader[]>>({});
	let secretValues = $state<Record<string, Record<string, string>>>({});
	let connecting = $state<Record<string, boolean>>({});

	let searchTimer: ReturnType<typeof setTimeout> | undefined;

	// Defense-in-depth against duplicate `registryName`s: the registry publishes
	// one entry per server *version* (same name), and the backend dedups to the
	// latest — but a version can still straddle a pagination boundary across
	// `loadMore`. A duplicate key in the `{#each (entry.registryName)}` below
	// throws at runtime and blanks the list, so we keep the list unique by name.
	function dedupByName(list: McpRegistryEntry[]): McpRegistryEntry[] {
		const seen = new Set<string>();
		const out: McpRegistryEntry[] = [];
		for (const e of list) {
			if (!seen.has(e.registryName)) {
				seen.add(e.registryName);
				out.push(e);
			}
		}
		return out;
	}

	onMount(() => {
		void search();
	});

	function onInput() {
		clearTimeout(searchTimer);
		searchTimer = setTimeout(() => void search(), 300);
	}

	async function search() {
		loading = true;
		listError = null;
		const result = await mcpRegistryServers({ q: query.trim() || undefined });
		loading = false;
		if (result.success) {
			entries = dedupByName(result.data.entries);
			nextCursor = result.data.nextCursor;
		} else {
			listError = result.errors[0]?.message ?? 'Could not load the registry';
			entries = [];
			nextCursor = null;
		}
	}

	async function loadMore() {
		if (!nextCursor || loadingMore) return;
		loadingMore = true;
		const result = await mcpRegistryServers({ q: query.trim() || undefined, cursor: nextCursor });
		loadingMore = false;
		if (result.success) {
			entries = dedupByName([...entries, ...result.data.entries]);
			nextCursor = result.data.nextCursor;
		}
	}

	async function add(entry: McpRegistryEntry) {
		const key = entry.registryName;
		if (importStates[key] === 'importing') return;
		importStates = { ...importStates, [key]: 'importing' };
		importErrors = { ...importErrors, [key]: '' };

		const result = await importMcpRegistryServer({ registryName: key });
		if (result.success) {
			const next: ImportState = result.data.alreadyImported
				? 'already'
				: result.data.status === 'connected'
					? 'connected'
					: result.data.status === 'needs_auth'
						? 'needs_auth'
						: 'error';
			importStates = { ...importStates, [key]: next };
			// Capture the new server id for any follow-up (static connect or OAuth redirect).
			serverIds = { ...serverIds, [key]: result.data.server.id };
			if (next === 'needs_auth') {
				authHeaders = { ...authHeaders, [key]: result.data.requiredHeaders };
				secretValues = { ...secretValues, [key]: {} };
			}
			// A server now exists (imported, already-imported, or connected): tell
			// the parent to refresh Installed so the row shows up there too.
			if (next !== 'error') onImported?.();
		} else {
			importStates = { ...importStates, [key]: 'error' };
			importErrors = {
				...importErrors,
				[key]: result.errors[0]?.message ?? 'Could not add this server'
			};
		}
	}

	// Unique template variables across an entry's required headers, in order.
	function authVars(headers: McpRequiredHeader[]): string[] {
		const seen = new Set<string>();
		const vars: string[] = [];
		for (const h of headers) {
			for (const v of h.vars) {
				if (!seen.has(v)) {
					seen.add(v);
					vars.push(v);
				}
			}
		}
		return vars;
	}

	function setSecret(key: string, varName: string, value: string) {
		secretValues = {
			...secretValues,
			[key]: { ...(secretValues[key] ?? {}), [varName]: value }
		};
	}

	function canConnect(key: string): boolean {
		const headers = authHeaders[key] ?? [];
		const values = secretValues[key] ?? {};
		return authVars(headers).every((v) => (values[v] ?? '').trim() !== '');
	}

	/** Static-header connect: resolve the public templates and POST the secrets. */
	async function connectStatic(key: string) {
		const id = serverIds[key];
		const headers = authHeaders[key];
		if (!id || !headers || connecting[key] || !canConnect(key)) return;

		const values = secretValues[key] ?? {};
		// Substitute the public templates with the secrets the user typed.
		const resolved: Record<string, string> = {};
		for (const h of headers) {
			let value = h.template;
			for (const v of h.vars) {
				value = value.replaceAll(`{${v}}`, values[v] ?? '');
			}
			resolved[h.name] = value;
		}

		connecting = { ...connecting, [key]: true };
		const result = await connectMcpServer(id, resolved);
		connecting = { ...connecting, [key]: false };

		if (result.success && result.data.status === 'connected') {
			importStates = { ...importStates, [key]: 'connected' };
			onImported?.();
		} else if (result.success) {
			importStates = { ...importStates, [key]: 'error' };
			importErrors = { ...importErrors, [key]: 'Could not connect with those credentials.' };
		} else {
			importStates = { ...importStates, [key]: 'error' };
			importErrors = {
				...importErrors,
				[key]: result.errors[0]?.message ?? 'Could not connect'
			};
		}
	}

	/**
	 * OAuth connect-on-import: full-page redirect into Task 4's flow, mirroring the
	 * Installed list's `connect()`. The browser returns to /settings/mcp-servers
	 * with a non-secret `mcp_oauth` / `mcp_oauth_error` param that the page handles.
	 */
	function connectOAuth(key: string) {
		const id = serverIds[key];
		if (!id) return;
		window.location.href = `/oauth/mcp/${id}/start`;
	}

	function statusLabel(state: ImportState): string {
		switch (state) {
			case 'connected':
				return 'Added';
			case 'already':
				return 'Already added';
			case 'needs_auth':
				return 'Added — needs auth';
			case 'error':
				return 'Failed';
			default:
				return '';
		}
	}
</script>

<div class="space-y-4" data-testid="settings-mcp-browse">
	<p class="flex items-center gap-1 text-xs text-muted-foreground">
		<span>Browsing the public</span>
		<a
			href="https://registry.modelcontextprotocol.io"
			target="_blank"
			rel="noopener noreferrer"
			class="inline-flex items-center gap-1 font-medium text-foreground hover:underline"
			data-testid="mcp-registry-source-link"
		>
			Model Context Protocol registry
			<ExternalLink class="size-3" />
		</a>
	</p>

	<label class="relative block">
		<Search
			class="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground"
		/>
		<input
			type="text"
			bind:value={query}
			oninput={onInput}
			placeholder="Search the registry (e.g. github, linear, sentry)…"
			data-testid="mcp-registry-search"
			class="{FIELD} pl-8"
		/>
	</label>

	{#if loading}
		<div class="h-48 animate-pulse rounded-xl bg-muted/60" data-testid="mcp-registry-loading"></div>
	{:else if listError}
		<p class="py-6 text-center text-sm text-destructive" data-testid="mcp-registry-error">
			{listError}
		</p>
	{:else if entries.length === 0}
		<p class="py-6 text-center text-sm text-muted-foreground">No matching servers found.</p>
	{:else}
		<ul class="space-y-2" data-testid="mcp-registry-list">
			{#each entries as entry (entry.registryName)}
				{@const state = importStates[entry.registryName] ?? 'idle'}
				<li
					class="flex items-start gap-3 rounded-lg border bg-card p-3"
					data-testid="mcp-registry-item"
				>
					<div class="min-w-0 flex-1">
						<p class="flex items-center gap-2 text-sm font-medium">
							<span class="truncate">{entry.displayName}</span>
							{#if entry.version}
								<span class="shrink-0 text-xs font-normal text-muted-foreground">
									v{entry.version}
								</span>
							{/if}
							{#if entry.requiresAuth}
								<span
									class="inline-flex shrink-0 items-center gap-1 rounded-full bg-secondary px-1.5 py-0.5 text-[10px] font-medium text-muted-foreground"
									title="Requires authentication"
								>
									<ShieldAlert class="size-3" /> Auth
								</span>
							{/if}
						</p>
						{#if entry.description}
							<p class="mt-0.5 line-clamp-2 text-xs text-muted-foreground">{entry.description}</p>
						{/if}
						<p class="mt-0.5 truncate text-[11px] text-muted-foreground" title={entry.registryName}>
							{entry.registryName}
						</p>
						<div
							class="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-muted-foreground"
						>
							<a
								href={`https://registry.modelcontextprotocol.io/?search=${encodeURIComponent(
									entry.registryName
								)}`}
								target="_blank"
								rel="noopener noreferrer"
								class="inline-flex items-center gap-1 hover:text-foreground"
								data-testid="mcp-registry-entry-link"
							>
								<ExternalLink class="size-3" /> View in registry
							</a>
							{#if entry.repositoryUrl}
								<a
									href={entry.repositoryUrl}
									target="_blank"
									rel="noopener noreferrer"
									class="inline-flex items-center gap-1 hover:text-foreground"
								>
									<ExternalLink class="size-3" /> Repository
								</a>
							{/if}
						</div>
						{#if state === 'needs_auth' && entry.authType === 'static_header'}
							<form
								class="mt-2 space-y-2 rounded-md border bg-secondary/40 p-2.5"
								data-testid="mcp-registry-auth-form"
								onsubmit={(event) => {
									event.preventDefault();
									void connectStatic(entry.registryName);
								}}
							>
								<p class="text-xs text-muted-foreground">Added. Enter credentials to connect.</p>
								{#each authVars(authHeaders[entry.registryName] ?? []) as v (v)}
									<label class="flex flex-col gap-1">
										<span class="text-[11px] font-medium text-muted-foreground">{v}</span>
										<input
											type="password"
											autocomplete="off"
											value={secretValues[entry.registryName]?.[v] ?? ''}
											oninput={(e) => setSecret(entry.registryName, v, e.currentTarget.value)}
											data-testid="mcp-registry-secret"
											class={FIELD}
										/>
									</label>
								{/each}
								<Button
									type="submit"
									size="sm"
									disabled={connecting[entry.registryName] || !canConnect(entry.registryName)}
									data-testid="mcp-registry-connect"
								>
									{connecting[entry.registryName] ? 'Connecting…' : 'Connect'}
								</Button>
							</form>
						{:else if state === 'needs_auth'}
							<div
								class="mt-2 flex flex-col items-start gap-2 rounded-md border bg-secondary/40 p-2.5"
							>
								<p class="text-xs text-muted-foreground">
									Added. Authorize with OAuth to connect.
								</p>
								<Button
									type="button"
									size="sm"
									onclick={() => connectOAuth(entry.registryName)}
									data-testid="mcp-registry-oauth-connect"
								>
									<Link2 class="size-4" />
									Connect
								</Button>
							</div>
						{:else if state === 'error' && importErrors[entry.registryName]}
							<p class="mt-1 text-xs text-destructive">{importErrors[entry.registryName]}</p>
						{/if}
					</div>

					<div class="shrink-0">
						{#if state === 'connected' || state === 'already'}
							<span
								class="inline-flex items-center gap-1 text-xs font-medium text-success"
								data-testid="mcp-registry-added"
							>
								<Check class="size-4" />
								{statusLabel(state)}
							</span>
						{:else if state === 'needs_auth'}
							<span class="text-xs font-medium text-muted-foreground">{statusLabel(state)}</span>
						{:else}
							<Button
								size="sm"
								disabled={state === 'importing'}
								onclick={() => void add(entry)}
								data-testid="mcp-registry-add"
							>
								{#if state === 'importing'}
									<Loader2 class="size-4 animate-spin" />
								{:else}
									<Plus class="size-4" />
								{/if}
								{state === 'error' ? 'Retry' : 'Add'}
							</Button>
						{/if}
					</div>
				</li>
			{/each}
		</ul>

		{#if nextCursor}
			<div class="mt-3 flex justify-center">
				<Button
					variant="ghost"
					size="sm"
					disabled={loadingMore}
					onclick={() => void loadMore()}
					data-testid="mcp-registry-load-more"
				>
					{loadingMore ? 'Loading…' : 'Load more'}
				</Button>
			</div>
		{/if}
	{/if}
</div>

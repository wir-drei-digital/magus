<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import {
		ExternalLink,
		Link2,
		Pencil,
		Plus,
		Power,
		RefreshCw,
		Server,
		Trash2,
		Unlink
	} from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import SettingsSection from '$lib/components/crud/section.svelte';
	import McpRegistryBrowse from '$lib/components/settings/mcp-registry-browse.svelte';
	import {
		createMcpServer,
		destroyMcpServer,
		disconnectMcpCredential,
		discoverMcpServer,
		getMcpCredential,
		listMcpServers,
		toggleMcpServer,
		updateMcpServer,
		upsertMcpStaticHeaders,
		type McpAuthType,
		type McpCredentialEntry,
		type McpCredentialStatus,
		type McpServerEntry,
		type McpTransport
	} from '$lib/ash/api';
	import { mcpStatusBadge, mcpStatusToneClass } from '$lib/mcp/status';
	import { mcpOAuthFeedback, type McpOAuthFeedback } from '$lib/mcp/oauth-feedback';

	type McpTab = 'installed' | 'browse';
	let tab = $state<McpTab>('installed');

	const FIELD =
		'w-full rounded-md border border-input bg-secondary px-2.5 py-1.5 text-sm outline-none focus:border-primary/60 disabled:opacity-60';

	let servers = $state<McpServerEntry[]>([]);
	// Per-server credential record, keyed by server id (null = no credential row).
	// We keep the whole entry (not just status) so Disconnect has the credential id.
	let credentials = $state<Record<string, McpCredentialEntry | null>>({});
	let loading = $state(true);
	let loadError = $state<string | null>(null);

	// Feedback banner shown after returning from the OAuth redirect flow.
	let oauthFeedback = $state<McpOAuthFeedback | null>(null);

	// Per-row busy flags so one server's action doesn't disable the whole list.
	let busyId = $state<string | null>(null);
	let confirmingDeleteId = $state<string | null>(null);

	/** Status for a server's credential, or null when there is no credential row. */
	function statusFor(serverId: string): McpCredentialStatus | null {
		return credentials[serverId]?.status ?? null;
	}

	// Dialog state. `editing` holds the server being edited, or null when creating.
	let dialogOpen = $state(false);
	let editing = $state<McpServerEntry | null>(null);
	let saving = $state(false);
	let saveError = $state<string | null>(null);

	let name = $state('');
	let handle = $state('');
	let url = $state('');
	let transport = $state<McpTransport>('streamable_http');
	let mcpPath = $state('/mcp');
	let authType = $state<McpAuthType>('none');
	// Static-header credential input: the user pastes a bearer token (write-only).
	let bearerToken = $state('');

	const dialogTitle = $derived(editing ? 'Edit MCP server' : 'Add MCP server');

	onMount(() => void init());

	async function init() {
		await load();
		await handleOAuthReturn();
	}

	/**
	 * The OAuth flow (Task 4) full-page-redirects back here with exactly one of
	 * `?mcp_oauth=connected` or `?mcp_oauth_error=<code>`. Surface the result,
	 * re-fetch the affected credential's status, then strip the params so a
	 * refresh does not re-toast.
	 */
	async function handleOAuthReturn() {
		const success = page.url.searchParams.get('mcp_oauth');
		const errorCode = page.url.searchParams.get('mcp_oauth_error');
		const feedback = mcpOAuthFeedback(success, errorCode);
		if (!feedback) return;

		oauthFeedback = feedback;

		// Refresh every server's credential status: the redirect does not carry
		// the server id, and a successful connect changes exactly one of them.
		await loadCredentials(servers);

		// Drop the query params so a reload doesn't replay the banner.
		const clean = new URL(page.url);
		clean.searchParams.delete('mcp_oauth');
		clean.searchParams.delete('mcp_oauth_error');
		await goto(`${clean.pathname}${clean.search}`, { replaceState: true, noScroll: true });
	}

	async function load() {
		loading = true;
		loadError = null;
		const result = await listMcpServers();
		if (result.success) {
			servers = result.data;
			await loadCredentials(result.data);
		} else {
			loadError = result.errors[0]?.message ?? 'Could not load MCP servers';
		}
		loading = false;
	}

	async function loadCredentials(list: McpServerEntry[]) {
		const entries = await Promise.all(
			list.map(async (server) => {
				const result = await getMcpCredential(server.id);
				return [server.id, result.success ? result.data : null] as const;
			})
		);
		credentials = Object.fromEntries(entries);
	}

	/** Re-fetch one server's credential and update the map in place. */
	async function refreshCredential(serverId: string) {
		const result = await getMcpCredential(serverId);
		credentials = { ...credentials, [serverId]: result.success ? result.data : null };
	}

	function badgeFor(server: McpServerEntry) {
		return mcpStatusBadge({
			enabled: server.enabled,
			reachability: server.reachability,
			credentialStatus: statusFor(server.id)
		});
	}

	function openCreate() {
		editing = null;
		name = '';
		handle = '';
		url = '';
		transport = 'streamable_http';
		mcpPath = '/mcp';
		authType = 'none';
		bearerToken = '';
		saveError = null;
		dialogOpen = true;
	}

	function openEdit(server: McpServerEntry) {
		editing = server;
		name = server.name;
		handle = server.handle;
		url = server.url;
		transport = server.transport;
		mcpPath = server.mcpPath;
		authType = server.authType;
		// Never prefill the secret — it is write-only and never returned.
		bearerToken = '';
		saveError = null;
		dialogOpen = true;
	}

	function replaceServer(updated: McpServerEntry) {
		servers = servers.map((server) => (server.id === updated.id ? updated : server));
	}

	async function save() {
		if (saving || name.trim() === '') return;
		saving = true;
		saveError = null;

		const result = editing
			? await updateMcpServer(editing.id, {
					name: name.trim(),
					url: url.trim(),
					transport,
					mcpPath: mcpPath.trim() || '/mcp',
					authType
				})
			: await createMcpServer({
					name: name.trim(),
					handle: handle.trim(),
					url: url.trim(),
					transport,
					mcpPath: mcpPath.trim() || '/mcp',
					authType
				});

		if (!result.success) {
			saving = false;
			saveError = result.errors[0]?.message ?? 'Could not save server';
			return;
		}

		const server = result.data;
		if (editing) replaceServer(server);
		else servers = [server, ...servers];

		// Persist a static-header credential only when one was entered.
		if (authType === 'static_header' && bearerToken.trim() !== '') {
			const credResult = await upsertMcpStaticHeaders(server.id, {
				Authorization: `Bearer ${bearerToken.trim()}`
			});
			if (credResult.success) {
				credentials = { ...credentials, [server.id]: credResult.data };
			} else {
				saving = false;
				saveError = credResult.errors[0]?.message ?? 'Server saved, but credential failed';
				return;
			}
		}

		saving = false;
		dialogOpen = false;
	}

	async function toggle(server: McpServerEntry) {
		if (busyId) return;
		busyId = server.id;
		const result = await toggleMcpServer(server.id);
		if (result.success) replaceServer(result.data);
		busyId = null;
	}

	async function refresh(server: McpServerEntry) {
		if (busyId) return;
		busyId = server.id;
		const result = await discoverMcpServer(server.id);
		if (result.success) {
			replaceServer(result.data);
			await refreshCredential(server.id);
		}
		busyId = null;
	}

	/**
	 * Begin the OAuth connect flow with a full-page redirect into the Task 4
	 * route. No secrets leave the SPA — the browser returns to this page with a
	 * non-secret `mcp_oauth` / `mcp_oauth_error` param.
	 */
	function connect(server: McpServerEntry) {
		window.location.href = `/oauth/mcp/${server.id}/start`;
	}

	/** Disconnect an OAuth server: clear the actor's tokens, then refresh status. */
	async function disconnect(server: McpServerEntry) {
		if (busyId) return;
		const credential = credentials[server.id];
		if (!credential) return;
		busyId = server.id;
		const result = await disconnectMcpCredential(credential.id);
		if (result.success) {
			credentials = { ...credentials, [server.id]: result.data };
		} else {
			await refreshCredential(server.id);
		}
		busyId = null;
	}

	async function remove(server: McpServerEntry) {
		if (confirmingDeleteId !== server.id) {
			confirmingDeleteId = server.id;
			setTimeout(() => {
				if (confirmingDeleteId === server.id) confirmingDeleteId = null;
			}, 3000);
			return;
		}
		confirmingDeleteId = null;
		if (busyId) return;
		busyId = server.id;
		const result = await destroyMcpServer(server.id);
		if (result.success) {
			servers = servers.filter((entry) => entry.id !== server.id);
		}
		busyId = null;
	}
</script>

{#snippet tabButton(id: McpTab, label: string)}
	<button
		type="button"
		role="tab"
		aria-selected={tab === id}
		tabindex={tab === id ? 0 : -1}
		data-testid="mcp-tab-{id}"
		class="rounded-md px-3 py-1.5 text-sm font-medium transition-colors {tab === id
			? 'bg-card text-foreground shadow-sm'
			: 'text-muted-foreground hover:text-foreground'}"
		onclick={() => (tab = id)}
		onkeydown={(event) => {
			if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
				event.preventDefault();
				tab = tab === 'installed' ? 'browse' : 'installed';
				// Move focus to the now-selected tab (roving tabindex).
				const tablist = event.currentTarget.closest('[role="tablist"]');
				tablist?.querySelector<HTMLElement>(`[data-testid="mcp-tab-${tab}"]`)?.focus();
			}
		}}
	>
		{label}
	</button>
{/snippet}

<div class="space-y-6" data-testid="settings-mcp">
	<div
		class="inline-flex gap-1 rounded-lg border bg-secondary/40 p-1"
		role="tablist"
		aria-label="MCP servers"
	>
		{@render tabButton('installed', 'Installed')}
		{@render tabButton('browse', 'Browse registry')}
	</div>

	{#if tab === 'browse'}
		<SettingsSection
			title="Browse the MCP registry"
			description="Search the public MCP registry and connect a remote server in one click. Its tools become available to your agents."
		>
			<McpRegistryBrowse onImported={() => void load()} />
		</SettingsSection>
	{:else if loading}
		<div class="h-48 animate-pulse rounded-xl bg-muted/60" data-testid="settings-mcp-loading"></div>
	{:else}
		<SettingsSection
			title="MCP servers"
			description="Connect Model Context Protocol servers to expose their tools to your agents."
		>
			<div class="mb-3">
				<Button onclick={openCreate} data-testid="mcp-server-new">
					<Plus class="size-4" />
					Add server
				</Button>
			</div>

			{#if oauthFeedback}
				<div
					class="mb-3 flex items-start gap-2 rounded-md px-3 py-2 text-xs {oauthFeedback.tone ===
					'ok'
						? 'bg-success/15 text-success'
						: 'bg-destructive/15 text-destructive'}"
					data-testid="mcp-oauth-feedback"
				>
					<span class="flex-1">{oauthFeedback.message}</span>
					<button
						type="button"
						class="shrink-0 opacity-70 hover:opacity-100"
						aria-label="Dismiss"
						data-testid="mcp-oauth-feedback-dismiss"
						onclick={() => (oauthFeedback = null)}
					>
						×
					</button>
				</div>
			{/if}

			{#if loadError}
				<p class="mb-3 text-xs text-destructive" data-testid="mcp-server-error">{loadError}</p>
			{/if}

			{#if servers.length === 0}
				<p class="py-4 text-center text-sm text-muted-foreground" data-testid="mcp-server-empty">
					No MCP servers yet.
				</p>
			{:else}
				<ul class="divide-y" data-testid="mcp-server-list">
					{#each servers as server (server.id)}
						{@const badge = badgeFor(server)}
						<li
							class="flex items-center gap-3 py-3 first:pt-0 last:pb-0"
							data-testid="mcp-server-row"
						>
							<Server class="size-4 shrink-0 text-muted-foreground" />
							<div class="min-w-0 flex-1">
								<p class="flex items-center gap-2 text-sm font-medium">
									<span class="truncate">{server.name}</span>
									<span
										class="shrink-0 rounded-full bg-secondary px-1.5 py-0.5 text-[10px] font-medium uppercase text-muted-foreground"
									>
										{server.transport === 'sse' ? 'SSE' : 'HTTP'}
									</span>
									<span
										class="shrink-0 rounded-full px-1.5 py-0.5 text-[10px] font-medium {mcpStatusToneClass(
											badge.tone
										)}"
										data-testid="mcp-server-status"
									>
										{badge.label}
									</span>
								</p>
								<p class="truncate text-xs text-muted-foreground">
									<code class="font-mono">{server.handle}</code>
									· {server.cachedTools.length}
									{server.cachedTools.length === 1 ? 'tool' : 'tools'}
								</p>
								{#if server.source === 'registry'}
									<p
										class="mt-0.5 flex items-center gap-2 text-xs text-muted-foreground"
										data-testid="mcp-server-provenance"
									>
										<span
											class="shrink-0 rounded-full bg-secondary px-1.5 py-0.5 text-[10px] font-medium"
										>
											From registry
										</span>
										{#if server.repositoryUrl}
											<a
												href={server.repositoryUrl}
												target="_blank"
												rel="noopener noreferrer"
												class="inline-flex min-w-0 items-center gap-1 hover:text-foreground"
											>
												<ExternalLink class="size-3 shrink-0" />
												<span class="truncate">{server.registryName ?? 'Repository'}</span>
											</a>
										{:else if server.description}
											<span class="truncate">{server.description}</span>
										{/if}
									</p>
								{/if}
							</div>
							{#if server.authType === 'oauth'}
								{@const status = statusFor(server.id)}
								{#if status === 'connected' || status === 'needs_auth'}
									<button
										type="button"
										class="wb-pill-btn shrink-0 hover:!text-destructive"
										title={status === 'needs_auth' ? 'Reconnect' : 'Disconnect'}
										data-testid="mcp-oauth-disconnect"
										disabled={busyId === server.id}
										onclick={() => void disconnect(server)}
									>
										<Unlink class="size-3.5" />
										Disconnect
									</button>
									{#if status === 'needs_auth'}
										<button
											type="button"
											class="wb-pill-btn shrink-0"
											title="Reconnect"
											data-testid="mcp-oauth-connect"
											disabled={busyId === server.id}
											onclick={() => connect(server)}
										>
											<Link2 class="size-3.5" />
											Reconnect
										</button>
									{/if}
								{:else}
									<button
										type="button"
										class="wb-pill-btn shrink-0"
										title="Connect"
										data-testid="mcp-oauth-connect"
										disabled={busyId === server.id}
										onclick={() => connect(server)}
									>
										<Link2 class="size-3.5" />
										Connect
									</button>
								{/if}
							{/if}
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0"
								title="Test / refresh"
								data-testid="mcp-server-refresh"
								disabled={busyId === server.id}
								onclick={() => void refresh(server)}
							>
								<RefreshCw class="size-3.5 {busyId === server.id ? 'animate-spin' : ''}" />
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0 {server.enabled
									? 'hover:!text-destructive'
									: '!text-muted-foreground'}"
								title={server.enabled ? 'Disable' : 'Enable'}
								data-testid="mcp-server-toggle"
								disabled={busyId === server.id}
								onclick={() => void toggle(server)}
							>
								<Power class="size-3.5" />
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0"
								title="Edit"
								data-testid="mcp-server-edit"
								onclick={() => openEdit(server)}
							>
								<Pencil class="size-3.5" />
							</button>
							<button
								type="button"
								class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingDeleteId === server.id
									? '!border-destructive !bg-destructive !text-destructive-foreground'
									: 'hover:!text-destructive'}"
								title={confirmingDeleteId === server.id ? 'Confirm delete' : 'Delete'}
								data-testid="mcp-server-delete"
								disabled={busyId === server.id}
								onclick={() => void remove(server)}
							>
								<Trash2 class="size-3.5" />
							</button>
						</li>
					{/each}
				</ul>
			{/if}
		</SettingsSection>
	{/if}
</div>

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="mcp-server-dialog">
		<Dialog.Header>
			<Dialog.Title>{dialogTitle}</Dialog.Title>
			<Dialog.Description>
				Point at a Model Context Protocol endpoint. The handle is permanent.
			</Dialog.Description>
		</Dialog.Header>
		<form
			class="space-y-3"
			onsubmit={(event) => {
				event.preventDefault();
				void save();
			}}
		>
			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">Name</span>
				<input
					type="text"
					bind:value={name}
					maxlength="100"
					placeholder="e.g. GitHub MCP"
					data-testid="mcp-server-name-input"
					class={FIELD}
				/>
			</label>
			{#if !editing}
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Handle</span>
					<input
						type="text"
						bind:value={handle}
						maxlength="64"
						placeholder="e.g. github"
						data-testid="mcp-server-handle-input"
						class="{FIELD} font-mono"
					/>
				</label>
			{/if}
			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">URL</span>
				<input
					type="url"
					bind:value={url}
					placeholder="https://mcp.example.com"
					data-testid="mcp-server-url-input"
					class={FIELD}
				/>
			</label>
			<div class="grid grid-cols-2 gap-3">
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Transport</span>
					<select bind:value={transport} data-testid="mcp-server-transport-input" class={FIELD}>
						<option value="streamable_http">Streamable HTTP</option>
						<option value="sse">SSE</option>
					</select>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">MCP path</span>
					<input
						type="text"
						bind:value={mcpPath}
						placeholder="/mcp"
						data-testid="mcp-server-path-input"
						class={FIELD}
					/>
				</label>
			</div>
			<label class="flex flex-col gap-1.5">
				<span class="text-xs font-medium text-muted-foreground">Authentication</span>
				<select bind:value={authType} data-testid="mcp-server-auth-input" class={FIELD}>
					<option value="none">None</option>
					<option value="static_header">Static header (bearer token)</option>
					<option value="oauth">OAuth</option>
				</select>
			</label>

			{#if authType === 'static_header'}
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Bearer token</span>
					<input
						type="password"
						bind:value={bearerToken}
						autocomplete="off"
						placeholder={editing ? 'Leave blank to keep existing' : 'Paste token'}
						data-testid="mcp-static-header-input"
						class="{FIELD} font-mono"
					/>
					<span class="text-[10px] text-muted-foreground">
						Sent as <code>Authorization: Bearer …</code>. Stored encrypted; never shown again.
					</span>
				</label>
			{/if}

			{#if authType === 'oauth'}
				<p
					class="rounded-md bg-secondary px-3 py-2 text-[10px] text-muted-foreground"
					data-testid="mcp-oauth-hint"
				>
					Save the server, then use <strong>Connect</strong> on its row in the list to authorize with
					OAuth.
				</p>
			{/if}

			{#if saveError}
				<p class="text-xs text-destructive" data-testid="mcp-server-save-error">{saveError}</p>
			{/if}

			<Dialog.Footer>
				<Button type="button" variant="ghost" onclick={() => (dialogOpen = false)}>Cancel</Button>
				<Button type="submit" disabled={saving || name.trim() === ''} data-testid="mcp-server-save">
					{saving ? 'Saving…' : editing ? 'Save' : 'Add server'}
				</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>

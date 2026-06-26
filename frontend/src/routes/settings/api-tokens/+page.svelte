<script lang="ts">
	import { onMount } from 'svelte';
	import { Check, Copy, KeyRound, Plus, Trash2 } from '@lucide/svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import { Section as SettingsSection, CONTROL_CLASS } from '$lib/components/crud';
	import {
		apiTokens,
		createApiToken,
		myWorkspaces,
		revokeApiToken,
		type ApiTokenEntry,
		type CreatedApiToken,
		type WorkspaceSummary
	} from '$lib/ash/api';
	import { relativeTime } from '$lib/time';

	const FIELD =
		CONTROL_CLASS;

	let tokens = $state<ApiTokenEntry[]>([]);
	let workspaces = $state<WorkspaceSummary[]>([]);
	let loading = $state(true);

	let dialogOpen = $state(false);
	let name = $state('');
	let scope = $state<'read' | 'write'>('read');
	let workspaceId = $state('');
	let expiresAt = $state('');
	let creating = $state(false);
	let createError = $state<string | null>(null);
	// The one-time plaintext, shown after creation until the dialog closes.
	let created = $state<CreatedApiToken | null>(null);
	let copied = $state(false);

	let confirmingRevokeId = $state<string | null>(null);

	onMount(() => {
		void load();
	});

	async function load() {
		const [t, w] = await Promise.all([apiTokens(), myWorkspaces()]);
		if (t.success) tokens = t.data;
		if (w.success) workspaces = w.data;
		loading = false;
	}

	function openDialog() {
		name = '';
		scope = 'read';
		workspaceId = '';
		expiresAt = '';
		createError = null;
		created = null;
		copied = false;
		dialogOpen = true;
	}

	async function create() {
		if (creating || name.trim() === '') return;
		creating = true;
		createError = null;
		const result = await createApiToken({
			name: name.trim(),
			scope,
			workspaceId: workspaceId || null,
			// <input type=date> gives YYYY-MM-DD; send an end-of-day UTC instant.
			expiresAt: expiresAt ? new Date(`${expiresAt}T23:59:59Z`).toISOString() : null
		});
		creating = false;
		if (result.success) {
			created = result.data;
			tokens = [result.data, ...tokens];
		} else {
			createError = result.errors[0]?.message ?? 'Could not create token';
		}
	}

	async function copyPlaintext() {
		if (!created) return;
		try {
			await navigator.clipboard.writeText(created.plaintext);
			copied = true;
			setTimeout(() => (copied = false), 1500);
		} catch {
			// Clipboard blocked — the value is selectable in the field.
		}
	}

	async function revoke(token: ApiTokenEntry) {
		if (confirmingRevokeId !== token.id) {
			confirmingRevokeId = token.id;
			setTimeout(() => {
				if (confirmingRevokeId === token.id) confirmingRevokeId = null;
			}, 3000);
			return;
		}
		confirmingRevokeId = null;
		const result = await revokeApiToken(token.id);
		if (result.success) {
			tokens = tokens.map((entry) =>
				entry.id === token.id ? { ...entry, revokedAt: new Date().toISOString() } : entry
			);
		}
	}

	function workspaceName(id: string | null): string | null {
		if (!id) return null;
		return workspaces.find((workspace) => workspace.id === id)?.name ?? 'Workspace';
	}
</script>

{#if loading}
	<div
		class="h-48 animate-pulse rounded-xl bg-muted/60"
		data-testid="settings-api-tokens-loading"
	></div>
{:else}
	<div class="space-y-6" data-testid="settings-api-tokens">
		<SettingsSection
			title="Personal access tokens"
			description="Authenticate the magus CLI and MCP server. Treat tokens like passwords."
		>
			<div class="mb-3">
				<Button onclick={openDialog} data-testid="api-token-new">
					<Plus class="size-4" />
					Generate token
				</Button>
			</div>

			{#if tokens.length === 0}
				<p class="py-4 text-center text-sm text-muted-foreground">No tokens yet.</p>
			{:else}
				<ul class="divide-y" data-testid="api-token-list">
					{#each tokens as token (token.id)}
						<li class="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
							<KeyRound class="size-4 shrink-0 text-muted-foreground" />
							<div class="min-w-0 flex-1">
								<p class="flex items-center gap-2 text-sm font-medium">
									<span class="truncate">{token.name}</span>
									<span
										class="shrink-0 rounded-full bg-secondary px-1.5 py-0.5 text-[10px] font-medium uppercase text-muted-foreground"
									>
										{token.scope}
									</span>
									{#if token.revokedAt}
										<span
											class="shrink-0 rounded-full bg-destructive/15 px-1.5 py-0.5 text-[10px] font-medium text-destructive"
										>
											Revoked
										</span>
									{/if}
								</p>
								<p class="truncate text-xs text-muted-foreground">
									<code class="font-mono">{token.keyPrefix}…</code>
									{#if workspaceName(token.workspaceId)}
										· {workspaceName(token.workspaceId)}
									{/if}
									· {token.lastUsedAt ? `used ${relativeTime(token.lastUsedAt)}` : 'never used'}
								</p>
							</div>
							{#if !token.revokedAt}
								<button
									type="button"
									class="wb-pill-btn wb-pill-btn-square shrink-0 {confirmingRevokeId === token.id
										? '!border-destructive !bg-destructive !text-destructive-foreground'
										: 'hover:!text-destructive'}"
									title={confirmingRevokeId === token.id ? 'Confirm revoke' : 'Revoke'}
									data-testid="api-token-revoke"
									onclick={() => void revoke(token)}
								>
									<Trash2 class="size-3.5" />
								</button>
							{/if}
						</li>
					{/each}
				</ul>
			{/if}
		</SettingsSection>
	</div>
{/if}

<Dialog.Root bind:open={dialogOpen}>
	<Dialog.Content class="sm:max-w-md" data-testid="api-token-dialog">
		{#if created}
			<Dialog.Header>
				<Dialog.Title>Copy your token now</Dialog.Title>
				<Dialog.Description>
					This is the only time the full token is shown. Store it somewhere safe.
				</Dialog.Description>
			</Dialog.Header>
			<div class="flex items-center gap-2">
				<input
					readonly
					value={created.plaintext}
					data-testid="api-token-plaintext"
					class="{FIELD} font-mono text-xs"
				/>
				<Button
					variant="outline"
					size="icon"
					onclick={() => void copyPlaintext()}
					data-testid="api-token-copy"
				>
					{#if copied}<Check class="size-4 text-success" />{:else}<Copy class="size-4" />{/if}
				</Button>
			</div>
			<Dialog.Footer>
				<Button onclick={() => (dialogOpen = false)} data-testid="api-token-done">Done</Button>
			</Dialog.Footer>
		{:else}
			<Dialog.Header>
				<Dialog.Title>Generate access token</Dialog.Title>
				<Dialog.Description>Scope and optional expiry for the new token.</Dialog.Description>
			</Dialog.Header>
			<form
				class="space-y-3"
				onsubmit={(event) => {
					event.preventDefault();
					void create();
				}}
			>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Name</span>
					<input
						type="text"
						bind:value={name}
						maxlength="100"
						placeholder="e.g. Laptop CLI"
						data-testid="api-token-name"
						class={FIELD}
					/>
				</label>
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Scope</span>
					<select bind:value={scope} data-testid="api-token-scope" class={FIELD}>
						<option value="read">Read only</option>
						<option value="write">Read and write</option>
					</select>
				</label>
				{#if workspaces.length > 0}
					<label class="flex flex-col gap-1.5">
						<span class="text-xs font-medium text-muted-foreground">Workspace (optional)</span>
						<select bind:value={workspaceId} data-testid="api-token-workspace" class={FIELD}>
							<option value="">Personal scope</option>
							{#each workspaces as workspace (workspace.id)}
								<option value={workspace.id}>{workspace.name}</option>
							{/each}
						</select>
					</label>
				{/if}
				<label class="flex flex-col gap-1.5">
					<span class="text-xs font-medium text-muted-foreground">Expires (optional)</span>
					<input type="date" bind:value={expiresAt} data-testid="api-token-expires" class={FIELD} />
				</label>
				{#if createError}
					<p class="text-xs text-destructive">{createError}</p>
				{/if}
				<Dialog.Footer>
					<Button type="button" variant="ghost" onclick={() => (dialogOpen = false)}>Cancel</Button>
					<Button
						type="submit"
						disabled={creating || name.trim() === ''}
						data-testid="api-token-create"
					>
						{creating ? 'Generating…' : 'Generate'}
					</Button>
				</Dialog.Footer>
			</form>
		{/if}
	</Dialog.Content>
</Dialog.Root>

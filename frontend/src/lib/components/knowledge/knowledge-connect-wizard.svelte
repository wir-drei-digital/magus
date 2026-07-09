<script lang="ts">
	import { base } from '$app/paths';
	import { Database, ExternalLink, Loader2 } from '@lucide/svelte';
	import { SvelteMap } from 'svelte/reactivity';
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import {
		connectKnowledgeSource,
		createKnowledgeCollections,
		knowledgeSourceFolders,
		type KnowledgeFolderNode,
		type KnowledgeSourceEntry
	} from '$lib/ash/api';
	import KnowledgeFolderNodeView from './knowledge-folder-node.svelte';

	let {
		open = $bindable(false),
		workspaceId = null,
		resumeSource = null,
		onConnected
	}: {
		open?: boolean;
		workspaceId?: string | null;
		/** When set as the dialog opens, skip to the folder picker (OAuth return). */
		resumeSource?: KnowledgeSourceEntry | null;
		onConnected?: () => void;
	} = $props();

	type FormField = { name: string; label: string; type: string; placeholder?: string };
	type Provider =
		| { key: string; label: string; kind: 'oauth'; oauthKey: string; hint: string }
		| { key: string; label: string; kind: 'form'; fields: FormField[]; hint: string };

	const PROVIDERS: Provider[] = [
		{
			key: 'google_drive',
			label: 'Google Drive',
			kind: 'oauth',
			oauthKey: 'google_drive_knowledge',
			hint: 'Sign in with Google to browse your Drive folders.'
		},
		{
			key: 'notion',
			label: 'Notion',
			kind: 'oauth',
			oauthKey: 'notion_knowledge',
			hint: 'Authorize Notion to import pages and databases.'
		},
		{
			key: 'nextcloud',
			label: 'Nextcloud',
			kind: 'form',
			hint: 'Connect with your server URL and an app password.',
			fields: [
				{
					name: 'base_url',
					label: 'Server URL',
					type: 'url',
					placeholder: 'https://cloud.example.com'
				},
				{ name: 'username', label: 'Username', type: 'text' },
				{ name: 'password', label: 'App password', type: 'password' }
			]
		},
		{
			key: 'web',
			label: 'Website',
			kind: 'form',
			hint: 'Crawl a public site or docs URL.',
			fields: [
				{ name: 'seed_url', label: 'URL', type: 'url', placeholder: 'https://example.com/docs' }
			]
		},
		{
			key: 'onedrive',
			label: 'OneDrive',
			kind: 'oauth',
			oauthKey: 'onedrive_knowledge',
			hint: 'Sign in with Microsoft to browse your OneDrive folders.'
		},
		{
			key: 'dropbox',
			label: 'Dropbox',
			kind: 'oauth',
			oauthKey: 'dropbox_knowledge',
			hint: 'Authorize Dropbox to sync selected folders.'
		},
		{
			key: 'kdrive',
			label: 'Infomaniak kDrive',
			kind: 'form',
			hint: 'Paste an API token created in the Infomaniak Manager (Drive scope).',
			fields: [{ name: 'api_token', label: 'API token', type: 'password' }]
		},
		{
			key: 'webdav',
			label: 'WebDAV',
			kind: 'form',
			hint: 'Any WebDAV server: ownCloud, Koofr, Hetzner Storage Share, Fastmail.',
			fields: [
				{
					name: 'base_url',
					label: 'WebDAV URL',
					type: 'url',
					placeholder: 'https://dav.example.com/files/user'
				},
				{ name: 'username', label: 'Username', type: 'text' },
				{ name: 'password', label: 'Password or app password', type: 'password' }
			]
		}
	];

	type Step = 'provider' | 'auth' | 'folders' | 'done';
	let step = $state<Step>('provider');
	let provider = $state<Provider | null>(null);
	let formValues = $state<Record<string, string>>({});
	let busy = $state(false);
	let error = $state<string | null>(null);

	let source = $state<KnowledgeSourceEntry | null>(null);
	let rootFolders = $state<KnowledgeFolderNode[]>([]);
	let loadingFolders = $state(false);
	const selected = new SvelteMap<string, KnowledgeFolderNode>();
	let createdCount = $state(0);

	// Each time the dialog opens, reset — and if we are resuming after an OAuth
	// redirect, jump straight to the folder picker for the freshly-created source.
	$effect(() => {
		if (!open) return;
		step = resumeSource ? 'folders' : 'provider';
		provider = null;
		formValues = {};
		busy = false;
		error = null;
		source = resumeSource ?? null;
		rootFolders = [];
		selected.clear();
		createdCount = 0;
		if (resumeSource) void loadRootFolders(resumeSource.id);
	});

	function pickProvider(p: Provider) {
		provider = p;
		error = null;
		formValues = {};
		step = 'auth';
	}

	function oauthHref(p: Extract<Provider, { kind: 'oauth' }>): string {
		const returnTo = `${base}/settings/knowledge?wizard_provider=${p.key}`;
		return `/oauth/${p.oauthKey}/authorize?return_to=${encodeURIComponent(returnTo)}`;
	}

	async function connectForm() {
		if (!provider || provider.kind !== 'form') return;
		busy = true;
		error = null;
		const result = await connectKnowledgeSource({
			provider: provider.key,
			authConfig: { ...formValues },
			workspaceId
		});
		busy = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not connect with those credentials.';
			return;
		}
		source = result.data;
		step = 'folders';
		void loadRootFolders(result.data.id);
	}

	async function loadRootFolders(sourceId: string) {
		loadingFolders = true;
		error = null;
		const result = await knowledgeSourceFolders(sourceId, null);
		loadingFolders = false;
		if (result.success) rootFolders = result.data;
		else error = result.errors[0]?.message ?? 'Could not load folders.';
	}

	function onToggle(node: KnowledgeFolderNode, checked: boolean) {
		if (checked) selected.set(node.id, node);
		else selected.delete(node.id);
	}

	async function startSync() {
		if (!source || selected.size === 0) return;
		busy = true;
		error = null;
		const result = await createKnowledgeCollections(source.id, [...selected.values()]);
		busy = false;
		if (!result.success) {
			error = result.errors[0]?.message ?? 'Could not start syncing.';
			return;
		}
		createdCount = result.data.created;
		step = 'done';
		onConnected?.();
	}
</script>

<Dialog.Root bind:open>
	<Dialog.Content class="max-w-lg">
		<Dialog.Header>
			<Dialog.Title>
				{#if step === 'provider'}
					Connect a knowledge source
				{:else if step === 'auth' && provider}
					Connect {provider.label}
				{:else}
					{source?.name ?? 'Choose folders'}
				{/if}
			</Dialog.Title>
		</Dialog.Header>

		{#if error}
			<p class="text-sm text-destructive" data-testid="knowledge-wizard-error">{error}</p>
		{/if}

		{#if step === 'provider'}
			<div class="grid grid-cols-2 gap-2" data-testid="knowledge-provider-picker">
				{#each PROVIDERS as p (p.key)}
					<button
						type="button"
						class="flex flex-col gap-1 rounded-lg border border-input p-3 text-left transition-colors hover:border-primary/60 hover:bg-accent/40"
						data-testid="knowledge-provider-option"
						onclick={() => pickProvider(p)}
					>
						<span class="flex items-center gap-2 text-sm font-medium">
							<Database class="size-4 text-muted-foreground" />
							{p.label}
						</span>
						<span class="text-xs text-muted-foreground">{p.hint}</span>
					</button>
				{/each}
			</div>
		{:else if step === 'auth' && provider}
			<div class="flex flex-col gap-3">
				<p class="text-sm text-muted-foreground">{provider.hint}</p>

				{#if provider.kind === 'oauth'}
					<a
						href={oauthHref(provider)}
						class="inline-flex w-fit items-center gap-2 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90"
						data-testid="knowledge-oauth-connect"
					>
						<ExternalLink class="size-4" />
						Connect with {provider.label}
					</a>
					<button
						type="button"
						class="w-fit text-xs text-muted-foreground hover:underline"
						onclick={() => (step = 'provider')}
					>
						Back
					</button>
				{:else}
					{#each provider.fields as field (field.name)}
						<label class="flex flex-col gap-1">
							<span class="text-xs font-medium text-muted-foreground">{field.label}</span>
							<input
								type={field.type}
								placeholder={field.placeholder ?? ''}
								bind:value={formValues[field.name]}
								class="rounded-md border border-input bg-secondary px-2 py-1.5 text-sm outline-none focus:border-primary/60"
							/>
						</label>
					{/each}
					<div class="flex justify-end gap-2">
						<Button variant="ghost" size="sm" onclick={() => (step = 'provider')}>Back</Button>
						<Button
							size="sm"
							disabled={busy}
							onclick={connectForm}
							data-testid="knowledge-connect-submit"
						>
							{busy ? 'Connecting…' : 'Connect'}
						</Button>
					</div>
				{/if}
			</div>
		{:else if step === 'folders'}
			<div class="flex flex-col gap-3">
				<p class="text-sm text-muted-foreground">
					Choose folders to sync into your knowledge base.
				</p>
				<div
					class="wb-scroll max-h-72 overflow-y-auto rounded-lg border border-input p-1"
					data-testid="knowledge-folder-tree"
				>
					{#if loadingFolders}
						<div class="flex items-center gap-2 p-3 text-sm text-muted-foreground">
							<Loader2 class="size-4 animate-spin" />
							Loading folders…
						</div>
					{:else if rootFolders.length === 0}
						<p class="p-3 text-sm text-muted-foreground">No folders found.</p>
					{:else}
						{#each rootFolders as node (node.id)}
							<KnowledgeFolderNodeView sourceId={source?.id ?? ''} {node} {selected} {onToggle} />
						{/each}
					{/if}
				</div>
				<div class="flex items-center justify-between">
					<span class="text-xs text-muted-foreground">{selected.size} selected</span>
					<Button
						size="sm"
						disabled={busy || selected.size === 0}
						onclick={startSync}
						data-testid="knowledge-sync-submit"
					>
						{busy ? 'Starting…' : 'Sync selected'}
					</Button>
				</div>
			</div>
		{:else if step === 'done'}
			<div class="flex flex-col gap-3">
				<p class="text-sm">
					Syncing {createdCount}
					{createdCount === 1 ? 'folder' : 'folders'}. They'll appear in your knowledge base
					shortly.
				</p>
				<div class="flex justify-end">
					<Button size="sm" onclick={() => (open = false)}>Done</Button>
				</div>
			</div>
		{/if}
	</Dialog.Content>
</Dialog.Root>

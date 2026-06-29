<script lang="ts">
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { page } from '$app/state';
	import { History, Plus, Search, Trash2, Upload } from '@lucide/svelte';
	import { uploadFile } from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';
	import { searchOverlay } from '$lib/stores/search-overlay.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';
	import AgentsNav from './agents-nav.svelte';
	import BrainNav from './brain-nav.svelte';
	import ChatNav from './chat-nav.svelte';
	import FilesNav from './files-nav.svelte';
	import NewResourceDialog, { type NewResourceKind } from './new-resource-dialog.svelte';
	import PromptsNav from './prompts-nav.svelte';
	import SettingsNav from './settings-nav.svelte';
	import WorkspaceSwitcher from './workspace-switcher.svelte';

	// Settings reuses the main nav pane for its section list (no second sidebar).
	const inSettings = $derived(page.url.pathname.startsWith(`${base}/settings`));

	let fileInput = $state<HTMLInputElement | null>(null);

	// Prompt/agent/brain creation share one shadcn dialog, keyed by kind.
	let createKind = $state<NewResourceKind>('prompt');
	let createOpen = $state(false);

	function openCreate(kind: NewResourceKind) {
		createKind = kind;
		createOpen = true;
	}

	function onKeydown(event: KeyboardEvent) {
		if (event.key === 'k' && (event.metaKey || event.ctrlKey)) {
			event.preventDefault();
			searchOverlay.open = true;
		}
	}

	// Classic parity: New chat opens the landing page (animated logo, greeting,
	// composer). The conversation isn't created until the first message is sent.
	function newConversation() {
		void goto(`${base}/chat`);
	}

	let uploading = $state(false);
	let uploadError = $state<string | null>(null);

	async function uploadFiles(selected: FileList) {
		uploading = true;
		uploadError = null;
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		for (const file of Array.from(selected)) {
			// Channel folder/file hints refresh the browser after each upload.
			const result = await uploadFile(file, workspaceId ? { workspaceId } : {});
			if (!result.success) uploadError = result.errors[0]?.message ?? 'Upload failed';
		}
		uploading = false;
	}
</script>

<svelte:window onkeydown={onKeydown} />

<Sidebar.Provider class="!min-h-0 w-auto shrink-0" style="--sidebar-width: 18rem">
	<Sidebar.Root collapsible="none" class="border-r bg-background" data-testid="nav-pane">
		<Sidebar.Header class="gap-2">
			<WorkspaceSwitcher />

			<!-- Search opens the classic global overlay (also via ⌘K). -->
			<Sidebar.Menu>
				<Sidebar.MenuItem>
					<Sidebar.MenuButton data-testid="nav-search" onclick={() => (searchOverlay.open = true)}>
						<Search class="text-muted-foreground" />
						<span>Search</span>
					</Sidebar.MenuButton>
					<Sidebar.MenuBadge class="text-[10px] text-muted-foreground">⌘K</Sidebar.MenuBadge>
				</Sidebar.MenuItem>
			</Sidebar.Menu>

			<!-- Mode-specific primary action. Hidden in settings, where the pane
			     shows the settings section list instead. -->
			{#if !inSettings}
				<Sidebar.Menu>
					<Sidebar.MenuItem>
						{#if workbench.mode === 'chat'}
							<Sidebar.MenuButton onclick={() => newConversation()} data-testid="new-conversation">
								<Plus class="text-muted-foreground" />
								<span>New chat</span>
							</Sidebar.MenuButton>
						{:else if workbench.mode === 'brain'}
							<Sidebar.MenuButton onclick={() => openCreate('brain')} data-testid="new-brain">
								<Plus class="text-muted-foreground" />
								<span>New brain</span>
							</Sidebar.MenuButton>
						{:else if workbench.mode === 'files'}
							<Sidebar.MenuButton
								class={uploading ? 'pointer-events-none opacity-50' : ''}
								onclick={() => fileInput?.click()}
								data-testid="files-upload"
							>
								{#if uploading}
									<span
										class="size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent"
									></span>
									<span>Uploading…</span>
								{:else}
									<Upload class="text-muted-foreground" />
									<span>Upload files</span>
								{/if}
							</Sidebar.MenuButton>
							{#if uploadError}
								<p class="px-2 pt-1 text-xs text-destructive">{uploadError}</p>
							{/if}
							<input
								bind:this={fileInput}
								type="file"
								multiple
								class="hidden"
								onchange={(event) => {
									const files = event.currentTarget.files;
									if (files && files.length > 0) void uploadFiles(files);
									event.currentTarget.value = '';
								}}
							/>
						{:else if workbench.mode === 'prompts'}
							<Sidebar.MenuButton onclick={() => openCreate('prompt')} data-testid="new-prompt">
								<Plus class="text-muted-foreground" />
								<span>New prompt</span>
							</Sidebar.MenuButton>
						{:else if workbench.mode === 'agents'}
							<Sidebar.MenuButton onclick={() => openCreate('agent')} data-testid="new-agent">
								<Plus class="text-muted-foreground" />
								<span>New agent</span>
							</Sidebar.MenuButton>
						{/if}
					</Sidebar.MenuItem>
				</Sidebar.Menu>
			{/if}
		</Sidebar.Header>

		<Sidebar.Content class="wb-scroll">
			{#if inSettings}
				<SettingsNav />
			{:else if workbench.mode === 'chat'}
				<ChatNav />
			{:else if workbench.mode === 'files'}
				<FilesNav />
			{:else if workbench.mode === 'brain'}
				<BrainNav />
			{:else if workbench.mode === 'prompts'}
				<PromptsNav />
			{:else if workbench.mode === 'agents'}
				<AgentsNav />
			{/if}
		</Sidebar.Content>

		<!-- Secondary items, per mode (sidebar-15's bottom nav section). -->
		{#if !inSettings && (workbench.mode === 'chat' || workbench.mode === 'brain' || workbench.mode === 'files')}
			<Sidebar.Footer class="border-t">
				<Sidebar.Menu>
					<Sidebar.MenuItem>
						{#if workbench.mode === 'chat'}
							<Sidebar.MenuButton>
								{#snippet child({ props })}
									<a {...props} href="{base}/history" data-testid="nav-show-history">
										<History class="text-muted-foreground" />
										<span>Show history</span>
									</a>
								{/snippet}
							</Sidebar.MenuButton>
						{:else if workbench.mode === 'brain'}
							<Sidebar.MenuButton data-testid="brain-trash-link">
								{#snippet child({ props })}
									<a {...props} href="{base}/brain/trash">
										<Trash2 class="text-muted-foreground" />
										<span>Trash</span>
									</a>
								{/snippet}
							</Sidebar.MenuButton>
						{:else}
							<Sidebar.MenuButton data-testid="files-scope-trash">
								{#snippet child({ props })}
									<a {...props} href="{base}/files?scope=trash">
										<Trash2 class="text-muted-foreground" />
										<span>Trash</span>
									</a>
								{/snippet}
							</Sidebar.MenuButton>
						{/if}
					</Sidebar.MenuItem>
				</Sidebar.Menu>
			</Sidebar.Footer>
		{/if}
	</Sidebar.Root>
</Sidebar.Provider>
<NewResourceDialog kind={createKind} bind:open={createOpen} />

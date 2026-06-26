<script lang="ts">
	import { page } from '$app/state';
	import { base } from '$app/paths';
	import { Clock, Files, Folder, HardDrive, Star, Users } from '@lucide/svelte';
	import {
		creditStatus,
		myKnowledgeCollections,
		workspaceKnowledgeCollections,
		type CreditStatus,
		type KnowledgeCollectionSummary
	} from '$lib/ash/api';
	import { formatFileSize } from '$lib/files/format';
	import { session } from '$lib/stores/session.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';

	const scopes = $derived([
		{ key: null, label: 'My files', icon: Folder },
		{ key: 'recent', label: 'Recent', icon: Clock },
		{ key: 'templates', label: 'Templates', icon: Star },
		...(session.user?.currentWorkspaceId
			? [{ key: 'shared', label: 'Shared with me', icon: Users }]
			: [])
	]);

	// Connected sources (classic parity): synced knowledge collections.
	let collections = $state<KnowledgeCollectionSummary[]>([]);

	// Storage usage meter (classic files nav footer).
	let usage = $state<CreditStatus | null>(null);

	$effect(() => {
		void creditStatus().then((result) => {
			if (result.success) usage = result.data;
		});
	});

	$effect(() => {
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		const request = workspaceId
			? workspaceKnowledgeCollections(workspaceId)
			: myKnowledgeCollections();
		void request.then((result) => {
			if (result.success) collections = result.data ?? [];
		});
	});
</script>

<Sidebar.Group data-testid="files-nav">
	<Sidebar.GroupLabel>Library</Sidebar.GroupLabel>
	<Sidebar.GroupContent>
		<Sidebar.Menu>
			{#each scopes as entry (entry.label)}
				{@const href = entry.key ? `${base}/files?scope=${entry.key}` : `${base}/files`}
				{@const active =
					page.url.pathname.endsWith('/files') &&
					(page.url.searchParams.get('scope') ?? null) === entry.key}
				<Sidebar.MenuItem>
					<Sidebar.MenuButton isActive={active} data-testid="files-scope-{entry.key ?? 'my_files'}">
						{#snippet child({ props })}
							<a {href} {...props}>
								<entry.icon class="text-muted-foreground" />
								<span>{entry.label}</span>
							</a>
						{/snippet}
					</Sidebar.MenuButton>
				</Sidebar.MenuItem>
			{/each}
		</Sidebar.Menu>
	</Sidebar.GroupContent>
</Sidebar.Group>

{#if collections.length > 0}
	<Sidebar.Group data-testid="files-knowledge-nav">
		<Sidebar.GroupLabel>Connected sources</Sidebar.GroupLabel>
		<Sidebar.GroupContent>
			<Sidebar.Menu>
				{#each collections as collection (collection.id)}
					<Sidebar.MenuItem>
						<Sidebar.MenuButton
							isActive={page.url.pathname.endsWith(`/files/knowledge/${collection.id}`)}
							data-testid="files-knowledge-collection"
						>
							{#snippet child({ props })}
								<a {...props} href="{base}/files/knowledge/{collection.id}">
									<Files class="text-muted-foreground" />
									<span class="min-w-0 flex-1 truncate">{collection.name}</span>
									{#if collection.syncStatus === 'error'}
										<span class="size-1.5 shrink-0 rounded-full bg-destructive" title="Sync error"
										></span>
									{:else if collection.syncStatus === 'syncing'}
										<span class="size-1.5 shrink-0 rounded-full bg-warning" title="Syncing"></span>
									{/if}
								</a>
							{/snippet}
						</Sidebar.MenuButton>
						<Sidebar.MenuBadge class="text-[10px] text-muted-foreground">
							{collection.itemCount}
						</Sidebar.MenuBadge>
					</Sidebar.MenuItem>
				{/each}
			</Sidebar.Menu>
		</Sidebar.GroupContent>
	</Sidebar.Group>
{/if}

{#if usage && usage.storageLimit}
	{@const percent = Math.min(100, (usage.storageUsed / usage.storageLimit) * 100)}
	<Sidebar.Group data-testid="files-storage-meter">
		<Sidebar.GroupContent class="px-2 pb-1">
			<div class="flex items-center gap-1.5 text-[11px] text-muted-foreground">
				<HardDrive class="size-3 shrink-0" />
				<span class="min-w-0 flex-1 truncate">
					{formatFileSize(usage.storageUsed)} of {formatFileSize(usage.storageLimit)}
				</span>
			</div>
			<div class="mt-1 h-1.5 w-full overflow-hidden rounded-full bg-secondary">
				<div
					class="h-full {percent >= 90
						? 'bg-destructive'
						: percent >= 75
							? 'bg-warning'
							: 'bg-primary'}"
					style="width: {percent}%"
				></div>
			</div>
		</Sidebar.GroupContent>
	</Sidebar.Group>
{/if}

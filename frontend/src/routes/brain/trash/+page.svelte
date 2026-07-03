<script lang="ts">
	import { FileText, Undo2 } from '@lucide/svelte';
	import { restoreBrainPage, trashedBrainPages, type PageTreeNode } from '$lib/ash/api';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import { workbench } from '$lib/stores/workbench.svelte';

	let pages = $state<PageTreeNode[]>([]);
	let loading = $state(true);

	// One-shot: deep links sync the nav once; afterwards the mode strip
	// may switch the nav freely without this route forcing it back.
	let modeSynced = false;
	$effect(() => {
		if (modeSynced || !workbench.session) return;
		modeSynced = true;
		if (workbench.mode !== 'brain') void workbench.setMode('brain');
	});

	$effect(() => {
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		loading = true;
		void trashedBrainPages(workspaceId).then((result) => {
			if (result.success) pages = result.data;
			loading = false;
		});
	});

	async function restore(id: string) {
		const result = await restoreBrainPage(id);
		if (result.success) {
			pages = pages.filter((page) => page.id !== id);
			void brainNav.reloadTree();
		}
	}
</script>

<svelte:head>
	<title>Magus — Brain trash</title>
</svelte:head>

<div class="flex h-full min-h-0 flex-col" data-testid="brain-trash">
	<header class="flex min-h-11 items-baseline gap-2 border-b py-2 pr-6 pl-14 md:pl-6">
		<h1 class="text-sm font-semibold">Trash</h1>
		<p class="min-w-0 truncate text-xs text-muted-foreground">
			Trashed pages are deleted permanently after 30 days.
		</p>
	</header>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-4">
		{#if loading}
			<div class="space-y-2">
				{#each [1, 2, 3] as i (i)}
					<div class="h-9 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if pages.length === 0}
			<p class="pt-8 text-center text-sm text-muted-foreground">Trash is empty.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each pages as page (page.id)}
					<li
						class="group flex items-center gap-3 rounded-md px-2 py-1.5 transition-colors hover:bg-accent/40"
						data-testid="trashed-page"
					>
						{#if page.icon}
							<span class="shrink-0 leading-none">{page.icon}</span>
						{:else}
							<FileText class="size-4 shrink-0 text-muted-foreground" />
						{/if}
						<span class="min-w-0 flex-1 truncate text-sm">{page.title ?? 'Untitled'}</span>
						<button
							type="button"
							class="flex shrink-0 items-center gap-1.5 rounded-md px-2 py-1 text-xs text-secondary-foreground opacity-0 transition-opacity hover:bg-accent group-hover:opacity-100"
							data-testid="restore-page"
							onclick={() => void restore(page.id)}
						>
							<Undo2 class="size-3.5" />
							<span>Restore</span>
						</button>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>

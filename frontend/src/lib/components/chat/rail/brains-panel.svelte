<script lang="ts">
	import { onMount } from 'svelte';
	import { Brain, ChevronDown, ChevronRight, FileText } from '@lucide/svelte';
	import {
		brainPageChildren,
		myBrains,
		rootBrainPages,
		workspaceBrains,
		type BrainSummary,
		type CompanionSpec,
		type PageTreeNode
	} from '$lib/ash/api';
	import { session } from '$lib/stores/session.svelte';
	import { SvelteMap, SvelteSet } from 'svelte/reactivity';

	let {
		onCompanionRequest
	}: {
		onCompanionRequest?: (spec: CompanionSpec) => void;
	} = $props();

	let brains = $state<BrainSummary[]>([]);
	let search = $state('');
	let loading = $state(true);

	// Lazily loaded page trees: brain id → roots, page id → children.
	const expandedBrains = new SvelteSet<string>();
	const expandedPages = new SvelteSet<string>();
	const rootsByBrain = new SvelteMap<string, PageTreeNode[]>();
	const childrenByPage = new SvelteMap<string, PageTreeNode[]>();

	onMount(() => {
		// Scope to the active workspace, mirroring the shell brain nav
		// (brain-nav.svelte.ts): workspace query when one is selected, personal
		// otherwise, then filter — workspaceBrains also returns shared personals.
		const workspaceId = session.user?.currentWorkspaceId ?? null;
		const request = workspaceId ? workspaceBrains(workspaceId) : myBrains();
		void request.then((result) => {
			if (result.success) {
				brains = result.data.filter((brain) => (brain.workspaceId ?? null) === workspaceId);
			}
			loading = false;
		});
	});

	const visibleBrains = $derived.by(() => {
		const query = search.trim().toLowerCase();
		if (query === '') return brains;
		return brains.filter((brain) => brain.title.toLowerCase().includes(query));
	});

	function toggleBrain(brainId: string) {
		if (expandedBrains.has(brainId)) {
			expandedBrains.delete(brainId);
			return;
		}
		expandedBrains.add(brainId);
		if (!rootsByBrain.has(brainId)) {
			void rootBrainPages(brainId).then((result) => {
				if (result.success) rootsByBrain.set(brainId, result.data);
			});
		}
	}

	function togglePage(pageId: string) {
		if (expandedPages.has(pageId)) {
			expandedPages.delete(pageId);
			return;
		}
		expandedPages.add(pageId);
		if (!childrenByPage.has(pageId)) {
			void brainPageChildren(pageId).then((result) => {
				if (result.success) childrenByPage.set(pageId, result.data);
			});
		}
	}

	function openPage(pageId: string) {
		onCompanionRequest?.({ type: 'brain_page', id: pageId });
	}
</script>

{#snippet pageRow(page: PageTreeNode, depth: number)}
	{@const children = childrenByPage.get(page.id)}
	<li>
		<span class="flex items-center" style="padding-left: {depth * 12}px">
			<button
				type="button"
				class="shrink-0 rounded p-0.5 text-muted-foreground hover:text-foreground"
				aria-label={expandedPages.has(page.id) ? 'Collapse' : 'Expand'}
				onclick={() => togglePage(page.id)}
			>
				{#if expandedPages.has(page.id)}
					<ChevronDown class="size-3" />
				{:else}
					<ChevronRight class="size-3" />
				{/if}
			</button>
			<button
				type="button"
				class="flex min-w-0 flex-1 items-center gap-1.5 rounded-md px-1.5 py-1 text-left text-xs transition-colors hover:bg-accent/60"
				data-testid="rail-brain-page"
				onclick={() => openPage(page.id)}
			>
				{#if page.icon}
					<span class="shrink-0 text-sm leading-none" aria-hidden="true">{page.icon}</span>
				{:else}
					<FileText class="size-3.5 shrink-0 text-muted-foreground" />
				{/if}
				<span class="min-w-0 truncate">{page.title ?? 'Untitled'}</span>
			</button>
		</span>
		{#if expandedPages.has(page.id) && children}
			{#if children.length === 0}
				<p
					class="py-0.5 text-[11px] text-muted-foreground"
					style="padding-left: {depth * 12 + 36}px"
				>
					No subpages
				</p>
			{:else}
				<ul>
					{#each children as child (child.id)}
						{@render pageRow(child, depth + 1)}
					{/each}
				</ul>
			{/if}
		{/if}
	</li>
{/snippet}

<div class="flex min-h-0 flex-1 flex-col" data-testid="rail-brains-panel">
	<div class="border-b p-2.5">
		<input
			type="search"
			bind:value={search}
			placeholder="Search brains…"
			class="w-full rounded-md border border-input bg-secondary px-2 py-1.5 text-xs outline-none focus:border-primary/60"
		/>
	</div>

	<div class="wb-scroll min-h-0 flex-1 overflow-y-auto p-1.5">
		{#if loading}
			<div class="space-y-2 p-1">
				{#each [1, 2, 3] as i (i)}
					<div class="h-10 animate-pulse rounded-md bg-muted"></div>
				{/each}
			</div>
		{:else if visibleBrains.length === 0}
			<p class="p-2 text-xs text-muted-foreground">No brains yet.</p>
		{:else}
			<ul class="space-y-0.5">
				{#each visibleBrains as brain (brain.id)}
					{@const roots = rootsByBrain.get(brain.id)}
					<li>
						<button
							type="button"
							class="flex w-full items-center gap-1.5 rounded-md px-1.5 py-1.5 text-left transition-colors hover:bg-accent/60"
							data-testid="rail-brain"
							onclick={() => toggleBrain(brain.id)}
						>
							{#if expandedBrains.has(brain.id)}
								<ChevronDown class="size-3 shrink-0 text-muted-foreground" />
							{:else}
								<ChevronRight class="size-3 shrink-0 text-muted-foreground" />
							{/if}
							{#if brain.icon}
								<span class="shrink-0 text-sm leading-none" aria-hidden="true">{brain.icon}</span>
							{:else}
								<Brain class="size-3.5 shrink-0 text-muted-foreground" />
							{/if}
							<span class="min-w-0 truncate text-xs font-medium">{brain.title}</span>
						</button>
						{#if expandedBrains.has(brain.id)}
							{#if !roots}
								<p class="py-1 pl-9 text-[11px] text-muted-foreground">Loading…</p>
							{:else if roots.length === 0}
								<p class="py-1 pl-9 text-[11px] text-muted-foreground">No pages yet</p>
							{:else}
								<ul>
									{#each roots as page (page.id)}
										{@render pageRow(page, 1)}
									{/each}
								</ul>
							{/if}
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	</div>
</div>

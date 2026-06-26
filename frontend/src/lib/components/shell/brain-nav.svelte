<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { base } from '$app/paths';
	import { Brain, ChevronRight, FileText, Plus, Settings } from '@lucide/svelte';
	import { createBrainPage, type BrainSummary, type PageTreeNode } from '$lib/ash/api';
	import { brainNav } from '$lib/stores/brain-nav.svelte';
	import { session } from '$lib/stores/session.svelte';
	import * as Sidebar from '$lib/components/ui/sidebar';
	import BrainSettingsDialog from '$lib/components/brain/brain-settings-dialog.svelte';

	let { query = '' }: { query?: string } = $props();

	let settingsBrainId = $state<string | null>(null);
	let settingsOpen = $state(false);
	// Derive from the store so a share toggle (which doesn't close the dialog)
	// reflects the updated brain immediately.
	const settingsBrain = $derived(
		brainNav.brains.find((brain) => brain.id === settingsBrainId) ?? null
	);

	function openSettings(brain: BrainSummary) {
		settingsBrainId = brain.id;
		settingsOpen = true;
	}

	$effect(() => {
		void brainNav.load(session.user?.currentWorkspaceId ?? null);
	});

	const matches = (brain: BrainSummary) =>
		query === '' || brain.title.toLowerCase().includes(query.toLowerCase());

	const shared = $derived(brainNav.shared.filter(matches));
	const personal = $derived(brainNav.personal.filter(matches));
	const all = $derived(brainNav.brains.filter(matches));

	async function newPage(brainId: string, parentPageId: string | null = null) {
		const result = await createBrainPage({ brainId, title: 'Untitled', parentPageId });
		if (result.success) {
			await brainNav.expandBrain(brainId, true);
			if (parentPageId) await brainNav.expandPage(parentPageId, true);
			await goto(`${base}/brain/page/${result.data.id}`);
		}
	}
</script>

{#snippet pageRow(node: PageTreeNode, brainId: string)}
	{@const expanded = brainNav.children[node.id] !== undefined}
	<Sidebar.MenuItem>
		<!-- Composite row (expand + link + action), so no MenuButton: its
		     child slot is for a single interactive element and would clip
		     this multi-control layout with h-8/overflow-clip. The hover group
		     lives HERE, not on the <li> — expanded children render inside the
		     same <li>, so an li-scoped group would flip every nested row. -->
		<div
			class="group/label flex items-center gap-1 rounded-md p-2 py-1.5 text-sm transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground {page.url.pathname.endsWith(
				`/brain/page/${node.id}`
			)
				? 'bg-sidebar-accent font-medium text-sidebar-accent-foreground'
				: ''}"
		>
			<!-- Notion-style: the page icon swaps to the expand chevron on row
			     hover instead of a permanently visible chevron column. -->
			<button
				type="button"
				class="flex size-5 shrink-0 items-center justify-center rounded text-muted-foreground hover:bg-accent hover:text-foreground"
				aria-label={expanded ? 'Collapse' : 'Expand'}
				onclick={() => {
					if (expanded) brainNav.collapsePage(node.id);
					else void brainNav.expandPage(node.id);
				}}
			>
				<span class="flex items-center justify-center group-hover/label:hidden">
					{#if node.icon}
						<span class="text-xs leading-none">{node.icon}</span>
					{:else}
						<FileText class="size-3.5" />
					{/if}
				</span>
				<ChevronRight
					class="hidden size-3 transition-transform group-hover/label:block {expanded
						? 'rotate-90'
						: ''}"
				/>
			</button>
			<a href="{base}/brain/page/{node.id}" class="flex min-w-0 flex-1 items-center gap-1.5">
				<span class="min-w-0 truncate text-sm">{node.title ?? 'Untitled'}</span>
			</a>
			<button
				type="button"
				class="shrink-0 rounded p-0.5 text-muted-foreground opacity-0 transition-opacity hover:text-foreground group-hover/label:opacity-100"
				aria-label="New sub-page"
				title="New sub-page"
				onclick={() => void newPage(brainId, node.id)}
			>
				<Plus class="size-3" />
			</button>
		</div>
		{#if expanded}
			<Sidebar.MenuSub class="mr-0 pr-0">
				{#each brainNav.children[node.id] ?? [] as child (child.id)}
					{@render pageRow(child, brainId)}
				{/each}
				{#if (brainNav.children[node.id] ?? []).length === 0}
					<li class="py-1 pl-2 text-xs text-muted-foreground">No sub-pages</li>
				{/if}
			</Sidebar.MenuSub>
		{/if}
	</Sidebar.MenuItem>
{/snippet}

{#snippet brainRow(brain: BrainSummary)}
	{@const expanded = brainNav.isBrainExpanded(brain.id)}
	<Sidebar.MenuItem data-testid="brain-root">
		<Sidebar.MenuButton
			class="group/label"
			onclick={() =>
				expanded ? brainNav.collapseBrain(brain.id) : void brainNav.expandBrain(brain.id)}
		>
			<!-- Same icon↔chevron swap as page rows. -->
			<span class="flex size-4 shrink-0 items-center justify-center">
				<span class="flex items-center justify-center group-hover/label:hidden">
					{#if brain.icon}
						<span class="text-sm leading-none">{brain.icon}</span>
					{:else}
						<Brain class="size-4 text-muted-foreground" />
					{/if}
				</span>
				<ChevronRight
					class="hidden size-4 transition-transform group-hover/label:block {expanded
						? 'rotate-90'
						: ''}"
				/>
			</span>
			<span class="min-w-0 flex-1 truncate font-medium">{brain.title}</span>
		</Sidebar.MenuButton>
		<Sidebar.MenuAction
			showOnHover
			class="end-7"
			title="Brain settings"
			data-testid="brain-settings"
			onclick={() => openSettings(brain)}
		>
			<Settings />
			<span class="sr-only">Settings</span>
		</Sidebar.MenuAction>
		<Sidebar.MenuAction
			showOnHover
			title="New page in {brain.title}"
			data-testid="brain-new-page"
			onclick={() => void newPage(brain.id)}
		>
			<Plus />
			<span class="sr-only">New page</span>
		</Sidebar.MenuAction>
		{#if expanded}
			<Sidebar.MenuSub class="mr-0 pr-0">
				{#each brainNav.roots[brain.id] ?? [] as node (node.id)}
					{@render pageRow(node, brain.id)}
				{/each}
				{#if (brainNav.roots[brain.id] ?? []).length === 0}
					<li class="py-1 pl-2 text-xs text-muted-foreground">No pages yet</li>
				{/if}
			</Sidebar.MenuSub>
		{/if}
	</Sidebar.MenuItem>
{/snippet}

{#snippet section(title: string, brains: BrainSummary[], emptyLabel: string)}
	<Sidebar.Group>
		<Sidebar.GroupLabel>{title}</Sidebar.GroupLabel>
		<Sidebar.GroupContent>
			{#if brains.length === 0}
				<p class="px-2 pb-1 text-xs text-muted-foreground">{emptyLabel}</p>
			{:else}
				<Sidebar.Menu>
					{#each brains as brain (brain.id)}
						{@render brainRow(brain)}
					{/each}
				</Sidebar.Menu>
			{/if}
		</Sidebar.GroupContent>
	</Sidebar.Group>
{/snippet}

<div data-testid="brain-nav" class="contents">
	{#if brainNav.loading}
		<Sidebar.Group>
			<Sidebar.GroupContent>
				<Sidebar.Menu>
					{#each [1, 2, 3] as i (i)}
						<Sidebar.MenuItem>
							<Sidebar.MenuSkeleton />
						</Sidebar.MenuItem>
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{:else if session.user?.currentWorkspaceId}
		{@render section('Shared', shared, 'No shared brains')}
		{@render section('Personal', personal, 'No brains yet')}
	{:else if all.length === 0}
		<p class="p-4 pt-3 text-sm text-muted-foreground">
			{query ? 'No matches.' : 'Create a brain to start.'}
		</p>
	{:else}
		<Sidebar.Group>
			<Sidebar.GroupContent>
				<Sidebar.Menu data-testid="brain-page-tree">
					{#each all as brain (brain.id)}
						{@render brainRow(brain)}
					{/each}
				</Sidebar.Menu>
			</Sidebar.GroupContent>
		</Sidebar.Group>
	{/if}
</div>

<BrainSettingsDialog brain={settingsBrain} bind:open={settingsOpen} />
